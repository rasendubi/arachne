module Data.TopicFilterTrieSpec (spec) where

import           Data.List (foldl', sort)

import qualified Data.Text as T

import qualified Data.TopicFilterTrie as TT
import           Network.MQTT.Packet

import           Test.Hspec

spec :: Spec
spec = do
  describe "empty" $ do
    it "creates empty topic filter trie" $ do
      let tt = TT.empty :: TT.TopicFilterTrie Int
      TT.lookup (topicFilter "b") tt `shouldBe` Nothing

    it "empty tries are same" $ do
      let x = TT.empty :: TT.TopicFilterTrie Int
      let y = TT.empty :: TT.TopicFilterTrie Int
      x `shouldBe` y

  describe "member" $ do
    it "returns False on empty trie" $ do
      TT.member (topicFilter "a") TT.empty `shouldBe` False

    it "finds element" $ do
      let tt = trie [ "a" --> "text" ]
      TT.member (topicFilter "a") tt `shouldBe` True

  describe "insert" $ do
    it "inserts single element in empty trie" $ do
      let tt = TT.insert (topicFilter "a") "text" TT.empty
      TT.lookup (topicFilter "a") tt `shouldBe` Just "text"

    it "inserts with empty topic filter name" $ do
      let tt = TT.insert (topicFilter "") "hello" TT.empty
      TT.lookup (topicFilter "") tt `shouldBe` Just "hello"

    it "overrides old value" $ do
      let tt = TT.insert (topicFilter "a/b") "y" $ trie [ "a/b" --> "x" ]
      TT.lookup (topicFilter "a/b") tt `shouldBe` Just "y"

  describe "lookup" $ do
    it "doesn't find anything in empty trie" $ do
      TT.lookup (topicFilter "a") (TT.empty :: TT.TopicFilterTrie Int) `shouldBe` Nothing

  describe "delete" $ do
    it "deletes single element" $ do
      let tt = trie [ "a" --> "text" ]
      let tt' = TT.delete (topicFilter "a") tt
      TT.member (topicFilter "a") tt' `shouldBe` False

    it "deletes from empty trie" $ do
      let tt = TT.delete (topicFilter "a") TT.empty :: TT.TopicFilterTrie Int
      TT.member (topicFilter "a") tt `shouldBe` False

  describe "matches" $ do
    it "works on one-element filter" $ do
      let tt = trie [ "a" --> "text" ]
      TT.matches (topic "a") tt `shouldBe` ["text"]

    it "finds exact match" $ do
      let tt = trie [ "a/b/c" --> "text" ]
      TT.matches (topic "a/b/c") tt `shouldBe` ["text"]

    it "doesn't trigger on submatch" $ do
      let tt = trie [ "a/b/c" --> "text" ]
      TT.matches (topic "a/b") tt `shouldBe` []

    it "doesn't trigger on overmatch" $ do
      let tt = trie [ "a/b/c" --> "text" ]
      TT.matches (topic "a/b/c/d") tt `shouldBe` []

    it "single-level wildcard works in one-level topic" $ do
      let tt = trie [ "+" --> "text" ]
      TT.matches (topic "hello") tt `shouldBe` ["text"]

    it "single-level wildcard works at end" $ do
      let tt = trie [ "a/+" --> "text" ]
      TT.matches (topic "a/b") tt `shouldBe` ["text"]

    it "multiple matches" $ do
      let tt = trie [ "+" --> "wildcard"
                    , "hello" --> "exact match"
                    ]
      -- sorting to make results stable
      sort (TT.matches (topic "hello") tt)
        `shouldBe` sort ["exact match", "wildcard"]

    it "single-level wildcard works in the middle" $ do
      let tt = trie [ "a/+/b" --> "text" ]
      TT.matches (topic "a/hello/b") tt `shouldBe` ["text"]
      TT.matches (topic "a/hello/c") tt `shouldBe` []

    it "multi-level wildcard work in one-level topic" $ do
      let tt = trie [ "#" --> "text" ]
      TT.matches (topic "hello") tt `shouldBe` ["text"]

    it "multi-level wildcard matches at end" $ do
      let tt = trie [ "hello/#" --> "text" ]
      TT.matches (topic "hello/world") tt `shouldBe` ["text"]

    it "multi-level wildcard matches multiple levels" $ do
      let tt = trie [ "hello/#" --> "text" ]
      TT.matches (topic "hello/world/test") tt `shouldBe` ["text"]

trie :: [(String, a)] -> TT.TopicFilterTrie a
trie = foldl' (\xs (x,y) -> TT.insert (topicFilter x) y xs) TT.empty

(-->) :: a -> b -> (a, b)
(-->) = (,)

topicFilter :: String -> TopicFilter
topicFilter = TopicFilter . T.pack

topic :: String -> Topic
topic = Topic . T.pack
