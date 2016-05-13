module Main (main) where

import Network (withSocketsDo)
import Network.MQTT.Gateway (runServer, defaultMQTTAddr)

main :: IO ()
main = withSocketsDo $ runServer defaultMQTTAddr True
