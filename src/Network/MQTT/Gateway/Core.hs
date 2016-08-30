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

import           Control.Concurrent        (forkIO, killThread)
import           Control.Concurrent.STM    (STM, TQueue, TVar, atomically,
                                            modifyTVar, newTQueue, newTVar,
                                            newTVarIO, readTVar, throwSTM,
                                            writeTQueue, writeTVar)
import           Control.Exception         (Exception, SomeException, finally,
                                            throwIO, try)
import           Control.Monad             (forM_, unless, when)
import           Control.Monad.Loops       (dropWhileM)
import qualified Data.Map.Strict           as Map
import           Data.Maybe                (fromJust)
import qualified Data.Sequence             as Seq
import qualified Data.Text                 as T
import qualified Data.TopicFilterTrie      as TT
import           Data.Word                 (Word16)
import           Network.MQTT.Client       as Client
import           Network.MQTT.Client.Utils as ClientUtils
import qualified Network.MQTT.Packet       as MQTT
import           Network.MQTT.Utils
import qualified STMContainers.Map         as STM (Map)
import qualified STMContainers.Map         as STM.Map
import qualified STMContainers.Set         as STM (Set)
import qualified STMContainers.Set         as STM.Set
import           System.IO.Streams         (InputStream, OutputStream)
import qualified System.IO.Streams         as S
import           System.Log.Logger         (debugM)
import           System.Random             (newStdGen, randomRs)


-- | Internal gateway state.
data Gateway =
  Gateway {
  -- | Represents Gateway Clients which were created for handling Alien Clients.
    gClients               :: STM.Map MQTT.ClientIdentifier GatewayClient

  -- | Represents subscriptions which Gateway has (which were acknowledged by the main Broker).
  , gSubscriptions         :: STM.Map MQTT.TopicFilter MQTT.QoS

  -- | Represents awaiting for acknowledgment Subscribe packets which were received from Alien Clients.
  , gUnAckSubscribePackets :: STM.Map MQTT.SubscribePacket GatewayClient

  -- | Represents subscriptions which each Gateway Client has (contains specific level of quality of service).
  , gClientSubscriptions   :: TVar (TT.TopicFilterTrie (Map.Map GatewayClient MQTT.QoS))

  -- | Represents communication channel between Gateway and Client (which sends data to the main Broker).
  -- Use it for sending data to the Client.
  , gClientCommands        :: OutputStream ClientCommand
  }

data GatewayClient =
  GatewayClient
  { gcClientIdentifier        :: TVar MQTT.ClientIdentifier
  , gcSendQueue               :: TQueue (Maybe MQTT.Packet)
  , gcUsedPacketIdentifiers   :: STM.Set MQTT.PacketIdentifier
  , gcRandomVals              :: TVar [Word16]
  , gcUnAckSentPublishPackets :: TVar (Seq.Seq MQTT.PublishPacket)
  , gcUnAckSentPubrelPackets  :: TVar (Seq.Seq MQTT.PubrelPacket)
  , gcUnAckReceivedPublishIds :: STM.Set MQTT.PacketIdentifier
  }

data MQTTError = MQTTError
  deriving (Show)

instance Exception MQTTError

instance Eq GatewayClient where
  gw1 == gw2 = (gcClientIdentifier gw1) == (gcClientIdentifier gw2)

instance Ord GatewayClient where
  gw1 `compare` gw2 = gw1 `compare` gw2

-- | Creates a new Gateway.
--
newGateway :: (InputStream ClientResult, OutputStream ClientCommand) -> IO Gateway
newGateway (client_result, client_command) = do
  gw <- Gateway <$> STM.Map.newIO
                <*> STM.Map.newIO
                <*> STM.Map.newIO
                <*> newTVarIO TT.empty
                <*> pure client_command

  S.makeOutputStream (clientResultHandler gw) >>= S.connect client_result

  return gw

genPacketIdentifier :: GatewayClient -> STM MQTT.PacketIdentifier
genPacketIdentifier state = do
  randomVals <- readTVar $ gcRandomVals state
  (identifier : restIds) <- dropWhileM
    (\i -> STM.Set.lookup (MQTT.PacketIdentifier i) $ gcUsedPacketIdentifiers state) randomVals
  writeTVar (gcRandomVals state) restIds
  let packetIdentifier = MQTT.PacketIdentifier identifier
  STM.Set.insert packetIdentifier $ gcUsedPacketIdentifiers state
  return packetIdentifier

