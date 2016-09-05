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


import           Control.Concurrent      (ThreadId, forkFinally, forkIO, killThread)
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

data UserCredentials
  = UserCredentials
    { userName :: MQTT.UserName
    , password :: Maybe MQTT.Password
    }

data ClientConfig
  = ClientConfig
    { ccClientIdentifier :: !MQTT.ClientIdentifier
    , ccWillMsg          :: !(Maybe MQTT.Message)
    , ccUserCredentials  :: !(Maybe UserCredentials)
    , ccCleanSession     :: !Bool
    , ccKeepAlive        :: !Word16
    }

data Gateway =
  Gateway
  { gClients               :: STM.Map MQTT.ClientIdentifier GatewayClient
  , gSubscriptions         :: STM.Map MQTT.TopicFilter MQTT.QoS
  , gUnAckSubscribePackets :: TVar (TT.TopicFilterTrie (Map.Map MQTT.SubscribePacket GatewayClient))
  , gClientSubscriptions   :: TVar (TT.TopicFilterTrie (Map.Map GatewayClient MQTT.QoS))
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

data Client
  = Client
    { csSendQueue                   :: TQueue (Maybe MQTT.Packet)
    , csUsedPacketIdentifiers       :: STM.Set MQTT.PacketIdentifier
    , csRandomVals                  :: TVar [Word16]
    , csUnAckSentPublishPackets     :: TVar (Seq.Seq MQTT.PublishPacket)
    , csUnAckSentPubrelPackets      :: TVar (Seq.Seq MQTT.PubrelPacket)
    , csUnAckSentSubscribePackets   :: TVar (Seq.Seq MQTT.SubscribePacket)
    , csUnAckSentUnsubscribePackets :: TVar (Seq.Seq MQTT.UnsubscribePacket)
    , csUnAckReceivedPublishIds     :: STM.Set MQTT.PacketIdentifier
    }

data MQTTError = MQTTError
  deriving (Show)

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------

instance Exception MQTTError

instance Eq GatewayClient where
  gw1 == gw2 = (gcClientIdentifier gw1) == (gcClientIdentifier gw2)

instance Ord GatewayClient where
  gw1 `compare` gw2 = gw1 `compare` gw2

--------------------------------------------------------------------------------
-- Handle client flow
--------------------------------------------------------------------------------

-- | Run client handling on the given streams.
--
-- Note that this function doesn't exit until connection is closed.
handleAlienClient :: Gateway -> (InputStream MQTT.Packet, OutputStream MQTT.Packet) -> IO ()
handleAlienClient gw (is, os) = do
  state <- newGatewayClient

  t <- forkIO $ receiverGatewayClientThread gw state is `finally`
    -- properly close sender queue
    atomically (writeTQueue (gcSendQueue state) Nothing)

  sender os (gcSendQueue state) `finally` killThread t

newGatewayClient :: IO GatewayClient
newGatewayClient = do
  newStdGen >>= \gen -> atomically $ do
    GatewayClient <$> newTVar (MQTT.ClientIdentifier $ T.pack "")
                  <*> newTQueue
                  <*> STM.Set.new
                  <*> newTVar (randomRs (0, 65535) gen)
                  <*> newTVar Seq.empty
                  <*> newTVar Seq.empty
                  <*> STM.Set.new

receiverGatewayClientThread :: Gateway -> GatewayClient -> InputStream MQTT.Packet -> IO ()
receiverGatewayClientThread gw state is = do
    r <- try (gatewayClientAuthenticator gw state is) :: IO (Either SomeException ())
    debugM "MQTT.Gateway" $ "Receiver exit: " ++ show r

gatewayClientAuthenticator :: Gateway -> GatewayClient -> InputStream MQTT.Packet -> IO ()
gatewayClientAuthenticator gw state is = do
  -- Possible pattern-match failure is intended
  Just (MQTT.CONNECT MQTT.ConnectPacket{..}) <- S.read is
  if connectProtocolLevel /= 4
    then
      atomically $
        sendGatewayClientPacket state (MQTT.CONNACK $ MQTT.ConnackPacket False MQTT.UnacceptableProtocol)
    else do
      atomically $ do
        sendGatewayClientPacket state (MQTT.CONNACK $ MQTT.ConnackPacket False MQTT.Accepted)

        mx <- STM.Map.lookup connectClientIdentifier (gClients gw)
        modifyTVar (gcClientIdentifier state) (const connectClientIdentifier)
        STM.Map.insert state connectClientIdentifier (gClients gw)
        case mx of
          Nothing -> return ()
          Just x  -> writeTQueue (gcSendQueue x) Nothing

      S.makeOutputStream (gatewayClientPacketHandler gw state) >>= S.connect is

gatewayClientPacketHandler :: Gateway -> GatewayClient -> Maybe MQTT.Packet -> IO ()
gatewayClientPacketHandler _  _     Nothing  = return ()
gatewayClientPacketHandler gw state (Just p) = do
  debugM "MQTT.Gateway" $ "Received: " ++ show p
  case p of
    MQTT.CONNECT _ -> throwIO MQTTError

    MQTT.PINGREQ _ -> atomically $ do
      sendGatewayClientPacket state (MQTT.PINGRESP MQTT.PingrespPacket)

    MQTT.UNSUBSCRIBE MQTT.UnsubscribePacket{..} -> atomically $ do
      sendGatewayClientPacket state $
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
      sendGatewayClientPacket state $ MQTT.PUBREL pubrelPacket

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
          sendGatewayClientPacket state $ MQTT.PUBACK (MQTT.PubackPacket packetIdentifier)
        MQTT.QoS2 -> atomically $ do
          sendGatewayClientPacket state $ MQTT.PUBREC (MQTT.PubrecPacket packetIdentifier)
          let s = gcUnAckReceivedPublishIds state
          present <- STM.Set.lookup packetIdentifier s
          unless present $ STM.Set.insert packetIdentifier s
      undefined


    MQTT.PUBREL pubrelPacket -> atomically $ do
      let packetIdentifier = MQTT.pubrelPacketIdentifier pubrelPacket
      STM.Set.delete packetIdentifier $ gcUnAckReceivedPublishIds state
      sendGatewayClientPacket state $ MQTT.PUBCOMP (MQTT.PubcompPacket packetIdentifier)

    _ -> return ()


sendGatewayClientPacket :: GatewayClient -> MQTT.Packet -> STM ()
sendGatewayClientPacket state p = do
  writeTQueue (gcSendQueue state) (Just p)

--------------------------------------------------------------------------------
-- Gateway creation
--------------------------------------------------------------------------------

newGateway :: ClientConfig -> (InputStream MQTT.Packet, OutputStream MQTT.Packet) -> IO Gateway
newGateway config brokerStreams = do
  gw <- Gateway <$> STM.Map.newIO
                <*> STM.Map.newIO
                <*> newTVarIO TT.empty
                <*> newTVarIO TT.empty

  connectClient config gw brokerStreams

  return gw

connectClient :: ClientConfig -> Gateway -> (InputStream MQTT.Packet, OutputStream MQTT.Packet) -> IO ()
connectClient ClientConfig{..} gw (is,os) = do
  state <- newClientState

  t <- forkIO $ receiverClientThread gw state is `finally`
    -- properly close sender queue
    atomically (writeTQueue (csSendQueue state) Nothing)

  sendConnect state
    MQTT.ConnectPacket
    { connectClientIdentifier = ccClientIdentifier
    , connectProtocolLevel    = 0x04
    , connectWillMsg          = ccWillMsg
    , connectUserName         = fmap userName ccUserCredentials
    , connectPassword         = maybe Nothing password ccUserCredentials
    , connectCleanSession     = ccCleanSession
    , connectKeepAlive        = ccKeepAlive
    }

  sender os (csSendQueue state) `finally` killThread t

receiverClientThread :: Gateway -> Client -> InputStream MQTT.Packet -> IO ()
receiverClientThread gw state is = do
    r <- try (clientAuthenticator gw state is) :: IO (Either SomeException ())
    debugM "MQTT.Gateway" $ "Receiver exit: " ++ show r

clientAuthenticator :: Gateway -> Client -> InputStream MQTT.Packet -> IO ()
clientAuthenticator gw state is = do
  -- TODO Start from here
  undefined

sendConnect :: Client -> MQTT.ConnectPacket -> IO ()
sendConnect state packet = atomically $ sendClientPacket state $ MQTT.CONNECT packet

sendClientPacket :: Client -> MQTT.Packet -> STM ()
sendClientPacket state p = writeTQueue (csSendQueue state) $ Just p

newClientState :: IO Client
newClientState = do
  newStdGen >>= \gen -> atomically $ do
    Client <$> newTQueue
                <*> STM.Set.new
                <*> newTVar (randomRs (0, 65535) gen)
                <*> newTVar Seq.empty
                <*> newTVar Seq.empty
                <*> newTVar Seq.empty
                <*> newTVar Seq.empty
                <*> STM.Set.new

defaultClientConfig :: ClientConfig
defaultClientConfig = ClientConfig
                      -- TODO generate random string for client identifier?
                      { ccClientIdentifier = MQTT.ClientIdentifier $ T.pack "arachne-client"
                      , ccWillMsg          = Nothing
                      , ccUserCredentials  = Nothing
                      , ccCleanSession     = True
                      , ccKeepAlive        = 0
                      }

--------------------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------------------

genPacketIdentifier :: GatewayClient -> STM MQTT.PacketIdentifier
genPacketIdentifier state = do
  randomVals <- readTVar $ gcRandomVals state
  (identifier : restIds) <- dropWhileM
    (\i -> STM.Set.lookup (MQTT.PacketIdentifier i) $ gcUsedPacketIdentifiers state) randomVals
  writeTVar (gcRandomVals state) restIds
  let packetIdentifier = MQTT.PacketIdentifier identifier
  STM.Set.insert packetIdentifier $ gcUsedPacketIdentifiers state
  return packetIdentifier

sender :: OutputStream MQTT.Packet -> TQueue (Maybe MQTT.Packet) -> IO ()
sender os queue = do
  stmQueueStream queue >>= S.mapM_ logPacket >>= S.connectTo os
  debugM "MQTT.Gateway" $ "sender exit"
  where
    logPacket p = debugM "MQTT.Gateway" $ "Sending: " ++ show p
