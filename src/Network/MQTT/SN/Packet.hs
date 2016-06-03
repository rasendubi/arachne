{-# LANGUAGE DeriveGeneric #-}
-- | This module declares all MQTT-SN packet types.
--
-- For more info on MQTT-SN, read
-- <http://mqtt.org/new/wp-content/uploads/2009/06/MQTT-SN_spec_v1.2.pdf the protocol specification>.
module Network.MQTT.SN.Packet
  ( Packet(..)

  , AdvertisePacket(..)
  , SearchgwPacket(..)
  , GwinfoPacket(..)
  , ConnectPacket(..)
  , ConnackPacket(..)
  , WilltopicreqPacket(..)
  , WilltopicPacket(..)
  , WillmsgreqPacket(..)
  , WillmsgPacket(..)
  , RegisterPacket(..)
  , RegackPacket(..)
  , PublishPacket(..)
  , PubackPacket(..)
  , PubrecPacket(..)
  , PubrelPacket(..)
  , PubcompPacket(..)
  , SubscribePacket(..)
  , SubackPacket(..)
  , UnsubscribePacket(..)
  , UnsubackPacket(..)
  , PingreqPacket(..)
  , PingrespPacket(..)
  , DisconnectPacket(..)
  , WilltopicupdPacket(..)
  , WillmsgupdPacket(..)
  , WilltopicrespPacket(..)
  , WillmsgrespPacket(..)
  , ForwardPacket(..)
  ) where

import Data.Word (Word16, Word8)
import Data.ByteString (ByteString)

import GHC.Generics (Generic)

-- | General MQTT-SN packet that encapsulates all other packets.
data Packet
  = ADVERTISE     !AdvertisePacket
  | SEARCHGW      !SearchgwPacket
  | GWINFO        !GwinfoPacket
  | CONNECT       !ConnectPacket
  | CONNACK       !ConnackPacket
  | WILLTOPICREQ  !WilltopicreqPacket
  | WILLTOPIC     !WilltopicPacket
  | WILLMSGREQ    !WillmsgreqPacket
  | WILLMSG       !WillmsgPacket
  | REGISTER      !RegisterPacket
  | REGACK        !RegackPacket
  | PUBLISH       !PublishPacket
  | PUBACK        !PubackPacket
  | PUBREC        !PubrecPacket
  | PUBREL        !PubrelPacket
  | PUBCOMP       !PubcompPacket
  | SUBSCRIBE     !SubscribePacket
  | SUBACK        !SubackPacket
  | UNSUBSCRIBE   !UnsubscribePacket
  | UNSUBACK      !UnsubackPacket
  | PINGREQ       !PingreqPacket
  | PINGRESP      !PingrespPacket
  | DISCONNECT    !DisconnectPacket
  | WILLTOPICUPD  !WilltopicupdPacket
  | WILLMSGUPD    !WillmsgupdPacket
  | WILLTOPICRESP !WilltopicrespPacket
  | WILLMSGRESP   !WillmsgrespPacket
  | FORWARD       !ForwardPacket
  deriving (Eq, Show, Generic)

-- | The ADVERTISE message is broadcasted periodically by a gateway to
-- advertise its presence. The time interval until the next broadcast
-- time is indicated in the Duration field of this message.
data AdvertisePacket
  = AdvertisePacket
    {
      -- | The id of the gateway which sends this message.
      advertiseGwId :: !Word8

      -- | Time interval until the next ADVERTISE is broadcasted by
      -- this gateway.
    , advertiseDuration :: !Word16
    } deriving (Eq, Show, Generic)

-- | The SEARCHGW message is broadcasted by a client when it searches
-- for a GW. The broadcast radius of the SEARCHGW is limited and
-- depends on the density of the clients deployment, e.g. only 1-hop
-- broadcast in case of a very dense network in which every MQTT-SN
-- client is reachable from each other within 1-hop transmission.
--
-- The broadcast radius is also indicated to the underlying network
-- layer when MQTT-SN gives this message for transmission.
data SearchgwPacket
  = SearchgwPacket
    {
      -- | The broadcast radius of this message.
      searchgwRadius :: !Word8
    } deriving (Eq, Show, Generic)

-- | The GWINFO message is sent as response to a SEARCHGW message
-- using the broadcast service of the underlying layer, with the
-- radius as indicated in the SEARCHGW message. If sent by a GW, it
-- contains only the id of the sending GW; otherwise, if sent by a
-- client, it also includes the address of the GW.
--
-- Like the SEARCHGW message the broadcast radius for this message is
-- also indicated to the underlying network layer when MQTT-SN gives
-- this message for transmission.
data GwinfoPacket
  = GwinfoPacket
    { gwinfoGwId :: !Word8 -- ^ The id of a GW.

      -- | Address of the indicated GW; optional, only included if
      -- message is sent by a client
    , gwinfoGwAdd :: !(Maybe ByteString)
    } deriving (Eq, Show, Generic)

-- | The CONNECT message is sent by a client to setup a connection.
data ConnectPacket
  = ConnectPacket
    {
      -- | DUP, QoS, Retain, TopicIdType: not used.
      --
      -- Will: if set, indicates that client is requesting for Will
      -- topic and Will message prompting;
      --
      -- CleanSession: same meaning as with MQTT, however extended for
      -- Will topic and Will message.
      connectFlags :: !Word8

      -- | Corresponds to the \"Protocol Name\" and \"Protocol
      -- Version\" of the MQTT CONNECT message.
    , connectProtocolId :: !Word8

      -- | Same as with MQTT, contains the value of the Keep Alive
      -- timer.
    , connectDuration :: !Word16

      -- | Same as with MQTT, contains the client id which is a 1-23
      -- character long string which uniquely identifies the client to
      -- the server.
    , connectClientId :: !ByteString
    } deriving (Eq, Show, Generic)

-- | The CONNACK message is sent by the server in response to a
-- connection request from a client.
data ConnackPacket
  = ConnackPacket
    {
      -- | CONNACK return code.
      connackReturnCode :: !Word8
    } deriving (Eq, Show, Generic)

-- | The WILLTOPICREQ message is sent by the GW to request a client
-- for sending the Will topic name.
data WilltopicreqPacket
  = WilltopicreqPacket
  deriving (Eq, Show, Generic)

-- | The WILLTOPIC message is sent by a client as response to the
-- WILLTOPICREQ message for transferring its Will topic name to the
-- GW.
--
-- An empty WILLTOPIC message is a WILLTOPIC message without Flags and
-- WillTopic field (i.e. it is exactly 2 octets long). It is used by a
-- client to delete the Will topic and the Will message stored in the
-- server.
data WilltopicPacket
  = WilltopicPacket
    {
      -- | DUP: not used.
      --
      -- QoS: same as MQTT, contains the Will QoS.
      --
      -- Retain: same as MQTT, contains the Will Retain flag.
      --
      -- Will: not used.
      --
      -- CleanSession: not used.
      --
      -- TopicIdType: not used.
      willtopicFlags :: !Word8

      -- | Contains the Will topic name.
    , willtopicWillTopic :: !ByteString
    } deriving (Eq, Show, Generic)

-- | The WILLMSGREQ message is sent by the GW to request a client for
-- sending the Will message.
data WillmsgreqPacket
  = WillmsgreqPacket
  deriving (Eq, Show, Generic)

-- | The WILLMSG message is sent by a client as response to a
-- WILLMSGREQ for transferring its Will message to the GW.
data WillmsgPacket
  = WillmsgPacket
    {
      -- | Contains the Will message.
      willmsgWillMsg :: !ByteString
    } deriving (Eq, Show, Generic)

-- | The REGISTER message is sent by a client to a GW for requesting a
-- topic id value for the included topic name. It is also sent by a GW
-- to inform a client about the topic id value it has assigned to the
-- included topic name.
data RegisterPacket
  = RegisterPacket
    {
      -- | If sent by a client, it is coded 0x0000 and is not
      -- relevant; if sent by a GW, it contains the topic id value
      -- assigned to the topic name included in the TopicName field.
      registerTopicId :: !Word16

      -- | Should be coded such that it can be used to identify the
      -- corresponding REGACK message.
    , registerMsgId :: !Word16

      -- | Contains the topic name.
    , registerTopicName :: !ByteString
    } deriving (Eq, Show, Generic)

-- | The REGACK message is sent by a client or by a GW as an
-- acknowledgment to the receipt and processing of a REGISTER message.
data RegackPacket
  = RegackPacket
    {
      -- | The value that shall be used as a topic id in the PUBLISH
      -- messages.
      regackTopicId :: !Word16

      -- | Same value as the one contained in the corresponding
      -- REGISTER message.
    , regackMsgId :: !Word16

      -- | \"accepted\", or rejection reason.
    , regackReturnCode :: !Word8
    } deriving (Eq, Show, Generic)

-- | This message is used by both clients and gateways to publish data
-- for a certain topic.
data PublishPacket
  = PublishPacket
    {
      -- | DUP: same as MQTT, indicates whether message is sent for
      -- the first time or not.
      --
      -- QoS: same as MQTT, contains the QoS level for this PUBLISH
      -- message.
      --
      -- Will: not used.
      --
      -- CleanSession: not used.
      --
      -- TopicIdType: indicates the type of the topic id contained in
      -- the TopicId field.
      publishFlags :: !Word8

      -- | Contains the topic id value or the short topic name for
      -- which the data is published.
    , publishTopicId :: !Word16

      -- | Same as the MQTT \"Message ID\"; only relevant in case of
      -- QoS levels 1 and 2, otherwise coded as 0x0000.
    , publishMsgId :: !Word16

      -- | The published data.
    , publishData :: !ByteString
    } deriving (Eq, Show, Generic)

-- | The PUBACK message is sent by a gateway or a client as an
-- acknowledgment to the receipt and processing of a PUBLISH message
-- in case of QoS levels 1 or 2. It can also be sent as response to a
-- PUBLISH message in case of an error; the error reason is then
-- indicated in the ReturnCode field.
data PubackPacket
  = PubackPacket
    {
      -- | Same value the one contained in the corresponding PUBLISH
      -- message.
      pubackTopicId :: !Word16

      -- | Same value as the one contained in the corresponding
      -- PUBLISH message.
    , pubackMsgId :: !Word16

      -- | \"accepted\", or rejection reason.
    , pubackReturnCode :: !Word8
    } deriving (Eq, Show, Generic)

-- | As with MQTT, the PUBREC is used in conjunction with a PUBLISH
-- message with QoS level 2.
data PubrecPacket
  = PubrecPacket
    {
      -- | Same value as the one contained in the corresponding
      -- PUBLISH message.
      pubrecMsgId :: !Word16
    } deriving (Eq, Show, Generic)

-- | As with MQTT, the PUBREL is used in conjunction with a PUBLISH
-- message with QoS level 2.
data PubrelPacket
  = PubrelPacket
    {
      -- | Same value as the one contained in the corresponding
      -- PUBLISH message.
      pubrelMsgId :: !Word16
    } deriving (Eq, Show, Generic)

-- | As with MQTT, the PUBCOMP is used in conjunction with a PUBLISH
-- message with QoS level 2.
data PubcompPacket
  = PubcompPacket
    {
      -- | Same value as the one contained in the corresponding
      -- PUBLISH message.
      pubcompMsgId :: !Word16
    } deriving (Eq, Show, Generic)

-- | The SUBSCRIBE message is used by a client to subscribe to a
-- certain topic name.
data SubscribePacket
  = SubscribePacket
    {
      -- | DUP: same as MQTT, indicates whether message is sent for
      -- first time or not.
      --
      -- QoS: same as MQTT, contains the requested QoS level, for this
      -- topic.
      --
      -- Retain: not used.
      --
      -- Will: not used.
      --
      -- CleanSession: not used.
      --
      -- TopicIdType: indicates the type of information included at
      -- the end of the message, namely \"0b00\" topic name, \"0b01\"
      -- pre-defined topic id, \"0b10\" short topic name, and \"0b11\"
      -- reserved.
      subscribeFlags :: !Word8

      -- | Should be coded such that it can be used to identify the
      -- corresponding SUBACK message.
    , subscribeMsgId :: !Word16

      -- | Contains topic name, topic id, or short topic name as
      -- indicated in the TopicIdType field.
    , subscribeTopic :: !ByteString
    } deriving (Eq, Show, Generic)

-- | The SUBACK message is sent by a gateway to a client as an
-- acknowledgment to the receipt and processing of a SUBSCRIBE
-- message.
data SubackPacket
  = SubackPacket
    {
      -- | DUP: not used.
      --
      -- QoS: same as MQTT, contains the granted QoS level.
      --
      -- Retain: not used.
      --
      -- Will: not used.
      --
      -- CleanSession: not used.
      --
      -- TopicIdType: not used.
      subackFlags :: !Word8

      -- | In case of “accepted” the value that will be used as topic
      -- id by the gateway when sending PUBLISH messages to the client
      -- (not relevant in case of subscriptions to a short topic name
      -- or to a topic name which contains wildcard characters).
    , subackTopicId :: !Word16

      -- | Same value as the one contained in the corresponding
      -- SUBSCRIBE message.
    , subackMsgId :: !Word16

      -- | \"accepted\", or rejection reason.
    , subackReturnCode :: !Word8
    } deriving (Eq, Show, Generic)

-- | An UNSUBSCRIBE message is sent by the client to the GW to
-- unsubscribe from named topics.
data UnsubscribePacket
  = UnsubscribePacket
    {
      -- | DUP: not used.
      --
      -- QoS: not used.
      --
      -- Retain: not used.
      --
      -- Will: not used.
      --
      -- CleanSession: not used.
      --
      -- TopicIdType: indicates the type of information included at
      -- the end of the message, namely \"0b00\" topic name, \"0b01\"
      -- pre-defined topic id, \"0b10\" short topic name, and \"0b11\"
      -- reserved.
      unsubscribeFlags :: !Word8

      -- | Should be coded such that it can be used to identify the
      -- corresponding SUBACK message.
    , unsubscribeMsgId :: !Word16

      -- | Contains topic name, pre-defined topic id, or short topic
      -- name as indicated in the TopicIdType field.
    , unsubscribeTopic :: !ByteString
    } deriving (Eq, Show, Generic)

-- | An UNSUBACK message is sent by a GW to acknowledge the receipt
-- and processing of an UNSUBSCRIBE message.
data UnsubackPacket
  = UnsubackPacket
    {
      -- | Same value as the one contained in the corresponding
      -- UNSUBSCRIBE message.
      unsubackMsgId :: !Word16
    } deriving (Eq, Show, Generic)

-- | As with MQTT, the PINGREQ message is an \"are you alive\" message
-- that is sent from or received by a connected client.
data PingreqPacket
  = PingreqPacket
    {
      -- | Contains the client id; this field is optional and is
      -- included by a \"sleeping\" client when it goes to the
      -- \"awake\" state and is waiting for messages sent by the
      -- server/gateway.
      pingreqClientId :: !(Maybe ByteString)
    } deriving (Eq, Show, Generic)

-- | As with MQTT, a PINGRESP message is the response to a PINGREQ
-- message and means \"yes I am alive\". Keep Alive messages flow in
-- either direction, sent either by a connected client or the
-- gateway.
--
-- Moreover, a PINGRESP message is sent by a gateway to inform a
-- sleeping client that it has no more buffered messages for that
-- client.
data PingrespPacket
  = PingrespPacket
  deriving (Eq, Show, Generic)

-- | As with MQTT, the DISCONNECT message is sent by a client to
-- indicate that it wants to close the connection. The gateway will
-- acknowledge the receipt of that message by returning a DISCONNECT
-- to the client. A server or gateway may also sends a DISCONNECT to a
-- client, e.g. in case a gateway, due to an error, cannot map a
-- received message to a client. Upon receiving such a DISCONNECT
-- message, a client should try to setup the connection again by
-- sending a CONNECT message to the gateway or server. In all these
-- cases the DISCONNECT message does not contain the Duration field.
--
-- A DISCONNECT message with a Duration field is sent by a client when
-- it wants to go to the \"asleep\" state. The receipt of this message
-- is also acknowledged by the gateway by means of a DISCONNECT
-- message (without a duration field).
data DisconnectPacket
  = DisconnectPacket
    {
      -- | Contains the value of the sleep timer; this field is
      -- optional and is included by a \"sleeping\" client that wants
      -- to go the \"asleep\" state.
      disconnectDuration :: !(Maybe Word16)
    } deriving (Eq, Show, Generic)

-- | The WILLTOPICUPD message is sent by a client to update its Will
-- topic name stored in the GW/server.
--
-- An empty WILLTOPICUPD message is a WILLTOPICUPD message without
-- Flags and WillTopic field (i.e. it is exactly 2 octets long). It is
-- used by a client to delete its Will topic and Will message stored
-- in the GW/server.
data WilltopicupdPacket
  = WilltopicupdPacket
    {
      -- | DUP: not used.
      --
      -- QoS: same as MQTT, contains the Will QoS.
      --
      -- Retain: same as MQTT, contains the Will Retain flag.
      --
      -- Will: not used.
      --
      -- CleanSession: not used.
      --
      -- TopicIdType: not used.
      willtopicupdFlags :: !Word8

      -- | Contains the Will topic name.
    , willtopicupdWillTopic :: !ByteString
    } deriving (Eq, Show, Generic)

-- | The WILLMSGUPD message is sent by a client to update its Will
-- message stored in the GW/server.
data WillmsgupdPacket
  = WillmsgupdPacket
    {
      -- | Contains the Will message.
      willmsgupdWillMsg :: !ByteString
    } deriving (Eq, Show, Generic)

-- | The WILLTOPICRESP message is sent by a GW to acknowledge the
-- receipt and processing of an WILLTOPICUPD message.
data WilltopicrespPacket
  = WilltopicrespPacket
    {
      -- | \"accepted\", or rejection reason.
      willtopicrespReturnCode :: !Word8
    } deriving (Eq, Show, Generic)

-- | The WILLMSGRESP message is sent by a GW to acknowledge the
-- receipt and processing of an WILLMSGUPD message.
data WillmsgrespPacket
  = WillmsgrespPacket
    {
      -- | \"accepted\", or rejection reason.
      willmsgrespReturnCode :: !Word8
    } deriving (Eq, Show, Generic)

-- | MQTT-SN clients can also access a GW via a forwarder in case the
-- GW is not directly attached to their WSNs. The forwarder simply
-- encapsulates the MQTT-SN frames it receives on the wireless side
-- and forwards them __unchanged__ to the GW; in the opposite
-- direction, it decapsulates the frames it receives from the gateway
-- and sends them to the clients, __unchanged__ too.
data ForwardPacket
  = ForwardPacket
    {
      -- | The Ctrl octet contains control information exchanged
      -- between the GW and the forwarder.
      --
      -- Radius: broadcast radius (only relevant in direction GW to
      -- forwarder).
      --
      -- All remaining bits are reserved.
      forwardCtrl :: !Word8

      -- | Identifies the wireless node which has sent or should
      -- receive the encapsulated MQTT-SN message. The mapping between
      -- this Id and the address of the wireless node is implemented
      -- by the forwarder, if needed.
    , forwardWirelessNodeId :: !ByteString

      -- | The MQTT-SN message.
    , forwardMessage :: !ByteString
    } deriving (Eq, Show, Generic)
