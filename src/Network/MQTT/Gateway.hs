module Network.MQTT.Gateway
  ( runServer
  , defaultMQTTAddr
  ) where

import Network.MQTT.Parser (parsePacket)

import Control.Concurrent (forkIOWithUnmask)
import Control.Exception (allowInterrupt, bracket, finally, mask_)
import Control.Monad (forever)
import Data.Attoparsec.ByteString (parse)
import Network.Attoparsec (parseMany)
import Network.Socket (AddrInfo(AddrInfo), Family(AF_INET), SockAddr(SockAddrInet), Socket, SocketType(Stream), accept, addrAddress, addrCanonName, addrFamily, addrFlags, addrProtocol, addrSocketType, bind, close, defaultProtocol, listen, socket, SocketOption(ReusePort), setSocketOption, ShutdownCmd(ShutdownBoth), shutdown)

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
      -- New thread is run in masked state.
      forkIOWithUnmask $ \unmask ->
        unmask (handleClient s a) `finally` (shutdown s ShutdownBoth >> close s)

defaultMQTTAddr :: AddrInfo
defaultMQTTAddr = AddrInfo{ addrFlags = []
                          , addrFamily = AF_INET
                          , addrSocketType = Stream
                          , addrProtocol = defaultProtocol
                          , addrAddress = SockAddrInet (fromInteger 1883) 0
                          , addrCanonName = Nothing
                          }

-- Don't need to close socket, as it's done in 'runServer' in a safer way..
handleClient :: Socket -> SockAddr -> IO ()
handleClient sock addr = do
  putStrLn $ "Connected: " ++ show addr
  print . snd =<< parseMany sock (parse parsePacket) (parse parsePacket)
