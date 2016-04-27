{-# LANGUAGE RecordWildCards, FlexibleInstances, MultiParamTypeClasses #-}

module Network.MQTT.EncoderSpec (spec) where

import           Network.MQTT.Packet
import           Network.MQTT.Encoder             (encodePacket)
import           Network.MQTT.Parser              (parsePacket)

import           Test.SmallCheck.Series           (Serial)
import           Test.SmallCheck                  ((==>))
import           Test.Hspec
import           Test.Hspec.SmallCheck            (property)
import           Test.SmallCheck.Series.Instances ()
import           Data.Attoparsec.ByteString       (parseOnly)
import           Data.ByteString.Builder          (toLazyByteString)
import           Data.ByteString.Lazy             (toStrict)
import           Data.Maybe                       (isNothing, isJust)

spec :: Spec
spec = do
  describe "Parser-Encoder" $ do
    it "parsePacket . encodePacket = id" $ property $ \p ->
      let bytes = toStrict . toLazyByteString $ encodePacket p
      in valid p ==> parseOnly parsePacket bytes == Right p

valid :: Packet -> Bool
valid packet = case packet of
  SUBSCRIBE SubscribePacket{..}     -> not $ null subscribeTopicFiltersQoS
  SUBACK SubackPacket{..}           -> not $ null subackResponses
  UNSUBSCRIBE UnsubscribePacket{..} -> not $ null unsubscribeTopicFilters
  CONNACK ConnackPacket{..}         -> not (connackReturnCode /= Accepted && connackSessionPresent)
  PUBLISH PublishPacket{..}         ->
    not ((messageQoS publishMessage /= QoS0 && isNothing publishPacketIdentifier) ||
         (messageQoS publishMessage == QoS0 && (publishDup || isJust publishPacketIdentifier)))
  CONNECT ConnectPacket{..}         -> not (isNothing connectUserName && isJust connectPassword)
  _                                 -> True

instance Monad m => Serial m Packet
instance Monad m => Serial m ConnectPacket
instance Monad m => Serial m ConnackPacket
instance Monad m => Serial m PublishPacket
instance Monad m => Serial m PubackPacket
instance Monad m => Serial m PubrecPacket
instance Monad m => Serial m PubrelPacket
instance Monad m => Serial m PubcompPacket
instance Monad m => Serial m SubscribePacket
instance Monad m => Serial m SubackPacket
instance Monad m => Serial m UnsubscribePacket
instance Monad m => Serial m UnsubackPacket
instance Monad m => Serial m PingreqPacket
instance Monad m => Serial m PingrespPacket
instance Monad m => Serial m DisconnectPacket

instance Monad m => Serial m ConnackReturnCode
instance Monad m => Serial m Message
instance Monad m => Serial m QoS
instance Monad m => Serial m ClientIdentifier
instance Monad m => Serial m PacketIdentifier
instance Monad m => Serial m UserName
instance Monad m => Serial m Password
instance Monad m => Serial m Topic
instance Monad m => Serial m TopicFilter
