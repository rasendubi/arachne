module Network.MQTT.Client.Socket
  ( runClientWithSockets
  , stopClient
  )
where

import           Network.MQTT.Client.Core
import           Network.MQTT.Utils
import           System.Log.Logger        ( debugM )

import qualified System.IO.Streams as S
import           System.IO.Streams        ( OutputStream )
import           Network.Socket           ( AddrInfo, Socket
                                          , SocketOption(KeepAlive)
                                          , SocketType(Stream), addrAddress
                                          , addrFamily, connect
                                          , defaultProtocol, setSocketOption
                                          , socket )

-- TODO(rasen): socket leak
runClientWithSockets :: ClientConfig -> OutputStream ClientResult -> AddrInfo -> IO (Socket, OutputStream ClientCommand)
runClientWithSockets config result_os serveraddr = do
  sock <- socket (addrFamily serveraddr) Stream defaultProtocol
  setSocketOption sock KeepAlive 1
  connect sock (addrAddress serveraddr)

  debugM "MQTT.Client" $ "Socket opened: " ++ show serveraddr

  (is, os) <- socketToMqttStreams sock
  command_os <- runClient config result_os is os
  return (sock, command_os)

stopClient :: OutputStream ClientCommand -> IO ()
stopClient command_os = do
  debugM "MQTT.Client.Socket" "stopClient"
  S.write (Just StopCommand) command_os
