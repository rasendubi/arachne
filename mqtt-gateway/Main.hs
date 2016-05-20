module Main (main) where

import           Network (withSocketsDo)
import qualified Network.MQTT.Gateway as Gateway (runOnAddr, defaultMQTTAddr)
import           System.Log.Logger (Priority(DEBUG), rootLoggerName, setLevel, updateGlobalLogger)

main :: IO ()
main = do
  updateGlobalLogger rootLoggerName (setLevel DEBUG)
  withSocketsDo $ Gateway.runOnAddr Gateway.defaultMQTTAddr
