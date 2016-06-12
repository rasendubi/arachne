module Main (main) where

import           Network (withSocketsDo)
import qualified Network.MQTT.Gateway as Gateway
import           System.Log.Logger (Priority(DEBUG), rootLoggerName, setLevel, updateGlobalLogger)

main :: IO ()
main = do
  updateGlobalLogger rootLoggerName (setLevel DEBUG)
  withSocketsDo $ do
    gw <- Gateway.newGateway
    Gateway.listenOnAddr gw Gateway.defaultMQTTAddr
