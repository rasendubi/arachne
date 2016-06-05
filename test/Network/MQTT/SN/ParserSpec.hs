module Network.MQTT.SN.ParserSpec (spec) where

import           Data.Attoparsec.ByteString

import qualified Data.ByteString as BS

import           Data.Maybe (fromJust)

import           Network.MQTT.SN.Packet
import           Network.MQTT.SN.Parser

import           Test.Hspec

shouldParseFully :: (Show a, Eq a) => Result a -> a -> Expectation
shouldParseFully r x = r `shouldSatisfy` fromJust . compareResults (Done BS.empty x)

spec :: Spec
spec = do
  describe "parsePacket" $ do
    it "parses packets with long length" $ do
      parse parsePacket (BS.pack [0x01, 0x00, 0x05, 0x01, 0x00])
        `shouldParseFully` SEARCHGW (SearchgwPacket 0)

    it "parses long packet" $ do
      parse parsePacket (BS.pack $ [0x01, 0x01, 0x02, 0x0c, 0x00, 0xab, 0xcd, 0xef, 0x01] ++ [1 .. 249])
        `shouldParseFully` PUBLISH (PublishPacket 0x00 0xabcd 0xef01 (BS.pack [1 .. 249]))
