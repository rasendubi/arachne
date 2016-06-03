{-# LANGUAGE RecordWildCards #-}
module Network.MQTT.SN.Encoder
  ( encodePacket
  ) where

import           Data.ByteString (ByteString)
import           Data.ByteString.Builder
import qualified Data.ByteString.Lazy as BL

import           Data.Int (Int64)
import           Data.Monoid ((<>))
import           Data.Word (Word16, Word8)

import           Network.MQTT.SN.Packet

w8 :: Word8 -> Builder
w8 = word8

w16 :: Word16 -> Builder
w16 = word16BE

bs :: ByteString -> Builder
bs = byteString

-- | Creates an ByteString Builder for the MQTT-SN packet.
encodePacket :: Packet -> Builder
encodePacket p = case p of
  ADVERTISE AdvertisePacket{..}         -> withLength 0x00 [ w8 advertiseGwId, w16 advertiseDuration]
  SEARCHGW SearchgwPacket{..}           -> withLength 0x01 [ w8 searchgwRadius]
  GWINFO GwinfoPacket{..}               -> withLength 0x02 [ w8 gwinfoGwId, maybe' bs gwinfoGwAdd]
  CONNECT ConnectPacket{..}             -> withLength 0x04 [ w8 connectFlags, w8 connectProtocolId, w16 connectDuration, bs connectClientId ]
  CONNACK ConnackPacket{..}             -> withLength 0x05 [ w8 connackReturnCode ]
  WILLTOPICREQ WilltopicreqPacket       -> withLength 0x06 [ ]
  WILLTOPIC WilltopicPacket{..}         -> withLength 0x07 [ w8 willtopicFlags, bs willtopicWillTopic ]
  WILLMSGREQ WillmsgreqPacket           -> withLength 0x08 [ ]
  WILLMSG WillmsgPacket{..}             -> withLength 0x09 [ bs willmsgWillMsg ]
  REGISTER RegisterPacket{..}           -> withLength 0x0a [ w16 registerTopicId, w16 registerMsgId, bs registerTopicName ]
  REGACK RegackPacket{..}               -> withLength 0x0b [ w16 regackTopicId, w16 regackMsgId, w8 regackReturnCode ]
  PUBLISH PublishPacket{..}             -> withLength 0x0c [ w8 publishFlags, w16 publishTopicId, w16 publishMsgId, bs publishData ]
  PUBACK PubackPacket{..}               -> withLength 0x0d [ w16 pubackTopicId, w16 pubackMsgId, w8 pubackReturnCode ]
  PUBCOMP PubcompPacket{..}             -> withLength 0x0e [ w16 pubcompMsgId ]
  PUBREC PubrecPacket{..}               -> withLength 0x0f [ w16 pubrecMsgId ]
  PUBREL PubrelPacket{..}               -> withLength 0x10 [ w16 pubrelMsgId ]
  SUBSCRIBE SubscribePacket{..}         -> withLength 0x12 [ w8 subscribeFlags, w16 subscribeMsgId, bs subscribeTopic ]
  SUBACK SubackPacket{..}               -> withLength 0x13 [ w8 subackFlags, w16 subackTopicId, w16 subackMsgId, w8 subackReturnCode ]
  UNSUBSCRIBE UnsubscribePacket{..}     -> withLength 0x14 [ w8 unsubscribeFlags, w16 unsubscribeMsgId, bs unsubscribeTopic ]
  UNSUBACK UnsubackPacket{..}           -> withLength 0x15 [ w16 unsubackMsgId ]
  PINGREQ PingreqPacket{..}             -> withLength 0x16 [ maybe' bs pingreqClientId ]
  PINGRESP PingrespPacket               -> withLength 0x17 [ ]
  DISCONNECT DisconnectPacket{..}       -> withLength 0x18 [ maybe' w16 disconnectDuration ]
  WILLTOPICUPD WilltopicupdPacket{..}   -> withLength 0x1a [ w8 willtopicupdFlags, bs willtopicupdWillTopic ]
  WILLTOPICRESP WilltopicrespPacket{..} -> withLength 0x1b [ w8 willtopicrespReturnCode ]
  WILLMSGUPD WillmsgupdPacket{..}       -> withLength 0x1c [ bs willmsgupdWillMsg ]
  WILLMSGRESP WillmsgrespPacket{..}     -> withLength 0x1d [ w8 willmsgrespReturnCode ]
  FORWARD ForwardPacket{..}             -> withLength 0xfe [ w8 forwardCtrl, bs forwardWirelessNodeId] <> bs forwardMessage

maybe' :: Monoid b => (a -> b) -> Maybe a -> b
maybe' = maybe mempty

-- | Prepends the length to the packet.
withLength :: Word8 -> [Builder] -> Builder
withLength msgType msg = encodeLength (BL.length msg' + 1) <> word8 msgType <> lazyByteString msg'
  where msg' = toLazyByteString (mconcat msg)

-- | Encode length in the MQTT-SN format.
--
-- The actual length encoded will be increased by the length of the
-- length field itself.
--
-- MQTT-SN encodes length in either 1 or 3 bytes.
encodeLength :: Int64 -> Builder
encodeLength n
  | n + 1 < 256 = word8 (fromIntegral n + 1)
  | otherwise   = word8 0x01 <> word16BE (fromIntegral n + 3)
