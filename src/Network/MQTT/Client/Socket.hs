module Network.MQTT.Client.Socket
  ( runClientWithSockets
  , closeConnection
  )
where

import           Network.MQTT.Client.Core
import           Network.MQTT.Utils
import           System.Log.Logger        ( debugM )

import           Network.MQTT.Packet
import           Network.Socket           ( AddrInfo, Socket
                                          , SocketOption(KeepAlive)
                                          , SocketType(Stream), addrAddress
                                          , addrFamily, close, connect
                                          , defaultProtocol, setSocketOption
                                          , socket )

-- TODO(rasen): socket leak
runClientWithSockets :: ClientConfig -> AddrInfo -> IO (Socket, Client)
runClientWithSockets config serveraddr = do
  sock <- socket (addrFamily serveraddr) Stream defaultProtocol
  setSocketOption sock KeepAlive 1
  connect sock (addrAddress serveraddr)

  debugM "MQTT.Client" $ "Socket opened: " ++ show serveraddr

  (is, os) <- socketToMqttStreams sock
  client <- runClient config is os
  return (sock, client)

closeConnection :: Socket -> Client -> IO ()
closeConnection sock client = do
  debugM "MQTT.Client.Socket" "closeConnection"
  stopClient client
  close sock
