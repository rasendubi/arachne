-- | This module is a companion to the "Network.MQTT.Gateway.Core" and
-- contains various functions for running MQTT Gateway over TCP
-- streams.
module Network.MQTT.Gateway.Socket
  ( defaultMQTTAddr
  , defaultClientConfig

  , listenOnAddr
  , newGatewayOnSocket

  -- * Low-level functions
  , listenOnSocket
  ) where

import           Control.Concurrent        (forkIOWithUnmask)
import           Control.Exception         (SomeException, allowInterrupt,
                                            bracket, mask_, mask, onException, try)
import           Control.Monad             (forever, when)
import qualified Data.Text                 as T
import           Network.MQTT.Gateway.Core
import           Network.MQTT.Packet
import           Network.MQTT.Utils
import           Network.Socket            (AddrInfo (AddrInfo),
                                            Family (AF_INET),
                                            SockAddr (SockAddrInet), Socket,
                                            SocketOption (ReusePort),
                                            SocketOption (KeepAlive),
                                            SocketType (Stream), accept,
                                            addrAddress, addrCanonName,
                                            addrFamily, addrFlags, addrProtocol,
                                            addrSocketType, bind, close,
                                            connect, defaultProtocol,
                                            isSupportedSocketOption, listen,
                                            setSocketOption, socket)

import           System.Log.Logger         (debugM)

-- | Default address for the MQTT server.
--
-- Listen on all IPv4 addresses, TCP port 1883.
defaultMQTTAddr :: AddrInfo
defaultMQTTAddr = AddrInfo{ addrFlags      = []
                          , addrFamily     = AF_INET
                          , addrSocketType = Stream
                          , addrProtocol   = 6 -- TCP
                          , addrAddress    = SockAddrInet 1883 0
                          , addrCanonName  = Nothing
                          }

-- | Default MQTT Client config.
defaultClientConfig :: ClientConfig
defaultClientConfig = ClientConfig
                      { ccClientIdentifier = ClientIdentifier $ T.pack "arachne-client"
                      , ccWillMsg          = Nothing
                      , ccUserCredentials  = Nothing
                      , ccCleanSession     = True
                      , ccKeepAlive        = 0
                      }

-- | Listen for clients on the given address and add connected clients
-- to the given gateway.
--
-- This function blocks until the socket is closed (or thread killed).
listenOnAddr :: Gateway -> AddrInfo -> IO ()
listenOnAddr gw addr = do
  bracket (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)) close $ \sock -> do
    when (isSupportedSocketOption ReusePort) $
      setSocketOption sock ReusePort 1
    bind sock (addrAddress addr)
    listen sock 5
    listenOnSocket gw sock

-- | Listen on the given socket for the clients and connect them to
-- the gateway.
--
-- You're encouraged to use 'listenOnAddr' as it's much easier.
--
-- The socket must be bound with 'bind' and configured for listening
-- with 'listen'.
--
-- This function blocks until the socket is closed (or thread killed).
listenOnSocket :: Gateway -> Socket -> IO ()
listenOnSocket gw sock = do
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
      streams <- socketToMqttStreams s

      debugM "MQTT.Gateway.Socket" $ "Connected client on " ++ show a

      -- New thread is run in masked state.
      forkIOWithUnmask $ \unmask -> do
        res <- unmask (try (handleAlienClient gw streams)) :: IO (Either SomeException ())
        close s
        debugM "MQTT.Gateway.Socket" $ "handleClient exited with " ++ show res

newGatewayOnSocket :: AddrInfo -> IO Gateway
newGatewayOnSocket brokerAddr = mask $ \unmask -> do
  sock <- socket (addrFamily brokerAddr) Stream defaultProtocol
  (unmask $ do
     setSocketOption sock KeepAlive 1
     connect sock (addrAddress brokerAddr)

     debugM "MQTT.Gateway" $ "Broker socket opened: " ++ show brokerAddr

     socketToMqttStreams sock >>= newGateway defaultClientConfig)
       `onException` close sock
