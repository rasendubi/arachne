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
import           Control.Exception        ( bracket )

runClientWithSockets :: ConnectPacket -> AddrInfo -> IO (Socket, Client)
runClientWithSockets cp addrInfo = do
  sock <- connectClient addrInfo
  (is, os) <- socketToMqttStreams sock
  client <- runClient cp is os
  return (sock, client)

connectClient :: AddrInfo -> IO Socket
connectClient serveraddr =
  bracket (socket (addrFamily serveraddr) Stream defaultProtocol) close $ \sock -> do
    setSocketOption sock KeepAlive 1
    connect sock (addrAddress serveraddr)
    debugM "MQTT.Client" $ "Connected: " ++ show serveraddr
    return sock

closeConnection :: Socket -> Client -> IO ()
closeConnection sock client = do
  debugM "MQTT.Client.Socket" "closeConnection"
  stopClient client
  close sock
