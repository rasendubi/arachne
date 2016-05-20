{-# LANGUAGE AutoDeriveTypeable #-}
module Network.MQTT.Gateway
  ( runServer
  , defaultMQTTAddr
  ) where

import           Control.Concurrent (forkIO, forkIOWithUnmask)
import           Control.Concurrent.STM (STM, TQueue, TVar, atomically, newTQueue, newTVar, readTVar, writeTQueue, writeTVar)
import           Control.Exception (Exception, allowInterrupt, bracket, finally, mask_, throwIO, SomeException, try)

import           Control.Monad (forever, guard, when, unless)

import qualified Network.MQTT.Packet as MQTT

import           Network.MQTT.Utils

import           Network.Socket (AddrInfo(AddrInfo), Family(AF_INET), SockAddr(SockAddrInet), SocketOption(ReusePort), SocketType(Stream), accept, addrAddress, addrCanonName, addrFamily, addrFlags, addrProtocol, addrSocketType, bind, close, listen, socket, setSocketOption, Socket, isSupportedSocketOption)

import           System.IO.Streams (InputStream, OutputStream)
import qualified System.IO.Streams as S

import           System.Log.Logger (debugM)

data MQTTError = MQTTError
  deriving (Show)

instance Exception MQTTError

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
      forkIOWithUnmask $ \unmask -> do
        res <- unmask (try (handleClient s a)) :: IO (Either SomeException ())
        close s
        debugM "MQTT.Gateway" $ "handleClient exited with " ++ show res

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
  (is, os) <- socketToMqttStreams sock

  forkIO $ clientSender os (gcSendQueue state)

  clientReceiver state is `finally`
    -- properly close sender queue
    atomically (writeTQueue (gcSendQueue state) Nothing)

clientReceiver :: GatewayClient -> InputStream MQTT.Packet -> IO ()
clientReceiver state is = S.makeOutputStream handler >>= S.connect is
  where
    handler Nothing  = return ()
    handler (Just p) = do
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
