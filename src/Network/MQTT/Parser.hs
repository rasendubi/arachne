module Network.MQTT.Parser
  ( parsePacket
  , remainingLength
  ) where

import Prelude hiding (take)

import Network.MQTT.Packet

import Control.Monad (when)

import Data.Bits ((.&.), (.|.), shiftR, shiftL, testBit, clearBit)
import Data.Word (Word32, Word8)

import Data.Text.Encoding (decodeUtf8')

import Data.Attoparsec.ByteString (Parser, anyWord8, word8, take, (<?>), count)
import Data.Attoparsec.Binary

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

packetIdentifier :: Parser PacketIdentifier
packetIdentifier = PacketIdentifier <$> anyWord16be

assert :: Bool -> String -> Parser ()
assert cond reason = when (not cond) $ fail reason

parseConnect :: Word8 -> Parser ConnectPacket
parseConnect flags = do
  assert (flags == 0) "Reserved bits MUST be set to zero"
  len <- remainingLength
  undefined

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
  let dupFlag     = flags .&. 0x8 /= 0
      qosLevel    = (flags .&. 0x6) `shiftR` 1
      retainFlag  = flags .&. 0x1 /= 0
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

  Right topic <- decodeUtf8' <$> take topicLen

  packetId <- if qosLevel == 0
              then return Nothing
              else Just <$> packetIdentifier

  payload <- take payloadLength

  return PublishPacket
    { publishDup = dupFlag
    , publishMessage = Message (toEnum $ fromIntegral qosLevel) retainFlag (Topic topic) payload
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
parseSubscribe = undefined

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
parseUnsubscribe = undefined

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
