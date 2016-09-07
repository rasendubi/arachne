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
  , handleAlienClient
  ) where

import           Data.Function           (on)
import           Control.Concurrent      (ThreadId, forkFinally, forkIO,
                                          killThread)
import           Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar)
import           Control.Concurrent.STM  (STM, TQueue, TVar, atomically,
                                          modifyTVar, newTQueue, newTVar,
                                          newTVarIO, readTVar, throwSTM,
                                          writeTQueue, writeTVar)
import           Control.Exception       (Exception, SomeException, finally,
                                          throwIO, try)
import           Control.Monad           (unless, when)
import           Control.Monad.Loops     (dropWhileM)
import qualified Data.Map.Strict         as Map
import           Data.Maybe              (fromJust)
import qualified Data.Sequence           as Seq
import qualified Data.Text               as T
import qualified Data.TopicFilterTrie    as TT
import           Data.Word               (Word16)
import qualified Network.MQTT.Packet     as MQTT
import           Network.MQTT.Utils
import           Network.Socket          (AddrInfo)
import qualified STMContainers.Map       as STM (Map)
import qualified STMContainers.Map       as STM.Map
import qualified STMContainers.Set       as STM (Set)
import qualified STMContainers.Set       as STM.Set
import           System.IO.Streams       (InputStream, OutputStream)
import qualified System.IO.Streams       as S
import           System.Log.Logger       (debugM)
import           System.Random           (StdGen, newStdGen, randomRs)

--------------------------------------------------------------------------------
-- Data declarations
--------------------------------------------------------------------------------

data UserCredentials =
  UserCredentials
  { userName :: MQTT.UserName
  , password :: Maybe MQTT.Password
  }

data ClientConfig =
  ClientConfig
  { ccClientIdentifier :: !MQTT.ClientIdentifier
  , ccWillMsg          :: !(Maybe MQTT.Message)
  , ccUserCredentials  :: !(Maybe UserCredentials)
  , ccCleanSession     :: !Bool
  , ccKeepAlive        :: !Word16
  }

data Gateway =
  Gateway
  { gClients               :: STM.Map MQTT.ClientIdentifier GatewayClient
  , gClientSubscriptions   :: TVar (TT.TopicFilterTrie (Map.Map GatewayClient MQTT.QoS))
  }

data MqttSession =
  MqttSession
  { msSenderQueue                 :: TQueue (Maybe MQTT.Packet)
  , msUsedPacketIdentifiers       :: STM.Set MQTT.PacketIdentifier
  , msRandomVals                  :: TVar [Word16]
  , msUnAckSentPublishPackets     :: TVar (Seq.Seq MQTT.PublishPacket)
  , msUnAckSentPubrelPackets      :: TVar (Seq.Seq MQTT.PubrelPacket)
  , msUnAckSentSubscribePackets   :: TVar (Seq.Seq MQTT.SubscribePacket)
  , msUnAckSentUnsubscribePackets :: TVar (Seq.Seq MQTT.UnsubscribePacket)
  , msUnAckReceivedPublishIds     :: STM.Set MQTT.PacketIdentifier
  }

data GatewayClient =
  GatewayClient
  { gcMqttSession      :: !MqttSession
  , gcClientIdentifier :: !MQTT.ClientIdentifier
  }

data BrokerClient =
  BrokerClient
  { bcMqttSession :: !MqttSession
  }

data MQTTError = MQTTError
  deriving (Show)

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------

instance Exception MQTTError

instance Eq GatewayClient where
  (==) = (==) `on` gcClientIdentifier

instance Ord GatewayClient where
  compare = compare `on` gcClientIdentifier

--------------------------------------------------------------------------------
-- Handle client flow
--------------------------------------------------------------------------------

-- | Run client handling on the given streams.
--
-- Note that this function doesn't exit until connection is closed.
handleAlienClient :: Gateway -> (InputStream MQTT.Packet, OutputStream MQTT.Packet) -> IO ()
handleAlienClient gw (is, os) = do
  mqttSession <- newMqttSession

  t <- forkIO $ receiverThread gw mqttSession is True `finally`
    -- properly close sender queue
    atomically (closeSenderQueue mqttSession)

  sender mqttSession os `finally` killThread t

--------------------------------------------------------------------------------
-- Gateway creation
--------------------------------------------------------------------------------

newGateway :: ClientConfig -> (InputStream MQTT.Packet, OutputStream MQTT.Packet) -> IO Gateway
newGateway config brokerStreams = do
  gw <- Gateway <$> STM.Map.newIO
                <*> newTVarIO TT.empty

  connectClient config gw brokerStreams

  return gw