clientResultHandler :: Gateway -> Maybe ClientResult -> IO ()
clientResultHandler _ Nothing = return ()
clientResultHandler gw (Just (Client.PublishResult message)) = atomically $ do
  readTVar (gClientSubscriptions gw) >>= \clientsSubscriptions-> do
    forM_ (TT.matches (MQTT.messageTopic message) clientsSubscriptions) $ \clientsSubscription -> do
      forM_ (Map.toList clientsSubscription) $ \(state, qos) -> do
        packetIdentifier <- getPublishPacketIdentifier (MQTT.messageQoS message) state
        sendPacket state $ MQTT.PUBLISH
          MQTT.PublishPacket { MQTT.publishDup              = False
                             , MQTT.publishMessage          = message { MQTT.messageQoS = min qos (MQTT.messageQoS message) }
                             , MQTT.publishPacketIdentifier = packetIdentifier
                             }
    where
      getPublishPacketIdentifier MQTT.QoS0 _     = pure Nothing
      getPublishPacketIdentifier _         state = Just <$> genPacketIdentifier state

clientResultHandler gw (Just (Client.SubscribeResult subscribeResult))   = atomically $ do
  undefined
  -- TODO read about subscribe flow in spec; ask rasen
  -- receive subscribe result
  -- check if we have unacknowledged subscribe packets with such topic filter
  -- if yes -- remove entity; send suback; put to client subscription
  -- if no -- check gateway subscriptions:
  -- if yes -- update subscription; update trie

  -- forM_ subscribeResult $ \(topicFilter, qos) -> do
  --   gSubscriptions gw >>= \subscriptions -> do
  --     case STM.Map.lookup topicFilter subscriptions of
  --       Just

clientResultHandler gw (Just (Client.UnsubscribeResult unsubscribeResult)) = undefined

newGatewayClient :: IO GatewayClient
newGatewayClient = do
  gen <- newStdGen
  atomically $ GatewayClient <$> newTVar (MQTT.ClientIdentifier $ T.pack "")
                             <*> newTQueue
                             <*> STM.Set.new
                             <*> newTVar (randomRs (0, 65535) gen)
                             <*> newTVar Seq.empty
                             <*> newTVar Seq.empty
                             <*> STM.Set.new

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
        modifyTVar (gcClientIdentifier state) (const connectClientIdentifier)
        STM.Map.insert state connectClientIdentifier (gClients gw)
        case mx of
          Nothing -> return ()
          Just x  -> writeTQueue (gcSendQueue x) Nothing

      S.makeOutputStream (packetHandler gw state) >>= S.connect is

