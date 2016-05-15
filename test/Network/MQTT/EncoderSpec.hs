{-# LANGUAGE RecordWildCards, FlexibleInstances, MultiParamTypeClasses #-}

module Network.MQTT.EncoderSpec (spec) where

import           Network.MQTT.Packet
import           Network.MQTT.Encoder             ( encodePacket )
import           Network.MQTT.Parser              ( parsePacket )

import           Test.SmallCheck.Series           ( (<~>), Serial, decDepth , getNonEmpty, series )
import           Test.SmallCheck                  ( (==>) )
import           Test.Hspec
import           Test.Hspec.SmallCheck            ( property )
import           Test.SmallCheck.Series.Instances ()
import           Data.Attoparsec.ByteString       ( parseOnly )
import           Data.ByteString.Builder          ( toLazyByteString )
import           Data.ByteString.Lazy             ( toStrict )
import qualified Data.Text                        as T
import qualified Data.ByteString                  as BS
import           Data.Maybe                       ( isJust, isNothing )

spec :: Spec
spec = do
  describe "Parser-Encoder" $ do
    it "parsePacket . encodePacket = id" $ property $ \p ->
      let bytes = toStrict . toLazyByteString $ encodePacket p
      in valid p ==> parseOnly parsePacket bytes == Right p

  describe "Encoder" $ do
    let shouldBeEncodedAs p bytes =
          (toStrict . toLazyByteString . encodePacket) p `shouldBe` BS.pack bytes

    it "should encode packet having a big payload" $ do
      let bigPayload = replicate 121 0xab

      PUBLISH PublishPacket{ publishDup = True
                           , publishMessage = Message
                                                QoS2
                                                True
                                                (Topic $ T.pack "a/b")
                                                (BS.pack bigPayload)
                           , publishPacketIdentifier = Just (PacketIdentifier 10)
                           }
        `shouldBeEncodedAs` ([0x3d, 0x80, 0x01, 0x00, 0x03, 0x61, 0x2f, 0x62, 0x00, 0x0a] ++ bigPayload)

valid :: Packet -> Bool
valid packet = case packet of
  CONNACK ConnackPacket{..}         -> not (connackReturnCode /= Accepted && connackSessionPresent)
  PUBLISH PublishPacket{..}         ->
    not ((messageQoS publishMessage /= QoS0 && isNothing publishPacketIdentifier) ||
         (messageQoS publishMessage == QoS0 && (publishDup || isJust publishPacketIdentifier)))
  CONNECT ConnectPacket{..}         -> not (isNothing connectUserName && isJust connectPassword)
  _                                 -> True

instance Monad m => Serial m Packet
instance Monad m => Serial m ConnectPacket where
    series = ConnectPacket <$> decDepth (decDepth series)
                           <~> decDepth (decDepth (decDepth series))
                           <~> series
                           <~> decDepth series
                           <~> decDepth series
                           <~> decDepth (decDepth (decDepth series))
                           <~> decDepth (decDepth (decDepth series))
instance Monad m => Serial m ConnackPacket
instance Monad m => Serial m PublishPacket
instance Monad m => Serial m PubackPacket
instance Monad m => Serial m PubrecPacket
instance Monad m => Serial m PubrelPacket
instance Monad m => Serial m PubcompPacket
instance Monad m => Serial m SubscribePacket where
  series = SubscribePacket <$> series <~> (getNonEmpty <$> series)
instance Monad m => Serial m SubackPacket where
  series = SubackPacket <$> series <~> (getNonEmpty <$> series)
instance Monad m => Serial m UnsubscribePacket where
  series = UnsubscribePacket <$> series <~> (getNonEmpty <$> series)
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
instance Monad m => Serial m Topic where
  series = Topic <$> (T.pack . getNonEmpty) <$> series
instance Monad m => Serial m TopicFilter where
  series = TopicFilter <$> (T.pack . getNonEmpty) <$> series
