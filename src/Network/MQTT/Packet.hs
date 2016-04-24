module Network.MQTT.Packet
  ( Packet(..)
  , ConnectPacket(..)
  , ConnackPacket(..)
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

  , ConnackReturnCode(..)
  , Message(..)
  , QoS(..)
  , ClientIdentifier(..)
  , PacketIdentifier(..)
  , UserName(..)
  , Password(..)
  , Topic(..)
  , TopicFilter(..)
  ) where

import Data.Word (Word16)
import Data.Text (Text)
import Data.ByteString (ByteString)

data QoS
  = QoS0
  | QoS1
  | QoS2
  deriving (Eq, Show)

newtype ClientIdentifier = ClientIdentifier { unClientIdentifier :: Text }
  deriving (Eq, Show)

newtype PacketIdentifier = PacketIdentifier { unPacketIdentifier :: Word16 }
  deriving (Eq, Show)

newtype UserName = UserName { unUserName :: Text }
  deriving (Eq, Show)

newtype Password = Password { unPassword :: ByteString }
  deriving (Eq, Show)

newtype Topic = Topic { unTopic :: Text }
  deriving (Eq, Show)

newtype TopicFilter = TopicFilter { unTopicFilter :: Text }
  deriving (Eq, Show)

data Message
  = Message
    { messageQoS     :: !QoS
    , messageRetain  :: !Bool
    , messageTopic   :: !Topic
    , messageMessage :: !ByteString
    } deriving (Eq, Show)

data Packet
  = CONNECT ConnectPacket
  | CONNACK ConnackPacket
  | PUBLISH PublishPacket
  | PUBACK PubackPacket
  | PUBREC PubrecPacket
  | PUBREL PubrelPacket
  | PUBCOMP PubcompPacket
  | SUBSCRIBE SubscribePacket
  | SUBACK SubackPacket
  | UNSUBSCRIBE UnsubscribePacket
  | UNSUBACK UnsubackPacket
  | PINGREQ PingreqPacket
  | PINGRESP PingrespPacket
  | DISCONNECT DisconnectPacket
  deriving (Eq, Show)

data ConnectPacket
  = ConnectPacket
    { connectClientIdentifier :: !ClientIdentifier
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
    } deriving (Eq, Show)

data ConnackReturnCode
  = Accepted
  | UnacceptableProtocol
  | IdentifierRejected
  | ServerUnavailable
  | BadUserNameOrPassword
  | NotAuthorized
  deriving (Eq, Show)

data PublishPacket
  = PublishPacket
    { publishDup              :: !Bool
    , publishMessage          :: !Message
    , publishPacketIdentifier :: !(Maybe PacketIdentifier)
    } deriving (Eq, Show)

data PubackPacket
  = PubackPacket
    { pubackPacketIdentifier :: !PacketIdentifier
    } deriving (Eq, Show)

data PubrecPacket
  = PubrecPacket
    { pubrecPacketIdentifier :: !PacketIdentifier
    } deriving (Eq, Show)

data PubrelPacket
  = PubrelPacket
    { pubrelPacketIdentifier :: !PacketIdentifier
    } deriving (Eq, Show)

data PubcompPacket
  = PubcompPacket
    { pubcompPacketIdentifier :: !PacketIdentifier
    } deriving (Eq, Show)

data SubscribePacket
  = SubscribePacket
    { subscribePacketIdentifier :: !PacketIdentifier,
      subscribeTopicFiltersQoS :: [(TopicFilter, QoS)]
    } deriving (Eq, Show)

data SubackPacket
  = SubackPacket
    { subackPacketIdentifier :: !PacketIdentifier,
      subackResponses :: [Maybe QoS]
    } deriving (Eq, Show)

data UnsubscribePacket
  = UnsubscribePacket
    { unsubscribePacketIdentifier :: !PacketIdentifier,
      unsubscribeTopicFilters :: [TopicFilter]
    } deriving (Eq, Show)

data UnsubackPacket
  = UnsubackPacket
    { unsubackPacketIdentifier :: !PacketIdentifier
    } deriving (Eq, Show)

data PingreqPacket
  = PingreqPacket
  deriving (Eq, Show)

data PingrespPacket
  = PingrespPacket
  deriving (Eq, Show)

data DisconnectPacket
  = DisconnectPacket
  deriving (Eq, Show)
