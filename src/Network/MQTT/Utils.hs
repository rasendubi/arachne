module Network.MQTT.Utils
  ( socketToMqttStreams
  , stmQueueStream
  ) where

import           Control.Concurrent.STM (TQueue, atomically, readTQueue)
import           Data.ByteString.Builder.Extra (flush)
import           Data.Monoid ((<>))

import qualified Network.MQTT.Encoder as MQTT
import qualified Network.MQTT.Packet as MQTT
import qualified Network.MQTT.Parser as MQTT

import           Network.Socket (Socket)

import           System.IO.Streams (InputStream, OutputStream)
import qualified System.IO.Streams as S
import qualified System.IO.Streams.Attoparsec as S

-- | Converts socket to input and output io-streams.
socketToMqttStreams :: Socket -> IO (InputStream MQTT.Packet, OutputStream MQTT.Packet)
socketToMqttStreams sock = do
  (ibs, obs) <- S.socketToStreams sock
  is <- S.parserToInputStream (Just <$> MQTT.parsePacket) ibs
  os <- S.contramap (\x -> MQTT.encodePacket x <> flush) =<< S.builderStream obs
  return (is, os)

stmQueueStream :: TQueue (Maybe a) -> IO (InputStream a)
stmQueueStream t = S.makeInputStream $ atomically (readTQueue t)
