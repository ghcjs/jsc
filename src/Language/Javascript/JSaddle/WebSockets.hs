{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-----------------------------------------------------------------------------
--
-- Module      :  Language.Javascript.JSaddle.WebSockets
-- Copyright   :  (c) Hamish Mackenzie
-- License     :  MIT
--
-- Maintainer  :  Hamish Mackenzie <Hamish.K.Mackenzie@googlemail.com>
--
-- |
--
-----------------------------------------------------------------------------

module Language.Javascript.JSaddle.WebSockets (
  -- * Running JSM over WebSockets
    run
  , syncPoint
  , syncAfter
#ifndef ghcjs_HOST_OS
  , jsaddleOr
  -- * Functions used to implement JSaddle over WebSockets
  , AsyncCommand(..)
  , Command(..)
  , Result(..)
  , sendCommand
  , sendLazyCommand
  , sendAsyncCommand
#endif
) where

#ifdef ghcjs_HOST_OS
import Language.Javascript.JSaddle.Types (JSM)
#else
import Control.Exception (throwIO)
import Control.Monad (void, forever)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Reader (ask, runReaderT)
import Control.Monad.STM (STM, atomically)
import Control.Concurrent (forkIO)
import Control.Concurrent.STM.TChan
       (tryReadTChan, TChan, readTChan, writeTChan, newTChanIO)
import Control.Concurrent.STM.TVar
       (writeTVar, readTVar, readTVarIO, modifyTVar, newTVarIO)
import Control.Concurrent.MVar
       (MVar, MVar, putMVar, takeMVar, newEmptyMVar)

import Data.Monoid ((<>))
import qualified Data.Text as T (unpack)
import qualified Data.Map as M (lookup, delete, insert, empty)
import Data.Aeson (encode, decode)

import Network.Wai (Application)
import Network.Wai.Handler.Warp
       (defaultSettings, setTimeout, setPort, runSettings)
import Network.Wai.Application.Static
       (ssIndices, staticApp)
import Network.WebSockets
       (ConnectionOptions(..), sendTextData, receiveDataMessage,
        acceptRequest, defaultConnectionOptions, ServerApp)
import qualified Network.WebSockets as WS (DataMessage(..))
import Network.Wai.Handler.WebSockets (websocketsOr)

import WaiAppStatic.Storage.Embedded (mkSettings)
import WaiAppStatic.Types (unsafeToPiece)

import Language.Javascript.JSaddle.Types
       (Command(..), AsyncCommand(..), Result(..), JSContextRef(..), JSVal(..),
        Object(..), JSValueReceived(..), JSM(..), Batch(..), JSValueForSend(..))
import Language.Javascript.JSaddle.Exception (JSException(..))
import Language.Javascript.JSaddle.Native (wrapJSVal)
import Language.Javascript.JSaddle.WebSockets.Files (mkEmbedded)
#endif

-- | Run the given 'JSM' action as the main entry point.  Either directly
--   in GHCJS or as a Warp server on the given port on GHC.
run :: Int -> JSM () -> IO ()
#ifdef ghcjs_HOST_OS
run _port = id
#else
run port f =
    runSettings (setPort port (setTimeout 3600 defaultSettings)) $
        jsaddleOr defaultConnectionOptions (f >> syncPoint) jsaddleApp
#endif

-- | Forces execution of pending asyncronous code
syncPoint :: JSM ()
#ifdef ghcjs_HOST_OS
syncPoint = return ()
#else
syncPoint = void $ sendCommand Sync
#endif

-- | Forces execution of pending asyncronous code after performing `f`
syncAfter :: JSM a -> JSM a
#ifdef ghcjs_HOST_OS
syncAfter = id
#else
syncAfter f = do
    result <- f
    syncPoint
    return result
#endif

#ifndef ghcjs_HOST_OS
sendCommand :: Command -> JSM Result
sendCommand cmd = do
    s <- doSendCommand <$> JSM ask
    liftIO $ s cmd

sendLazyCommand :: (JSValueForSend -> AsyncCommand) -> JSM JSVal
sendLazyCommand cmd = do
    nextRefTVar <- nextRef <$> JSM ask
    n <- liftIO . atomically $ do
        n <- subtract 1 <$> readTVar nextRefTVar
        writeTVar nextRefTVar n
        return n
    s <- doSendAsyncCommand <$> JSM ask
    liftIO $ s (cmd $ JSValueForSend n)
    wrapJSVal (JSValueReceived n)

sendAsyncCommand :: AsyncCommand -> JSM ()
sendAsyncCommand cmd = do
    s <- doSendAsyncCommand <$> JSM ask
    liftIO $ s cmd

jsaddleOr :: ConnectionOptions -> JSM () -> Application -> Application
jsaddleOr opts entryPoint = websocketsOr opts wsApp
  where
    wsApp :: ServerApp
    wsApp pending_conn = do
        conn <- acceptRequest pending_conn
        recvChan <- newTChanIO
        commandChan <- newTChanIO
        callbacks <- newTVarIO M.empty
        nextRef <- newTVarIO 0
        let ctx = JSContextRef {
            doSendCommand = \cmd -> do
                result <- newEmptyMVar
                atomically $ writeTChan commandChan (Right (cmd, result))
                takeMVar result >>= \case
                    (ThrowJSValue (JSValueReceived v)) -> throwIO $ JSException (JSVal v)
                    result -> return result
          , doSendAsyncCommand = atomically . writeTChan commandChan . Left
          , addCallback = \(Object (JSVal val)) cb -> atomically $ modifyTVar callbacks (M.insert val cb)
          , freeCallback = \(Object (JSVal val)) -> atomically $ modifyTVar callbacks (M.delete val)
          , nextRef = nextRef
          }
        forkIO . forever $
            receiveDataMessage conn >>= \case
                (WS.Text t) ->
                    case decode t of
                        Nothing                  -> error $ "jsaddle WebSocket decode failed : " <> show t
                        Just (ProtocolError err) -> error $ "Protocol error : " <> T.unpack err
                        Just (Callback f this a) -> do
                            f'@(JSVal fNumber) <- runReaderT (unJSM $ wrapJSVal f) ctx
                            this' <- runReaderT  (unJSM $ wrapJSVal this) ctx
                            args <- runReaderT (unJSM $ mapM wrapJSVal a) ctx
                            (M.lookup fNumber <$> liftIO (readTVarIO callbacks)) >>= \case
                                Nothing -> liftIO $ putStrLn "Callback called after it was freed"
                                Just cb -> void . forkIO $ runReaderT (unJSM $ cb f' this' args) ctx
                        Just m                   -> atomically $ writeTChan recvChan m
                _ -> error "jsaddle WebSocket unexpected binary data"
        forkIO . forever $ atomically (readBatch commandChan) >>= \case
                (batch, Just resultMVar) -> do
                    sendTextData conn $ encode batch
                    atomically (readTChan recvChan) >>= putMVar resultMVar
                (batch, Nothing) -> do
                    sendTextData conn $ encode batch
                    atomically (readTChan recvChan) >>= \case
                        SyncResult -> return ()
                        ThrowJSValue e -> atomically (discardToSyncPoint commandChan) >>= (`putMVar` ThrowJSValue e)
                        _ -> error "Unexpected result processing batch"
                    return ()
        runReaderT (unJSM entryPoint) ctx

    readBatch :: TChan (Either AsyncCommand (Command, MVar Result)) -> STM (Batch, Maybe (MVar Result))
    readBatch chan = do
        first <- readTChan chan -- We want at least one command to send
        loop first []
      where
        loop (Right (cmd, resultMVar)) asyncCmds =
            return (Batch (reverse asyncCmds) cmd, Just resultMVar)
        loop (Left asyncCmd) asyncCmds' = do
            let asyncCmds = asyncCmd:asyncCmds'
            tryReadTChan chan >>= \case
                Nothing -> return (Batch (reverse asyncCmds) Sync, Nothing)
                Just cmd -> loop cmd asyncCmds
    discardToSyncPoint :: TChan (Either AsyncCommand (Command, MVar Result)) -> STM (MVar Result)
    discardToSyncPoint chan =
        readTChan chan >>= \case
            Right (_, resultMVar) -> return resultMVar
            _                     -> discardToSyncPoint chan

jsaddleApp :: Application
jsaddleApp = staticApp ($(mkSettings mkEmbedded)) {ssIndices = [unsafeToPiece "index.html"]}

#endif
