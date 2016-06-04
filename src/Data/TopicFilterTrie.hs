module Data.TopicFilterTrie
  ( TopicFilterTrie
  , empty
  , insert
  , member
  , delete
  , lookup
  , matches
  ) where

import           Prelude hiding (lookup)

import qualified Data.HashMap.Lazy as HM

import qualified Data.List.NonEmpty as NE

import           Data.Maybe (maybeToList)

import           Data.Text (Text)
import qualified Data.Text as Text

import qualified Data.Trie.Class as TC
import qualified Data.Trie.HashMap as T

import           Network.MQTT.Packet (Topic(..), TopicFilter(..))

newtype TopicFilterTrie a = TopicFilterTrie (T.HashMapTrie Text a)
  deriving (Eq, Show)

empty :: TopicFilterTrie a
empty = TopicFilterTrie (T.HashMapTrie T.empty)

insert :: TopicFilter -> a -> TopicFilterTrie a -> TopicFilterTrie a
insert t v (TopicFilterTrie x) = TopicFilterTrie (TC.insert (filterToPath t) v x)

member :: TopicFilter -> TopicFilterTrie a -> Bool
member t (TopicFilterTrie x) = TC.member (filterToPath t) x

lookup :: TopicFilter -> TopicFilterTrie a -> Maybe a
lookup t (TopicFilterTrie x) = TC.lookup (filterToPath t) x

matches :: Topic -> TopicFilterTrie a -> [a]
matches t (TopicFilterTrie hmt) = matches' path hmt
  where
    path = Text.splitOn (Text.singleton '/') (unTopic t)

    matches' :: [Text] -> T.HashMapTrie Text a -> [a]
    matches' []     _ = [] -- this case is never called
    matches' (p:ps) (T.HashMapTrie (T.HashMapStep x)) = do
      let multilevel = maybeToList (HM.lookup (Text.pack "#") x >>= T.hashMapNode)
      let rest = do
            T.HashMapChildren mx mxs <- matchOne p x
            if null ps
              then maybeToList mx
              else case mxs of
                     Nothing -> []
                     Just xs -> matches' ps xs
      multilevel ++ rest

    matchOne :: Text -> HM.HashMap Text (T.HashMapChildren T.HashMapTrie Text a) -> [T.HashMapChildren T.HashMapTrie Text a]
    matchOne p x =
      maybeToList (HM.lookup p x) ++
      maybeToList (HM.lookup (Text.pack "+") x)

delete :: TopicFilter -> TopicFilterTrie a -> TopicFilterTrie a
delete t (TopicFilterTrie x) = TopicFilterTrie $ TC.delete (filterToPath t) x

filterToPath :: TopicFilter -> NE.NonEmpty Text
filterToPath = NE.fromList . Text.splitOn (Text.singleton '/') . unTopicFilter
