module Network.MQTT.ParserSpec (spec) where

import Control.Applicative ((<*))

import Test.Hspec

import Network.MQTT.Parser

import qualified Data.ByteString as BS
import Data.Attoparsec.ByteString (parseOnly, endOfInput)

spec :: Spec
spec = do
  describe "remainingLength" $ do
    it "parses zero length" $ do
      parseOnly remainingLength (BS.pack [0x00]) `shouldBe` Right 0
    it "parses non-zero length" $ do
      parseOnly remainingLength (BS.pack [0x1f]) `shouldBe` Right 31
    it "parses multi-byte length" $ do
      parseOnly remainingLength (BS.pack [0x80, 0x01]) `shouldBe` Right 128
    it "parses maximum length" $ do
      parseOnly remainingLength (BS.pack [0xff, 0xff, 0xff, 0x7f]) `shouldBe` Right 268435455
