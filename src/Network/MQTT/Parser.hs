{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Network.MQTT.Parser
  ( parsePacket
  , remainingLength
  ) where

import Prelude hiding (take)

import Network.MQTT.Packet

import Control.Monad (when)
import Data.Maybe (isNothing)

import Data.Bits ((.&.), (.|.), shiftR, shiftL, testBit, clearBit)
import Data.Word (Word32, Word16, Word8)

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS

import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8')

import Data.Attoparsec.ByteString (Parser, anyWord8, word8, take, string, count, (<?>))
import Data.Attoparsec.Binary (anyWord16be)

import qualified Control.Monad.Trans as T
import Control.Monad.State.Strict (MonadState, StateT, evalStateT, get, modify')

--------------------------------------------------------------------------------

-- | A parser monad that tracks remaining length.
--
-- It is used for complex packet types where it's hard to verify
-- remaining length is correct beforehand.
--
-- Parser fails if remaining length is not enough.
newtype ParserWithLength a =
  ParserWithLength (StateT Word32 Parser a)
  deriving (Functor, Applicative, Monad, MonadState Word32)

runParserWithLength :: Word32 -> ParserWithLength a -> Parser a
runParserWithLength l (ParserWithLength p) = evalStateT p l

-- | Attaches length information to the normal parser.
withLength :: Word32 -> Parser a -> ParserWithLength a
withLength len p = do
  curLen <- get
  ParserWithLength . T.lift $ assert (len <= curLen) "Length is not enough to parse message"
  modify' (subtract len)
  ParserWithLength $ T.lift p

anyWord16be' :: ParserWithLength Word16
anyWord16be' = withLength 2 anyWord16be

anyWord8' :: ParserWithLength Word8
anyWord8' = withLength 1 anyWord8

take' :: Int -> ParserWithLength ByteString
take' len = withLength (fromIntegral len) (take len)

--------------------------------------------------------------------------------

-- | An attoparsec parser for MQTT 3.1.1 packet.
--
-- The parser is fully compliant with the standard. If the parser
-- fails that means the message is ill-formatted and the connection
-- MUST be closed without sending any packet.
--
-- Note that there are packets that can not be processed but require a
-- response (e.g, wrong protocol level). In that case, parser succeeds
-- and that's a responsibility of the higher-level logic to examine
-- the packet and reply accordingly.
parsePacket :: Parser Packet
parsePacket = do
  byte1 <- anyWord8
  let packetType = byte1 `shiftR` 4
      flags = byte1 .&. 0x0f

  assert (packetType > 0 && packetType < 15)
    "Packet type should be between 1 and 14"

  case packetType of
    1  -> CONNECT     <$> parseConnect     flags
    2  -> CONNACK     <$> parseConnack     flags
    3  -> PUBLISH     <$> parsePublish     flags
    4  -> PUBACK      <$> parsePuback      flags
    5  -> PUBREC      <$> parsePubrec      flags
    6  -> PUBREL      <$> parsePubrel      flags
    7  -> PUBCOMP     <$> parsePubcomp     flags
    8  -> SUBSCRIBE   <$> parseSubscribe   flags
    9  -> SUBACK      <$> parseSuback      flags
    10 -> UNSUBSCRIBE <$> parseUnsubscribe flags
    11 -> UNSUBACK    <$> parseUnsuback    flags
    12 -> PINGREQ     <$> parsePingreq     flags
    13 -> PINGRESP    <$> parsePingresp    flags
    14 -> DISCONNECT  <$> parseDisconnect  flags
    _  -> error "This could not happen"

-- | Parses remaining length of the packet.
--
-- This function is for internal use only and was exported for proper
-- testing. It may be hidden in the future.
remainingLength :: Parser Word32
remainingLength = foldr1 (\x acc -> (acc `shiftL` 7) .|. x) <$> takeBytes 0
  where
    -- Takes bytes for interpreting as Remaining Length field.
    --
    -- It is guaranteed to fail as soon as it determines the field
    -- doesn't conform to the standard (i.e. it will never read more
    -- than 4 bytes).
    takeBytes :: Int -> Parser [Word32]
    takeBytes i = do
      assert (i < 4)
        "Remaining Length fields can be 4 bytes-long at max"
      byte <- fromIntegral <$> anyWord8
      if byte `testBit` 7 then
        ((byte `clearBit` 7) :) <$> takeBytes (i + 1)
      else
        return [byte]

assert :: Bool -> String -> Parser ()
assert cond reason = when (not cond) $ fail reason

parseConnect :: Word8 -> Parser ConnectPacket
parseConnect flags = do
  assert (flags == 0) "Reserved bits MUST be set to zero"
  len <- remainingLength
  assert (len >= 10) "Remaining length is too short"

  _ <- string $ BS.pack [0x00, 0x04, 0x4d, 0x51, 0x54, 0x54]

  protocolLevel <- anyWord8

  cflags <- anyWord8
  let userNameFlag = cflags `testBit` 7
      passwordFlag = cflags `testBit` 6
      willRetain   = cflags `testBit` 5
      willQoS      = cflags `shiftR` 3 .&. 0x03
      willFlag     = cflags `testBit` 2
      cleanSession = cflags `testBit` 1
      reservedBit  = cflags `testBit` 0

  assert (not reservedBit) "Reserved bit MUST be set to zero"
  assert (not $ not userNameFlag && passwordFlag)
    "MQTT-3.1.2-22: If the User Name Flag is set to 0, the Password Flag MUST be set to 0"
  assert (not $ not willFlag && (willQoS /= 0 || willRetain))
    "MQTT-3.1.2-11: If the Will Flag is set to 0 the Will QoS and Will Retain fields in the Connect Flags MUST be set to zero"
  assert (willQoS /= 3)
    "MQTT-3.1.2-14: If the Will Flag is set to 1, the value of Will QoS can be 0 (0x00), 1 (0x01), or 2 (0x02). It MUST NOT be 3 (0x03)"

  keepAlive <- anyWord16be

  runParserWithLength (len - 10) $ do
    clientId <- parseClientIdentifier
    willMsg <- maybeM willFlag $ do
      willTopic <- withLength 0 . toTopicName =<< parseByteString
      willMessage <- parseByteString
      return $ Message willTopic willMessage (toEnum $ fromIntegral willQoS) willRetain
    userName <- maybeM userNameFlag (UserName <$> parseText)
    password <- maybeM passwordFlag (Password <$> parseByteString)

    return ConnectPacket{ connectClientIdentifier = clientId
                        , connectProtocolLevel = protocolLevel
                        , connectWillMsg = willMsg
                        , connectUserName = userName
                        , connectPassword = password
                        , connectCleanSession = cleanSession
                        , connectKeepAlive = keepAlive
                        }

parseConnack :: Word8 -> Parser ConnackPacket
parseConnack flags = do
  assert (flags == 0) "Reserved bits MUST be set to zero"
  _ <- word8 0x02 <?> "CONNACK Remaining Length MUST be 2"
  acknowledgeFlags <- anyWord8
  assert (acknowledgeFlags .&. 0xfe == 0x0)
    "Reserved bits in Connect Acknowledge Flags MUST be set to zero"
  let sessionPresent = acknowledgeFlags == 0x01
  returnCode <- anyWord8
  assert (returnCode <= 5) "Unknown Connect Return code"
  let returnCode' = case returnCode of
                      0x00 -> Accepted
                      0x01 -> UnacceptableProtocol
                      0x02 -> IdentifierRejected
                      0x03 -> ServerUnavailable
                      0x04 -> BadUserNameOrPassword
                      0x05 -> NotAuthorized
                      _    -> error "This could not happen"
  assert (returnCode' == Accepted || not sessionPresent)
    "MQTT-3.2.2-4: If a server sends a CONNACK packet containing a non-zero return code it MUST set Session Present to 0"
  return $ ConnackPacket sessionPresent returnCode'

parsePublish :: Word8 -> Parser PublishPacket
parsePublish flags = do
  let dupFlag     = flags `testBit` 3
      qosLevel    = flags `shiftR` 1 .&. 0x03
      retainFlag  = flags `testBit` 0
      packetIdLen = if qosLevel /= 0 then 2 else 0

  assert (qosLevel /= 3)
    "MQTT-3.3.1-4: A PUBLISH Packet MUST NOT have both QoS bits set to 1"
  assert (not (qosLevel == 0 && dupFlag))
    "MQTT-3.3.1-2: The DUP flags MUST be set to 0 for all QoS 0 messages"

  len <- fromIntegral <$> remainingLength
  assert (len >= 2 + packetIdLen)
    "Remaining length is too short"

  topicLen <- fromIntegral <$> anyWord16be

  assert (len >= 2 + topicLen + packetIdLen)
    "Remaining length is not enough to read message"

  let payloadLength = len - 2 - topicLen - packetIdLen

  topic <- toTopicName =<< take topicLen

  packetId <- maybeM (qosLevel /= 0) packetIdentifier

  payload <- take payloadLength

  return PublishPacket
    { publishDup = dupFlag
    , publishMessage = Message topic payload (toEnum $ fromIntegral qosLevel) retainFlag
    , publishPacketIdentifier = packetId
    }

parsePuback :: Word8 -> Parser PubackPacket
parsePuback flags = do
  assert (flags == 0x00) "Reserved bits MUST be set to zero"
  _ <- word8 0x02 <?> "Remaining length MUST be 2"
  PubackPacket <$> packetIdentifier

parsePubrec :: Word8 -> Parser PubrecPacket
parsePubrec flags = do
  assert (flags == 0x00) "Reserved bits MUST be set to zero"
  _ <- word8 0x02 <?> "Remaining length MUST be 2"
  PubrecPacket <$> packetIdentifier

parsePubrel :: Word8 -> Parser PubrelPacket
parsePubrel flags = do
  assert (flags == 0x02) "Reserved bits MUST be set to 2"
  _ <- word8 0x02 <?> "Remaining length MUST be 2"
  PubrelPacket <$> packetIdentifier

parsePubcomp :: Word8 -> Parser PubcompPacket
parsePubcomp flags = do
  assert (flags == 0x00) "Reserved bits MUST be set to zero"
  _ <- word8 0x02 <?> "Remaining length MUST be 2"
  PubcompPacket <$> packetIdentifier

parseSubscribe :: Word8 -> Parser SubscribePacket
parseSubscribe flags = do
  assert (flags == 0x2) "Reserved bits MUST be set to 2"
  len <- remainingLength
  assert (len >= 5) "The minimum remaining length is 5"
  runParserWithLength len $ do
    packetId <- PacketIdentifier <$> anyWord16be'

    topicFilters <- parseTillEnd $ do
      topicFilter <- parseTopicFilter
      qosLevel <- fromIntegral <$> anyWord8'
      withLength 0 $ assert (qosLevel <= 0x2) "Invalid QoS level"
      return (topicFilter, toEnum qosLevel)

    return $ SubscribePacket packetId topicFilters

parseSuback :: Word8 -> Parser SubackPacket
parseSuback flags = do
  assert (flags == 0x00) "Reserved bits MUST be set to zero"

  len <- fromIntegral <$> remainingLength
  assert (len > 2) "Remaining length is too short"

  packetId <- packetIdentifier
  responses <- count (len - 2) packetResponse

  return SubackPacket
    { subackPacketIdentifier = packetId
    , subackResponses        = responses
    }

  where
    packetResponse :: Parser (Maybe QoS)
    packetResponse = do
      response <- anyWord8
      assert (response <= 0x02 || response == 0x80)
        "SUBACK return codes other than 0x00, 0x01, 0x02 and 0x80 are reserved and MUST NOT be used "
      return $
        case response of
          0x00 -> Just QoS0
          0x01 -> Just QoS1
          0x02 -> Just QoS2
          0x80 -> Nothing
          _    -> error "This could not happen"

parseUnsubscribe :: Word8 -> Parser UnsubscribePacket
parseUnsubscribe flags = do
  assert (flags == 0x2) "Reserved bits MUST be set to 2"

  len <- remainingLength
  assert (len >= 4) "Remaining length is too short"

  runParserWithLength len $ do
    packetId <- withLength 2 packetIdentifier
    filters <- parseTillEnd parseTopicFilter
    return $ UnsubscribePacket packetId filters

parseUnsuback :: Word8 -> Parser UnsubackPacket
parseUnsuback flags = do
  assert (flags == 0) "Reserved bits MUST be set to zero"
  _ <- word8 2 <?> "UNSUBACK packet MUST have 2-byte payload"
  UnsubackPacket <$> packetIdentifier

parsePingreq :: Word8 -> Parser PingreqPacket
parsePingreq flags = do
  assert (flags == 0) "Reserved bits MUST be set to zero"
  _ <- word8 0 <?> "PINGREQ packet MUST have no payload"
  return PingreqPacket

parsePingresp :: Word8 -> Parser PingrespPacket
parsePingresp flags = do
  assert (flags == 0) "Reserved bits MUST be set to zero"
  _ <- word8 0 <?> "PINGRESP packet MUST have no payload"
  return PingrespPacket

parseDisconnect :: Word8 -> Parser DisconnectPacket
parseDisconnect flags = do
  assert (flags == 0) "MQTT-3.14.1-1: Reserved bits MUST be set to zero"
  _ <- word8 0 <?> "DISCONNECT packet MUST have no payload"
  return DisconnectPacket


packetIdentifier :: Parser PacketIdentifier
packetIdentifier = PacketIdentifier <$> anyWord16be

parseClientIdentifier :: ParserWithLength ClientIdentifier
parseClientIdentifier = ClientIdentifier <$> parseText

parseTillEnd :: ParserWithLength a -> ParserWithLength [a]
parseTillEnd p = do
  len <- get
  if len == 0
    then return []
    else (:) <$> p <*> parseTillEnd p

parseTopicFilter :: ParserWithLength TopicFilter
parseTopicFilter = withLength 0 . toTopicFilter =<< parseByteString

parseText :: ParserWithLength Text
parseText = do
  Right text <- decodeUtf8' <$> parseByteString
  return text

parseByteString :: ParserWithLength ByteString
parseByteString = do
  len <- anyWord16be'
  take' (fromIntegral len)

-- | Converts a ByteString to the topic name. Fails if ByteString is
-- not valid Topic Name.
--
-- MQTT-4.7.1-1: The wildcard characters can be used in Topic Filters,
-- but MUST NOT be used within a Topic Name.
--
-- MQTT-4.7.3-1: All Topic Names and Topic Filters MUST be at least
-- one character long.
--
-- MQTT-4.7.3-2: Topic Names and Topic Filters MUST NOT include the
-- null character (Unicode U+0000).
--
-- MQTT-4.7.3-3: Topic Names and Topic Filters are UTF-8 encoded
-- strings, they MUST NOT encode to more than 65535 bytes.
toTopicName :: ByteString -> Parser TopicName
toTopicName bs = do
  assert (BS.length bs >= 1)
    "MQTT-4.7.3-1: All Topic Names MUST be at least one character long"
  assert (BS.length bs <= 65535)
    "MQTT-4.7.3-3: Topic Names MUST NOT encode to more than 65535 bytes"
  Right t <- return (decodeUtf8' bs) <?>
    "MQTT-4.7.3-3: Topic Names are UTF-8 encoded strings"
  assert (isNothing $ T.find (\c -> c == '#' || c == '+' || c == '\0') t)
    "Topic name can't include wildcard or null character"
  return $ TopicName t

-- | Converts a ByteString to the topic filter. Fails if ByteString is
-- not a valid Topic Filter.
--
-- MQTT-4.7.1-2: The multi-level wildcard character MUST be specified
-- either on its own or following a topic level separator. In either
-- case it MUST be the last character specified in the Topic Filter.
--
-- MQTT-4.7.1-3: The single-level wildcard can be used at any level in
-- the Topic Filter, including first and last levels. Where it is used
-- it MUST occupy an entire level of the filter.
--
-- MQTT-4.7.3-1: All Topic Names and Topic Filters MUST be at least
-- one character long.
--
-- MQTT-4.7.3-2: Topic Names and Topic Filters MUST NOT include the
-- null character (Unicode U+0000).
--
-- MQTT-4.7.3-3: Topic Names and Topic Filters are UTF-8 encoded
-- strings, they MUST NOT encode to more than 65535 bytes.
toTopicFilter :: ByteString -> Parser TopicFilter
toTopicFilter bs = do
  assert (BS.length bs >= 1)
    "MQTT-4.7.3-1: All Topic Filters MUST be at least one character long"
  assert (BS.length bs <= 65535)
    "MQTT-4.7.3-3: Topic Filters MUST NOT encode to more than 65535 bytes"
  Right t <- return (decodeUtf8' bs) <?>
    "MQTT-4.7.3-3: Topic Filters are UTF-8 encoded strings"
  let parts = T.splitOn (T.singleton '/') t
  assert (isValidTopicFilter parts)
    "Invalid topic filter"
  return $ TopicFilter t

isValidTopicFilter :: [Text] -> Bool
isValidTopicFilter [] = True
isValidTopicFilter (x : []) | x == T.singleton '#' = True
isValidTopicFilter (x : xs) | x == T.singleton '+' = isValidTopicFilter xs
isValidTopicFilter (x : xs) =
  isNothing (T.find (\c -> c == '#' || c == '+' || c == '\0') x) && isValidTopicFilter xs

maybeM :: Monad m => Bool -> m a -> m (Maybe a)
maybeM True  p = Just <$> p
maybeM False _ = return Nothing
