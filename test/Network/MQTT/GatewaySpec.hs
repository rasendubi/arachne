module Network.MQTT.GatewaySpec (spec, debugTests) where

import           Control.Concurrent (forkIO, killThread)
import           Control.Exception (bracket)

import           Control.Monad (forM_)
import           Control.Monad.Cont (liftIO)
import           Control.Monad.Reader (ReaderT, asks, runReaderT)

import qualified Data.Text as T

import qualified Network.MQTT.Gateway as Gateway
import           Network.MQTT.Client (ClientCommand, ClientResult)
import           Network.MQTT.Packet
import           Network.MQTT.Utils

import           Network.Socket (AddrInfo, addrAddress, addrFamily, connect, socket, addrProtocol, addrSocketType, SockAddr(SockAddrInet), close, Socket, aNY_PORT, bind, listen, socketPort)

import           System.IO.Streams (InputStream, OutputStream)
import qualified System.IO.Streams as S
import qualified System.IO.Streams.Concurrent as S

import           System.Log (Priority(DEBUG))
import           System.Log.Logger (debugM, rootLoggerName, setLevel, updateGlobalLogger)

import           System.Timeout (timeout)

import           Test.Hspec

debugTests :: IO ()
debugTests = updateGlobalLogger rootLoggerName (setLevel DEBUG)

spec :: Spec
spec = do
  describe "server" $ do
    it "should accept connect message" $ do
      -- debugTests
      withServer $ \_ _ testAddr -> do
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
      withServer $ \_ _ testAddr -> do
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
      withServer $ \_ _ testAddr -> do
        withClient testAddr $ do
          writePacket $ PINGREQ PingreqPacket
          expectConnectionClosed

    it "MQTT-3.1.0-2: The Server MUST process a second CONNECT Packet sent from a Client as a protocol violation and disconnect the Client" $ do
      withServer $ \_ _ testAddr -> do
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
          writePacket (CONNECT $ ConnectPacket
                       { connectClientIdentifier = ClientIdentifier $ T.pack "hi"
                       , connectProtocolLevel = 4
                       , connectWillMsg = Nothing
                       , connectUserName = Nothing
                       , connectPassword = Nothing
                       , connectCleanSession = True
                       , connectKeepAlive = 0
                       })
          expectConnectionClosed

    it "should close connection if new client connects with the same client identifier" $ do
      withServer $ \_ _ testAddr -> do
        c1 <- openClient testAddr
        c2 <- openClient testAddr

        runCC c1 $ do
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

        runCC c2 $ do
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

        runCC c1 $ expectConnectionClosed

        closeClient c1
        closeClient c2

    it "should not disconnect if the client identifier is different" $ do
      withServer $ \_ _ testAddr -> do
        c1 <- openClient testAddr
        c2 <- openClient testAddr

        runCC c1 $ do
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

        runCC c2 $ do
          writePacket (CONNECT $ ConnectPacket
                       { connectClientIdentifier = ClientIdentifier $ T.pack "hello"
                       , connectProtocolLevel = 4
                       , connectWillMsg = Nothing
                       , connectUserName = Nothing
                       , connectPassword = Nothing
                       , connectCleanSession = True
                       , connectKeepAlive = 0
                       })
          expectPacket (CONNACK $ ConnackPacket False Accepted)

        runCC c1 $ do
          writePacket (PINGREQ PingreqPacket)
          expectPacket (PINGRESP PingrespPacket)

        runCC c2 $ do
          writePacket (PINGREQ PingreqPacket)
          expectPacket (PINGRESP PingrespPacket)

        closeClient c1
        closeClient c2

    it "MQTT-3.1.2-2: The Server MUST respond to the CONNECT Packet with a CONNACK return code 0x01 (unacceptable protocol level) and then disconnect the Client if the Protocol Level is not supported by the Server" $ do
      withServer $ \_ _ testAddr -> do
        forM_ ([0x00 .. 0x03] ++ [0x05 .. 0xff]) $ \protocolLevel ->
          withClient testAddr $ do
            writePacket (CONNECT $ ConnectPacket
                         { connectClientIdentifier = ClientIdentifier $ T.pack "hi"
                         , connectProtocolLevel = protocolLevel
                         , connectWillMsg = Nothing
                         , connectUserName = Nothing
                         , connectPassword = Nothing
                         , connectCleanSession = True
                         , connectKeepAlive = 0
                         })
            expectPacket (CONNACK $ ConnackPacket False UnacceptableProtocol)

    it "should accept subscribe packet" $ do
      withServer $ \_ _ testAddr -> do
        withClient testAddr $ do
          clientConnect "client1"
          writePacket $
            SUBSCRIBE SubscribePacket
            { subscribePacketIdentifier = PacketIdentifier 0x01
            , subscribeTopicFiltersQoS = [ (TopicFilter (T.pack "a"), QoS0) ]
            }
          expectPacket $
            SUBACK SubackPacket
            { subackPacketIdentifier = PacketIdentifier 0x01
            , subackResponses = [ Just QoS0 ]
            }

    it "should accept subscribe with multiple topics" $ do
      withServer $ \_ _ testAddr -> do
        withClient testAddr $ do
          clientConnect "client1"
          writePacket $
            SUBSCRIBE SubscribePacket
            { subscribePacketIdentifier = PacketIdentifier 0x01
            , subscribeTopicFiltersQoS = [ (TopicFilter (T.pack "a"), QoS0)
                                         , (TopicFilter (T.pack "b"), QoS1)
                                         ]
            }
          expectPacket $
            SUBACK SubackPacket
            { subackPacketIdentifier = PacketIdentifier 0x01
            , subackResponses = [ Just QoS0, Just QoS1 ]
            }

    it "should reject subscribe packet if client is not connected" $ do
      withServer $ \_ _ testAddr -> do
        withClient testAddr $ do
          writePacket $
            SUBSCRIBE SubscribePacket
            { subscribePacketIdentifier = PacketIdentifier 0x01
            , subscribeTopicFiltersQoS = [ (TopicFilter (T.pack "a"), QoS0) ]
            }
          expectConnectionClosed

    it "should accept unsubscribe packet" $ do
      withSingleClient $ do
        clientConnect "client1"
        writePacket $
          UNSUBSCRIBE UnsubscribePacket
          { unsubscribePacketIdentifier = PacketIdentifier 0xab
          , unsubscribeTopicFilters = [ TopicFilter (T.pack "a") ]
          }
        expectPacket $
          UNSUBACK UnsubackPacket
          { unsubackPacketIdentifier = PacketIdentifier 0xab }

