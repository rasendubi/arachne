{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses #-}
module Network.MQTT.SN.EncoderSpec (spec) where

import           Data.Attoparsec.ByteString (parseOnly)

import qualified Data.ByteString as BS
import           Data.ByteString.Builder (toLazyByteString)
import           Data.ByteString.Lazy (toStrict)

import           Network.MQTT.SN.Encoder
import           Network.MQTT.SN.Packet
import           Network.MQTT.SN.Parser

import           Test.Hspec
import           Test.Hspec.SmallCheck (property)
import           Test.SmallCheck ((==>))
import           Test.SmallCheck.Series (Serial)
import           Test.SmallCheck.Series.Instances ()

spec :: Spec
spec = do
  describe "Parser-Encoder" $ do
    it "parsePacket . encodePacket = id" $ property $ \p ->
      let bytes = toStrict . toLazyByteString $ encodePacket p
      in valid p ==> parseOnly parsePacket bytes == Right p

valid :: Packet -> Bool
valid (PINGREQ p) = pingreqClientId p /= Just BS.empty
valid (GWINFO p) = gwinfoGwAdd p /= Just BS.empty
valid _ = True

instance Monad m => Serial m Packet
instance Monad m => Serial m AdvertisePacket
instance Monad m => Serial m SearchgwPacket
instance Monad m => Serial m GwinfoPacket
instance Monad m => Serial m ConnectPacket
instance Monad m => Serial m ConnackPacket
instance Monad m => Serial m WilltopicreqPacket
instance Monad m => Serial m WilltopicPacket
instance Monad m => Serial m WillmsgreqPacket
instance Monad m => Serial m WillmsgPacket
instance Monad m => Serial m RegisterPacket
instance Monad m => Serial m RegackPacket
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
instance Monad m => Serial m WilltopicupdPacket
instance Monad m => Serial m WillmsgupdPacket
instance Monad m => Serial m WilltopicrespPacket
instance Monad m => Serial m WillmsgrespPacket
instance Monad m => Serial m ForwardPacket
