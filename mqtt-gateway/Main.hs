module Main (main) where

import           Data.Maybe (fromMaybe)
import           Network (withSocketsDo)
import qualified Network.MQTT.Gateway as Gateway
import           Network.Socket (getAddrInfo)
import           Network.URI (parseURI, uriAuthority, uriPort, uriRegName)
import           System.Environment (getArgs)
import           System.Log.Logger (Priority (DEBUG), rootLoggerName, setLevel, updateGlobalLogger)

main :: IO ()
main = do
  updateGlobalLogger rootLoggerName (setLevel DEBUG)

  uri:_ <- getArgs
  let (regName, port) = fromMaybe (error "Must supply a valid MQTT broker URI") $ do
      authority <- uriAuthority <$> parseURI uri
      return (uriRegName <$> authority, uriPort <$> authority)

  brokerAddr:_ <- getAddrInfo Nothing regName port
  withSocketsDo $ do
    gw <- Gateway.newGatewayOnSocket brokerAddr
    Gateway.listenOnAddr gw Gateway.defaultMQTTAddr
