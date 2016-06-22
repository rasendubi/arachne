{-# LANGUAGE RecordWildCards #-}
module Network.MQTT.ClientSpec (spec) where

import           Control.Concurrent ( threadDelay )
import           Control.Concurrent.MVar ( newEmptyMVar, putMVar, takeMVar, isEmptyMVar )
import qualified Data.ByteString as BS
import           Data.Maybe ( isJust, fromJust )
import qualified Data.Text as T
import           Network.MQTT.Client ( runClient
                                     , sendPublish
                                     , sendSubscribe
                                     , sendUnsubscribe
                                     , setPublishCallback
                                     , Client)
import           Network.MQTT.Packet
import           System.IO.Streams ( InputStream, OutputStream )
import qualified System.IO.Streams as S
import qualified System.IO.Streams.Concurrent as S
import           System.Log ( Priority(DEBUG) )
import           System.Log.Logger            ( rootLoggerName, setLevel
                                              , updateGlobalLogger )
import qualified Data.Set as Set
import           Test.Hspec

debugTests :: IO ()
debugTests = updateGlobalLogger rootLoggerName (setLevel DEBUG)

new :: IO (Client, (InputStream Packet, OutputStream Packet))
new = do
  (is, is') <- S.makeChanPipe
  (os', os) <- S.makeChanPipe
  client <- runClient ConnectPacket{ connectClientIdentifier = ClientIdentifier (T.pack "42")
                                   , connectProtocolLevel    = 0x04
                                   , connectWillMsg          = Nothing
                                   , connectUserName         = Nothing
                                   , connectPassword         = Nothing
                                   , connectCleanSession     = True
                                   , connectKeepAlive        = 0
                                   }
                      is
                      os
  CONNECT _ <- fromJust <$> S.read os'
  S.write (Just $ CONNACK (ConnackPacket False Accepted)) is'
  return (client, (os', is'))


readPacket :: InputStream Packet -> IO Packet
readPacket is = fromJust <$> S.read is

writePacket :: OutputStream Packet -> Packet -> IO ()
writePacket os p = S.write (Just p) os

spec :: Spec
spec = do
  describe "MQTT Client" $ do

    it "In the QoS 0 delivery protocol, the Sender MUST send a PUBLISH packet with QoS=0, DUP=0 [MQTT-4.3.1-1]" $ do
      (client, (is, _)) <- new
      let message = Message { messageTopic   = TopicName $ T.pack "a/b"
                            , messageQoS     = QoS0
                            , messageMessage = BS.pack [0xab, 0x12]
                            , messageRetain  = False
                            }

      sendPublish client message

      PUBLISH PublishPacket{..} <- readPacket is
      messageQoS publishMessage `shouldBe` QoS0
      publishDup `shouldBe` False

    it "In the QoS 1 delivery protocol, the Sender MUST assign an unused Packet Identifier each time it has a new Application Message to publish [MQTT-4.3.2-1]" $ do
      (client, (is, _)) <- new
      let message = Message { messageTopic   = TopicName $ T.pack "a/b"
                            , messageQoS     = QoS1
                            , messageMessage = BS.pack [0xab, 0x12]
                            , messageRetain  = False
                            }
      sendPublish client message
      PUBLISH pp1 <- readPacket is
      sendPublish client message
      PUBLISH pp2 <- readPacket is
      sendPublish client message
      PUBLISH pp3 <- readPacket is

      Set.size (Set.fromList [ publishPacketIdentifier pp1, publishPacketIdentifier pp2, publishPacketIdentifier pp3 ]) `shouldBe` 3

    it "In the QoS 1 delivery protocol, the Sender MUST send a PUBLISH Packet containing this Packet Identifier with QoS=1, DUP=0 [MQTT-4.3.2-1]" $ do
      (client, (is, _)) <- new
      let message = Message { messageTopic   = TopicName $ T.pack "a/b"
                            , messageQoS     = QoS1
                            , messageMessage = BS.pack [0xab, 0x12]
                            , messageRetain  = False
                            }

      sendPublish client message

      PUBLISH PublishPacket{..} <- readPacket is
      messageQoS publishMessage `shouldBe` QoS1
      publishDup `shouldBe` False

    it "In the QoS 1 delivery protocol, the Sender MUST treat the PUBLISH Packet as 'unacknowledged' until it has received the corresponding PUBACK packet from the receiver [MQTT-4.3.2-1]" $ do
      pending

    it "In the QoS 1 delivery protocol, the Receiver MUST respond with a PUBACK Packet containing the Packet Identifier from the incoming PUBLISH Packet, having accepted ownership of the Application Message [MQTT-4.3.2-2]" $ do
      let packetIdentifier = PacketIdentifier 42
      let topicName        = TopicName $ T.pack "a/b"
      let messageMessage   = BS.pack [0xab, 0x12]
      let message = Message { messageTopic   = topicName
                            , messageQoS     = QoS1
                            , messageMessage = messageMessage
                            , messageRetain  = False
                            }
      callbackTopicName <- newEmptyMVar
      callbackMessage   <- newEmptyMVar

      (client, (is, os)) <- new
      setPublishCallback client $ Just $ \t m -> do
        putMVar callbackTopicName t
        putMVar callbackMessage m

      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just packetIdentifier
                             , publishMessage          = message
                             }

      PUBACK PubackPacket{..} <- readPacket is
      callbackTopicName'      <- takeMVar callbackTopicName
      callbackMessage'        <- takeMVar callbackMessage

      pubackPacketIdentifier `shouldBe` packetIdentifier
      callbackTopicName'     `shouldBe` topicName
      callbackMessage'       `shouldBe` messageMessage

    it "In the QoS 1 delivery protocol, the Receiver After it has sent a PUBACK Packet the Receiver MUST treat any incoming PUBLISH packet that contains the same Packet Identifier as being a new publication, irrespective of the setting of its DUP flag [MQTT-4.3.2-2]" $ do
      let packetIdentifier = PacketIdentifier 42
      let topicName        = TopicName $ T.pack "a/b"
      let messageMessage   = BS.pack [0xab, 0x12]
      let message = Message { messageTopic   = topicName
                            , messageQoS     = QoS1
                            , messageMessage = messageMessage
                            , messageRetain  = False
                            }
      callbackTopicName <- newEmptyMVar
      callbackMessage   <- newEmptyMVar

      (client, (is, os)) <- new
      setPublishCallback client $ Just $ \t m -> do
        putMVar callbackTopicName t
        putMVar callbackMessage m

      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just packetIdentifier
                             , publishMessage          = message
                             }

      PUBACK pp1         <- readPacket is
      callbackTopicName' <- takeMVar callbackTopicName
      callbackMessage'   <- takeMVar callbackMessage

      pubackPacketIdentifier pp1 `shouldBe` packetIdentifier
      callbackTopicName'         `shouldBe` topicName
      callbackMessage'           `shouldBe` messageMessage

      writePacket os $
        PUBLISH PublishPacket{ publishDup              = True
                             , publishPacketIdentifier = Just packetIdentifier
                             , publishMessage          = message
                             }

      PUBACK pp2          <- readPacket is
      callbackTopicName'' <- takeMVar callbackTopicName
      callbackMessage''   <- takeMVar callbackMessage

      pubackPacketIdentifier pp2 `shouldBe` packetIdentifier
      callbackTopicName''        `shouldBe` topicName
      callbackMessage''          `shouldBe` messageMessage

    it "In the QoS 2 delivery protocol, the Sender MUST assign an unused Packet Identifier when it has a new Application Message to publish [MQTT-4.3.3-1]" $ do
      (client, (is, _)) <- new
      let message = Message { messageTopic   = TopicName $ T.pack "a/b"
                            , messageQoS     = QoS2
                            , messageMessage = BS.pack [0xab, 0x12]
                            , messageRetain  = False
                            }

      sendPublish client message
      PUBLISH pp1 <- readPacket is
      sendPublish client message
      PUBLISH pp2 <- readPacket is
      sendPublish client message
      PUBLISH pp3 <- readPacket is

      Set.size (Set.fromList [ publishPacketIdentifier pp1, publishPacketIdentifier pp2, publishPacketIdentifier pp3 ]) `shouldBe` 3

    it "In the QoS 2 delivery protocol, the Sender MUST send a PUBLISH packet containing this Packet Identifier with QoS=2, DUP=0 [MQTT-4.3.3-1]" $ do
      (client, (is, _)) <- new
      let message = Message { messageTopic   = TopicName $ T.pack "a/b"
                            , messageQoS     = QoS2
                            , messageMessage = BS.pack [0xab, 0x12]
                            , messageRetain  = False
                            }

      sendPublish client message

      PUBLISH PublishPacket{..} <- readPacket is
      messageQoS publishMessage `shouldBe` QoS2
      publishDup `shouldBe` False

    it "In the QoS 2 delivery protocol, the Sender MUST treat the PUBLISH packet as 'unacknowledged' until it has received the corresponding PUBREC packet from the receiver [MQTT-4.3.3-1]" $ do
      pending

    it "In the QoS 2 delivery protocol, the Sender MUST send a PUBREL packet when it receives a PUBREC packet from the receiver [MQTT-4.3.3-1]" $ do
      let message = Message { messageTopic   = TopicName $ T.pack "a/b"
                            , messageQoS     = QoS2
                            , messageMessage = BS.pack [0xab, 0x12]
                            , messageRetain  = False
                            }
      (client, (is, os)) <- new

      sendPublish client message

      PUBLISH PublishPacket{..} <- readPacket is
      let packetIdentifier = fromJust publishPacketIdentifier
      writePacket os $ PUBREC $ PubrecPacket packetIdentifier

      PUBREL PubrelPacket{..} <- readPacket is
      pubrelPacketIdentifier `shouldBe` packetIdentifier

    it "In the QoS 2 delivery protocol, the Sender MUST treat the PUBREL packet as 'unacknowledged' until it has received the corresponding PUBCOMP packet from the receiver [MQTT-4.3.3-1]" $ do
      pending

    it "In the QoS 2 delivery protocol, the Sender MUST NOT re-send the PUBLISH once it has sent the corresponding PUBREL packet [MQTT-4.3.3-1]" $ do
      pending

    it "In the QoS2 delivery protocol, the Receiver MUST respond with a PUBREC containing the Packet Identifier from the incoming PUBLISH Packet, having accepted ownership of the Application Message [MQTT-4.3.3-1]" $ do
      let packetIdentifier = PacketIdentifier 42
      let topicName        = TopicName $ T.pack "a/b"
      let messageMessage   = BS.pack [0xab, 0x12]
      let message = Message { messageTopic   = topicName
                            , messageQoS     = QoS2
                            , messageMessage = messageMessage
                            , messageRetain  = False
                            }
      callbackTopicName <- newEmptyMVar
      callbackMessage   <- newEmptyMVar

      (client, (is, os)) <- new
      setPublishCallback client $ Just $ \t m -> do
        putMVar callbackTopicName t
        putMVar callbackMessage m

      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just packetIdentifier
                             , publishMessage          = message
                             }

      PUBREC PubrecPacket{..} <- readPacket is
      callbackTopicName'      <- takeMVar callbackTopicName
      callbackMessage'        <- takeMVar callbackMessage

      pubrecPacketIdentifier `shouldBe` packetIdentifier
      callbackTopicName'     `shouldBe` topicName
      callbackMessage'       `shouldBe` messageMessage

    it "In the QoS2 delivery protocol, the Receiver Until it has received the corresponding PUBREL packet, the Receiver MUST acknowledge any subsequent PUBLISH packet with the same Packet Identifier by sending a PUBREC [MQTT-4.3.3-1]" $ do
      let packetIdentifier = PacketIdentifier 42
      let message = Message { messageTopic   = TopicName $ T.pack "a/b"
                            , messageQoS     = QoS2
                            , messageMessage = BS.pack [0xab, 0x12]
                            , messageRetain  = False
                            }
      (_, (is, os)) <- new

      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just packetIdentifier
                             , publishMessage          = message
                             }
      PUBREC pp1 <- readPacket is
      writePacket os $
        PUBLISH PublishPacket{ publishDup              = True
                             , publishPacketIdentifier = Just packetIdentifier
                             , publishMessage          = message
                             }
      PUBREC pp2 <- readPacket is

      pubrecPacketIdentifier pp1 `shouldBe` packetIdentifier
      pubrecPacketIdentifier pp2 `shouldBe` packetIdentifier

    it "In the QoS2 delivery protocol, the Receiver MUST respond to a PUBREL packet by sending a PUBCOMP packet containing the same Packet Identifier as the PUBREL [MQTT-4.3.3-1]" $ do
      let packetIdentifier = PacketIdentifier 42
      let message = Message { messageTopic   = TopicName $ T.pack "a/b"
                            , messageQoS     = QoS2
                            , messageMessage = BS.pack [0xab, 0x12]
                            , messageRetain  = False
                            }
      (_, (is, os)) <- new
      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just packetIdentifier
                             , publishMessage          = message
                             }
      PUBREC _ <- readPacket is

      writePacket os $ PUBREL $ PubrelPacket packetIdentifier

      PUBCOMP PubcompPacket{..} <- readPacket is
      pubcompPacketIdentifier `shouldBe` packetIdentifier

    it "In the QoS2 delivery protocol, the Receiver After it has sent a PUBCOMP, the receiver MUST treat any subsequent PUBLISH packet that contains that Packet Identifier as being a new publication [MQTT-4.3.3-1]" $ do
      let packetIdentifier = PacketIdentifier 42
      let topicName        = TopicName $ T.pack "a/b"
      let messageMessage   = BS.pack [0xab, 0x12]
      let message = Message { messageTopic   = topicName
                            , messageQoS     = QoS2
                            , messageMessage = messageMessage
                            , messageRetain  = False
                            }
      callbackTopicName <- newEmptyMVar
      callbackMessage   <- newEmptyMVar

      (client, (is, os)) <- new
      setPublishCallback client $ Just $ \t m -> do
        putMVar callbackTopicName t
        putMVar callbackMessage m

      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just packetIdentifier
                             , publishMessage          = message
                             }
      PUBREC _ <- readPacket is

      callbackTopicName'      <- takeMVar callbackTopicName
      callbackMessage'        <- takeMVar callbackMessage
      callbackTopicName'     `shouldBe` topicName
      callbackMessage'       `shouldBe` messageMessage

      -- Check whether Receiver Before it has sent a PUBCOMP does not treat PUBLISH packet that contains that Packet Identifier as being a new publication
      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just packetIdentifier
                             , publishMessage          = message
                             }
      PUBREC _ <- readPacket is
      a <- isEmptyMVar callbackTopicName
      b <- isEmptyMVar callbackMessage
      a `shouldBe` True
      b `shouldBe` True

      -- Send a PUBCOMP
      writePacket os $ PUBREL $ PubrelPacket packetIdentifier
      PUBCOMP PubcompPacket{..} <- readPacket is

      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just packetIdentifier
                             , publishMessage          = message
                             }
      PUBREC _ <- readPacket is

      callbackTopicName'' <- takeMVar callbackTopicName
      callbackMessage''   <- takeMVar callbackMessage
      callbackTopicName'' `shouldBe` topicName
      callbackMessage''   `shouldBe` messageMessage

    it "When a Client reconnects with CleanSession set to 0, both the Client and Server MUST re-send any unacknowledged PUBLISH Packets (where QoS > 0) and PUBREL Packets using their original Packet Identifiers [MQTT-4.4.0-1]" $ do
      pending

    it "When it re-sends any PUBLISH packets, it MUST re-send them in the order in which the original PUBLISH packets were sent (this applies to QoS 1 and QoS 2 messages) [MQTT-4.6.0-1]" $ do
      pending

    it "It MUST send PUBACK packets in the order in which the corresponding PUBLISH packets were received (QoS 1 messages) [MQTT-4.6.0-2]" $ do
      let message = Message { messageTopic   = TopicName $ T.pack "a/b"
                            , messageQoS     = QoS1
                            , messageMessage = BS.pack [0xab, 0x12]
                            , messageRetain  = False
                            }
      (_, (is, os)) <- new

      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just (PacketIdentifier 1)
                             , publishMessage          = message
                             }
      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just (PacketIdentifier 2)
                             , publishMessage          = message
                             }
      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just (PacketIdentifier 3)
                             , publishMessage          = message
                             }

      PUBACK pp1 <- readPacket is
      PUBACK pp2 <- readPacket is
      PUBACK pp3 <- readPacket is

      pubackPacketIdentifier pp1 `shouldBe` PacketIdentifier 1
      pubackPacketIdentifier pp2 `shouldBe` PacketIdentifier 2
      pubackPacketIdentifier pp3 `shouldBe` PacketIdentifier 3

    it "It MUST send PUBREC packets in the order in which the corresponding PUBLISH packets were received (QoS 2 messages) [MQTT-4.6.0-3]" $ do
      let message = Message { messageTopic   = TopicName $ T.pack "a/b"
                            , messageQoS     = QoS2
                            , messageMessage = BS.pack [0xab, 0x12]
                            , messageRetain  = False
                            }
      (_, (is, os)) <- new

      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just (PacketIdentifier 1)
                             , publishMessage          = message
                             }
      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just (PacketIdentifier 2)
                             , publishMessage          = message
                             }
      writePacket os $
        PUBLISH PublishPacket{ publishDup              = False
                             , publishPacketIdentifier = Just (PacketIdentifier 3)
                             , publishMessage          = message
                             }

      PUBREC pp1 <- readPacket is
      PUBREC pp2 <- readPacket is
      PUBREC pp3 <- readPacket is

      pubrecPacketIdentifier pp1 `shouldBe` PacketIdentifier 1
      pubrecPacketIdentifier pp2 `shouldBe` PacketIdentifier 2
      pubrecPacketIdentifier pp3 `shouldBe` PacketIdentifier 3

    it "It MUST send PUBREL packets in the order in which the corresponding PUBREC packets were received (QoS 2 messages) [MQTT-4.6.0-4]" $ do
      let message = Message { messageTopic   = TopicName $ T.pack "a/b"
                            , messageQoS     = QoS2
                            , messageMessage = BS.pack [0xab, 0x12]
                            , messageRetain  = False
                            }
      (client, (is, os)) <- new

      sendPublish client message
      PUBLISH pp1 <- readPacket is
      sendPublish client message
      PUBLISH pp2 <- readPacket is
      sendPublish client message
      PUBLISH pp3 <- readPacket is

      let packetIdentifier1 = fromJust $ publishPacketIdentifier pp1
      let packetIdentifier2 = fromJust $ publishPacketIdentifier pp2
      let packetIdentifier3 = fromJust $ publishPacketIdentifier pp3

      writePacket os $ PUBREC $ PubrecPacket packetIdentifier1
      writePacket os $ PUBREC $ PubrecPacket packetIdentifier2
      writePacket os $ PUBREC $ PubrecPacket packetIdentifier3

      PUBREL pp1' <- readPacket is
      PUBREL pp2' <- readPacket is
      PUBREL pp3' <- readPacket is

      pubrelPacketIdentifier pp1' `shouldBe` packetIdentifier1
      pubrelPacketIdentifier pp2' `shouldBe` packetIdentifier2
      pubrelPacketIdentifier pp3' `shouldBe` packetIdentifier3

    it "After sending a DISCONNECT Packet the Client MUST close the Network Connection [MQTT-3.14.4-1]" $ do
      pending

    it "After sending a DISCONNECT Packet the Client MUST NOT send any more Control Packets on that Network Connection [MQTT-3.14.4-2]" $ do
      pending

    it "If the Client supplies a zero-byte ClientId, the Client MUST also set CleanSession to 1 [MQTT-3.1.3-7]." $ do
      pending

    it "If CleanSession is set to 1, the Client and Server MUST discard any previous Session and start a new one. This Session lasts as long as the Network Connection. State data associated with this Session MUST NOT be reused in any subsequent Session [MQTT-3.1.2-6]" $ do
      pending

    it "The Client and Server MUST store the Session after the Client and Server are disconnected [MQTT-3.1.2-4]" $ do
      pending

    it "Each time a Client sends a new packet of one of these types (SUBSCRIBE, UNSUBSCRIBE, and PUBLISH (in cases where QoS > 0)) it MUST assign it a currently unused Packet Identifier [MQTT-2.3.1-2]" $ do
      (client, (is, _)) <- new
      sendPublish client  Message { messageTopic   = TopicName $ T.pack "a/b"
                                  , messageQoS     = QoS1
                                  , messageMessage = BS.pack [0xab, 0x12]
                                  , messageRetain  = False
                                  }
      PUBLISH pp1 <- readPacket is
      sendSubscribe client [ (TopicFilter $ T.pack "c/d", QoS2) ]
      SUBSCRIBE pp2 <- readPacket is
      sendUnsubscribe client [ TopicFilter $ T.pack "c/d" ]
      UNSUBSCRIBE pp3 <- readPacket is

      Set.size (Set.fromList [ fromJust $ publishPacketIdentifier pp1, subscribePacketIdentifier pp2, unsubscribePacketIdentifier pp3 ]) `shouldBe` 3

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
