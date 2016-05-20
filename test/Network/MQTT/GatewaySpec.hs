module Network.MQTT.GatewaySpec (spec, debugTests) where

import           Control.Concurrent (forkIO, killThread, threadDelay)
import           Control.Exception (bracket)

import           Control.Monad.Cont (liftIO)
import           Control.Monad.Reader (ReaderT, asks, runReaderT)

import           Data.ByteString.Builder.Extra (flush)

import           Data.Monoid ((<>))

import qualified Data.Text as T

import           Network.MQTT.Encoder (encodePacket)
import qualified Network.MQTT.Gateway as Gateway (runOnAddr, defaultMQTTAddr)
import           Network.MQTT.Packet
import           Network.MQTT.Parser (parsePacket)
import           Network.MQTT.Utils

import           Network.Socket (AddrInfo, addrAddress, addrFamily, connect, socket, addrProtocol, addrSocketType, SockAddr(SockAddrInet), close, Socket)

import           System.IO.Streams (InputStream, OutputStream)
import qualified System.IO.Streams as S
import qualified System.IO.Streams.Attoparsec as S

import           System.Log (Priority(DEBUG))
import           System.Log.Logger (debugM, rootLoggerName, setLevel, updateGlobalLogger)

import           Test.Hspec

testAddr :: AddrInfo
testAddr = Gateway.defaultMQTTAddr{ addrAddress = SockAddrInet (fromInteger 27200) 0 }

debugTests :: IO ()
debugTests = updateGlobalLogger rootLoggerName (setLevel DEBUG)

spec :: Spec
spec = do
  describe "server" $ do
    it "should accept connect message" $ do
      -- debugTests
      withServer testAddr $ do
        withClient testAddr $ do
          writePacket (CONNECT $ ConnectPacket
                       { connectClientIdentifier = ClientIdentifier $ T.pack "hi"
                       , connectProtocolLevel = 4
                       , connectWillMsg = Nothing
                       , connectUserName = Nothing
                       , connectPassword = Nothing
                       , connectCleanSession = True
                       , connectKeepAlive = 0
                       })
          expectPacket (CONNACK $ ConnackPacket False Accepted)

    it "should answer pingreq" $ do
      withServer testAddr $ do
        withClient testAddr $ do
          writePacket (CONNECT $ ConnectPacket
                       { connectClientIdentifier = ClientIdentifier $ T.pack "hi"
                       , connectProtocolLevel = 4
                       , connectWillMsg = Nothing
                       , connectUserName = Nothing
                       , connectPassword = Nothing
                       , connectCleanSession = True
                       , connectKeepAlive = 0
                       })
          writePacket (PINGREQ PingreqPacket)
          expectPacket (CONNACK $ ConnackPacket False Accepted)
          expectPacket (PINGRESP PingrespPacket)

    it "should reject first message if it's not CONNECT" $ do
      withServer testAddr $ do
        withClient testAddr $ do
          writePacket $ PINGREQ PingreqPacket
          expectConnectionClosed

data ClientConnection =
  ClientConnection
  { ccInputStream :: InputStream Packet
  , ccOutputStream :: OutputStream Packet
  }

type CCMonad a = ReaderT ClientConnection IO a

withServer :: AddrInfo -> IO a -> IO a
withServer addr x =
  -- give a sec to start server
  withThread (Gateway.runOnAddr addr) (threadDelay 100 >> x)

withClient :: AddrInfo -> (CCMonad a) -> IO a
withClient addr m = bracket (openClient addr) close $ \s -> do
  (is, os) <- socketToMqttStreams s
  runReaderT m (ClientConnection is os)

openClient :: AddrInfo -> IO Socket
openClient addr = do
  sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
  connect sock (addrAddress addr)
  return sock

writePacket :: Packet -> CCMonad ()
writePacket p = do
  os <- asks ccOutputStream
  liftIO $ debugM "MQTT.GatewaySpec" $ "Test sent: " ++ show p
  liftIO $ S.write (Just p) os

expectPacket :: Packet -> CCMonad ()
expectPacket p = do
  is <- asks ccInputStream
  p1 <- liftIO $ S.read is
  liftIO $ debugM "MQTT.GatewaySpec" $ "Test received: " ++ show p1
  liftIO $ p1 `shouldBe` Just p

expectConnectionClosed :: CCMonad ()
expectConnectionClosed = do
  liftIO $ debugM "MQTT.GatewaySpec" $ "Test expect connection closed"
  is <- asks ccInputStream
  liftIO $ S.read is `shouldThrow` anyException

closeConnection :: CCMonad ()
closeConnection = do
  os <- asks ccOutputStream
  liftIO $ debugM "MQTT.GatewaySpec" $ "Test closing connection"
  liftIO $ S.write Nothing os

-- | Runs first action in the parallel thread killing after second
-- action is done.
withThread :: IO () -> IO a -> IO a
withThread a b = bracket (forkIO a) killThread (\_ -> b)
