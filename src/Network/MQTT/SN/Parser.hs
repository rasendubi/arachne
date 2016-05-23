{-# LANGUAGE RecordWildCards #-}
module Network.MQTT.SN.Parser
  ( parsePacket
  ) where

import Prelude hiding (take)

import Network.MQTT.SN.Packet

import Control.Monad (guard)

import Data.Attoparsec.Binary (anyWord16be)
import Data.Attoparsec.ByteString ((<?>), Parser, anyWord8, take, takeByteString)

import Data.Word (Word16)

parsePacket :: Parser Packet
parsePacket = do
  len <- parseLength
  msgType <- anyWord8
  case msgType of
    0x00 -> ADVERTISE     <$> parseAdvertise     len
    0x01 -> SEARCHGW      <$> parseSearchgw      len
    0x02 -> GWINFO        <$> parseGwinfo        len
    0x04 -> CONNECT       <$> parseConnect       len
    0x05 -> CONNACK       <$> parseConnack       len
    0x06 -> WILLTOPICREQ  <$> parseWilltopicreq  len
    0x07 -> WILLTOPIC     <$> parseWilltopic     len
    0x08 -> WILLMSGREQ    <$> parseWillmsgreq    len
    0x09 -> WILLMSG       <$> parseWillmsg       len
    0x0a -> REGISTER      <$> parseRegister      len
    0x0b -> REGACK        <$> parseRegack        len
    0x0c -> PUBLISH       <$> parsePublish       len
    0x0d -> PUBACK        <$> parsePuback        len
    0x0e -> PUBCOMP       <$> parsePubcomp       len
    0x0f -> PUBREC        <$> parsePubrec        len
    0x10 -> PUBREL        <$> parsePubrel        len
    0x12 -> SUBSCRIBE     <$> parseSubscribe     len
    0x13 -> SUBACK        <$> parseSuback        len
    0x14 -> UNSUBSCRIBE   <$> parseUnsubscribe   len
    0x15 -> UNSUBACK      <$> parseUnsuback      len
    0x16 -> PINGREQ       <$> parsePingreq       len
    0x17 -> PINGRESP      <$> parsePingresp      len
    0x18 -> DISCONNECT    <$> parseDisconnect    len
    0x1a -> WILLTOPICUPD  <$> parseWilltopicupd  len
    0x1b -> WILLTOPICRESP <$> parseWilltopicresp len
    0x1c -> WILLMSGUPD    <$> parseWillmsgupd    len
    0x1d -> WILLMSGRESP   <$> parseWillmsgresp   len
    0xfe -> FORWARD       <$> parseForward       len
    _ -> fail "Unknown packet type"

-- | Returns remaining length of the message.
parseLength :: Parser Word16
parseLength = do
  octet1 <- fromIntegral <$> anyWord8
  res <- if octet1 == 0x01
    then subtract 3 <$> anyWord16be
    else return (octet1 - 1)
  guard (res >= 2) <?> "Packet length can't be zero or one"
  return res

parseAdvertise :: Word16 -> Parser AdvertisePacket
parseAdvertise len = do
  guard (len == 3)
  advertiseGwId <- anyWord8
  advertiseDuration <- anyWord16be
  return AdvertisePacket{..}

parseSearchgw :: Word16 -> Parser SearchgwPacket
parseSearchgw len = do
  guard (len == 1)
  SearchgwPacket <$> anyWord8

parseGwinfo :: Word16 -> Parser GwinfoPacket
parseGwinfo len = do
  guard (len == 1 || len == 3)
  gwinfoGwId <- anyWord8
  gwinfoGwAdd <- if len == 3
    then Just <$> take (fromIntegral len - 2)
    else return Nothing
  return GwinfoPacket{..}

parseConnect :: Word16 -> Parser ConnectPacket
parseConnect len = do
  guard (len >= 4)
  connectFlags <- anyWord8
  connectProtocolId <- anyWord8
  connectDuration <- anyWord16be
  connectClientId <- take (fromIntegral len - 4)
  return ConnectPacket{..}

parseConnack :: Word16 -> Parser ConnackPacket
parseConnack len = do
  guard (len == 1)
  ConnackPacket <$> anyWord8

parseWilltopicreq :: Word16 -> Parser WilltopicreqPacket
parseWilltopicreq len = do
  guard (len == 0)
  return WilltopicreqPacket

parseWilltopic :: Word16 -> Parser WilltopicPacket
parseWilltopic len = do
  guard (len >= 1)
  willtopicFlags <- anyWord8
  willtopicWillTopic <- take (fromIntegral len - 1)
  return WilltopicPacket{..}

parseWillmsgreq :: Word16 -> Parser WillmsgreqPacket
parseWillmsgreq len = do
  guard (len == 0)
  return WillmsgreqPacket

parseWillmsg :: Word16 -> Parser WillmsgPacket
parseWillmsg len = do
  WillmsgPacket <$> take (fromIntegral len)

parseRegister :: Word16 -> Parser RegisterPacket
parseRegister len = do
  guard (len >= 4)
  registerTopicId <- anyWord16be
  registerMsgId <- anyWord16be
  registerTopicName <- take (fromIntegral len - 4)
  return RegisterPacket{..}

parseRegack :: Word16 -> Parser RegackPacket
parseRegack len = do
  guard (len == 5)
  regackTopicId <- anyWord16be
  regackMsgId <- anyWord16be
  regackReturnCode <- anyWord8
  return RegackPacket{..}

parsePublish :: Word16 -> Parser PublishPacket
parsePublish len = do
  guard (len >= 5)
  publishFlags <- anyWord8
  publishTopicId <- anyWord16be
  publishMsgId <- anyWord16be
  publishData <- take (fromIntegral len - 5)
  return PublishPacket{..}

parsePuback :: Word16 -> Parser PubackPacket
parsePuback len = do
  guard (len == 5)
  pubackTopicId <- anyWord16be
  pubackMsgId <- anyWord16be
  pubackReturnCode <- anyWord8
  return PubackPacket{..}

parsePubcomp :: Word16 -> Parser PubcompPacket
parsePubcomp len = do
  guard (len == 2)
  PubcompPacket <$> anyWord16be

parsePubrec :: Word16 -> Parser PubrecPacket
parsePubrec len = do
  guard (len == 2)
  PubrecPacket <$> anyWord16be

parsePubrel :: Word16 -> Parser PubrelPacket
parsePubrel len = do
  guard (len == 2)
  PubrelPacket <$> anyWord16be

parseSubscribe :: Word16 -> Parser SubscribePacket
parseSubscribe len = do
  guard (len >= 3)
  subscribeFlags <- anyWord8
  subscribeMsgId <- anyWord16be
  subscribeTopic <- take (fromIntegral len - 3)
  return SubscribePacket{..}

parseSuback :: Word16 -> Parser SubackPacket
parseSuback len = do
  guard (len == 6)
  subackFlags <- anyWord8
  subackTopicId <- anyWord16be
  subackMsgId <- anyWord16be
  subackReturnCode <- anyWord8
  return SubackPacket{..}

parseUnsubscribe :: Word16 -> Parser UnsubscribePacket
parseUnsubscribe len = do
  guard (len >= 3)
  unsubscribeFlags <- anyWord8
  unsubscribeMsgId <- anyWord16be
  unsubscribeTopic <- take (fromIntegral len - 3)
  return UnsubscribePacket{..}

parseUnsuback :: Word16 -> Parser UnsubackPacket
parseUnsuback len = do
  guard (len == 2)
  UnsubackPacket <$> anyWord16be

parsePingreq :: Word16 -> Parser PingreqPacket
parsePingreq len = do
  PingreqPacket <$> if len == 0
    then return Nothing
    else Just <$> take (fromIntegral len)

parsePingresp :: Word16 -> Parser PingrespPacket
parsePingresp len = do
  guard (len == 0)
  return PingrespPacket

parseDisconnect :: Word16 -> Parser DisconnectPacket
parseDisconnect len = do
  guard (len == 0 || len == 2)
  DisconnectPacket <$> if len == 0
    then return Nothing
    else Just <$> anyWord16be

parseWilltopicupd :: Word16 -> Parser WilltopicupdPacket
parseWilltopicupd len = do
  guard (len >= 1)
  willtopicupdFlags <- anyWord8
  willtopicupdWillTopic <- take (fromIntegral len - 1)
  return WilltopicupdPacket{..}

parseWilltopicresp :: Word16 -> Parser WilltopicrespPacket
parseWilltopicresp len = do
  guard (len == 1)
  WilltopicrespPacket <$> anyWord8

parseWillmsgupd :: Word16 -> Parser WillmsgupdPacket
parseWillmsgupd len = do
  WillmsgupdPacket <$> take (fromIntegral len)

parseWillmsgresp :: Word16 -> Parser WillmsgrespPacket
parseWillmsgresp len = do
  guard (len == 1)
  WillmsgrespPacket <$> anyWord8

parseForward :: Word16 -> Parser ForwardPacket
parseForward len = do
  guard (len >= 1)
  forwardCtrl <- anyWord8
  forwardWirelessNodeId <- take (fromIntegral len - 1)
  forwardMessage <- takeByteString
  return ForwardPacket{..}
