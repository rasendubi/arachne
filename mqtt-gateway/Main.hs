module Main (main) where

import           Data.IP                      (IPv4, toHostAddress)
import           Network                      (withSocketsDo)
import           Network.MQTT.Client          as Client
import qualified Network.MQTT.Gateway         as Gateway
import           Network.Socket               (SockAddr (SockAddrInet),
                                               addrAddress)
import           System.Environment           (getArgs)
import qualified System.IO.Streams.Concurrent as S
import           System.Log.Logger            (Priority (DEBUG), rootLoggerName,
                                               setLevel, updateGlobalLogger)

main :: IO ()
main = do
  args <- getArgs
  case args of
    []   -> error "Must supply a MQTT broker IP address"

    [ip] -> do
      updateGlobalLogger rootLoggerName (setLevel DEBUG)
      withSocketsDo $ do

        (client_result, client_result')    <- S.makeChanPipe
        let brokerAddr = Gateway.defaultMQTTAddr { addrAddress = SockAddrInet 1883 (toHostAddress (read ip :: IPv4)) }
        (socket, client_command) <- Client.runClientWithSockets Client.defaultClientConfig client_result' brokerAddr

        gw <- Gateway.newGateway client_result client_command
        Gateway.listenOnAddr gw Gateway.defaultMQTTAddr

    _    -> error "Too many arguments"
