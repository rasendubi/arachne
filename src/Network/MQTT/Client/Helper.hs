{-# LANGUAGE RecordWildCards #-}
module Network.MQTT.Client.Helper
  ( fromCallbacks
  , Callbacks(..))
  where

import           Network.MQTT.Client.Core
import           Network.MQTT.Packet
import           System.IO.Streams ( OutputStream )
import qualified System.IO.Streams as S


data Callbacks
  = Callbacks
  { publishCallback     :: Message -> IO ()
  , subscribeCallback   :: [(TopicFilter, Maybe QoS)] -> IO ()
  , unsubscribeCallback :: [TopicFilter] -> IO ()
  }


fromCallbacks :: Callbacks -> IO (OutputStream ClientResult)
fromCallbacks Callbacks{..} = S.makeOutputStream handler
  where
    handler Nothing = return ()
    handler (Just (PublishResult message))           = publishCallback message
    handler (Just (SubscribeResult topicFiltersQoS)) = subscribeCallback topicFiltersQoS
    handler (Just (UnsubscribeResult topicFilters))  = unsubscribeCallback topicFilters
