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
import           Control.Concurrent.STM (TQueue, TVar, atomically, readTVar, writeTQueue, writeTVar, newTQueueIO, newTVarIO)
import           Control.Exception (Exception, finally, throwIO, SomeException, try)

import           Control.Monad (unless)

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
      cont <- atomically $ do
        case p of
          MQTT.CONNECT connect -> do
            -- Accept all connections.
            connected <- readTVar (gcConnected state)

            -- TODO ExceptT
            if connected
              then return False
              else do
                if MQTT.connectProtocolLevel connect /= 4
                  then do
                    writeTQueue (gcSendQueue state) (Just $ MQTT.CONNACK $ MQTT.ConnackPacket False MQTT.UnacceptableProtocol)
                    return False
                  else do
                    writeTQueue (gcSendQueue state) (Just $ MQTT.CONNACK $ MQTT.ConnackPacket False MQTT.Accepted)
                    writeTVar (gcConnected state) True

                    mx <- STM.Map.lookup (MQTT.connectClientIdentifier connect) (gClients gw)
                    STM.Map.insert state (MQTT.connectClientIdentifier connect) (gClients gw)
                    case mx of
                      Nothing -> return ()
                      Just x -> writeTQueue (gcSendQueue x) Nothing

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
