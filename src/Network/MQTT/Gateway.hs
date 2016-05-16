{-# LANGUAGE AutoDeriveTypeable #-}
module Network.MQTT.Gateway
  ( runServer
  , defaultMQTTAddr
  ) where

import           Control.Concurrent (forkIO, forkIOWithUnmask)
import           Control.Concurrent.STM (STM, TQueue, TVar, atomically, newTQueue, newTVar, readTVar, readTQueue, writeTQueue, writeTVar)
import           Control.Exception (Exception, allowInterrupt, bracket, finally, mask_, throwIO)

import           Control.Monad (forever, guard, void, when, unless)

import           Data.ByteString.Builder.Extra (flush)

import           Data.Monoid ((<>))

import qualified Network.MQTT.Encoder as MQTT
import qualified Network.MQTT.Packet as MQTT
import qualified Network.MQTT.Parser as MQTT

import           Network.Socket (AddrInfo(AddrInfo), Family(AF_INET), SockAddr(SockAddrInet), SocketOption(ReusePort), SocketType(Stream), accept, addrAddress, addrCanonName, addrFamily, addrFlags, addrProtocol, addrSocketType, bind, close, listen, socket, setSocketOption, Socket, isSupportedSocketOption)

import           System.IO.Streams (InputStream, OutputStream)
import qualified System.IO.Streams as S
import qualified System.IO.Streams.Attoparsec as S

import           System.Log.Logger (debugM)

data MQTTError = MQTTError
  deriving (Show)

instance Exception MQTTError

-- | Converts socket to input and output io-streams.
toMQTTStreams :: Socket -> IO (InputStream MQTT.Packet, OutputStream MQTT.Packet)
toMQTTStreams sock = do
  (ibs, obs) <- S.socketToStreams sock
  is <- S.parserToInputStream (Just <$> MQTT.parsePacket) ibs
  os <- S.contramap (\x -> MQTT.encodePacket x <> flush) =<< S.builderStream obs
  return (is, os)

stmQueueStream :: TQueue (Maybe a) -> IO (InputStream a)
stmQueueStream t = S.makeInputStream (atomically $ readTQueue t)

data GatewayClient =
  GatewayClient
  { gcSendQueue :: TQueue (Maybe MQTT.Packet)
  , gcConnected :: TVar Bool
  }

newGatewayClient :: STM GatewayClient
newGatewayClient = GatewayClient <$> newTQueue <*> newTVar False

runServer :: AddrInfo -> IO ()
runServer addr = do
  bracket (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)) close $ \sock -> do
    when (isSupportedSocketOption ReusePort) $
      setSocketOption sock ReusePort 1
    bind sock (addrAddress addr)
    listen sock 5

    -- We want to handle all incoming socket in exception-safe way, so
    -- no sockets leak.
    --
    -- Disable interrupts first to ensure no async exception is throw
    -- between accept and setting finalizer.
    mask_ $ forever $ do
      -- Allow an interrupt between connections, so the thread is
      -- still interruptible.
      allowInterrupt

      (s, a) <- accept sock

      -- New thread is run in masked state.
      forkIOWithUnmask $ \unmask ->
        unmask (handleClient s a) `finally` close s

defaultMQTTAddr :: AddrInfo
defaultMQTTAddr = AddrInfo{ addrFlags = []
                          , addrFamily = AF_INET
                          , addrSocketType = Stream
                          , addrProtocol = 6 -- TCP
                          , addrAddress = SockAddrInet (fromInteger 1883) 0
                          , addrCanonName = Nothing
                          }

-- Don't need to close socket, as it's done in 'runServer' in a safer
-- way.
handleClient :: Socket -> SockAddr -> IO ()
handleClient sock addr = do
  debugM "MQTT.Gateway" $ "Connected: " ++ show addr

  state <- atomically newGatewayClient
  (is, os) <- toMQTTStreams sock
  void $ forkIO $ clientSender os (gcSendQueue state)

  (S.connect is =<<) $ S.makeOutputStream $ \mp -> do
    case mp of
      Nothing -> return ()
      Just p -> do
        debugM "MQTT.Gateway" $ "Received: " ++ show p
        cont <- atomically $ do
          case p of
            MQTT.CONNECT MQTT.ConnectPacket{ } -> do
              -- Accept all connections.
              connected <- readTVar (gcConnected state)
              guard (not connected)
              writeTQueue (gcSendQueue state) (Just $ MQTT.CONNACK (MQTT.ConnackPacket False MQTT.Accepted))
              writeTVar (gcConnected state) True
              return True
            MQTT.PINGREQ _ -> do
              connected <- readTVar (gcConnected state)
              writeTQueue (gcSendQueue state) $
                if connected then Just (MQTT.PINGRESP MQTT.PingrespPacket) else Nothing
              return connected
            _ -> return True
        debugM "MQTT.Gateway" $ "Asserting: " ++ show cont
        unless cont $ throwIO MQTTError

clientSender :: OutputStream MQTT.Packet -> TQueue (Maybe MQTT.Packet) -> IO ()
clientSender os queue = do
  stmQueueStream queue >>= S.mapM_ logPacket >>= S.connectTo os
  debugM "MQTT.Gateway" $ "clientSender exit"
  where
    logPacket p = debugM "MQTT.Gateway" $ "Sending: " ++ show p
