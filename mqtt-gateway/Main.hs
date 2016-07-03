module Main (main) where

import           Control.Concurrent (forkIO)

import qualified Data.Text as T

import           Network (withSocketsDo)
import qualified Network.MQTT.Client as Client
import qualified Network.MQTT.Gateway as Gateway
import qualified Network.MQTT.Packet as MQTT
import           Network.Socket (getAddrInfo, defaultHints)

import           System.Environment (getArgs)

import qualified System.IO.Streams as S
import qualified System.IO.Streams.Concurrent as S

import           System.Log.Logger (Priority(DEBUG), rootLoggerName, setLevel, updateGlobalLogger)

main :: IO ()
main = do
  [host, port] <- getArgs

  updateGlobalLogger rootLoggerName (setLevel DEBUG)
  withSocketsDo $ do
    addrInfo : _ <- getAddrInfo (Just defaultHints) (Just host) (Just port)

    (command_is, command_os) <- S.makeChanPipe
    (gw, result_os) <- Gateway.newGateway command_os

    t <- forkIO $ do
      (_sock, command_os') <- Client.runClientWithSockets clientConfig result_os addrInfo
      S.connect command_is command_os'

    Gateway.listenOnAddr gw Gateway.defaultMQTTAddr

clientConfig :: Client.ClientConfig
clientConfig = Client.ClientConfig
  { Client.ccClientIdentifier = MQTT.ClientIdentifier (T.pack "arachne-1234")
  , Client.ccWillMsg = Nothing
  , Client.ccUserCredentials = Nothing
  , Client.ccCleanSession = True
  , Client.ccKeepAlive = 0
  }
