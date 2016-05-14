module Main (main) where

import Network (withSocketsDo)
import Network.MQTT.Gateway (runServer, defaultMQTTAddr)
import System.Log.Logger (Priority(DEBUG), rootLoggerName, setLevel, updateGlobalLogger)

main :: IO ()
main = do
  updateGlobalLogger rootLoggerName (setLevel DEBUG)
  withSocketsDo $ runServer defaultMQTTAddr True
