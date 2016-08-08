module Main (main) where

import           Network                      (withSocketsDo)
import           Network.MQTT.Client          as Client
import qualified Network.MQTT.Gateway         as Gateway
import           Network.Socket               (getAddrInfo)
import           Network.URI                  (parseURI, uriAuthority,
                                               uriPort, uriRegName)
import           System.Environment           (getArgs)
import           System.IO.Streams            (InputStream, OutputStream)
import qualified System.IO.Streams.Concurrent as S
import           System.Log.Logger            (Priority (DEBUG), rootLoggerName,
                                               setLevel, updateGlobalLogger)

main :: IO ()
main = do
  let err = error "Must supply a valid MQTT broker URI"
  args <- getArgs
  case args of
    [uri] -> do
      case parseURI uri of
        Just u -> do
          case uriAuthority u of
            Just authority -> do
              updateGlobalLogger rootLoggerName (setLevel DEBUG)
              withSocketsDo $ do
                client <- startClient (uriRegName authority) (uriPort authority)
                gw     <- Gateway.newGateway client
                Gateway.listenOnAddr gw Gateway.defaultMQTTAddr
            Nothing -> err
        Nothing -> err
    _    -> err

startClient :: String -> String -> IO (InputStream ClientResult, OutputStream ClientCommand)
startClient regName port = do
  (client_result, client_result') <- S.makeChanPipe
  brokerAddr:_ <- getAddrInfo Nothing (Just regName) (getServiceName port)
  -- TODO how to gracefully close Client's socket?
  (socket, client_command) <- Client.runClientWithSockets Client.defaultClientConfig client_result' brokerAddr
  return (client_result, client_command)
    where
      getServiceName []    = Nothing
      getServiceName [':'] = Nothing
      getServiceName p     = Just p
