module Network.MQTT.Gateway
  ( runServer
  , defaultMQTTAddr
  ) where

import Network.MQTT.Parser (parsePacket)

import Control.Concurrent (forkIO)
import Control.Exception (bracket, finally)
import Control.Monad (forever, forM_)
import Data.Attoparsec.ByteString (parse)
import Network.Attoparsec (parseMany)
import Network.Socket (AddrInfo(AddrInfo), AddrInfoFlag(AI_PASSIVE), Family(AF_INET), SockAddr(SockAddrInet), Socket, SocketType(Stream), accept, addrAddress, addrCanonName, addrFamily, addrFlags, addrProtocol, addrSocketType, bind, close, defaultProtocol, listen, socket, SocketOption(ReusePort), setSocketOption)

runServer :: AddrInfo -> IO ()
runServer addr = do
  bracket (socket (addrFamily addr) Stream defaultProtocol) close $ \sock -> do
    setSocketOption sock ReusePort 1
    bind sock (addrAddress addr)
    listen sock 5
    forever $ forkIO . handleClient =<< accept sock

defaultMQTTAddr :: AddrInfo
defaultMQTTAddr = AddrInfo{ addrFlags = [AI_PASSIVE]
                          , addrFamily = AF_INET
                          , addrSocketType = Stream
                          , addrProtocol = 6
                          , addrAddress = SockAddrInet (fromInteger 1883) 0
                          , addrCanonName = Nothing
                          }

handleClient :: (Socket, SockAddr) -> IO ()
handleClient (sock, addr) = do
  putStrLn $ "Connected: " ++ show addr
  flip finally (close sock) $ do
    (_, res) <- parseMany sock (parse parsePacket) (parse parsePacket)
    forM_ res print
  close sock
