{-# LANGUAGE RecordWildCards #-}
module Network.MQTT.ClientSpec (spec) where

import           Control.Concurrent ( threadDelay )
import           Control.Concurrent.MVar ( newEmptyMVar, putMVar, takeMVar, isEmptyMVar )
import qualified Data.ByteString as BS
import           Data.Maybe ( isJust, fromJust )
import qualified Data.Text as T
import           Network.MQTT.Client ( runClient

                                     , UserCredentials(..)
                                     , ClientCommand(..)
                                     , ClientConfig(..)
                                     , ClientResult(..))
import           Network.MQTT.Packet
import           System.IO.Streams ( InputStream, OutputStream )
import qualified System.IO.Streams as S
import qualified System.IO.Streams.Concurrent as S
import           System.Log ( Priority(DEBUG) )
import           System.Log.Logger            ( rootLoggerName
                                              , setLevel
                                              , updateGlobalLogger )
import           Control.Monad ( forM_ )
import qualified Data.Set as Set
import           Test.Hspec
import           System.Timeout (timeout)

debugTests :: IO ()
debugTests = updateGlobalLogger rootLoggerName (setLevel DEBUG)

data Session
  = Session
    { is         :: InputStream Packet
    , os         :: OutputStream Packet
    , result_is  :: InputStream ClientResult
    , command_os :: OutputStream ClientCommand
    }

newSession :: ClientConfig -> IO Session
newSession config = do
  (is', os)    <- S.makeChanPipe
  (is, os')    <- S.makeChanPipe
  (result_is, result_os) <- S.makeChanPipe

  command_os <- runClient config result_os is' os'

  CONNECT _ <- readFromStream is
  writeToStream os $ CONNACK (ConnackPacket False Accepted)
  return Session{..}

readFromStream :: InputStream a -> IO a
readFromStream is = fromJust <$> S.read is

writeToStream :: OutputStream a -> a -> IO ()
writeToStream os x = S.write (Just x) os

reconnectClient :: OutputStream Packet -> InputStream Packet -> IO ()
reconnectClient os is = do
  S.write Nothing os
  CONNECT ConnectPacket{..} <- readFromStream is
  writeToStream os $ CONNACK (ConnackPacket False Accepted)

defaultConfig = ClientConfig
                { ccClientIdenfier   = ClientIdentifier $ T.pack "arachne-test"
                , ccWillMsg          = Nothing
                , ccUserCredentials  = Nothing
                , ccCleanSession     = True
                , ccKeepAlive        = 0
                }

defaultMessage = Message
                 { messageTopic   = TopicName $ T.pack "a/b"
                 , messageQoS     = QoS0
                 , messageMessage = BS.pack [0xab, 0x12]
                 , messageRetain  = False
                 }

defaultPacketIdentifier = PacketIdentifier 42

defaultPublish = PublishPacket{ publishDup              = False
                              , publishPacketIdentifier = Just defaultPacketIdentifier
                              , publishMessage          = defaultMessage { messageQoS = QoS1 }
                              }

spec :: Spec
spec = do
  describe "MQTT Client" $ do


    it "In the QoS 0 delivery protocol, the Sender MUST send a PUBLISH packet with QoS=0, DUP=0 [MQTT-4.3.1-1]" $ do
      Session{..} <- newSession defaultConfig
      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS0 }
      PUBLISH PublishPacket{..} <- readFromStream is
      messageQoS publishMessage `shouldBe` QoS0
      publishDup                `shouldBe` False


    it "In the QoS 1 delivery protocol, the Sender MUST assign an unused Packet Identifier each time it has a newSession Application Message to publish [MQTT-4.3.2-1]" $ do
      Session{..} <- newSession defaultConfig

      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS1 }
      PUBLISH p1 <- readFromStream is
      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS1 }
      PUBLISH p2 <- readFromStream is
      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS1 }
      PUBLISH p3 <- readFromStream is

      Set.size (Set.fromList [ publishPacketIdentifier p1
                             , publishPacketIdentifier p2
                             , publishPacketIdentifier p3
                             ]) `shouldBe` 3


    it "In the QoS 1 delivery protocol, the Sender MUST send a PUBLISH Packet containing this Packet Identifier with QoS=1, DUP=0 [MQTT-4.3.2-1]" $ do
      Session{..} <- newSession defaultConfig
      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS1 }
      PUBLISH PublishPacket{..} <- readFromStream is
      messageQoS publishMessage `shouldBe` QoS1
      publishDup                `shouldBe` False


    it "In the QoS 1 delivery protocol, the Sender MUST treat the PUBLISH Packet as 'unacknowledged' until it has received the corresponding PUBACK packet from the receiver [MQTT-4.3.2-1]" $ do
      Session{..} <- newSession $ defaultConfig { ccCleanSession = False }

      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS1 }
      PUBLISH p1 <- readFromStream is
      writeToStream os $ PUBACK $ PubackPacket (fromJust $ publishPacketIdentifier p1)

      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS1 }
      PUBLISH p2 <- readFromStream is

      reconnectClient os is

      PUBLISH p2' <- readFromStream is
      Nothing <- timeout 100 (readFromStream is)

      p2 { publishDup = True } `shouldBe` p2'


    it "In the QoS 1 delivery protocol, the Receiver MUST respond with a PUBACK Packet containing the Packet Identifier from the incoming PUBLISH Packet, having accepted ownership of the Application Message [MQTT-4.3.2-2]" $ do
      Session{..} <- newSession defaultConfig

      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS1 } }

      PUBACK PubackPacket{..} <- readFromStream is
      PublishResult message   <- readFromStream result_is

      message                `shouldBe` defaultMessage { messageQoS = QoS1 }
      pubackPacketIdentifier `shouldBe` defaultPacketIdentifier


    it "In the QoS 1 delivery protocol, the Receiver After it has sent a PUBACK Packet the Receiver MUST treat any incoming PUBLISH packet that contains the same Packet Identifier as being a newSession publication, irrespective of the setting of its DUP flag [MQTT-4.3.2-2]" $ do
      Session{..} <- newSession defaultConfig

      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS1 } }

      PUBACK p1              <- readFromStream is
      PublishResult message' <- readFromStream result_is

      message'                  `shouldBe` defaultMessage { messageQoS = QoS1 }
      pubackPacketIdentifier p1 `shouldBe` defaultPacketIdentifier

      writeToStream os $ PUBLISH
        defaultPublish { publishDup = True
                       , publishMessage = defaultMessage { messageQoS = QoS1 }
                       }

      PUBACK p2               <- readFromStream is
      PublishResult message'' <- readFromStream result_is

      message''                 `shouldBe` defaultMessage { messageQoS = QoS1 }
      pubackPacketIdentifier p2 `shouldBe` defaultPacketIdentifier


    it "In the QoS 2 delivery protocol, the Sender MUST assign an unused Packet Identifier when it has a newSession Application Message to publish [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession defaultConfig

      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p1 <- readFromStream is
      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p2 <- readFromStream is
      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p3 <- readFromStream is

      Set.size (Set.fromList [ publishPacketIdentifier p1
                             , publishPacketIdentifier p2
                             , publishPacketIdentifier p3
                             ]) `shouldBe` 3


    it "In the QoS 2 delivery protocol, the Sender MUST send a PUBLISH packet containing this Packet Identifier with QoS=2, DUP=0 [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession defaultConfig
      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH PublishPacket{..} <- readFromStream is
      messageQoS publishMessage `shouldBe` QoS2
      publishDup                `shouldBe` False


    it "In the QoS 2 delivery protocol, the Sender MUST treat the PUBLISH packet as 'unacknowledged' until it has received the corresponding PUBREC packet from the receiver [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession $ defaultConfig { ccCleanSession = False }

      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p1 <- readFromStream is
      writeToStream os $ PUBREC $ PubrecPacket (fromJust $ publishPacketIdentifier p1)
      PUBREL _ <- readFromStream is

      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p2 <- readFromStream is

      reconnectClient os is

      PUBLISH p2' <- readFromStream is
      p2 { publishDup = True } `shouldBe` p2'


    it "In the QoS 2 delivery protocol, the Sender MUST send a PUBREL packet when it receives a PUBREC packet from the receiver [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession defaultConfig

      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH PublishPacket{..} <- readFromStream is
      let packetIdentifier = fromJust publishPacketIdentifier
      writeToStream os $ PUBREC (PubrecPacket packetIdentifier)
      PUBREL PubrelPacket{..} <- readFromStream is

      pubrelPacketIdentifier `shouldBe` packetIdentifier


    it "In the QoS 2 delivery protocol, the Sender MUST treat the PUBREL packet as 'unacknowledged' until it has received the corresponding PUBCOMP packet from the receiver [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession $ defaultConfig { ccCleanSession = False }

      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH publish1 <- readFromStream is
      writeToStream os $ PUBREC $ PubrecPacket (fromJust $ publishPacketIdentifier publish1)
      PUBREL pubrel1 <- readFromStream is
      writeToStream os $ PUBCOMP $ PubcompPacket (fromJust $ publishPacketIdentifier publish1)

      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH publish2 <- readFromStream is
      writeToStream os $ PUBREC $ PubrecPacket (fromJust $ publishPacketIdentifier publish2)
      PUBREL pubrel2 <- readFromStream is

      reconnectClient os is

      PUBREL pubrel2' <- readFromStream is
      Nothing <- timeout 100 (S.read result_is)

      pubrel2' `shouldBe` pubrel2


    it "In the QoS 2 delivery protocol, the Sender MUST NOT re-send the PUBLISH once it has sent the corresponding PUBREL packet [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession $ defaultConfig { ccCleanSession = False }
      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH publish <- readFromStream is
      writeToStream os $ PUBREC $ PubrecPacket (fromJust $ publishPacketIdentifier publish)
      PUBREL pubrel <- readFromStream is

      reconnectClient os is

      PUBREL pubrel' <- readFromStream is
      Nothing <- timeout 100 (S.read result_is)
      pubrel' `shouldBe` pubrel


    it "In the QoS2 delivery protocol, the Receiver MUST respond with a PUBREC containing the Packet Identifier from the incoming PUBLISH Packet, having accepted ownership of the Application Message [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession defaultConfig

      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 } }

      PUBREC PubrecPacket{..} <- readFromStream is
      PublishResult message   <- readFromStream result_is

      message                `shouldBe` defaultMessage { messageQoS = QoS2 }
      pubrecPacketIdentifier `shouldBe` defaultPacketIdentifier


    it "In the QoS2 delivery protocol, the Receiver Until it has received the corresponding PUBREL packet, the Receiver MUST acknowledge any subsequent PUBLISH packet with the same Packet Identifier by sending a PUBREC [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession defaultConfig

      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 } }

      PUBREC p1 <- readFromStream is
      writeToStream os $ PUBLISH
        defaultPublish { publishDup = True
                       , publishMessage = defaultMessage { messageQoS = QoS2 }
                       }
      PUBREC p2 <- readFromStream is

      pubrecPacketIdentifier p1 `shouldBe` defaultPacketIdentifier
      pubrecPacketIdentifier p2 `shouldBe` defaultPacketIdentifier


    it "In the QoS2 delivery protocol, the Receiver MUST respond to a PUBREL packet by sending a PUBCOMP packet containing the same Packet Identifier as the PUBREL [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession defaultConfig

      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 } }

      PUBREC _ <- readFromStream is

      writeToStream os $ PUBREL $ PubrelPacket defaultPacketIdentifier

      PUBCOMP PubcompPacket{..} <- readFromStream is

      pubcompPacketIdentifier `shouldBe` defaultPacketIdentifier


    it "In the QoS2 delivery protocol, the Receiver After it has sent a PUBCOMP, the receiver MUST treat any subsequent PUBLISH packet that contains that Packet Identifier as being a newSession publication [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession defaultConfig

      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 } }

      PUBREC _ <- readFromStream is
      PublishResult message' <- readFromStream result_is

      message' `shouldBe` defaultMessage { messageQoS = QoS2 }

      -- Check whether Receiver Before it has sent a PUBCOMP does not treat PUBLISH packet that contains that Packet Identifier as being a newSession publication
      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 } }

      PUBREC _ <- readFromStream is
      Nothing <- timeout 100 (S.read result_is)

      -- Send a PUBCOMP
      writeToStream os $ PUBREL $ PubrelPacket defaultPacketIdentifier
      PUBCOMP PubcompPacket{..} <- readFromStream is

      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 } }
      PUBREC _ <- readFromStream is

      PublishResult message'' <- readFromStream result_is
      message'' `shouldBe` defaultMessage { messageQoS = QoS2 }


    it "When a Client reconnects with CleanSession set to 0, both the Client and Server MUST re-send any unacknowledged PUBLISH Packets (where QoS > 0) and PUBREL Packets using their original Packet Identifiers [MQTT-4.4.0-1]" $ do
      Session{..} <- newSession $ defaultConfig { ccCleanSession = False }

      writeToStream command_os $ PublishCommand $
        defaultMessage { messageQoS = QoS0 }
      PUBLISH _ <- readFromStream is

      writeToStream command_os $ PublishCommand $
        defaultMessage { messageQoS = QoS1 }
      PUBLISH publish1 <- readFromStream is

      writeToStream command_os $ PublishCommand $
        defaultMessage { messageQoS = QoS2 }
      PUBLISH publish2 <- readFromStream is

      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH publish3 <- readFromStream is
      writeToStream os $ PUBREC $ PubrecPacket (fromJust $ publishPacketIdentifier publish3)
      PUBREL pubrel <- readFromStream is

      reconnectClient os is

      PUBLISH publish1' <- readFromStream is
      PUBLISH publish2' <- readFromStream is
      PUBREL pubrel' <- readFromStream is

      publishPacketIdentifier publish1' `shouldBe` publishPacketIdentifier publish1
      publishPacketIdentifier publish2' `shouldBe` publishPacketIdentifier publish2
      pubrelPacketIdentifier  pubrel'   `shouldBe` pubrelPacketIdentifier pubrel


    it "When it re-sends any PUBLISH packets, it MUST re-send them in the order in which the original PUBLISH packets were sent (this applies to QoS 1 and QoS 2 messages) [MQTT-4.6.0-1]" $ do
      Session{..} <- newSession $ defaultConfig { ccCleanSession = False }

      writeToStream command_os $ PublishCommand $
        defaultMessage { messageQoS = QoS1 }
      PUBLISH p1 <- readFromStream is

      writeToStream command_os $ PublishCommand $
        defaultMessage { messageQoS = QoS2 }
      PUBLISH p2 <- readFromStream is

      writeToStream command_os $ PublishCommand $
        defaultMessage { messageQoS = QoS1 }
      PUBLISH p3 <- readFromStream is

      reconnectClient os is

      PUBLISH p1' <- readFromStream is
      PUBLISH p2' <- readFromStream is
      PUBLISH p3' <- readFromStream is

      forM_ (zip [p1, p2, p3] [p1', p2', p3']) $ \(p, p') -> do
        publishPacketIdentifier p `shouldBe` publishPacketIdentifier p'
        publishDup p  `shouldBe` False
        publishDup p' `shouldBe` True


    it "It MUST send PUBACK packets in the order in which the corresponding PUBLISH packets were received (QoS 1 messages) [MQTT-4.6.0-2]" $ do
      Session{..} <- newSession defaultConfig

      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS1 }
                       , publishPacketIdentifier = Just $ PacketIdentifier 1
                       }

      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS1 }
                       , publishPacketIdentifier = Just $ PacketIdentifier 2
                       }

      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS1 }
                       , publishPacketIdentifier = Just $ PacketIdentifier 3
                       }

      PUBACK p1 <- readFromStream is
      PUBACK p2 <- readFromStream is
      PUBACK p3 <- readFromStream is

      pubackPacketIdentifier p1 `shouldBe` PacketIdentifier 1
      pubackPacketIdentifier p2 `shouldBe` PacketIdentifier 2
      pubackPacketIdentifier p3 `shouldBe` PacketIdentifier 3


    it "It MUST send PUBREC packets in the order in which the corresponding PUBLISH packets were received (QoS 2 messages) [MQTT-4.6.0-3]" $ do
      Session{..} <- newSession defaultConfig

      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 }
                       , publishPacketIdentifier = Just $ PacketIdentifier 1
                       }

      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 }
                       , publishPacketIdentifier = Just $ PacketIdentifier 2
                       }

      writeToStream os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 }
                       , publishPacketIdentifier = Just $ PacketIdentifier 3
                       }

      PUBREC p1 <- readFromStream is
      PUBREC p2 <- readFromStream is
      PUBREC p3 <- readFromStream is

      pubrecPacketIdentifier p1 `shouldBe` PacketIdentifier 1
      pubrecPacketIdentifier p2 `shouldBe` PacketIdentifier 2
      pubrecPacketIdentifier p3 `shouldBe` PacketIdentifier 3


    it "It MUST send PUBREL packets in the order in which the corresponding PUBREC packets were received (QoS 2 messages) [MQTT-4.6.0-4]" $ do
      Session{..} <- newSession defaultConfig

      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p1 <- readFromStream is
      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p2 <- readFromStream is
      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p3 <- readFromStream is

      let packetIdentifier1 = fromJust $ publishPacketIdentifier p1
      let packetIdentifier2 = fromJust $ publishPacketIdentifier p2
      let packetIdentifier3 = fromJust $ publishPacketIdentifier p3

      writeToStream os $ PUBREC (PubrecPacket packetIdentifier1)
      writeToStream os $ PUBREC (PubrecPacket packetIdentifier2)
      writeToStream os $ PUBREC (PubrecPacket packetIdentifier3)

      PUBREL p1' <- readFromStream is
      PUBREL p2' <- readFromStream is
      PUBREL p3' <- readFromStream is

      pubrelPacketIdentifier p1' `shouldBe` packetIdentifier1
      pubrelPacketIdentifier p2' `shouldBe` packetIdentifier2
      pubrelPacketIdentifier p3' `shouldBe` packetIdentifier3


    it "After sending a DISCONNECT Packet the Client MUST close the Network Connection [MQTT-3.14.4-1]" $ do
      pending


    it "After sending a DISCONNECT Packet the Client MUST NOT send any more Control Packets on that Network Connection [MQTT-3.14.4-2]" $ do
      pending


    it "If the Client supplies a zero-byte ClientId, the Client MUST also set CleanSession to 1 [MQTT-3.1.3-7]." $ do
      pending


    it "If CleanSession is set to 1, the Client and Server MUST discard any previous Session and start a newSession one. This Session lasts as long as the Network Connection. State data associated with this Session MUST NOT be reused in any subsequent Session [MQTT-3.1.2-6]" $ do
      pending


    it "The Client and Server MUST store the Session after the Client and Server are disconnected [MQTT-3.1.2-4]" $ do
      pending


    it "Each time a Client sends a newSession packet of one of these types (SUBSCRIBE, UNSUBSCRIBE, and PUBLISH (in cases where QoS > 0)) it MUST assign it a currently unused Packet Identifier [MQTT-2.3.1-2]" $ do
      Session{..} <- newSession defaultConfig

      writeToStream command_os $ PublishCommand $ defaultMessage { messageQoS = QoS1 }
      PUBLISH p1     <- readFromStream is
      writeToStream command_os $ SubscribeCommand [ (TopicFilter $ T.pack "c/d", QoS2) ]
      SUBSCRIBE p2   <- readFromStream is
      writeToStream command_os $ UnsubscribeCommand [ TopicFilter $ T.pack "c/d" ]
      UNSUBSCRIBE p3 <- readFromStream is

      Set.size (Set.fromList [ fromJust $ publishPacketIdentifier p1
                             , subscribePacketIdentifier p2
                             , unsubscribePacketIdentifier p3
                             ]) `shouldBe` 3


    it "If a Client re-sends a particular Control Packet, then it MUST use the same Packet Identifier in subsequent re-sends of that packet. The Packet Identifier becomes available for reuse after the Client has processed the corresponding acknowledgement packet. In the case of a QoS 1 PUBLISH this is the corresponding PUBACK; in the case of QoS 2 it is PUBCOMP. For SUBSCRIBE or UNSUBSCRIBE it is the corresponding SUBACK or UNSUBACK [MQTT-2.3.1-3]" $ do
      pending


    it "Similarly SUBACK and UNSUBACK MUST contain the Packet Identifier that was used in the corresponding SUBSCRIBE and UNSUBSCRIBE Packet respectively [MQTT-2.3.1-7]" $ do
      pending


    it "The DUP flag MUST be set to 1 by the Client or Server when it attempts to re-deliver a PUBLISH Packet [MQTT-3.3.1-1]" $ do
      pending


    it "Unless stated otherwise, if either the Server or Client encounters a protocol violation, it MUST close the Network Connection on which it received that Control Packet which caused the protocol violation [MQTT-4.8.0-1]" $ do
      pending


    it "It is the responsibility of the Client to ensure that the interval between Control Packets being sent does not exceed the Keep Alive value. In the absence of sending any other Control Packets, the Client MUST send a PINGREQ Packet [MQTT-3.1.2-23]" $ do
      pending

