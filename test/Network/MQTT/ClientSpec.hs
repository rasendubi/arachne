{-# LANGUAGE RecordWildCards #-}
module Network.MQTT.ClientSpec (spec) where

import           Control.Concurrent ( threadDelay )
import           Control.Concurrent.MVar ( newEmptyMVar, putMVar, takeMVar, isEmptyMVar )
import qualified Data.ByteString as BS
import           Data.Maybe ( isJust, fromJust )
import qualified Data.Text as T
import           Network.MQTT.Client ( runClient
                                     , stopClient

                                     , sendPublish
                                     , sendSubscribe
                                     , sendUnsubscribe

                                     , UserCredentials(..)
                                     , ClientConfig(..)
                                     , Client)
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

debugTests :: IO ()
debugTests = updateGlobalLogger rootLoggerName (setLevel DEBUG)

data Session = Session
               { client :: Client
               , is     :: InputStream Packet
               , os     :: OutputStream Packet
               }

newSession :: ClientConfig -> IO Session
newSession config = do
  (is, is') <- S.makeChanPipe
  (os', os) <- S.makeChanPipe
  client <- runClient config is os
  CONNECT _ <- readPacket os'
  flip S.write is' $ Just (CONNACK (ConnackPacket False Accepted))
  return Session
    { client = client
    , is     = os'
    , os     = is'
    }

readPacket :: InputStream Packet -> IO Packet
readPacket is = fromJust <$> S.read is

writePacket :: OutputStream Packet -> Packet -> IO ()
writePacket os p = S.write (Just p) os

disconnectClient :: OutputStream Packet -> IO ()
disconnectClient = S.write Nothing

defaultConfig = ClientConfig
                { ccClientIdenfier   = ClientIdentifier $ T.pack "arachne-test"
                , ccWillMsg          = Nothing
                , ccUserCredentials  = Nothing
                , ccCleanSession     = True
                , ccKeepAlive        = 0
                , ccPublishCallback  = const $ return ()
                , ccSubackCallback   = const $ return ()
                , ccUnsubackCallback = const $ return ()
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
      sendPublish client $ defaultMessage { messageQoS = QoS0 }
      PUBLISH PublishPacket{..} <- readPacket is
      messageQoS publishMessage `shouldBe` QoS0
      publishDup                `shouldBe` False


    it "In the QoS 1 delivery protocol, the Sender MUST assign an unused Packet Identifier each time it has a newSession Application Message to publish [MQTT-4.3.2-1]" $ do
      Session{..} <- newSession defaultConfig

      sendPublish client $ defaultMessage { messageQoS = QoS1 }
      PUBLISH p1 <- readPacket is
      sendPublish client $ defaultMessage { messageQoS = QoS1 }
      PUBLISH p2 <- readPacket is
      sendPublish client $ defaultMessage { messageQoS = QoS1 }
      PUBLISH p3 <- readPacket is

      Set.size (Set.fromList [ publishPacketIdentifier p1
                             , publishPacketIdentifier p2
                             , publishPacketIdentifier p3
                             ]) `shouldBe` 3


    it "In the QoS 1 delivery protocol, the Sender MUST send a PUBLISH Packet containing this Packet Identifier with QoS=1, DUP=0 [MQTT-4.3.2-1]" $ do
      Session{..} <- newSession defaultConfig
      sendPublish client $ defaultMessage { messageQoS = QoS1 }
      PUBLISH PublishPacket{..} <- readPacket is
      messageQoS publishMessage `shouldBe` QoS1
      publishDup                `shouldBe` False


    it "In the QoS 1 delivery protocol, the Sender MUST treat the PUBLISH Packet as 'unacknowledged' until it has received the corresponding PUBACK packet from the receiver [MQTT-4.3.2-1]" $ do
      pending


    it "In the QoS 1 delivery protocol, the Receiver MUST respond with a PUBACK Packet containing the Packet Identifier from the incoming PUBLISH Packet, having accepted ownership of the Application Message [MQTT-4.3.2-2]" $ do
      callbackMessage   <- newEmptyMVar

      Session{..} <- newSession $ defaultConfig { ccPublishCallback = putMVar callbackMessage }

      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS1 } }

      PUBACK PubackPacket{..} <- readPacket is
      callbackMessage' <- takeMVar callbackMessage

      callbackMessage'       `shouldBe` defaultMessage { messageQoS = QoS1 }
      pubackPacketIdentifier `shouldBe` defaultPacketIdentifier


    it "In the QoS 1 delivery protocol, the Receiver After it has sent a PUBACK Packet the Receiver MUST treat any incoming PUBLISH packet that contains the same Packet Identifier as being a newSession publication, irrespective of the setting of its DUP flag [MQTT-4.3.2-2]" $ do
      callbackMessage   <- newEmptyMVar

      Session{..} <- newSession $ defaultConfig { ccPublishCallback = putMVar callbackMessage }

      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS1 } }

      PUBACK p1        <- readPacket is
      callbackMessage' <- takeMVar callbackMessage

      callbackMessage'          `shouldBe` defaultMessage { messageQoS = QoS1 }
      pubackPacketIdentifier p1 `shouldBe` defaultPacketIdentifier

      writePacket os $ PUBLISH
        defaultPublish { publishDup = True
                       , publishMessage = defaultMessage { messageQoS = QoS1 }
                       }

      PUBACK p2         <- readPacket is
      callbackMessage'' <- takeMVar callbackMessage

      callbackMessage''         `shouldBe` defaultMessage { messageQoS = QoS1 }
      pubackPacketIdentifier p2 `shouldBe` defaultPacketIdentifier


    it "In the QoS 2 delivery protocol, the Sender MUST assign an unused Packet Identifier when it has a newSession Application Message to publish [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession defaultConfig

      sendPublish client $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p1 <- readPacket is
      sendPublish client $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p2 <- readPacket is
      sendPublish client $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p3 <- readPacket is

      Set.size (Set.fromList [ publishPacketIdentifier p1
                             , publishPacketIdentifier p2
                             , publishPacketIdentifier p3
                             ]) `shouldBe` 3


    it "In the QoS 2 delivery protocol, the Sender MUST send a PUBLISH packet containing this Packet Identifier with QoS=2, DUP=0 [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession defaultConfig
      sendPublish client $ defaultMessage { messageQoS = QoS2 }
      PUBLISH PublishPacket{..} <- readPacket is
      messageQoS publishMessage `shouldBe` QoS2
      publishDup                `shouldBe` False


    it "In the QoS 2 delivery protocol, the Sender MUST treat the PUBLISH packet as 'unacknowledged' until it has received the corresponding PUBREC packet from the receiver [MQTT-4.3.3-1]" $ do
      pending


    it "In the QoS 2 delivery protocol, the Sender MUST send a PUBREL packet when it receives a PUBREC packet from the receiver [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession defaultConfig

      sendPublish client $ defaultMessage { messageQoS = QoS2 }
      PUBLISH PublishPacket{..} <- readPacket is
      let packetIdentifier = fromJust publishPacketIdentifier
      writePacket os $ PUBREC (PubrecPacket packetIdentifier)
      PUBREL PubrelPacket{..} <- readPacket is

      pubrelPacketIdentifier `shouldBe` packetIdentifier


    it "In the QoS 2 delivery protocol, the Sender MUST treat the PUBREL packet as 'unacknowledged' until it has received the corresponding PUBCOMP packet from the receiver [MQTT-4.3.3-1]" $ do
      pending


    it "In the QoS 2 delivery protocol, the Sender MUST NOT re-send the PUBLISH once it has sent the corresponding PUBREL packet [MQTT-4.3.3-1]" $ do
      pending


    it "In the QoS2 delivery protocol, the Receiver MUST respond with a PUBREC containing the Packet Identifier from the incoming PUBLISH Packet, having accepted ownership of the Application Message [MQTT-4.3.3-1]" $ do
      callbackMessage   <- newEmptyMVar

      Session{..} <- newSession $ defaultConfig { ccPublishCallback = putMVar callbackMessage }

      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 } }

      PUBREC PubrecPacket{..} <- readPacket is
      callbackMessage' <- takeMVar callbackMessage

      callbackMessage'       `shouldBe` defaultMessage { messageQoS = QoS2 }
      pubrecPacketIdentifier `shouldBe` defaultPacketIdentifier

    it "In the QoS2 delivery protocol, the Receiver Until it has received the corresponding PUBREL packet, the Receiver MUST acknowledge any subsequent PUBLISH packet with the same Packet Identifier by sending a PUBREC [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession defaultConfig

      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 } }

      PUBREC p1 <- readPacket is
      writePacket os $ PUBLISH
        defaultPublish { publishDup = True
                       , publishMessage = defaultMessage { messageQoS = QoS2 }
                       }
      PUBREC p2 <- readPacket is

      pubrecPacketIdentifier p1 `shouldBe` defaultPacketIdentifier
      pubrecPacketIdentifier p2 `shouldBe` defaultPacketIdentifier

    it "In the QoS2 delivery protocol, the Receiver MUST respond to a PUBREL packet by sending a PUBCOMP packet containing the same Packet Identifier as the PUBREL [MQTT-4.3.3-1]" $ do
      Session{..} <- newSession defaultConfig

      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 } }

      PUBREC _ <- readPacket is

      writePacket os $ PUBREL $ PubrelPacket defaultPacketIdentifier

      PUBCOMP PubcompPacket{..} <- readPacket is

      pubcompPacketIdentifier `shouldBe` defaultPacketIdentifier


    it "In the QoS2 delivery protocol, the Receiver After it has sent a PUBCOMP, the receiver MUST treat any subsequent PUBLISH packet that contains that Packet Identifier as being a newSession publication [MQTT-4.3.3-1]" $ do
      callbackMessage   <- newEmptyMVar

      Session{..} <- newSession $ defaultConfig { ccPublishCallback = putMVar callbackMessage }

      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 } }

      PUBREC _ <- readPacket is

      callbackMessage'        <- takeMVar callbackMessage
      callbackMessage' `shouldBe` defaultMessage { messageQoS = QoS2 }

      -- Check whether Receiver Before it has sent a PUBCOMP does not treat PUBLISH packet that contains that Packet Identifier as being a newSession publication
      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 } }

      PUBREC _ <- readPacket is
      a <- isEmptyMVar callbackMessage
      a `shouldBe` True

      -- Send a PUBCOMP
      writePacket os $ PUBREL $ PubrelPacket defaultPacketIdentifier
      PUBCOMP PubcompPacket{..} <- readPacket is

      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 } }
      PUBREC _ <- readPacket is

      callbackMessage''        <- takeMVar callbackMessage
      callbackMessage'' `shouldBe` defaultMessage { messageQoS = QoS2 }


    it "When a Client reconnects with CleanSession set to 0, both the Client and Server MUST re-send any unacknowledged PUBLISH Packets (where QoS > 0) and PUBREL Packets using their original Packet Identifiers [MQTT-4.4.0-1]" $ do
      pending


    it "When it re-sends any PUBLISH packets, it MUST re-send them in the order in which the original PUBLISH packets were sent (this applies to QoS 1 and QoS 2 messages) [MQTT-4.6.0-1]" $ do
      -- Session{..} <- newSession defaultConfig

      -- sendPublish client $
      --   defaultMessage { messageTopic = TopicName $ T.pack "a/b"
      --                  , messageQoS     = QoS1
      --                  }
      -- PUBLISH p1 <- readPacket is

      -- sendPublish client $
      --   defaultMessage { messageTopic = TopicName $ T.pack "c/d"
      --                  , messageQoS     = QoS2
      --                  }
      -- PUBLISH p2 <- readPacket is

      -- sendPublish client $
      --   defaultMessage { messageTopic = TopicName $ T.pack "a/b"
      --                  , messageQoS     = QoS1
      --                  }
      -- PUBLISH p3 <- readPacket is

      -- disconnectClient os

      -- CONNECT ConnectPacket{..} <- readPacket is
      -- writePacket os $ CONNACK (ConnackPacket False Accepted)

      -- PUBLISH p1' <- readPacket is
      -- PUBLISH p2' <- readPacket is
      -- PUBLISH p3' <- readPacket is

      -- forM_ (zip [p1, p2, p3] [p1', p2', p3']) $ \(p, p') -> do
      --   publishPacketIdentifier p `shouldBe` publishPacketIdentifier p'
      --   publishDup p  `shouldBe` False
      --   publishDup p' `shouldBe` True
      pending


    it "It MUST send PUBACK packets in the order in which the corresponding PUBLISH packets were received (QoS 1 messages) [MQTT-4.6.0-2]" $ do
      Session{..} <- newSession defaultConfig

      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS1 }
                       , publishPacketIdentifier = Just $ PacketIdentifier 1
                       }

      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS1 }
                       , publishPacketIdentifier = Just $ PacketIdentifier 2
                       }

      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS1 }
                       , publishPacketIdentifier = Just $ PacketIdentifier 3
                       }

      PUBACK p1 <- readPacket is
      PUBACK p2 <- readPacket is
      PUBACK p3 <- readPacket is

      pubackPacketIdentifier p1 `shouldBe` PacketIdentifier 1
      pubackPacketIdentifier p2 `shouldBe` PacketIdentifier 2
      pubackPacketIdentifier p3 `shouldBe` PacketIdentifier 3


    it "It MUST send PUBREC packets in the order in which the corresponding PUBLISH packets were received (QoS 2 messages) [MQTT-4.6.0-3]" $ do
      Session{..} <- newSession defaultConfig

      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 }
                       , publishPacketIdentifier = Just $ PacketIdentifier 1
                       }

      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 }
                       , publishPacketIdentifier = Just $ PacketIdentifier 2
                       }

      writePacket os $ PUBLISH
        defaultPublish { publishMessage = defaultMessage { messageQoS = QoS2 }
                       , publishPacketIdentifier = Just $ PacketIdentifier 3
                       }

      PUBREC p1 <- readPacket is
      PUBREC p2 <- readPacket is
      PUBREC p3 <- readPacket is

      pubrecPacketIdentifier p1 `shouldBe` PacketIdentifier 1
      pubrecPacketIdentifier p2 `shouldBe` PacketIdentifier 2
      pubrecPacketIdentifier p3 `shouldBe` PacketIdentifier 3


    it "It MUST send PUBREL packets in the order in which the corresponding PUBREC packets were received (QoS 2 messages) [MQTT-4.6.0-4]" $ do
      Session{..} <- newSession defaultConfig

      sendPublish client $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p1 <- readPacket is
      sendPublish client $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p2 <- readPacket is
      sendPublish client $ defaultMessage { messageQoS = QoS2 }
      PUBLISH p3 <- readPacket is

      let packetIdentifier1 = fromJust $ publishPacketIdentifier p1
      let packetIdentifier2 = fromJust $ publishPacketIdentifier p2
      let packetIdentifier3 = fromJust $ publishPacketIdentifier p3

      writePacket os $ PUBREC (PubrecPacket packetIdentifier1)
      writePacket os $ PUBREC (PubrecPacket packetIdentifier2)
      writePacket os $ PUBREC (PubrecPacket packetIdentifier3)

      PUBREL p1' <- readPacket is
      PUBREL p2' <- readPacket is
      PUBREL p3' <- readPacket is

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

      sendPublish client $ defaultMessage { messageQoS = QoS1 }
      PUBLISH p1     <- readPacket is
      sendSubscribe client [ (TopicFilter $ T.pack "c/d", QoS2) ]
      SUBSCRIBE p2   <- readPacket is
      sendUnsubscribe client [ TopicFilter $ T.pack "c/d" ]
      UNSUBSCRIBE p3 <- readPacket is

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
