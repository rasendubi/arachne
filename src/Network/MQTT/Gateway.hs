module Network.MQTT.Gateway
  ( runServer
  , defaultMQTTAddr
  ) where

import           Control.Concurrent (forkIO, forkIOWithUnmask)
import           Control.Concurrent.STM (STM, TQueue, TVar, atomically, newTQueue, newTVar, readTQueue, writeTQueue)
import           Control.Exception (allowInterrupt, bracket, finally, mask_)

import           Control.Monad (forM_, forever, void)

import qualified Data.Attoparsec.ByteString.Lazy as A

import qualified Data.ByteString.Builder as BL.Builder
import qualified Data.ByteString.Lazy as BL

import qualified Network.MQTT.Encoder as MQTT
import qualified Network.MQTT.Packet as MQTT
import           Network.MQTT.Parser (parsePacket)

import           Network.Socket (AddrInfo(AddrInfo), Family(AF_INET), SockAddr(SockAddrInet), SocketOption(ReusePort), SocketType(Stream), accept, addrAddress, addrCanonName, addrFamily, addrFlags, addrProtocol, addrSocketType, bind, close, defaultProtocol, listen, socket, setSocketOption, socketToHandle)

import           System.IO (Handle, IOMode(ReadWriteMode), hClose)

data GatewayClient =
  GatewayClient
  { gcSendQueue :: TQueue MQTT.Packet
  , gcConnected :: TVar Bool
  }

newGatewayClient :: STM GatewayClient
newGatewayClient = GatewayClient <$> newTQueue <*> newTVar False

runServer :: AddrInfo -> IO ()
runServer addr = do
  bracket (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)) close $ \sock -> do
    setSocketOption sock ReusePort 1
    bind sock (addrAddress addr)
    listen sock 5

    -- We want to handle all incoming socket in exception-safe way, so
    -- no sockets leak.
    --
    -- Disable interrupts first to ensure no async exception is throw
    -- between accept and setting finalizer.
    mask_ $ forever $ do
      -- Allow an interrupt between connections, so the thread is
      -- still interruptible.
      allowInterrupt

      (s, a) <- accept sock
      handler <- socketToHandle s ReadWriteMode

      -- New thread is run in masked state.
      forkIOWithUnmask $ \unmask ->
        unmask (handleClient handler a) `finally` hClose handler

defaultMQTTAddr :: AddrInfo
defaultMQTTAddr = AddrInfo{ addrFlags = []
                          , addrFamily = AF_INET
                          , addrSocketType = Stream
                          , addrProtocol = defaultProtocol
                          , addrAddress = SockAddrInet (fromInteger 1883) 0
                          , addrCanonName = Nothing
                          }

-- Don't need to close socket, as it's done in 'runServer' in a safer way..
handleClient :: Handle -> SockAddr -> IO ()
handleClient handler addr = do
  putStrLn $ "Connected: " ++ show addr

  state <- atomically newGatewayClient
  void $ forkIO $ clientSender handler (gcSendQueue state)

  pkgs <- parseStream <$> BL.hGetContents handler

  forM_ pkgs $ \p -> do
    putStrLn $ "Received: " ++ show p
    atomically $ do
      writeTQueue (gcSendQueue state) (MQTT.CONNACK (MQTT.ConnackPacket False MQTT.Accepted))

-- | Parses a lazy ByteString to the list of MQTT Packets.
--
-- It should be removed and replaced by strict parsing, as lazy
-- parsing is not idiomatic Attoparsec.
parseStream :: BL.ByteString -> [MQTT.Packet]
parseStream s
  | BL.null s = []
  | otherwise =
      case A.parse parsePacket s of
        A.Fail _ _ _ -> error "Parsing failed"
        A.Done c p   -> p : parseStream c

clientSender :: Handle -> TQueue MQTT.Packet -> IO ()
clientSender h queue = forever $ do
  p <- atomically $ readTQueue queue
  putStrLn $ "Sending: " ++ show p
  BL.Builder.hPutBuilder h (MQTT.encodePacket p)
