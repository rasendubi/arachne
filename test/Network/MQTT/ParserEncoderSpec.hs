{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses #-}

module Network.MQTT.ParserEncoderSpec       (spec) where

import           Network.MQTT.Packet
import           Network.MQTT.Encoder       (encodePacket)
import           Network.MQTT.Parser        (parsePacket)

import           Test.SmallCheck.Series
import           Test.Hspec
import           Test.Hspec.SmallCheck      (property)

import           Data.Attoparsec.ByteString (parseOnly)
import           Data.Word                  (Word16)
import           Data.ByteString            (ByteString, singleton)
import           Data.ByteString.Builder    (toLazyByteString)
import           Data.ByteString.Lazy       (toStrict)
import qualified Data.Text as T

spec :: Spec
spec = do
  describe "Parser-Encoder" $ do
    it "test identity" $ property $
      \p -> let encodedPacket = toStrict $ toLazyByteString (encodePacket p)
                (Right decodedPacket) = parseOnly parsePacket encodedPacket
            in decodedPacket == (p :: Packet)

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

instance Monad m => Serial m Word16 where
  series = generate $ \d -> take (d+1) [ 0..65535 ]

instance Monad m => Serial m ByteString where
  series = generate $ \d -> take (d+1) (singleton <$> [ 0..255 ])

instance Monad m => Serial m T.Text where
  series = generate $ \d -> take (d+1) (T.singleton <$> ['a'..'z'])
