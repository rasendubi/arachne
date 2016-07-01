module Network.MQTT.Client.Socket
  ( runClientWithSockets
  , closeConnection
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
                                          , addrFamily, close, connect
                                          , defaultProtocol, setSocketOption
                                          , socket )

-- TODO(rasen): socket leak
runClientWithSockets :: ClientConfig -> OutputStream ClientResult -> AddrInfo -> IO (Socket, OutputStream ClientCommand)
runClientWithSockets config cOs serveraddr = do
  sock <- socket (addrFamily serveraddr) Stream defaultProtocol
  setSocketOption sock KeepAlive 1
  connect sock (addrAddress serveraddr)

  debugM "MQTT.Client" $ "Socket opened: " ++ show serveraddr

  (is, os) <- socketToMqttStreams sock
  ccOs <- runClient config cOs is os
  return (sock, ccOs)

closeConnection :: Socket -> OutputStream ClientCommand -> IO ()
closeConnection sock ccOs = do
  debugM "MQTT.Client.Socket" "closeConnection"
  S.write (Just StopCommand) ccOs
  close sock
