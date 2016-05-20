{-# LANGUAGE OverloadedStrings, RecordWildCards #-}
module Network.MQTT.Encoder (encodePacket) where

import           Network.MQTT.Packet

import           Data.Bits (shiftL, (.|.))
import           Data.ByteString.Builder (word8, word16BE, Builder, toLazyByteString, byteString)
import           Data.Int (Int64)
import           Data.List (foldl1')
import           Data.Maybe (isJust)
import           Data.Monoid ((<>))
import           Data.Text (Text)
import           Data.Text.Encoding (encodeUtf8)
import           Data.Word (Word8)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL

-- | Encode packet to the ByteString.
--
-- The function assumes the packet is well-formed and valid.
encodePacket :: Packet -> Builder
encodePacket packet = mconcat [fixedHeader', variableHeader', payload']
  where
    fixedHeader' = fixedHeader packet remaining
    variableHeader' = variableHeader packet
    payload' = payload packet

    remaining = BSL.length $ toLazyByteString (variableHeader' <> payload')

fixedHeader :: Packet -> Int64 -> Builder
fixedHeader packet remaining = word8 (packetTypeValue packet `shiftL` 4 .|. flagBits packet)
                               <> encodeRemainingLength remaining

variableHeader :: Packet -> Builder
variableHeader (CONNECT connectPacket)             = encodeConnectVariableHeader connectPacket
variableHeader (CONNACK connackPacket)             = encodeConnackVariableHeader connackPacket
variableHeader (PUBLISH publishPacket)             = encodePublishVariableHeader publishPacket
variableHeader (PUBACK PubackPacket{..})           = encodePacketIdentifier pubackPacketIdentifier
variableHeader (PUBREC PubrecPacket{..})           = encodePacketIdentifier pubrecPacketIdentifier
variableHeader (PUBREL PubrelPacket{..})           = encodePacketIdentifier pubrelPacketIdentifier
variableHeader (PUBCOMP PubcompPacket{..})         = encodePacketIdentifier pubcompPacketIdentifier
variableHeader (SUBSCRIBE SubscribePacket{..})     = encodePacketIdentifier subscribePacketIdentifier
variableHeader (SUBACK SubackPacket{..})           = encodePacketIdentifier subackPacketIdentifier
variableHeader (UNSUBSCRIBE UnsubscribePacket{..}) = encodePacketIdentifier unsubscribePacketIdentifier
variableHeader (UNSUBACK UnsubackPacket{..})       = encodePacketIdentifier unsubackPacketIdentifier
variableHeader _                                   = mempty

encodeConnectVariableHeader :: ConnectPacket -> Builder
encodeConnectVariableHeader ConnectPacket{..} = mconcat
                                                  [ encodeText "MQTT"
                                                  , word8 connectProtocolLevel
                                                  , word8 flags
                                                  , word16BE connectKeepAlive
                                                  ]
  where
    flags = foldl1' (.|.)
              [ toBit (isJust connectUserName)                 `shiftL` 7
              , toBit (isJust connectPassword)                 `shiftL` 6
              , maybe 0 (toBit . messageRetain) connectWillMsg `shiftL` 5
              , maybe 0 (fromQoS . messageQoS) connectWillMsg  `shiftL` 3
              , toBit (isJust connectWillMsg)                  `shiftL` 2
              , toBit connectCleanSession                      `shiftL` 1
              ]

encodePublishVariableHeader :: PublishPacket -> Builder
encodePublishVariableHeader PublishPacket{..} =
  encodeText (unTopic $ messageTopic publishMessage)
  <> maybe mempty encodePacketIdentifier publishPacketIdentifier

encodeText :: Text -> Builder
encodeText = encodeBytes . encodeUtf8

encodeBytes :: BS.ByteString -> Builder
encodeBytes bytes = word16BE (fromIntegral (BS.length bytes)) <> byteString bytes

encodeConnackVariableHeader :: ConnackPacket -> Builder
encodeConnackVariableHeader ConnackPacket{..} = word8 (toBit connackSessionPresent)
                                              <> word8 (returnCodeValue connackReturnCode)

returnCodeValue :: ConnackReturnCode -> Word8
returnCodeValue Accepted              = 0
returnCodeValue UnacceptableProtocol  = 1
returnCodeValue IdentifierRejected    = 2
returnCodeValue ServerUnavailable     = 3
returnCodeValue BadUserNameOrPassword = 4
returnCodeValue NotAuthorized         = 5

encodePacketIdentifier :: PacketIdentifier -> Builder
encodePacketIdentifier = word16BE . unPacketIdentifier

payload :: Packet -> Builder
payload (CONNECT connectPacket)         = encodeConnectPayload connectPacket
payload (PUBLISH publishPacket)         = encodePublishPayload publishPacket
payload (SUBSCRIBE subscribePacket)     = encodeSubscribePayload subscribePacket
payload (SUBACK subackPacket)           = encodeSubackPayload subackPacket
payload (UNSUBSCRIBE unsubscribePacket) = encodeUnsubscribePayload unsubscribePacket
payload _                               = mempty

encodeUnsubscribePayload :: UnsubscribePacket -> Builder
encodeUnsubscribePayload = foldMap (encodeText . unTopicFilter) . unsubscribeTopicFilters

encodeSubackPayload :: SubackPacket -> Builder
encodeSubackPayload = foldMap (word8 . maybe 0x80 fromQoS) . subackResponses

encodeSubscribePayload :: SubscribePacket -> Builder
encodeSubscribePayload = foldMap (\(topicFilter, qos) -> encodeText (unTopicFilter topicFilter) <> word8 (fromQoS qos))
                         . subscribeTopicFiltersQoS

encodePublishPayload :: PublishPacket -> Builder
encodePublishPayload = byteString . messageMessage . publishMessage

encodeConnectPayload :: ConnectPacket -> Builder
encodeConnectPayload ConnectPacket{..} =
  mconcat
    [ encodeText $ unClientIdentifier connectClientIdentifier
    , maybe mempty (encodeText . unTopic . messageTopic) connectWillMsg
    , maybe mempty (encodeBytes . messageMessage)        connectWillMsg
    , maybe mempty (encodeText . unUserName)             connectUserName
    , maybe mempty (encodeBytes . unPassword)            connectPassword
    ]

encodeRemainingLength :: Int64 -> Builder
encodeRemainingLength n
  | n > 536870911 = error $ "Maximum Remaining Length is 536870911, current length is " ++ show n
  | otherwise =
      let (x, encodedByte) = n `quotRem` 128
          encodedByte' = fromIntegral encodedByte
      in if x > 0
           then word8 (encodedByte' .|. 128) <> encodeRemainingLength x
           else word8 encodedByte'

packetTypeValue :: Packet -> Word8
packetTypeValue (CONNECT _)     = 1
packetTypeValue (CONNACK _)     = 2
packetTypeValue (PUBLISH _)     = 3
packetTypeValue (PUBACK _)      = 4
packetTypeValue (PUBREC _)      = 5
packetTypeValue (PUBREL _)      = 6
packetTypeValue (PUBCOMP _)     = 7
packetTypeValue (SUBSCRIBE _)   = 8
packetTypeValue (SUBACK _)      = 9
packetTypeValue (UNSUBSCRIBE _) = 10
packetTypeValue (UNSUBACK _)    = 11
packetTypeValue (PINGREQ _)     = 12
packetTypeValue (PINGRESP _)    = 13
packetTypeValue (DISCONNECT _)  = 14

flagBits :: Packet -> Word8
flagBits (PUBREL _)      = 2
flagBits (SUBSCRIBE _)   = 2
flagBits (UNSUBSCRIBE _) = 2
flagBits (PUBLISH publishPacket) =
  let message = publishMessage publishPacket
  in toBit (publishDup publishPacket) `shiftL` 3
     .|. fromQoS (messageQoS message) `shiftL` 1
     .|. toBit (messageRetain message)
flagBits _               = 0

toBit :: (Num a) => Bool -> a
toBit False = 0
toBit True  = 1

fromQoS :: (Num a) => QoS -> a
fromQoS QoS0 = 0
fromQoS QoS1 = 1
fromQoS QoS2 = 2
