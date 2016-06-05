-- | The heart of the gateway.
--
-- The gateway per se is pretty generic and can handle client over any
-- transport channel. That's why this module only requires
-- 'InputStream' and 'OutputStream'.
--
-- This module neither establishes connection to the server, nor
-- listens for the incoming client connections.
--
-- See "Network.MQTT.Gateway.Socket" on how to establish listening for
-- new clients.
module Network.MQTT.Gateway.Core
  ( Gateway
  , newGateway
  , handleClient
  ) where

import           Control.Concurrent (forkIO, killThread)
import           Control.Concurrent.STM (STM, TQueue, TVar, atomically, readTVar, writeTQueue, writeTVar, newTQueueIO, newTVarIO, throwSTM)
import           Control.Exception (Exception, finally, throwIO, SomeException, try)

import           Control.Monad (unless, when)

import qualified Network.MQTT.Packet as MQTT

import           Network.MQTT.Utils

import qualified STMContainers.Map as STM (Map)
import qualified STMContainers.Map as STM.Map

import           System.IO.Streams (InputStream, OutputStream)
import qualified System.IO.Streams as S

import           System.Log.Logger (debugM)

-- | Internal gateway state.
data Gateway =
  Gateway
  { gClients :: STM.Map MQTT.ClientIdentifier GatewayClient
  }

data GatewayClient =
  GatewayClient
  { gcSendQueue :: TQueue (Maybe MQTT.Packet)
  , gcConnected :: TVar Bool
  }

data MQTTError = MQTTError
  deriving (Show)

instance Exception MQTTError

-- | Creates a new Gateway.
--
-- Note that this doesn't start gateway operation.
newGateway :: IO Gateway
newGateway = Gateway <$> STM.Map.newIO

newGatewayClient :: IO GatewayClient
newGatewayClient = GatewayClient <$> newTQueueIO <*> newTVarIO False

-- | Run client handling on the given streams.
--
-- Note that this function doesn't exit until connection is closed.
handleClient :: Gateway -> (InputStream MQTT.Packet, OutputStream MQTT.Packet) -> IO ()
handleClient gw (is, os) = do
  state <- newGatewayClient

  t <- forkIO $ clientReceiver gw state is `finally`
    -- properly close sender queue
    atomically (writeTQueue (gcSendQueue state) Nothing)

  clientSender os (gcSendQueue state) `finally` killThread t

clientReceiver :: Gateway -> GatewayClient -> InputStream MQTT.Packet -> IO ()
clientReceiver gw state is = do
  r <- try (S.makeOutputStream handler >>= S.connect is) :: IO (Either SomeException ())
  debugM "MQTT.Gateway" $ "clientReceiver exit: " ++ show r

  where
    handler Nothing  = return ()
    handler (Just p) = do
      debugM "MQTT.Gateway" $ "Received: " ++ show p
      case p of
        MQTT.CONNECT connect -> do
          stop <- atomically $ do
            -- Accept all connections.
            connected <- readTVar (gcConnected state)
            when connected $ throwSTM MQTTError

            if MQTT.connectProtocolLevel connect /= 4
              then do
                sendPacket state (MQTT.CONNACK $ MQTT.ConnackPacket False MQTT.UnacceptableProtocol)
                return True
              else do
                sendPacket state (MQTT.CONNACK $ MQTT.ConnackPacket False MQTT.Accepted)
                writeTVar (gcConnected state) True

                mx <- STM.Map.lookup (MQTT.connectClientIdentifier connect) (gClients gw)
                STM.Map.insert state (MQTT.connectClientIdentifier connect) (gClients gw)
                case mx of
                  Nothing -> return ()
                  Just x -> writeTQueue (gcSendQueue x) Nothing

                return False
          when stop $ throwIO MQTTError

        MQTT.PINGREQ _ -> atomically $ do
          checkConnected state
          sendPacket state (MQTT.PINGRESP MQTT.PingrespPacket)

        MQTT.SUBSCRIBE subscribe -> atomically $ do
          checkConnected state
          sendPacket state $
            MQTT.SUBACK (MQTT.SubackPacket
                          (MQTT.subscribePacketIdentifier subscribe)
                          [ Just MQTT.QoS0 ])
        _ -> return ()

sendPacket :: GatewayClient -> MQTT.Packet -> STM ()
sendPacket state p = do
  writeTQueue (gcSendQueue state) (Just p)

checkConnected :: GatewayClient -> STM ()
checkConnected state = do
  connected <- readTVar $ gcConnected state
  unless connected $ throwSTM MQTTError

clientSender :: OutputStream MQTT.Packet -> TQueue (Maybe MQTT.Packet) -> IO ()
clientSender os queue = do
  stmQueueStream queue >>= S.mapM_ logPacket >>= S.connectTo os
  debugM "MQTT.Gateway" $ "clientSender exit"
  where
    logPacket p = debugM "MQTT.Gateway" $ "Sending: " ++ show p