packetHandler :: Gateway -> GatewayClient -> Maybe MQTT.Packet -> IO ()
packetHandler _  _     Nothing  = return ()
packetHandler gw state (Just p) = do
  debugM "MQTT.Gateway" $ "Received: " ++ show p
  case p of
    MQTT.CONNECT _ -> throwIO MQTTError

    MQTT.PINGREQ _ -> atomically $ do
      sendPacket state (MQTT.PINGRESP MQTT.PingrespPacket)

    MQTT.SUBSCRIBE subscribe@MQTT.SubscribePacket{..} -> do
      forM_ subscribeTopicFiltersQoS $ \(topicFilter, qos) -> do
        present <- atomically $ do
          gwSubscription <- STM.Map.lookup topicFilter (gSubscriptions gw)
          case gwSubscription of
            Just gwQos -> do
              if fromEnum qos <= fromEnum gwQos
                then do
                  sendPacket state $ MQTT.SUBACK (MQTT.SubackPacket subscribePacketIdentifier [Just qos])
                  readTVar (gClientSubscriptions gw) >>= \clientsSubscriptions-> do
                    case (TT.lookup topicFilter clientsSubscriptions) of
                      Just clientsSubscription -> modifyTVar (gClientSubscriptions gw) $ do
                        \tt -> TT.insert topicFilter (Map.insert state qos clientsSubscription) tt
                      Nothing -> modifyTVar (gClientSubscriptions gw) $ do
                        \tt -> TT.insert topicFilter (Map.singleton state qos) tt
                  return True
                else do
                  STM.Map.insert state subscribe (gUnAckSubscribePackets gw)
                  return False
            Nothing -> do
              STM.Map.insert state subscribe (gUnAckSubscribePackets gw)
              return False

        unless present $ ClientUtils.subscribe (gClientCommands gw) [(topicFilter, qos)]

    MQTT.UNSUBSCRIBE MQTT.UnsubscribePacket{..} -> atomically $ do
      sendPacket state $
        MQTT.UNSUBACK (MQTT.UnsubackPacket unsubscribePacketIdentifier)

    MQTT.PUBACK pubackPacket -> atomically $ do
      unAckSentPublishPackets <- readTVar $ gcUnAckSentPublishPackets state
      let packetIdentifier = MQTT.pubackPacketIdentifier pubackPacket
      let (xs, ys) = Seq.breakl (\pp -> fromJust (MQTT.publishPacketIdentifier pp) == packetIdentifier) unAckSentPublishPackets
      let publishPacket = Seq.index ys 0
      when (MQTT.messageQoS (MQTT.publishMessage publishPacket) /= MQTT.QoS1) $ throwSTM MQTTError
      writeTVar (gcUnAckSentPublishPackets state) $ xs Seq.>< Seq.drop 1 ys
      STM.Set.delete packetIdentifier $ gcUsedPacketIdentifiers state

    MQTT.PUBREC pubrecPacket -> atomically $ do
      unAckSentPublishPackets <- readTVar $ gcUnAckSentPublishPackets state
      let packetIdentifier = MQTT.pubrecPacketIdentifier pubrecPacket
      let (xs, ys) = Seq.breakl (\pp -> fromJust (MQTT.publishPacketIdentifier pp) == packetIdentifier) unAckSentPublishPackets
      let publishPacket = Seq.index ys 0
      when (MQTT.messageQoS (MQTT.publishMessage publishPacket) /= MQTT.QoS2) $ throwSTM MQTTError
      let pubrelPacket = MQTT.PubrelPacket packetIdentifier
      writeTVar (gcUnAckSentPublishPackets state) $ xs Seq.>< Seq.drop 1 ys
      modifyTVar (gcUnAckSentPubrelPackets state) $ \pp -> pp Seq.|> pubrelPacket
      sendPacket state $ MQTT.PUBREL pubrelPacket

    MQTT.PUBCOMP pubcompPacket -> atomically $ do
      unAckSentPubrelPackets <- readTVar $ gcUnAckSentPubrelPackets state
      let packetIdentifier = MQTT.pubcompPacketIdentifier pubcompPacket
      let pubrelPacket = Seq.index unAckSentPubrelPackets 0
      when (MQTT.pubrelPacketIdentifier pubrelPacket /= packetIdentifier) $ throwSTM MQTTError
      writeTVar (gcUnAckSentPubrelPackets state) $ Seq.drop 1 unAckSentPubrelPackets
      STM.Set.delete packetIdentifier $ gcUsedPacketIdentifiers state

    MQTT.PUBLISH publishPacket -> do
      let qos = MQTT.messageQoS $ MQTT.publishMessage publishPacket
      let packetIdentifier = fromJust $ MQTT.publishPacketIdentifier publishPacket
      case qos of
        MQTT.QoS0 -> return ()
        MQTT.QoS1 -> atomically $ do
          sendPacket state $ MQTT.PUBACK (MQTT.PubackPacket packetIdentifier)
        MQTT.QoS2 -> atomically $ do
          sendPacket state $ MQTT.PUBREC (MQTT.PubrecPacket packetIdentifier)
          let s = gcUnAckReceivedPublishIds state
          present <- STM.Set.lookup packetIdentifier s
          unless present $ STM.Set.insert packetIdentifier s
      ClientUtils.publish (gClientCommands gw) (MQTT.publishMessage publishPacket)

    MQTT.PUBREL pubrelPacket -> atomically $ do
      let packetIdentifier = MQTT.pubrelPacketIdentifier pubrelPacket
      STM.Set.delete packetIdentifier $ gcUnAckReceivedPublishIds state
      sendPacket state $ MQTT.PUBCOMP (MQTT.PubcompPacket packetIdentifier)

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