connectClient :: ClientConfig -> Gateway -> (InputStream MQTT.Packet, OutputStream MQTT.Packet) -> IO ()
connectClient ClientConfig{..} gw (is,os) = do
  mqttSession <- newMqttSession

  t <- forkIO $ receiverThread gw mqttSession is False `finally`
    -- properly close sender queue
    atomically (closeSenderQueue mqttSession)

  sendConnect mqttSession
    MQTT.ConnectPacket
    { connectClientIdentifier = ccClientIdentifier
    , connectProtocolLevel    = 0x04
    , connectWillMsg          = ccWillMsg
    , connectUserName         = fmap userName ccUserCredentials
    , connectPassword         = maybe Nothing password ccUserCredentials
    , connectCleanSession     = ccCleanSession
    , connectKeepAlive        = ccKeepAlive
    }

  sender mqttSession os `finally` killThread t

--------------------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------------------

genPacketIdentifier :: MqttSession -> STM MQTT.PacketIdentifier
genPacketIdentifier mqttSession = do
  randomVals <- readTVar $ msRandomVals mqttSession
  (identifier : restIds) <- dropWhileM
    (\i -> STM.Set.lookup (MQTT.PacketIdentifier i) $ msUsedPacketIdentifiers mqttSession) randomVals
  writeTVar (msRandomVals mqttSession) restIds
  let packetIdentifier = MQTT.PacketIdentifier identifier
  STM.Set.insert packetIdentifier $ msUsedPacketIdentifiers mqttSession
  return packetIdentifier

sender :: MqttSession -> OutputStream MQTT.Packet -> IO ()
sender mqttSession os = do
  stmQueueStream (msSenderQueue mqttSession) >>= S.mapM_ logPacket >>= S.connectTo os
  debugM "MQTT.Gateway" $ "sender exit"
  where
    logPacket p = debugM "MQTT.Gateway" $ "Sending: " ++ show p

closeSenderQueue :: MqttSession -> STM ()
closeSenderQueue mqttSession = writeTQueue (msSenderQueue mqttSession) Nothing

sendPacket :: MqttSession -> MQTT.Packet -> STM ()
sendPacket mqttSession p = writeTQueue (msSenderQueue mqttSession) $ Just p

sendConnect :: MqttSession -> MQTT.ConnectPacket -> IO ()
sendConnect mqttSession connectPacket = atomically $ do
  sendPacket mqttSession $ MQTT.CONNECT connectPacket

