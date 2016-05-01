module Network.MQTT.ParserSpec (spec) where

import Test.Hspec

import Network.MQTT.Packet
import Network.MQTT.Parser

import Control.Monad
import Data.Maybe
import qualified Data.ByteString as BS
import qualified Data.Text as T
import Data.Attoparsec.ByteString

import Data.Bits

isParseFail :: Result a -> Bool
isParseFail (Fail _ _ _) = True
isParseFail _            = False

shouldParseFully :: (Show a, Eq a) => Result a -> a -> Expectation
shouldParseFully r x = r `shouldSatisfy` fromJust . compareResults (Done BS.empty x)

spec :: Spec
spec = do
  let shouldParseAs r x = parse parsePacket (BS.pack r) `shouldSatisfy` fromJust . compareResults (Done BS.empty x)

  let shouldFailParsing x = parse parsePacket (BS.pack x) `shouldSatisfy` isParseFail

  describe "parsePacket" $ do
    it "fails fast on unknown packet types" $ do
      shouldFailParsing [0x00]
      shouldFailParsing [0xf0]

    describe "CONNECT" $ do
      it "parses valid packet" $ do
        [0x10,
         -- remaining length = 33 bytes
         33,
         -- protocol name = MQTT
         0x00, 0x04, 0x4d, 0x51, 0x54, 0x54,
         -- protocol level = 4
         0x04,
         -- username = 1
         -- password = 1
         -- retain   = 0
         -- willqos  = 01
         -- will     = 1
         -- clean    = 1
         -- reserved = 0
         0xce,
         -- keep alie = 0x000c
         0x00, 0x0c,
         -- client id = "abc"
         0x00, 0x03, 0x61, 0x62, 0x63,
         -- topic name = "a/b"
         0x00, 0x03, 0x61, 0x2f, 0x62,
         -- will message = [0x12, 0xab]
         0x00, 0x02, 0x12, 0xab,
         -- username = "ac"
         0x00, 0x02, 0x61, 0x63,
         -- password = [0xcd, 0xbb, 0x11]
         0x00, 0x03, 0xcd, 0xbb, 0x11] `shouldParseAs`
          CONNECT ConnectPacket{ connectClientIdentifier = ClientIdentifier (T.pack "abc")
                               , connectProtocolLevel = 0x04
                               , connectWillMsg = Just $
                                   Message QoS1 False (Topic $ T.pack "a/b") (BS.pack [0x12, 0xab])
                               , connectUserName = Just (UserName $ T.pack "ac")
                               , connectPassword = Just (Password $ BS.pack [0xcd, 0xbb, 0x11])
                               , connectCleanSession = True
                               , connectKeepAlive = 0x000c
                               }

      it "parses unknown protocol level" $ do
        -- MQTTT-3.1.2-2: The Server MUST respond to the CONNECT
        -- Packet with a CONNACK return code 0x01 (unacceptable
        -- protocol level) and then disconnect the Client if the
        -- Protocol Level is not supported by the Server.
        --
        -- That means we should successfully parse packets with
        -- unknown protocol levels to let server respond to them.
        [0x10,
         -- remaining length = 33 bytes
         33,
         -- protocol name = MQTT
         0x00, 0x04, 0x4d, 0x51, 0x54, 0x54,
         -- protocol level = 0xf1
         0xf1,
         -- username = 1
         -- password = 1
         -- retain   = 0
         -- willqos  = 01
         -- will     = 1
         -- clean    = 1
         -- reserved = 0
         0xce,
         -- keep alie = 0x000c
         0x00, 0x0c,
         -- client id = "abc"
         0x00, 0x03, 0x61, 0x62, 0x63,
         -- topic name = "a/b"
         0x00, 0x03, 0x61, 0x2f, 0x62,
         -- will message = [0x12, 0xab]
         0x00, 0x02, 0x12, 0xab,
         -- username = "ac"
         0x00, 0x02, 0x61, 0x63,
         -- password = [0xcd, 0xbb, 0x11]
         0x00, 0x03, 0xcd, 0xbb, 0x11] `shouldParseAs`
          CONNECT ConnectPacket{ connectClientIdentifier = ClientIdentifier (T.pack "abc")
                               , connectProtocolLevel = 0xf1
                               , connectWillMsg = Just $
                                   Message QoS1 False (Topic $ T.pack "a/b") (BS.pack [0x12, 0xab])
                               , connectUserName = Just (UserName $ T.pack "ac")
                               , connectPassword = Just (Password $ BS.pack [0xcd, 0xbb, 0x11])
                               , connectCleanSession = True
                               , connectKeepAlive = 0x000c
                               }

      it "fails on non-zero reserved field" $ do
        forM_ [0x1 .. 0xf] $ \flags ->
          shouldFailParsing [0x10 .|. flags]

      it "fails on remaining length less than 10" $ do
        -- 10-bytes variable header
        forM_ [0x00 .. 0x09] $ \len ->
          shouldFailParsing [0x10, len]

      it "fails if protocol name doesn't match" $ do
        -- valid sequence is [0x01, 0x0a, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54]
        shouldFailParsing [0x10, 0x0a, 0x01]
        shouldFailParsing [0x10, 0x0a, 0x00, 0x03]
        shouldFailParsing [0x10, 0x0a, 0x00, 0x04, 0x01]
        shouldFailParsing [0x10, 0x0a, 0x00, 0x04, 0x4d, 0x53]
        shouldFailParsing [0x10, 0x0a, 0x00, 0x04, 0x4d, 0x51, 0x53]
        shouldFailParsing [0x10, 0x0a, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x52]

      it "MQTT-3.1.2-3: The Server MUST validate that the reserved flag in the CONNECT Control Packet is set to zero and disconnect the Client if it is not zero" $ do
        forM_ [0x01, 0x3 .. 0xff] $ \flags ->
          shouldFailParsing [0x10, 0x0a, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, flags]

      it "MQTT-3.1.2-11: If the Will Flag is set to 0 the Will QoS and Will Retain fields in the Connect Flags MUST be set to zero" $ do
        forM_ [0x01 .. 0x07] $ \bits ->
          shouldFailParsing [0x10, 0x0a, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, bits `shiftL` 3]

      it "MQTT-3.1.2-14: If the Will Flag is set to 1, the value of Will QoS can be 0 (0x00), 1 (0x01), or 2 (0x02). It MUST NOT be 3 (0x03)" $ do
        -- 0x1c == 0b00011100
        shouldFailParsing [0x10, 0x0a, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x1c]

      it "MQTT-3.1.2-22: If the User Name Flag is set to 0, the Password Flag MUST be set to 0" $  do
        shouldFailParsing [0x10, 0x0a, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x40]

      it "MQTT-3.1.3-5: The Server MUST allow ClientIds which are between 1 and 23 UTF-8 encoded bytes in length, and that contain only the characters \"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\"" $ do
        -- The Server MAY allow ClientId’s that contain more than 23
        -- encoded bytes. The Server MAY allow ClientId’s that contain
        -- characters not included in the list given above.
        pending

      it "MQTT-3.1.3-6: A Server MAY allow a Client to supply a ClientId that has a length of zero bytes, however if it does so the Server MUST treat this as a special case and assign a unique ClientId to that Client" $ do
        [0x10,
         -- remaining length = 30 bytes
         30,
         -- protocol name = MQTT
         0x00, 0x04, 0x4d, 0x51, 0x54, 0x54,
         -- protocol level = 0xf1
         0x04,
         -- username = 1
         -- password = 1
         -- retain   = 0
         -- willqos  = 01
         -- will     = 1
         -- clean    = 1
         -- reserved = 0
         0xce,
         -- keep alie = 0x000c
         0x00, 0x0c,
         -- client id = ""
         0x00, 0x00,
         -- topic name = "a/b"
         0x00, 0x03, 0x61, 0x2f, 0x62,
         -- will message = [0x12, 0xab]
         0x00, 0x02, 0x12, 0xab,
         -- username = "ac"
         0x00, 0x02, 0x61, 0x63,
         -- password = [0xcd, 0xbb, 0x11]
         0x00, 0x03, 0xcd, 0xbb, 0x11] `shouldParseAs`
          CONNECT ConnectPacket{ connectClientIdentifier = ClientIdentifier T.empty
                               , connectProtocolLevel = 0x04
                               , connectWillMsg = Just $
                                   Message QoS1 False (Topic $ T.pack "a/b") (BS.pack [0x12, 0xab])
                               , connectUserName = Just (UserName $ T.pack "ac")
                               , connectPassword = Just (Password $ BS.pack [0xcd, 0xbb, 0x11])
                               , connectCleanSession = True
                               , connectKeepAlive = 0x000c
                               }

      it "MQTT-3.1.3-8: If the Client supplies a zero-byte ClientId with CleanSession set to 0, the Server MUST respond to the CONNECT Packet with a CONNACK return code 0x02 (Identifier rejected) and then close the Network Connection" $ do
        -- that means, packet should parse successfuly
        [0x10,
         -- remaining length = 30 bytes
         30,
         -- protocol name = MQTT
         0x00, 0x04, 0x4d, 0x51, 0x54, 0x54,
         -- protocol level = 0xf1
         0x04,
         -- username = 1
         -- password = 1
         -- retain   = 0
         -- willqos  = 01
         -- will     = 1
         -- clean    = 0
         -- reserved = 0
         0xcc,
         -- keep alie = 0x000c
         0x00, 0x0c,
         -- client id = ""
         0x00, 0x00,
         -- topic name = "a/b"
         0x00, 0x03, 0x61, 0x2f, 0x62,
         -- will message = [0x12, 0xab]
         0x00, 0x02, 0x12, 0xab,
         -- username = "ac"
         0x00, 0x02, 0x61, 0x63,
         -- password = [0xcd, 0xbb, 0x11]
         0x00, 0x03, 0xcd, 0xbb, 0x11] `shouldParseAs`
          CONNECT ConnectPacket{ connectClientIdentifier = ClientIdentifier T.empty
                               , connectProtocolLevel = 0x04
                               , connectWillMsg = Just $
                                   Message QoS1 False (Topic $ T.pack "a/b") (BS.pack [0x12, 0xab])
                               , connectUserName = Just (UserName $ T.pack "ac")
                               , connectPassword = Just (Password $ BS.pack [0xcd, 0xbb, 0x11])
                               , connectCleanSession = False
                               , connectKeepAlive = 0x000c
                               }

      it "MQTT-3.1.3-10: The Will Topic MUST be a UTF-8 encoded string as defined in Section 1.5.3" $ do
        pending

      it "MQTT-3.1.3-11: The User Name MUST be a UTF-8 encoded string as defined in Section 1.5.3" $ do
        pending

    describe "CONNACK" $ do
      it "parses valid packet" $ do
        [0x20, 0x02, 0x01, 0x00] `shouldParseAs` CONNACK (ConnackPacket True Accepted)
        [0x20, 0x02, 0x00, 0x01] `shouldParseAs` CONNACK (ConnackPacket False UnacceptableProtocol)

      it "fails on non-zero flags" $ do
        forM_ [1 .. 15] $ \flags ->
          shouldFailParsing [0x20 .|. flags]

      it "fails on non-two length" $ do
        shouldFailParsing [0x20, 0x00]
        shouldFailParsing [0x20, 0x01]
        shouldFailParsing [0x20, 0x03]

      it "fails on non-zero reserved bits in connect acknowledge flags" $ do
        forM_ [0x02 .. 0xff] $ \flags ->
          shouldFailParsing [0x20, 0x02, flags]

      it "fails on unknown connect return code" $ do
        forM_ [0x06 .. 0xff] $ \flags ->
          shouldFailParsing [0x20, 0x02, 0x00, flags]

      it "MQTT-3.2.2-4: If a server sends a CONNACK packet containing a non-zero return code it MUST set Session Present to 0" $ do
        forM_ [0x01 .. 0x05] $ \returnCode ->
          shouldFailParsing [0x20, 0x02, 0x01, returnCode]

    describe "PUBLISH" $ do
      it "parses valid packet" $ do
        [0x3d, 0x09, 0x00, 0x03, 0x61, 0x2f, 0x62, 0x00, 0x0a, 0xab, 0x12] `shouldParseAs`
          PUBLISH PublishPacket{ publishDup = True
                               , publishMessage = Message QoS2 True (Topic $ T.pack "a/b") (BS.pack [0xab, 0x12])
                               , publishPacketIdentifier = Just (PacketIdentifier 10)
                               }

        [0x30, 0x07, 0x00, 0x03, 0x61, 0x2f, 0x62, 0xab, 0x12] `shouldParseAs`
          PUBLISH PublishPacket{ publishDup = False
                               , publishMessage = Message QoS0 False (Topic $ T.pack "a/b") (BS.pack [0xab, 0x12])
                               , publishPacketIdentifier = Nothing
                               }

      it "parses packet with no payload" $ do
        [0x30, 0x05, 0x00, 0x03, 0x61, 0x2f, 0x62] `shouldParseAs`
          PUBLISH PublishPacket{ publishDup = False
                               , publishMessage = Message QoS0 False (Topic $ T.pack "a/b") BS.empty
                               , publishPacketIdentifier = Nothing
                               }

      it "MQTT-3.3.1-2: The DUP flags MUST be set to 0 for all QoS 0 messages" $ do
        shouldFailParsing [0x38]

      it "MQTT-3.3.1-4: A PUBLISH Packet MUST NOT have both QoS bits set to 1" $ do
        shouldFailParsing [0x36]

      it "fails on Remaining Length < 2 if QoS level is 0" $ do
        -- The packet should at least contain 2-byte topic length
        shouldFailParsing [0x30, 0x00]
        shouldFailParsing [0x30, 0x01]

      it "fails on Remaining Length < 4 if QoS level is 1 or 2" $ do
        -- The packet should at least contain 2-byte packet identifier and 2-byte topic length
        shouldFailParsing [0x32, 0x00]
        shouldFailParsing [0x32, 0x01]
        shouldFailParsing [0x32, 0x03]
        shouldFailParsing [0x34, 0x00]
        shouldFailParsing [0x34, 0x01]
        shouldFailParsing [0x34, 0x03]

      it "MQTT-3.3.2-1: Topic Name MUST be a UTF-8 encoded string" $ do
        pending

      it "MQTT-3.3.2-2: The Topic Name in the PUBLISH Packet MUST NOT contain wildcard characters" $ do
        pending

      it "fails if remaining length is not enough to read topic name" $ do
        -- QoS 0, topic name is 3 bytes long. Remaining length should
        -- be at least 5 bytes.
        shouldFailParsing [0x30, 0x04, 0x00, 0x03]

      it "fails if remaining length is not enough to read packet identifier" $ do
        -- QoS 1, topic name is 3 bytes long. Remaining length should
        -- be at least 7 bytes.
        shouldFailParsing [0x32, 0x06, 0x00, 0x03]

    describe "PUBACK" $ do
      it "parses valid packet" $ do
        [0x40, 0x02, 0xab, 0x12] `shouldParseAs` PUBACK (PubackPacket $ PacketIdentifier 0xab12)

      it "fails on non-zero flags" $ do
        forM_ [0x01 .. 0x0f] $ \flags ->
          shouldFailParsing [0x40 .|. flags]

      it "fails on non-two length" $ do
        shouldFailParsing [0x40, 0x00]
        shouldFailParsing [0x40, 0x01]
        forM_ [0x03 .. 0xff] $ \len ->
          shouldFailParsing [0x40, len]

    describe "PUBREC" $ do
      it "parses valid packet" $ do
        [0x50, 0x02, 0xab, 0x12] `shouldParseAs` PUBREC (PubrecPacket $ PacketIdentifier 0xab12)

      it "fails on non-zero flags" $ do
        forM_ [0x01 .. 0x0f] $ \flags ->
          shouldFailParsing [0x50 .|. flags]

      it "fails on non-two length" $ do
        shouldFailParsing [0x50, 0x00]
        shouldFailParsing [0x50, 0x01]
        forM_ [0x03 .. 0xff] $ \len ->
          shouldFailParsing [0x50, len]

    describe "PUBREL" $ do
      it "parses valid packet" $ do
        [0x62, 0x02, 0xab, 0x12] `shouldParseAs` PUBREL (PubrelPacket $ PacketIdentifier 0xab12)

      it "fails on non-two flags" $ do
        forM_ [0x00 .. 0x01] $ \flags ->
          shouldFailParsing [0x60 .|. flags]
        forM_ [0x03 .. 0x0f] $ \flags ->
          shouldFailParsing [0x60 .|. flags]

      it "fails on non-two length" $ do
        shouldFailParsing [0x62, 0x00]
        shouldFailParsing [0x62, 0x01]
        forM_ [0x03 .. 0xff] $ \len ->
          shouldFailParsing [0x62, len]

    describe "PUBCOMP" $ do
      it "parses valid packet" $ do
        [0x70, 0x02, 0xab, 0x12] `shouldParseAs` PUBCOMP (PubcompPacket $ PacketIdentifier 0xab12)

      it "fails on non-zero flags" $ do
        forM_ [0x01 .. 0x0f] $ \flags ->
          shouldFailParsing [0x70 .|. flags]

      it "fails on non-two length" $ do
        shouldFailParsing [0x70, 0x00]
        shouldFailParsing [0x70, 0x01]
        forM_ [0x03 .. 0xff] $ \len ->
          shouldFailParsing [0x70, len]

    describe "SUBSCRIBE" $ do
      it "parses valid packet" $ do
        [0x82, 0x0e, 0x12, 0xab,
         0x00, 0x03, 0x61, 0x2f, 0x62, 0x01,
         0x00, 0x03, 0x63, 0x2f, 0x64, 0x02] `shouldParseAs`
          SUBSCRIBE (SubscribePacket
                     (PacketIdentifier 0x12ab)
                     [ (TopicFilter $ T.pack "a/b", QoS1)
                     , (TopicFilter $ T.pack "c/d", QoS2)
                     ])


      it "MQTT-3.8.1-1: Bits 3,2,1 and 0 of the fixed header of the SUBSCRIBE Control Packet are reserved and MUST be set to 0,0,1 and 0 respectively. The Server MUST treat any other value as malformed and close the Network Connection" $ do
        forM_ ([0x0 .. 0x1] ++ [0x3 .. 0xf]) $ \flags ->
          shouldFailParsing [0x80 .|. flags]

      it "fails when remaining length is less than 5" $ do
        -- 2 for packet identifier
        -- 2 for topic filter length
        -- 1 for desired QoS
        forM_ [0x00 .. 0x04] $ \len ->
          shouldFailParsing [0x82, len]

      it "MQTT-3.8.3-1: The Topic Filters in a SUBSCRIBE packet payload MUST be UTF-8 encoded strings as defined in Section 1.5.3" $ do
        pending

      it "MQTT-3.8.3-4: The Server MUST treat a SUBSCRIBE packet as malformed and close the Network Connection if any of Reserved bits in the payload are non-zero, or QoS is not 0,1 or 2" $ do
        forM_ [0x03 .. 0xff] $ \flags ->
          shouldFailParsing [0x82, 0x0e, 0x12, 0xab,
                             0x00, 0x03, 0x63, 0x2f, 0x64, flags]

    describe "SUBACK" $ do
      it "parses valid packet" $ do
        [0x90, 0x05, 0xab, 0x12, 0x00, 0x02, 0x80] `shouldParseAs`
          SUBACK SubackPacket{ subackPacketIdentifier = PacketIdentifier 0xab12
                             , subackResponses        = [Just QoS0, Just QoS2, Nothing]
                             }

      it "fails on non-zero reserved field" $ do
        forM_ [0x91 .. 0x9f] $ \byte1 ->
          shouldFailParsing [byte1]

      it "fails on remaining length less than 3" $ do
        -- 2 bytes for variable header and at least one 1-byte for return code
        forM_ [0x00 .. 0x02] $ \len ->
          shouldFailParsing [0x90, len]

      describe "return code" $ do
        it "QoS 0 is accepted" $ do
          [0x90, 0x03, 0xab, 0x12, 0x00] `shouldParseAs`
            SUBACK SubackPacket{ subackPacketIdentifier = PacketIdentifier 0xab12
                               , subackResponses        = [Just QoS0]
                               }

        it "QoS 1 is accepted" $ do
          [0x90, 0x03, 0xab, 0x12, 0x01] `shouldParseAs`
            SUBACK SubackPacket{ subackPacketIdentifier = PacketIdentifier 0xab12
                               , subackResponses        = [Just QoS1]
                               }

        it "QoS 2 is accepted" $ do
          [0x90, 0x03, 0xab, 0x12, 0x02] `shouldParseAs`
            SUBACK SubackPacket{ subackPacketIdentifier = PacketIdentifier 0xab12
                               , subackResponses        = [Just QoS2]
                               }

        it "Failure is accepted" $ do
          [0x90, 0x03, 0xab, 0x12, 0x80] `shouldParseAs`
            SUBACK SubackPacket{ subackPacketIdentifier = PacketIdentifier 0xab12
                               , subackResponses        = [Nothing]
                               }

        it "other return codes are rejected" $ do
          forM_ ([0x03 .. 0x7f] ++ [0x81 .. 0xff]) $ \returnCode ->
            shouldFailParsing [0x90, 0x03, 0xab, 0x12, returnCode]

    describe "UNSUBSCRIBE" $ do
      it "parses valid packet" $ do
        [0xa2, 0x0c, 0x12, 0xab,
         0x00, 0x03, 0x61, 0x2f, 0x62,
         0x00, 0x03, 0x63, 0x2f, 0x64] `shouldParseAs`
          UNSUBSCRIBE (UnsubscribePacket
                       (PacketIdentifier 0x12ab)
                       (fmap (TopicFilter . T.pack) ["a/b", "c/d"]))

      it "fails on non-two flags" $ do
        forM_ ([0x0 .. 0x1] ++ [0x3 .. 0xf]) $ \flags ->
          shouldFailParsing [0xa0 .|. flags]

      it "fails on length less than 4" $ do
        -- two bytes for variable header plus two bytes for at least
        -- one topic length
        forM_ [0x00 .. 0x03] $ \len ->
          shouldFailParsing [0xa2, len]

      it "fails on non-valid utf-8" $ do
        pending

    describe "UNSUBACK" $ do
      it "parses valid packet" $ do
        [0xb0, 0x02, 0xab, 0x12] `shouldParseAs` UNSUBACK (UnsubackPacket $ PacketIdentifier 0xab12)

      it "fails on non-zero flags" $ do
        forM_ [1 .. 15] $ \flags ->
          shouldFailParsing [0xb0 .|. flags]

      it "fails on non-two length" $ do
        shouldFailParsing [0xb0, 0x00]
        shouldFailParsing [0xb0, 0x01]
        shouldFailParsing [0xb0, 0x03]

    describe "PINGREQ" $ do
      it "parses valid packet" $ do
        [0xc0, 0x00] `shouldParseAs` PINGREQ PingreqPacket

      it "fails on non-zero flags" $ do
        forM_ [1 .. 15] $ \flags ->
          shouldFailParsing [0xc0 .|. flags]

      it "fails on non-zero length" $ do
        shouldFailParsing [0xc0, 0x01]

    describe "PINGRESP" $ do
      it "parses valid packet" $ do
        [0xd0, 0x00] `shouldParseAs` PINGRESP PingrespPacket

      it "fails on non-zero flags" $ do
        forM_ [1 .. 15] $ \flags ->
          shouldFailParsing [0xd0 .|. flags]

      it "fails on non-zero length" $ do
        shouldFailParsing [0xd0, 0x01]

    describe "DISCONNECT" $ do
      it "parses valid packet" $ do
        [0xe0, 0x00] `shouldParseAs` DISCONNECT DisconnectPacket

      it "fails on non-zero flags" $ do
        forM_ [1 .. 15] $ \flags ->
          shouldFailParsing [0xe0 .|. flags]

      it "fails on non-zero length" $ do
        shouldFailParsing [0xe0, 0x01]

  describe "remainingLength" $ do
    it "parses zero length" $ do
      parse remainingLength (BS.pack [0x00]) `shouldParseFully` 0

    it "parses non-zero length" $ do
      parse remainingLength (BS.pack [0x1f]) `shouldParseFully` 31

    it "parses multi-byte length" $ do
      parse remainingLength (BS.pack [0x80, 0x01]) `shouldParseFully` 128

    it "parses maximum length" $ do
      parse remainingLength (BS.pack [0xff, 0xff, 0xff, 0x7f]) `shouldParseFully` 268435455

    it "fails fast on too long field" $ do
      parse remainingLength (BS.pack [0xff, 0xff, 0xff, 0xff]) `shouldSatisfy` isParseFail