withSingleClient :: CCMonad () -> IO ()
withSingleClient x = withServer $ \_ _ testAddr -> withClient testAddr x

clientConnect :: String -> CCMonad ()
clientConnect clientId = do
  writePacket (CONNECT $ ConnectPacket
                { connectClientIdentifier = ClientIdentifier $ T.pack clientId
                , connectProtocolLevel = 4
                , connectWillMsg = Nothing
                , connectUserName = Nothing
                , connectPassword = Nothing
                , connectCleanSession = True
                , connectKeepAlive = 0
                })
  expectPacket (CONNACK $ ConnackPacket False Accepted)

data ClientConnection =
  ClientConnection
  { ccSocket :: Socket
  , ccInputStream :: InputStream Packet
  , ccOutputStream :: OutputStream Packet
  }

type CCMonad a = ReaderT ClientConnection IO a

withServer :: (InputStream ClientCommand -> OutputStream ClientResult -> AddrInfo -> IO a) -> IO a
withServer x = do
  (command_is, command_os) <- S.makeChanPipe

  (gw, result_os) <- Gateway.newGateway command_os
  bracket (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)) close $ \sock -> do
    bind sock (addrAddress addr)
    listen sock 5
    withThread (Gateway.listenOnSocket gw sock) $ do
      port <- socketPort sock
      x command_is result_os Gateway.defaultMQTTAddr{ addrAddress = SockAddrInet port 0 }
  where
    addr = Gateway.defaultMQTTAddr{ addrAddress = SockAddrInet aNY_PORT 0 }

withClient :: AddrInfo -> CCMonad a -> IO a
withClient addr m = bracket (openClient addr) closeClient $ runReaderT m

openClient :: AddrInfo -> IO ClientConnection
openClient addr = do
  sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
  connect sock (addrAddress addr)
  (is, os) <- socketToMqttStreams sock
  return $ ClientConnection sock is os

closeClient :: ClientConnection -> IO ()
closeClient = close . ccSocket

runCC :: ClientConnection -> CCMonad a -> IO a
runCC = flip runReaderT

writePacket :: Packet -> CCMonad ()
writePacket p = do
  os <- asks ccOutputStream
  liftIO $ debugM "MQTT.GatewaySpec" $ "Test sent: " ++ show p
  liftIO $ S.write (Just p) os

expectPacket :: Packet -> CCMonad ()
expectPacket p = do
  is <- asks ccInputStream
  p1 <- liftIO $ timeout 1000000 (S.read is)
  liftIO $ debugM "MQTT.GatewaySpec" $ "Test received: " ++ show p1
  liftIO $ p1 `shouldBe` Just (Just p)

expectConnectionClosed :: CCMonad ()
expectConnectionClosed = do
  liftIO $ debugM "MQTT.GatewaySpec" $ "Test expect connection closed"
  is <- asks ccInputStream
  liftIO $ timeout 1000000 (S.read is) `shouldThrow` anyException

-- | Runs first action in the parallel thread killing after second
-- action is done.
withThread :: IO () -> IO a -> IO a
withThread a b = bracket (forkIO a) killThread (\_ -> b)
