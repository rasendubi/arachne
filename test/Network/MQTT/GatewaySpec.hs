module Network.MQTT.GatewaySpec (spec) where

import           Control.Concurrent (Chan, newChan, readChan, writeList2Chan, forkIO, killThread, threadDelay)
import           Control.Exception (bracket)

import           Control.Monad.Cont (liftIO)
import           Control.Monad.Reader (ReaderT, asks, runReaderT)

import qualified Data.Attoparsec.ByteString.Lazy as A

import           Data.ByteString.Builder (hPutBuilder)
import qualified Data.ByteString.Lazy as BL

import qualified Data.Text as T

import           Network.MQTT.Encoder (encodePacket)
import           Network.MQTT.Gateway (runServer, defaultMQTTAddr)
import           Network.MQTT.Packet
import           Network.MQTT.Parser (parsePacket)

import           Network.Socket (AddrInfo, addrAddress, addrFamily, connect, socket, socketToHandle, addrProtocol, addrSocketType, SockAddr(SockAddrInet))

import           System.IO (Handle, IOMode(ReadWriteMode), hClose)

import           Test.Hspec

testAddr :: AddrInfo
testAddr = defaultMQTTAddr{ addrAddress = SockAddrInet (fromInteger 27200) 0 }

spec :: Spec
spec = do
  describe "server" $ do
    it "should accept connect message" $ do
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

    it "should answer connack" $ do
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

data ClientConnection =
  ClientConnection
  { ccHandle :: Handle
  , ccQueue :: Chan Packet
  }

type CCMonad a = ReaderT ClientConnection IO a

withServer :: AddrInfo -> IO a -> IO a
withServer addr x =
  -- give a sec to start server
  withThread (runServer addr False) (threadDelay 100 >> x)

withClient :: AddrInfo -> (CCMonad a) -> IO a
withClient addr m = bracket (openClient addr) hClose $ \h -> do
  chan <- newChan
  withThread
    (writeList2Chan chan . parseStream =<< BL.hGetContents h)
    (runReaderT m $ ClientConnection h chan)

openClient :: AddrInfo -> IO Handle
openClient addr = do
  sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
  connect sock (addrAddress addr)
  socketToHandle sock ReadWriteMode

writePacket :: Packet -> CCMonad ()
writePacket p = do
  h <- asks ccHandle
  liftIO $ hPutBuilder h (encodePacket p)

expectPacket :: Packet -> CCMonad ()
expectPacket p = do
  ch <- asks ccQueue
  p1 <- liftIO $ readChan ch
  liftIO $ p1 `shouldBe` p

-- | Runs first action in the parallel thread killing after second
-- action is done.
withThread :: IO () -> IO a -> IO a
withThread a b = bracket (forkIO a) killThread (\_ -> b)

-- | Parses a lazy ByteString to the list of MQTT Packets.
--
-- It should be removed and replaced by strict parsing, as lazy
-- parsing is not idiomatic Attoparsec.
parseStream :: BL.ByteString -> [Packet]
parseStream s
  | BL.null s = []
  | otherwise =
      case A.parse parsePacket s of
        A.Fail _ _ _ -> error "Parsing failed"
        A.Done c p   -> p : parseStream c
