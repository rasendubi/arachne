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
  , ClientConfig(..)
  , newGateway
  , handleAlienClient
  ) where

import           Control.Concurrent      (ThreadId, forkFinally, forkIO,
                                          killThread)
import           Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar)
import           Control.Concurrent.STM  (STM, TQueue, TVar, atomically,
                                          modifyTVar, newTQueue, newTVar,
                                          newTVarIO, readTVar, throwSTM,
                                          writeTQueue, writeTVar)
import           Control.Exception       (Exception, SomeException, finally,
                                          throwIO, try)
import           Control.Monad           (forM_, unless, when)
import           Control.Monad.Loops     (dropWhileM)
import           Data.Function           (on)
import qualified Data.Map.Strict         as Map
import           Data.Maybe              (fromJust)
import qualified Data.Sequence           as Seq
import qualified Data.Set                as Set
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
import           System.Random           (newStdGen, randomRs)

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type RequestId = MQTT.PacketIdentifier

data ClientResult
  = PublishResult MQTT.Message
  | SubscribeResult [(MQTT.TopicFilter, Maybe MQTT.QoS)]
  | UnsubscribeResult [MQTT.TopicFilter]
  deriving (Eq, Show)

data ClientCommand
  = PublishCommand MQTT.Message
  | SubscribeCommand [(MQTT.TopicFilter, MQTT.QoS)]
  | UnsubscribeCommand [MQTT.TopicFilter]
  deriving (Eq, Show)

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
  {
  -- | Represents Gateway Clients which were created for handling Alien Clients.
    gClients                :: STM.Map MQTT.ClientIdentifier GatewayClient
  -- | Represents subscriptions which Gateway has (which were acknowledged by the main Broker).
  , gSubscriptions          :: STM.Map MQTT.TopicFilter MQTT.QoS
  -- TODO add doc
  , gAwaitingGatewayClients :: STM.Map RequestId (Set.Set GatewayClient)
  -- | Represents subscriptions which each Gateway Client has (contains specific level of quality of service).
  , gClientSubscriptions    :: TVar (TT.TopicFilterTrie (Map.Map GatewayClient MQTT.QoS))
  -- | Represents communication channel between Gateway and Broker Client
  , gBrokerCommandsStream   :: OutputStream ClientCommand
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

  t <- forkIO $ gatewayClientReceiverThread gw mqttSession is `finally`
    -- properly close sender queue
    atomically (closeSenderQueue mqttSession)

  sender mqttSession os `finally` killThread t

gatewayClientReceiverThread :: Gateway -> MqttSession -> InputStream MQTT.Packet -> IO ()
gatewayClientReceiverThread gw mqttSession is = do
    r <- try (gatewayClientAuthenticator gw mqttSession is) :: IO (Either SomeException ())
    debugM "MQTT.GatewayClient" $ "Receiver exit: " ++ show r

gatewayClientAuthenticator :: Gateway -> MqttSession -> InputStream MQTT.Packet -> IO ()
gatewayClientAuthenticator gw mqttSession is = do
  -- Possible pattern-match failure is intended
  Just (MQTT.CONNECT MQTT.ConnectPacket{..}) <- S.read is
  if connectProtocolLevel /= 4
    then
      atomically $
        sendPacket mqttSession (MQTT.CONNACK $ MQTT.ConnackPacket False MQTT.UnacceptableProtocol)
    else do
      gwc <- atomically $ do
        sendPacket mqttSession (MQTT.CONNACK $ MQTT.ConnackPacket False MQTT.Accepted)

        mx <- STM.Map.lookup connectClientIdentifier (gClients gw)
        let gwc = GatewayClient mqttSession connectClientIdentifier
        STM.Map.insert gwc
          connectClientIdentifier (gClients gw)
        case mx of
          Nothing -> return ()
          Just x  -> closeSenderQueue (gcMqttSession x)
        return gwc

      S.makeOutputStream (gatewayClientPacketHandler gw gwc) >>= S.connect is

gatewayClientPacketHandler :: Gateway -> GatewayClient -> Maybe MQTT.Packet -> IO ()
gatewayClientPacketHandler _  _ Nothing = return ()
gatewayClientPacketHandler gw gwc (Just p) = do
  let mqttSession = gcMqttSession gwc
  debugM "MQTT.GatewayClient" $ "Received: " ++ show p
  case p of
    MQTT.CONNECT _ -> throwIO MQTTError

    MQTT.PINGREQ _ -> atomically $ do
      sendPacket mqttSession (MQTT.PINGRESP MQTT.PingrespPacket)

    MQTT.SUBSCRIBE subscribe@MQTT.SubscribePacket{..} -> do
      forM_ subscribeTopicFiltersQoS $ \(topicFilter, qos) -> do
        present <- atomically $ do
          gwSubscription <- STM.Map.lookup topicFilter (gSubscriptions gw)
          case gwSubscription of
            Just gwQos -> do
              if fromEnum qos <= fromEnum gwQos
                then do
                  sendPacket mqttSession $ MQTT.SUBACK (MQTT.SubackPacket subscribePacketIdentifier [Just qos])
                  readTVar (gClientSubscriptions gw) >>= \clientsSubscriptions-> do
                    case (TT.lookup topicFilter clientsSubscriptions) of
                      Just clientsSubscription -> writeTVar (gClientSubscriptions gw) $ do
                        TT.insert topicFilter (Map.insert gwc qos clientsSubscription) clientsSubscriptions
                      Nothing -> writeTVar (gClientSubscriptions gw) $ do
                        TT.insert topicFilter (Map.singleton gwc qos) clientsSubscriptions
                  return True
                else do
  -- insert to , gAwaitingGatewayClients :: STM.Map RequestId (Set.Set GatewayClient)
                  return False
            Nothing -> do
  -- insert to , gAwaitingGatewayClients :: STM.Map RequestId (Set.Set GatewayClient)
              return False

        unless present $ brokerClientSubscribe (gBrokerCommandsStream gw) [(topicFilter, qos)]


    MQTT.UNSUBSCRIBE MQTT.UnsubscribePacket{..} -> atomically $ do
      sendPacket mqttSession $
        MQTT.UNSUBACK (MQTT.UnsubackPacket unsubscribePacketIdentifier)

    _ -> return ()

--------------------------------------------------------------------------------
-- Gateway creation
--------------------------------------------------------------------------------

newGateway :: ClientConfig -> (InputStream MQTT.Packet, OutputStream MQTT.Packet) -> IO Gateway
newGateway config brokerStreams = do
  mqttSession <- newMqttSession

  command_os <- connectBrokerClient config mqttSession (snd brokerStreams)
  gw <- Gateway <$> STM.Map.newIO
                <*> STM.Map.newIO
                <*> STM.Map.newIO
                <*> newTVarIO TT.empty
                <*> pure command_os

  _ <- forkIO $ brokerClientReceiverThread gw mqttSession (fst brokerStreams) `finally`
    -- properly close sender queue
    atomically (closeSenderQueue mqttSession)

  return gw

connectBrokerClient :: ClientConfig -> MqttSession -> OutputStream MQTT.Packet -> IO (OutputStream ClientCommand)
connectBrokerClient ClientConfig{..} mqttSession os = do
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

  sender mqttSession os -- TODO `finally` killThread t ?

  S.lockingOutputStream =<< S.contramapM_ logPacket =<< S.makeOutputStream (brokerClientCommandHandler mqttSession)
    where
      logPacket p = debugM "MQTT.BrokerClient" $ "BrokerClient command: " ++ show p

brokerClientCommandHandler :: MqttSession -> Maybe ClientCommand -> IO ()
brokerClientCommandHandler _ Nothing = return ()
brokerClientCommandHandler mqttSession (Just (PublishCommand publishMessage)) = atomically $ do
  let publishDup = False

  if MQTT.messageQoS publishMessage == MQTT.QoS0
    then writeTQueue (msSenderQueue mqttSession) $ Just $ MQTT.PUBLISH
      MQTT.PublishPacket{ publishDup              = publishDup
                        , publishMessage          = publishMessage
                        , publishPacketIdentifier = Nothing
                        }
    else do
      publishPacketIdentifier <- Just <$> genPacketIdentifier mqttSession
      modifyTVar (msUnAckSentPublishPackets mqttSession) $ \p -> p Seq.|> MQTT.PublishPacket{..}
      sendPacket mqttSession $ MQTT.PUBLISH MQTT.PublishPacket{..}
brokerClientCommandHandler mqttSession (Just (SubscribeCommand subscribeTopicFiltersQoS)) = atomically $ do
  subscribePacketIdentifier <- genPacketIdentifier mqttSession
  modifyTVar (msUnAckSentSubscribePackets mqttSession) $ \p -> p Seq.|> MQTT.SubscribePacket{..}
  writeTQueue (msSenderQueue mqttSession) (Just $ MQTT.SUBSCRIBE MQTT.SubscribePacket{..})
brokerClientCommandHandler mqttSession (Just (UnsubscribeCommand unsubscribeTopicFilters)) = atomically $ do
  unsubscribePacketIdentifier <- genPacketIdentifier mqttSession
  modifyTVar (msUnAckSentUnsubscribePackets mqttSession) $ \p -> p Seq.|> MQTT.UnsubscribePacket{..}
  writeTQueue (msSenderQueue mqttSession) (Just $ MQTT.UNSUBSCRIBE MQTT.UnsubscribePacket{..})

brokerClientReceiverThread :: Gateway -> MqttSession -> InputStream MQTT.Packet -> IO ()
brokerClientReceiverThread gw mqttSession is = do
    r <- try (brokerClientAuthenticator gw mqttSession is) :: IO (Either SomeException ())
    debugM "MQTT.BrokerClient" $ "Receiver exit: " ++ show r

brokerClientAuthenticator :: Gateway -> MqttSession -> InputStream MQTT.Packet -> IO ()
brokerClientAuthenticator gw mqttSession is = do
  -- Possible pattern-match failure is intended
  Just (MQTT.CONNACK MQTT.ConnackPacket{..}) <- S.read is
  unless (connackReturnCode /= MQTT.Accepted) $ do
        S.makeOutputStream (brokerClientPacketHandler gw mqttSession) >>= S.connect is

brokerClientPacketHandler :: Gateway -> MqttSession -> Maybe MQTT.Packet -> IO ()
brokerClientPacketHandler _  _ Nothing = return ()
brokerClientPacketHandler gw mqttSession (Just p) = do
  debugM "MQTT.BrokerClient" $ "Received: " ++ show p
  case p of
    MQTT.CONNACK _ -> throwIO MQTTError

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
        MQTT.QoS0 -> do
          brokerClientResultHandler gw (Just $ PublishResult (MQTT.publishMessage publishPacket))
        MQTT.QoS1 -> do
          brokerClientResultHandler gw (Just $ PublishResult (MQTT.publishMessage publishPacket))
          atomically $ sendPacket mqttSession $ MQTT.PUBACK (MQTT.PubackPacket packetIdentifier)
        MQTT.QoS2 -> do
          present <- atomically $ do
            sendPacket mqttSession $ MQTT.PUBREC (MQTT.PubrecPacket packetIdentifier)

            let s = msUnAckReceivedPublishIds mqttSession
            present <- STM.Set.lookup packetIdentifier s
            unless present $ STM.Set.insert packetIdentifier s
            return present

          unless present $ brokerClientResultHandler gw (Just $ PublishResult (MQTT.publishMessage publishPacket))

    MQTT.PUBREL pubrelPacket -> atomically $ do
      let packetIdentifier = MQTT.pubrelPacketIdentifier pubrelPacket
      STM.Set.delete packetIdentifier $ msUnAckReceivedPublishIds mqttSession
      sendPacket mqttSession $ MQTT.PUBCOMP (MQTT.PubcompPacket packetIdentifier)

    MQTT.SUBACK subackPacket -> do
      topicFilters <- atomically $ do
        let packetIdentifier = MQTT.subackPacketIdentifier subackPacket
        unAckSentSubscribePackets <- readTVar $ msUnAckSentSubscribePackets mqttSession
        let subscribePacket = Seq.index unAckSentSubscribePackets 0
        when (MQTT.subscribePacketIdentifier subscribePacket /= packetIdentifier) $ throwSTM MQTTError
        writeTVar (msUnAckSentSubscribePackets mqttSession) $ Seq.drop 1 unAckSentSubscribePackets
        STM.Set.delete packetIdentifier $ msUsedPacketIdentifiers mqttSession
        return $ fst <$> MQTT.subscribeTopicFiltersQoS subscribePacket
      brokerClientResultHandler gw (Just $ SubscribeResult (zip topicFilters (MQTT.subackResponses subackPacket)))

    MQTT.UNSUBACK unsubackPacket -> do
      unsubscribePacket <- atomically $ do
        let packetIdentifier = MQTT.unsubackPacketIdentifier unsubackPacket
        unAckSentUnsubscribePackets <- readTVar $ msUnAckSentUnsubscribePackets mqttSession
        let unsubscribePacket = Seq.index unAckSentUnsubscribePackets 0
        when (MQTT.unsubscribePacketIdentifier unsubscribePacket /= packetIdentifier) $ throwSTM MQTTError
        writeTVar (msUnAckSentUnsubscribePackets mqttSession) $ Seq.drop 1 unAckSentUnsubscribePackets
        STM.Set.delete packetIdentifier $ msUsedPacketIdentifiers mqttSession
        return unsubscribePacket
      brokerClientResultHandler gw (Just $ UnsubscribeResult (MQTT.unsubscribeTopicFilters unsubscribePacket))

    _ -> return ()

brokerClientResultHandler :: Gateway -> Maybe ClientResult -> IO ()
brokerClientResultHandler _ Nothing = return ()
brokerClientResultHandler gw (Just (PublishResult message)) = atomically $ do
  readTVar (gClientSubscriptions gw) >>= \clientsSubscriptions-> do
    forM_ (TT.matches (MQTT.messageTopic message) clientsSubscriptions) $ \clientsSubscription -> do
      forM_ (Map.toList clientsSubscription) $ \(client, qos) -> do
        packetIdentifier <- getPublishPacketIdentifier (MQTT.messageQoS message) (gcMqttSession client)
        sendPacket (gcMqttSession client) $ MQTT.PUBLISH
          MQTT.PublishPacket { MQTT.publishDup              = False
                             , MQTT.publishMessage          = message { MQTT.messageQoS = min qos (MQTT.messageQoS message) }
                             , MQTT.publishPacketIdentifier = packetIdentifier
                             }
    where
      getPublishPacketIdentifier MQTT.QoS0 _     = pure Nothing
      getPublishPacketIdentifier _         state = Just <$> genPacketIdentifier state
brokerClientResultHandler gw (Just (SubscribeResult subscribeResult)) = atomically $ do
  undefined

brokerClientPublish :: OutputStream ClientCommand -> MQTT.Message -> IO ()
brokerClientPublish os = writeTo os . PublishCommand

brokerClientSubscribe :: OutputStream ClientCommand -> [(MQTT.TopicFilter, MQTT.QoS)] -> IO ()
brokerClientSubscribe os = writeTo os . SubscribeCommand

brokerClientUnsubscribe :: OutputStream ClientCommand -> [MQTT.TopicFilter] -> IO ()
brokerClientUnsubscribe os = writeTo os . UnsubscribeCommand

writeTo :: OutputStream a -> a -> IO ()
writeTo os x = S.write (Just x) os

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
