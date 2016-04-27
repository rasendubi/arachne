{-# LANGUAGE DeriveGeneric #-}
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

import Data.Word (Word16, Word8)
import Data.Text (Text)
import Data.ByteString (ByteString)
import GHC.Generics (Generic)

data QoS
  = QoS0
  | QoS1
  | QoS2
  deriving (Eq, Show, Generic)

instance Enum QoS where
  toEnum 0 = QoS0
  toEnum 1 = QoS1
  toEnum 2 = QoS2
  toEnum _ = error "toEnum: wrong QoS level"

  fromEnum QoS0 = 0
  fromEnum QoS1 = 1
  fromEnum QoS2 = 2

newtype ClientIdentifier = ClientIdentifier { unClientIdentifier :: Text }
  deriving (Eq, Show, Generic)

newtype PacketIdentifier = PacketIdentifier { unPacketIdentifier :: Word16 }
  deriving (Eq, Show, Generic)

newtype UserName = UserName { unUserName :: Text }
  deriving (Eq, Show, Generic)

newtype Password = Password { unPassword :: ByteString }
  deriving (Eq, Show, Generic)

newtype Topic = Topic { unTopic :: Text }
  deriving (Eq, Show, Generic)

newtype TopicFilter = TopicFilter { unTopicFilter :: Text }
  deriving (Eq, Show, Generic)

data Message
  = Message
    { messageQoS     :: !QoS
    , messageRetain  :: !Bool
    , messageTopic   :: !Topic
    , messageMessage :: !ByteString
    } deriving (Eq, Show, Generic)

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
    } deriving (Eq, Show, Generic)

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
    { subscribePacketIdentifier :: !PacketIdentifier,
      subscribeTopicFiltersQoS  :: [(TopicFilter, QoS)]
    } deriving (Eq, Show, Generic)

data SubackPacket
  = SubackPacket
    { subackPacketIdentifier :: !PacketIdentifier,
      subackResponses        :: [Maybe QoS]
    } deriving (Eq, Show, Generic)

data UnsubscribePacket
  = UnsubscribePacket
    { unsubscribePacketIdentifier :: !PacketIdentifier,
      unsubscribeTopicFilters     :: [TopicFilter]
    } deriving (Eq, Show, Generic)

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
