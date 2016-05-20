{-# LANGUAGE RecordWildCards #-}
module Network.MQTT.Client.Core
 ( runClient
 , stopClient

 , sendPublish
 , sendSubscribe

 , setPublishCallback
 , setSubackCallback

 , Client)
where

import           Control.Concurrent ( forkFinally, ThreadId )
import           Control.Concurrent.MVar ( MVar, newEmptyMVar, putMVar )
import           Control.Concurrent.STM ( STM, TQueue, TVar, newTVar, newTQueue, atomically, writeTQueue, writeTVar, modifyTVar, readTVar, throwSTM )
import           Control.Exception ( Exception, throwIO )
import           Control.Monad ( unless, when )
import           Control.Monad.Loops ( dropWhileM )
import           Data.ByteString ( ByteString )
import           Data.Maybe ( isJust, fromJust )
import qualified Data.Sequence as Seq
import           Data.Word ( Word16 )
import           Network.MQTT.Packet
import           Network.MQTT.Utils
import qualified STMContainers.Set as TSet
import           System.IO.Streams ( InputStream, OutputStream )
import qualified System.IO.Streams as S
import           System.Log.Logger ( debugM )
import           System.Random ( randomRs, mkStdGen )


data Client =
  Client
  { threads :: (SynchronizedThread, SynchronizedThread)
  , state   :: ClientState
  }

data ClientState =
  ClientState
  { csSendQueue                   :: TQueue (Maybe Packet)
  , csUsedPacketIdentifiers       :: TSet.Set PacketIdentifier
  , csRandomVals                  :: TVar [Word16]
  , csUnAckSentPublishPackets     :: TVar (Seq.Seq PublishPacket)
  , csUnAckSentPubrelPackets      :: TVar (Seq.Seq PubrelPacket)
  , csUnAckSentSubscribePackets   :: TVar (Seq.Seq SubscribePacket)
  , csUnAckSentUnsubscribePackets :: TVar (Seq.Seq UnsubscribePacket)
  , csUnAckReceivedPublishIds     :: TSet.Set PacketIdentifier
  , csPublishCallback             :: TVar (Maybe (TopicName -> ByteString -> IO ()))
  , csSubackCallback              :: TVar (Maybe ([Maybe QoS] -> IO ()))
  }

data SynchronizedThread =
  SynchronizedThread
    { handle   :: MVar ()
    , threadId :: ThreadId
    } deriving (Eq)

data MQTTError = MQTTError
  deriving (Show)

instance Exception MQTTError


newClientState :: STM ClientState
newClientState =
  ClientState <$> newTQueue
              <*> TSet.new
              <*> newTVar (randomRs (0, 65535) (mkStdGen 42))
              <*> newTVar Seq.empty
              <*> newTVar Seq.empty
              <*> newTVar Seq.empty
              <*> newTVar Seq.empty
              <*> TSet.new
              <*> newTVar Nothing
              <*> newTVar Nothing

forkThread :: IO () -> IO SynchronizedThread
forkThread proc = do
  handle   <- newEmptyMVar
  threadId <- forkFinally proc (\_ -> putMVar handle ())
  return SynchronizedThread{..}

runClient :: ConnectPacket -> InputStream Packet -> OutputStream Packet -> IO Client
runClient p is os = do
  state <- atomically newClientState

  senderThread   <- forkThread $ sender (csSendQueue state) os
  receiverThread <- forkThread $ authenticator state is
  let threads = (senderThread, receiverThread)

  sendConnect state p

  return Client{..}

stopClient = undefined

sendPacket :: ClientState -> Packet -> STM ()
sendPacket state p = writeTQueue (csSendQueue state) $ Just p

runPublishCallback :: ClientState -> PublishPacket -> IO ()
runPublishCallback state publishPacket = do
  userCallback <- atomically $ readTVar (csPublishCallback state)
  when (isJust userCallback) $
    fromJust userCallback
      (messageTopic $ publishMessage publishPacket)
      (messageMessage $ publishMessage publishPacket)

authenticator :: ClientState -> InputStream Packet -> IO ()
authenticator state is = do
  -- Possible pattern-match failure is intended
  Just (CONNACK ConnackPacket{..}) <- S.read is
  unless (connackReturnCode /= Accepted) $ receiver state is

receiver :: ClientState -> InputStream Packet -> IO ()
receiver state is = S.makeOutputStream handler >>= S.connect is
  where
    handler Nothing = return ()
    handler (Just p) = do
      debugM "MQTT.Client.Core" $ "Received: " ++ show p
      case p of
        CONNACK _ -> throwIO MQTTError

        PUBACK pubackPacket -> atomically $ do
          unAckSentPublishPackets <- readTVar $ csUnAckSentPublishPackets state
          let packetIdentifier = pubackPacketIdentifier pubackPacket
          let (xs, ys) = Seq.breakl (\pp -> fromJust (publishPacketIdentifier pp) == packetIdentifier) unAckSentPublishPackets
          let publishPacket = Seq.index ys 0
          when (messageQoS (publishMessage publishPacket) /= QoS1) $ throwSTM MQTTError
          writeTVar (csUnAckSentPublishPackets state) $ xs Seq.>< Seq.drop 1 ys
          TSet.delete packetIdentifier $ csUsedPacketIdentifiers state

        PUBREC pubrecPacket -> atomically $ do
          unAckSentPublishPackets <- readTVar $ csUnAckSentPublishPackets state
          let packetIdentifier = pubrecPacketIdentifier pubrecPacket
          let (xs, ys) = Seq.breakl (\pp -> fromJust (publishPacketIdentifier pp) == packetIdentifier) unAckSentPublishPackets
          let publishPacket = Seq.index ys 0
          when (messageQoS (publishMessage publishPacket) /= QoS2) $ throwSTM MQTTError
          let pubrelPacket = PubrelPacket packetIdentifier
          writeTVar (csUnAckSentPublishPackets state) $ xs Seq.>< Seq.drop 1 ys
          modifyTVar (csUnAckSentPubrelPackets state) $ \pp -> pp Seq.|> pubrelPacket
          sendPacket state $ PUBREL pubrelPacket

        PUBCOMP pubcompPacket -> atomically $ do
          unAckSentPubrelPackets <- readTVar $ csUnAckSentPubrelPackets state
          let packetIdentifier = pubcompPacketIdentifier pubcompPacket
          let pubrelPacket = Seq.index unAckSentPubrelPackets 0
          when (pubrelPacketIdentifier pubrelPacket /= packetIdentifier) $ throwSTM MQTTError
          writeTVar (csUnAckSentPubrelPackets state) $ Seq.drop 1 unAckSentPubrelPackets
          TSet.delete packetIdentifier $ csUsedPacketIdentifiers state

        PUBLISH publishPacket -> do
          let qos = messageQoS $ publishMessage publishPacket
          let packetIdentifier = publishPacketIdentifier publishPacket
          case qos of
            QoS0 ->
              runPublishCallback state publishPacket
            QoS1 -> do
              runPublishCallback state publishPacket
              atomically $ sendPacket state $ PUBACK (PubackPacket $ fromJust packetIdentifier)
            QoS2 -> do
              let packetIdentifier' = fromJust packetIdentifier
              present <- atomically $ do
                sendPacket state $ PUBREC (PubrecPacket packetIdentifier')

                let s = csUnAckReceivedPublishIds state
                present <- TSet.lookup packetIdentifier' s
                unless present $ TSet.insert packetIdentifier' s
                return present

              unless present $ runPublishCallback state publishPacket

        PUBREL pubrelPacket -> atomically $ do
          let packetIdentifier = pubrelPacketIdentifier pubrelPacket
          TSet.delete packetIdentifier $ csUnAckReceivedPublishIds state
          sendPacket state $ PUBCOMP (PubcompPacket packetIdentifier)

        _ -> return ()


sendConnect :: ClientState -> ConnectPacket -> IO ()
sendConnect state packet = atomically $ sendPacket state $ CONNECT packet

genPacketIdentifier :: ClientState -> STM PacketIdentifier
genPacketIdentifier state = do
  randomVals <- readTVar $ csRandomVals state
  (identifier : restIds) <- dropWhileM
    (\i -> TSet.lookup (PacketIdentifier i) $ csUsedPacketIdentifiers state) randomVals
  writeTVar (csRandomVals state) restIds
  let packetIdentifier = PacketIdentifier identifier
  TSet.insert packetIdentifier $ csUsedPacketIdentifiers state
  return packetIdentifier

sendPublish :: Client -> Message -> IO ()
sendPublish client publishMessage = atomically $ do
  let publishDup = False

  if messageQoS publishMessage == QoS0
    then writeTQueue (csSendQueue $ state client) $ Just $ PUBLISH
      PublishPacket{ publishDup              = publishDup
                   , publishMessage          = publishMessage
                   , publishPacketIdentifier = Nothing
                   }
    else do
      publishPacketIdentifier <- Just <$> genPacketIdentifier (state client)
      modifyTVar (csUnAckSentPublishPackets $ state client) $ \p -> p Seq.|> PublishPacket{..}
      sendPacket (state client) $ PUBLISH PublishPacket{..}

sendSubscribe :: Client -> [(TopicFilter, QoS)] -> IO ()
sendSubscribe client subscribeTopicFiltersQoS = atomically $ do
  subscribePacketIdentifier <- genPacketIdentifier (state client)
  writeTQueue (csSendQueue $ state client) (Just $ SUBSCRIBE SubscribePacket{..})

sender :: TQueue (Maybe Packet) -> OutputStream Packet -> IO ()
sender queue os = do
  stmQueueStream queue >>= S.mapM_ logPacket >>= S.connectTo os
  debugM "MQTT.Client.Core" "sender exit"
  where
    logPacket p = debugM "MQTT.Client.Core" $ "Sending: " ++ show p


setPublishCallback :: Client -> Maybe (TopicName -> ByteString -> IO ()) -> IO ()
setPublishCallback client = atomically . writeTVar (csPublishCallback $ state client)

setSubackCallback :: Client -> Maybe ([Maybe QoS] -> IO ()) -> IO ()
setSubackCallback client = atomically . writeTVar (csSubackCallback $ state client)