packetHandler :: Gateway -> MqttSession -> Maybe MQTT.Packet -> IO ()
packetHandler _  _ Nothing = return ()
packetHandler gw mqttSession (Just p) = do
  debugM "MQTT.GatewayClient" $ "Received: " ++ show p
  case p of
    MQTT.CONNECT _ -> throwIO MQTTError

    MQTT.PINGREQ _ -> atomically $ do
      sendPacket mqttSession (MQTT.PINGRESP MQTT.PingrespPacket)

    MQTT.UNSUBSCRIBE MQTT.UnsubscribePacket{..} -> atomically $ do
      sendPacket mqttSession $
        MQTT.UNSUBACK (MQTT.UnsubackPacket unsubscribePacketIdentifier)

    MQTT.PUBACK pubackPacket -> atomically $ do
      unAckSentPublishPackets <- readTVar $ msUnAckSentPublishPackets mqttSession
      let packetIdentifier = MQTT.pubackPacketIdentifier pubackPacket
      let (xs, ys) = Seq.breakl (\pp -> fromJust (MQTT.publishPacketIdentifier pp) == packetIdentifier) unAckSentPublishPackets
      let publishPacket = Seq.index ys 0
      when (MQTT.messageQoS (MQTT.publishMessage publishPacket) /= MQTT.QoS1) $ throwSTM MQTTError
      writeTVar (msUnAckSentPublishPackets mqttSession) $ xs Seq.>< Seq.drop 1 ys
      STM.Set.delete packetIdentifier $ msUsedPacketIdentifiers mqttSession

    MQTT.PUBREC pubrecPacket -> atomically $ do
      unAckSentPublishPackets <- readTVar $ msUnAckSentPublishPackets mqttSession
      let packetIdentifier = MQTT.pubrecPacketIdentifier pubrecPacket
      let (xs, ys) = Seq.breakl (\pp -> fromJust (MQTT.publishPacketIdentifier pp) == packetIdentifier) unAckSentPublishPackets
      let publishPacket = Seq.index ys 0
      when (MQTT.messageQoS (MQTT.publishMessage publishPacket) /= MQTT.QoS2) $ throwSTM MQTTError
      let pubrelPacket = MQTT.PubrelPacket packetIdentifier
      writeTVar (msUnAckSentPublishPackets mqttSession) $ xs Seq.>< Seq.drop 1 ys
      modifyTVar (msUnAckSentPubrelPackets mqttSession) $ \pp -> pp Seq.|> pubrelPacket
      sendPacket mqttSession $ MQTT.PUBREL pubrelPacket

    MQTT.PUBCOMP pubcompPacket -> atomically $ do
      unAckSentPubrelPackets <- readTVar $ msUnAckSentPubrelPackets mqttSession
      let packetIdentifier = MQTT.pubcompPacketIdentifier pubcompPacket
      let pubrelPacket = Seq.index unAckSentPubrelPackets 0
      when (MQTT.pubrelPacketIdentifier pubrelPacket /= packetIdentifier) $ throwSTM MQTTError
      writeTVar (msUnAckSentPubrelPackets mqttSession) $ Seq.drop 1 unAckSentPubrelPackets
      STM.Set.delete packetIdentifier $ msUsedPacketIdentifiers mqttSession

    MQTT.PUBLISH publishPacket -> do
      let qos = MQTT.messageQoS $ MQTT.publishMessage publishPacket
      let packetIdentifier = fromJust $ MQTT.publishPacketIdentifier publishPacket
      case qos of
        MQTT.QoS0 -> return ()
        MQTT.QoS1 -> atomically $ do
          sendPacket mqttSession $ MQTT.PUBACK (MQTT.PubackPacket packetIdentifier)
        MQTT.QoS2 -> atomically $ do
          sendPacket mqttSession $ MQTT.PUBREC (MQTT.PubrecPacket packetIdentifier)
          let s = msUnAckReceivedPublishIds mqttSession
          present <- STM.Set.lookup packetIdentifier s
          unless present $ STM.Set.insert packetIdentifier s
      undefined


    MQTT.PUBREL pubrelPacket -> atomically $ do
      let packetIdentifier = MQTT.pubrelPacketIdentifier pubrelPacket
      STM.Set.delete packetIdentifier $ msUnAckReceivedPublishIds mqttSession
      sendPacket mqttSession $ MQTT.PUBCOMP (MQTT.PubcompPacket packetIdentifier)

    _ -> return ()

newMqttSession :: IO MqttSession
newMqttSession = do
  newStdGen >>= \gen -> atomically $ do
    MqttSession <$> newTQueue
                <*> STM.Set.new
                <*> newTVar (randomRs (0, 65535) gen)
                <*> newTVar Seq.empty
                <*> newTVar Seq.empty
                <*> newTVar Seq.empty
                <*> newTVar Seq.empty
                <*> STM.Set.new

receiverThread :: Gateway -> MqttSession -> InputStream MQTT.Packet -> Bool -> IO ()
receiverThread gw mqttSession is is_server = do
    r <- try (authenticator gw mqttSession is is_server) :: IO (Either SomeException ())
    debugM "MQTT.Gateway" $ "Receiver exit: " ++ show r

authenticator :: Gateway -> MqttSession -> InputStream MQTT.Packet -> Bool -> IO ()
authenticator gw mqttSession is is_server = do
  if is_server
    then do
      -- Possible pattern-match failure is intended
      Just (MQTT.CONNECT MQTT.ConnectPacket{..}) <- S.read is
      if connectProtocolLevel /= 4
        then
          atomically $
            sendPacket mqttSession (MQTT.CONNACK $ MQTT.ConnackPacket False MQTT.UnacceptableProtocol)
        else do
          atomically $ do
            sendPacket mqttSession (MQTT.CONNACK $ MQTT.ConnackPacket False MQTT.Accepted)

            mx <- STM.Map.lookup connectClientIdentifier (gClients gw)
            STM.Map.insert (GatewayClient mqttSession connectClientIdentifier)
              connectClientIdentifier (gClients gw)
            case mx of
              Nothing -> return ()
              Just x -> closeSenderQueue (gcMqttSession x)

          S.makeOutputStream (packetHandler gw mqttSession) >>= S.connect is
    else do
      -- Possible pattern-match failure is intended
      Just (MQTT.CONNACK MQTT.ConnackPacket{..}) <- S.read is
      unless (connackReturnCode /= MQTT.Accepted) $ do
            S.makeOutputStream (packetHandler gw mqttSession) >>= S.connect is
