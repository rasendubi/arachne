module Network.MQTT.Parser
  ( parsePacket
  , remainingLength
  ) where

import Network.MQTT.Packet

import Control.Monad (when)
import Control.Applicative ((<$>))

import Data.Bits ((.&.), (.|.), shiftR, shiftL, testBit, clearBit)
import Data.List (foldr1)
import Data.Word (Word32)

import Data.Attoparsec.ByteString (Parser, anyWord8)
import Data.Attoparsec.Binary

-- parsePacket :: Parser Packet
parsePacket = do
  byte1 <- anyWord8
  let packetType = byte1 `shiftR` 4
      flags = byte1 .&. 0x0f

  length <- remainingLength

  return (packetType, flags, length)

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
      when (i > 3) $
        fail "Too many bytes in the Remaining Length field"
      byte <- fromIntegral <$> anyWord8
      if byte `testBit` 7 then
        ((byte `clearBit` 7) :) <$> takeBytes (i + 1)
      else
        return [byte]
