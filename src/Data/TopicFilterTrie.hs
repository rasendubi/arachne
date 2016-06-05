-- | This module provides an implementation of a trie for topic
-- filters. Besides usual for trie operations it provides a function
-- for matching a single topic against a trie of filters returning all
-- results.
module Data.TopicFilterTrie
  ( TopicFilterTrie
  , empty
  , insert
  , member
  , lookup
  , lookupWithDefault
  , matches
  , delete
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

-- | That's main type of the topic filter trie.
--
-- You can create an instance of the type using 'empty' and adding
-- more values with 'insert'.
newtype TopicFilterTrie a = TopicFilterTrie (T.HashMapTrie Text a)
  deriving (Eq, Show)

-- | An empty trie.
empty :: TopicFilterTrie a
empty = TopicFilterTrie (T.HashMapTrie T.empty)

-- | Inserts a new filter to a trie.
insert :: TopicFilter -> a -> TopicFilterTrie a -> TopicFilterTrie a
insert t v (TopicFilterTrie x) = TopicFilterTrie (TC.insert (filterToPath t) v x)

-- | Check if topic filter is present in a trie.
member :: TopicFilter -> TopicFilterTrie a -> Bool
member t (TopicFilterTrie x) = TC.member (filterToPath t) x

-- | Lookup a topic filter in a trie. This function returns exact
-- match.
lookup :: TopicFilter -> TopicFilterTrie a -> Maybe a
lookup t (TopicFilterTrie x) = TC.lookup (filterToPath t) x

-- | Lookup a topic filter in a trie. This function returns exact
-- match.
--
-- Return first argument if no such topic filter exist.
lookupWithDefault :: a -> TopicFilter -> TopicFilterTrie a -> a
lookupWithDefault x tf (TopicFilterTrie t) = TC.lookupWithDefault x (filterToPath tf) t

-- | Matches a single topic against a trie of the filters. Returns a
-- list of all matches.
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

    matchOne
      :: Text
      -> HM.HashMap Text (T.HashMapChildren T.HashMapTrie Text a)
      -> [T.HashMapChildren T.HashMapTrie Text a]
    matchOne p x =
      maybeToList (HM.lookup p x) ++
      maybeToList (HM.lookup (Text.pack "+") x)

-- | Remove topic filter from a trie.
delete :: TopicFilter -> TopicFilterTrie a -> TopicFilterTrie a
delete t (TopicFilterTrie x) = TopicFilterTrie $ TC.delete (filterToPath t) x

filterToPath :: TopicFilter -> NE.NonEmpty Text
filterToPath = NE.fromList . Text.splitOn (Text.singleton '/') . unTopicFilter
