{-# LANGUAGE RecordWildCards #-}
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
import           Control.Concurrent.STM (STM, TQueue, atomically, writeTQueue, newTQueueIO)
import           Control.Exception (Exception, finally, throwIO, SomeException, try)

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
newGatewayClient = GatewayClient <$> newTQueueIO

-- | Run client handling on the given streams.
--
-- Note that this function doesn't exit until connection is closed.
handleClient :: Gateway -> (InputStream MQTT.Packet, OutputStream MQTT.Packet) -> IO ()
handleClient gw (is, os) = do
  state <- newGatewayClient

  t <- forkIO $ receiverThread gw state is `finally`
    -- properly close sender queue
    atomically (writeTQueue (gcSendQueue state) Nothing)

  clientSender os (gcSendQueue state) `finally` killThread t

receiverThread :: Gateway -> GatewayClient -> InputStream MQTT.Packet -> IO ()
receiverThread gw state is = do
    r <- try (authenticator gw state is) :: IO (Either SomeException ())
    debugM "MQTT.Gateway" $ "Receiver exit: " ++ show r

authenticator :: Gateway -> GatewayClient -> InputStream MQTT.Packet -> IO ()
authenticator gw state is = do
  -- Possible pattern-match failure is intended
  Just (MQTT.CONNECT MQTT.ConnectPacket{..}) <- S.read is
  if connectProtocolLevel /= 4
    then
      atomically $
        sendPacket state (MQTT.CONNACK $ MQTT.ConnackPacket False MQTT.UnacceptableProtocol)
    else do
      atomically $ do
        sendPacket state (MQTT.CONNACK $ MQTT.ConnackPacket False MQTT.Accepted)

        mx <- STM.Map.lookup connectClientIdentifier (gClients gw)
        STM.Map.insert state connectClientIdentifier (gClients gw)
        case mx of
          Nothing -> return ()
          Just x -> writeTQueue (gcSendQueue x) Nothing

      S.makeOutputStream (packetHandler state) >>= S.connect is

packetHandler :: GatewayClient -> Maybe MQTT.Packet -> IO ()
packetHandler _     Nothing  = return ()
packetHandler state (Just p) = do
  debugM "MQTT.Gateway" $ "Received: " ++ show p
  case p of
    MQTT.CONNECT _ -> throwIO MQTTError

    MQTT.PINGREQ _ -> atomically $ do
      sendPacket state (MQTT.PINGRESP MQTT.PingrespPacket)

    MQTT.SUBSCRIBE subscribe -> atomically $ do
      sendPacket state $
        MQTT.SUBACK (MQTT.SubackPacket
                      (MQTT.subscribePacketIdentifier subscribe)
                      [ Just MQTT.QoS0 ])

    _ -> return ()

sendPacket :: GatewayClient -> MQTT.Packet -> STM ()
sendPacket state p = do
  writeTQueue (gcSendQueue state) (Just p)

clientSender :: OutputStream MQTT.Packet -> TQueue (Maybe MQTT.Packet) -> IO ()
clientSender os queue = do
  stmQueueStream queue >>= S.mapM_ logPacket >>= S.connectTo os
  debugM "MQTT.Gateway" $ "clientSender exit"
  where
    logPacket p = debugM "MQTT.Gateway" $ "Sending: " ++ show p
