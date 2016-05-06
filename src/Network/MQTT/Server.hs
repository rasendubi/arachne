module Network.MQTT.Server
    ( runServer
    , plainHandler
    , testRun
    ) where

import           Network.Socket
import           Control.Concurrent         ( MVar, forkIO, newMVar, withMVar )
import           Network.Attoparsec         ( parseMany )
import           Control.Monad              ( forever )
import           Network.MQTT.Parser        ( parsePacket )
import           Network.MQTT.Packet        ( Packet )
import           Data.Attoparsec.ByteString ( parse )
import qualified Control.Exception          as Exc

type HandlerFunc = SockAddr -> Packet -> IO ()

-- | Run MQTT broker
runServer :: String -> HandlerFunc -> IO ()
runServer port handlerfunc =
    withSocketsDo $ do
        addrinfos <- getAddrInfo (Just (defaultHints { addrFlags = [ AI_PASSIVE ] }))
                                 Nothing
                                 (Just port)
        let serveraddr = head addrinfos
        sock <- socket (addrFamily serveraddr) Stream defaultProtocol
        bind sock (addrAddress serveraddr)
        listen sock 5
        procRequests sock
  where
    procRequests :: Socket -> IO ()
    procRequests mastersock =
        forever $ do
            (connsock, clientaddr) <- accept mastersock
            forkIO $ procMessages connsock clientaddr

    procMessages :: Socket -> SockAddr -> IO ()
    procMessages connsock clientaddr =
        flip Exc.finally (close connsock) $ do
            (_, res) <- parseMany connsock (parse parsePacket) (parse parsePacket)
            mapM_ (handlerfunc clientaddr) res

plainHandler :: MVar () -> HandlerFunc
plainHandler lock addr packet =
    withMVar lock
             (\a -> putStrLn ("From " ++ show addr ++ ": " ++ show packet) >> return a)

testRun :: IO ()
testRun = do
    lock <- newMVar ()
    runServer "10514" (plainHandler lock)
