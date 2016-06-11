{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Network.MQTT.Packet
  (
  -- * User facing types
  -- ** Connection
    ClientIdentifier(..)
  , UserName(..)
  , Password(..)

  -- ** Messages
  , TopicName(..)
  , TopicFilter(..)
  , QoS(..)
  , Message(..)

  -- * Packets
  -- | These are internal packet structures for MQTT protocol. They
  -- are largely undocumented for the purpose: you should really read
  -- <http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html the specification>.
  , PacketIdentifier(..)
  , Packet(..)
  , ConnectPacket(..)
  , ConnackPacket(..)
  , ConnackReturnCode(..)
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
  ) where

import Data.ByteString (ByteString)
import Data.Hashable (Hashable)
import Data.Text (Text)
import Data.Word (Word16, Word8)
import GHC.Generics (Generic)

-- | A client identifier.
--
-- The client identifier is an arbitrary Unicode string. The MQTT
-- server associates client state with the client identifier and there
-- can be no clients with the client identifier connected to the same
-- server simultaneously.
--
-- A client may supply an empty client identifier. In that case, the
-- server won't store any state among the connections. (Note that
-- server may not support empty client identifiers.)
newtype ClientIdentifier = ClientIdentifier { unClientIdentifier :: Text }
  deriving (Eq, Show, Generic, Hashable)

-- | User name.
--
-- User name is used for MQTT authentication. It's not mandatory,
-- however, and the broker may use a different authentication method
-- (e.g., authorization with certificates over TLS).
newtype UserName = UserName { unUserName :: Text }
  deriving (Eq, Show, Generic)

-- | User password.
--
-- User password is an arbitrary binary data (i.e., it shouldn't be
-- Unicode string).
newtype Password = Password { unPassword :: ByteString }
  deriving (Eq, Show, Generic)

-- | MQTT Topic Name.
--
-- MQTT topic is a list of topic levels separated by the topic level
-- separator (\'/'). Topic name MUST NOT include wildcards.
newtype TopicName = TopicName { unTopicName :: Text }
  deriving (Eq, Show)

-- | MQTT Topic Filter.
--
-- MQTT topic filters are largely similar to topic names, but may
-- include wildcards.
--
-- There are two wildcards:
-- - multi-level wildcard
-- - single-level wildcard
--
-- Multi-level wildcard is the \'#' character. It matches any number
-- of levels within topic and must be the last character specified in
-- the topic filter.
--
-- Single-level wildcard is the \'+' character. It matches only one
-- topic level.
--
-- Both wildcards occupy entire level of the filter. (i.e.,
-- \"hello/wor+ld" is not a valid topic filter.)
newtype TopicFilter = TopicFilter { unTopicFilter :: Text }
  deriving (Eq, Show)

-- | Quality of Service level.
--
-- MQTT defines three QoS levels.
--
-- Note that that's sender who determines the QoS level of the
-- message. For example, if the client subscribes to a topic with QoS
-- 2 level, and another client publishes message with the QoS 1 level,
-- the message will be delivered as a QoS 1 level message (i.e., it
-- may arrive multiple times).
data QoS
  = QoS0 -- ^ QoS 0 - At most once delivery
  | QoS1 -- ^ QoS 1 - At least once delivery
  | QoS2 -- ^ QoS 2 - Exactly once delivery
  deriving (Eq, Show, Generic)

instance Enum QoS where
  toEnum 0 = QoS0
  toEnum 1 = QoS1
  toEnum 2 = QoS2
  toEnum _ = error "toEnum: wrong QoS level"

  fromEnum QoS0 = 0
  fromEnum QoS1 = 1
  fromEnum QoS2 = 2

-- | Application message.
--
-- That's actual application message a client wants to publish to the
-- specific topic.
data Message
  = Message{
    -- | A topic the message is published to.
      messageTopic   :: !TopicName

    -- | Application-level payload
    , messageMessage :: !ByteString

    -- | Message QoS.
    , messageQoS     :: !QoS

    -- | Should message be retained?
    --
    -- Retain message is attached to the topic. If the new client
    -- subscribes to the topic it will receive the retained message
    -- immediately.
    --
    -- Retain messages don't accumulate. There can be only one
    -- retained message per a topic.
    , messageRetain  :: !Bool
    } deriving (Eq, Show, Generic)

