{-# LANGUAGE RecordWildCards #-}
module Network.MQTT.Client.Core
 ( runClient

 , UserCredentials(..)
 , ClientCommand(..)
 , ClientConfig(..)
 , ClientResult(..))
where

import           Control.Concurrent ( forkFinally, ThreadId, killThread )
import           Control.Concurrent.MVar ( MVar, newEmptyMVar, putMVar )
import           Control.Concurrent.STM ( STM, TQueue, TVar, newTVar, newTQueue, atomically, writeTQueue, writeTVar, modifyTVar, readTVar, throwSTM )
import           Control.Exception ( Exception, throwIO )
import           Control.Monad ( unless, when, forM_ )
import           Control.Monad.Loops ( dropWhileM )
import           Data.Maybe ( fromJust )
import qualified Data.Sequence as Seq
import           Data.Word ( Word16 )
import           Network.MQTT.Packet
import           Network.MQTT.Utils
import qualified STMContainers.Set as TSet
import           System.IO.Streams ( InputStream, OutputStream )
import qualified System.IO.Streams as S
import           System.Log.Logger ( debugM )
import           System.Random ( randomRs, newStdGen, StdGen )


data UserCredentials
  = UserCredentials
    { userName :: UserName
    , password :: Maybe Password
    }

data ClientConfig
  = ClientConfig
    { ccClientIdenfier   :: !ClientIdentifier
    , ccWillMsg          :: !(Maybe Message)
    , ccUserCredentials  :: !(Maybe UserCredentials)
    , ccCleanSession     :: !Bool
    , ccKeepAlive        :: !Word16
    }

data ClientResult
  = PublishResult Message
  | SubscribeResult [(TopicFilter, Maybe QoS)]
  | UnsubscribeResult [TopicFilter]
  deriving (Eq, Show)

data ClientCommand
  = PublishCommand Message
  | SubscribeCommand [(TopicFilter, QoS)]
  | UnsubscribeCommand [TopicFilter]
  | StopCommand
  deriving (Eq, Show)

data ClientState
  = ClientState
    { csSendQueue                   :: TQueue (Maybe Packet)
    , csUsedPacketIdentifiers       :: TSet.Set PacketIdentifier
    , csRandomVals                  :: TVar [Word16]
    , csUnAckSentPublishPackets     :: TVar (Seq.Seq PublishPacket)
    , csUnAckSentPubrelPackets      :: TVar (Seq.Seq PubrelPacket)
    , csUnAckSentSubscribePackets   :: TVar (Seq.Seq SubscribePacket)
    , csUnAckSentUnsubscribePackets :: TVar (Seq.Seq UnsubscribePacket)
    , csUnAckReceivedPublishIds     :: TSet.Set PacketIdentifier
    , csConfig                      :: ClientConfig
    }

data SynchronizedThread
  = SynchronizedThread
    { handle   :: MVar ()
    , threadId :: ThreadId
    } deriving (Eq)

data MQTTError = MQTTError
  deriving (Show)

instance Exception MQTTError


newClientState :: ClientConfig -> StdGen -> STM ClientState
newClientState config gen =
  ClientState <$> newTQueue
              <*> TSet.new
              <*> newTVar (randomRs (0, 65535) gen)
              <*> newTVar Seq.empty
              <*> newTVar Seq.empty
              <*> newTVar Seq.empty
              <*> newTVar Seq.empty
              <*> TSet.new
              <*> pure config

forkThread :: IO () -> IO SynchronizedThread
forkThread proc = do
  handle   <- newEmptyMVar
  threadId <- forkFinally proc (\_ -> putMVar handle ())
  return SynchronizedThread{..}

runClient :: ClientConfig -> OutputStream ClientResult -> InputStream Packet -> OutputStream Packet -> IO (OutputStream ClientCommand)
runClient config@ClientConfig{..} result_os is os = do
  gen <- newStdGen
  state <- atomically $ newClientState config gen

  senderThread   <- forkThread $ sender (csSendQueue state) os
  receiverThread <- forkThread $ authenticator state result_os is
  let threads = (senderThread, receiverThread)

  sendConnect state
    ConnectPacket
    { connectClientIdentifier = ccClientIdenfier
    , connectProtocolLevel    = 0x04
    , connectWillMsg          = ccWillMsg
    , connectUserName         = fmap userName ccUserCredentials
    , connectPassword         = maybe Nothing password ccUserCredentials
    , connectCleanSession     = ccCleanSession
    , connectKeepAlive        = ccKeepAlive
    }

  S.contramapM_ logPacket =<< S.makeOutputStream (commandHandler state threads)
    where
      logPacket p = debugM "MQTT.Client.Core" $ "Client command: " ++ show p

sendPacket :: ClientState -> Packet -> STM ()
sendPacket state p = writeTQueue (csSendQueue state) $ Just p

authenticator :: ClientState -> OutputStream ClientResult -> InputStream Packet -> IO ()
authenticator state result_os is = do
  -- Possible pattern-match failure is intended
  Just (CONNACK ConnackPacket{..}) <- S.read is
  unless (connackReturnCode /= Accepted) $ receiver state result_os is

commandHandler :: ClientState -> (SynchronizedThread, SynchronizedThread) -> Maybe ClientCommand -> IO ()
commandHandler _ _ Nothing = return ()
commandHandler state _ (Just (PublishCommand publishMessage)) = atomically $ do
  let publishDup = False

  if messageQoS publishMessage == QoS0
    then writeTQueue (csSendQueue state) $ Just $ PUBLISH
      PublishPacket{ publishDup              = publishDup
                   , publishMessage          = publishMessage
                   , publishPacketIdentifier = Nothing
                   }
    else do
      publishPacketIdentifier <- Just <$> genPacketIdentifier state
      modifyTVar (csUnAckSentPublishPackets state) $ \p -> p Seq.|> PublishPacket{..}
      sendPacket state $ PUBLISH PublishPacket{..}

commandHandler state _ (Just (SubscribeCommand subscribeTopicFiltersQoS)) = atomically $ do
  subscribePacketIdentifier <- genPacketIdentifier state
  modifyTVar (csUnAckSentSubscribePackets state) $ \p -> p Seq.|> SubscribePacket{..}
  writeTQueue (csSendQueue state) (Just $ SUBSCRIBE SubscribePacket{..})

commandHandler state _ (Just (UnsubscribeCommand unsubscribeTopicFilters)) = atomically $ do
  unsubscribePacketIdentifier <- genPacketIdentifier state
  modifyTVar (csUnAckSentUnsubscribePackets state) $ \p -> p Seq.|> UnsubscribePacket{..}
  writeTQueue (csSendQueue state) (Just $ UNSUBSCRIBE UnsubscribePacket{..})

commandHandler _ (senderThread, receiverThread) (Just StopCommand) = do
  killThread $ threadId senderThread
  killThread $ threadId receiverThread

receiver :: ClientState -> OutputStream ClientResult -> InputStream Packet -> IO ()
receiver state result_os is = S.makeOutputStream handler >>= S.connect is
  where
    handler Nothing = do
      debugM "MQTT.Client.Core" "Re-connecting: "
      let ClientConfig{..} = csConfig state
      sendConnect state
        ConnectPacket
        { connectClientIdentifier = ccClientIdenfier
        , connectProtocolLevel    = 0x04
        , connectWillMsg          = ccWillMsg
        , connectUserName         = fmap userName ccUserCredentials
        , connectPassword         = maybe Nothing password ccUserCredentials
        , connectCleanSession     = ccCleanSession
        , connectKeepAlive        = ccKeepAlive
        }
      when (not ccCleanSession) $ atomically $ do
        unAckSentPublishPackets <- readTVar $ csUnAckSentPublishPackets state
        forM_ unAckSentPublishPackets $ \p -> sendPacket state $ PUBLISH $ p { publishDup = True }
        unAckSentPubrelPackets <- readTVar $ csUnAckSentPubrelPackets state
        forM_ unAckSentPubrelPackets $ sendPacket state . PUBREL
        unAckSentSubscribePackets <- readTVar $ csUnAckSentSubscribePackets state
        forM_ unAckSentSubscribePackets $ sendPacket state . SUBSCRIBE
        unAckSentUnsubscribePackets <- readTVar $ csUnAckSentUnsubscribePackets state
        forM_ unAckSentUnsubscribePackets $ sendPacket state . UNSUBSCRIBE
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
              writeTo result_os $ Just (PublishResult $ publishMessage publishPacket)
            QoS1 -> do
              writeTo result_os $ Just (PublishResult $ publishMessage publishPacket)
              atomically $ sendPacket state $ PUBACK (PubackPacket $ fromJust packetIdentifier)
            QoS2 -> do
              let packetIdentifier' = fromJust packetIdentifier
              present <- atomically $ do
                sendPacket state $ PUBREC (PubrecPacket packetIdentifier')

                let s = csUnAckReceivedPublishIds state
                present <- TSet.lookup packetIdentifier' s
                unless present $ TSet.insert packetIdentifier' s
                return present

              unless present $ writeTo result_os $ Just (PublishResult $ publishMessage publishPacket)

        PUBREL pubrelPacket -> atomically $ do
          let packetIdentifier = pubrelPacketIdentifier pubrelPacket
          TSet.delete packetIdentifier $ csUnAckReceivedPublishIds state
          sendPacket state $ PUBCOMP (PubcompPacket packetIdentifier)

        SUBACK subackPacket -> do
          topicFilters <- atomically $ do
            let packetIdentifier = subackPacketIdentifier subackPacket
            unAckSentSubscribePackets <- readTVar $ csUnAckSentSubscribePackets state
            let subscribePacket = Seq.index unAckSentSubscribePackets 0
            when (subscribePacketIdentifier subscribePacket /= packetIdentifier) $ throwSTM MQTTError
            writeTVar (csUnAckSentSubscribePackets state) $ Seq.drop 1 unAckSentSubscribePackets
            TSet.delete packetIdentifier $ csUsedPacketIdentifiers state
            return $ fst <$> subscribeTopicFiltersQoS subscribePacket
          writeTo result_os $ Just (SubscribeResult $ zip topicFilters (subackResponses subackPacket))

        UNSUBACK unsubackPacket -> do
          unsubscribePacket <- atomically $ do
            let packetIdentifier = unsubackPacketIdentifier unsubackPacket
            unAckSentUnsubscribePackets <- readTVar $ csUnAckSentUnsubscribePackets state
            let unsubscribePacket = Seq.index unAckSentUnsubscribePackets 0
            when (unsubscribePacketIdentifier unsubscribePacket /= packetIdentifier) $ throwSTM MQTTError
            writeTVar (csUnAckSentUnsubscribePackets state) $ Seq.drop 1 unAckSentUnsubscribePackets
            TSet.delete packetIdentifier $ csUsedPacketIdentifiers state
            return unsubscribePacket
          writeTo result_os $ Just (UnsubscribeResult $ unsubscribeTopicFilters unsubscribePacket)

        _ -> return ()

writeTo :: OutputStream a -> Maybe a -> IO ()
writeTo = flip S.write

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

sender :: TQueue (Maybe Packet) -> OutputStream Packet -> IO ()
sender queue os = do
  stmQueueStream queue >>= S.mapM_ logPacket >>= S.connectTo os
  debugM "MQTT.Client.Core" "sender exit"
  where
    logPacket p = debugM "MQTT.Client.Core" $ "Sending: " ++ show p