newtype PacketIdentifier = PacketIdentifier { unPacketIdentifier :: Word16 }
  deriving (Eq, Show, Generic)

data Packet
  = CONNECT     !ConnectPacket
  | CONNACK     !ConnackPacket
  | PUBLISH     !PublishPacket
  | PUBACK      !PubackPacket
  | PUBREC      !PubrecPacket
  | PUBREL      !PubrelPacket
  | PUBCOMP     !PubcompPacket
  | SUBSCRIBE   !SubscribePacket
  | SUBACK      !SubackPacket
  | UNSUBSCRIBE !UnsubscribePacket
  | UNSUBACK    !UnsubackPacket
  | PINGREQ     !PingreqPacket
  | PINGRESP    !PingrespPacket
  | DISCONNECT  !DisconnectPacket
  deriving (Eq, Show, Generic)

data ConnectPacket
  = ConnectPacket
    { connectClientIdentifier :: !ClientIdentifier
    , connectProtocolLevel    :: !Word8
    , connectWillMsg          :: !(Maybe Message)
    , connectUserName         :: !(Maybe UserName)
    , connectPassword         :: !(Maybe Password)
    , connectCleanSession     :: !Bool
    , connectKeepAlive        :: !Word16
    } deriving (Eq, Show)

data ConnackPacket
  = ConnackPacket
    { connackSessionPresent :: !Bool
    , connackReturnCode     :: !ConnackReturnCode
    } deriving (Eq, Show, Generic)

data ConnackReturnCode
  = Accepted
  | UnacceptableProtocol
  | IdentifierRejected
  | ServerUnavailable
  | BadUserNameOrPassword
  | NotAuthorized
  deriving (Eq, Show, Generic)

data PublishPacket
  = PublishPacket
    { publishDup              :: !Bool
    , publishMessage          :: !Message
    , publishPacketIdentifier :: !(Maybe PacketIdentifier)
    } deriving (Eq, Show, Generic)

data PubackPacket
  = PubackPacket
    { pubackPacketIdentifier :: !PacketIdentifier
    } deriving (Eq, Show, Generic)

data PubrecPacket
  = PubrecPacket
    { pubrecPacketIdentifier :: !PacketIdentifier
    } deriving (Eq, Show, Generic)

data PubrelPacket
  = PubrelPacket
    { pubrelPacketIdentifier :: !PacketIdentifier
    } deriving (Eq, Show, Generic)

data PubcompPacket
  = PubcompPacket
    { pubcompPacketIdentifier :: !PacketIdentifier
    } deriving (Eq, Show, Generic)

data SubscribePacket
  = SubscribePacket
    { subscribePacketIdentifier :: !PacketIdentifier
    , subscribeTopicFiltersQoS  :: [(TopicFilter, QoS)]
    } deriving (Eq, Show)

data SubackPacket
  = SubackPacket
    { subackPacketIdentifier :: !PacketIdentifier
    , subackResponses        :: [Maybe QoS]
    } deriving (Eq, Show)

data UnsubscribePacket
  = UnsubscribePacket
    { unsubscribePacketIdentifier :: !PacketIdentifier
    , unsubscribeTopicFilters     :: [TopicFilter]
    } deriving (Eq, Show)

data UnsubackPacket
  = UnsubackPacket
    { unsubackPacketIdentifier :: !PacketIdentifier
    } deriving (Eq, Show, Generic)

data PingreqPacket
  = PingreqPacket
  deriving (Eq, Show, Generic)

data PingrespPacket
  = PingrespPacket
  deriving (Eq, Show, Generic)

data DisconnectPacket
  = DisconnectPacket
  deriving (Eq, Show, Generic)
