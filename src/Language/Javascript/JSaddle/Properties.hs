{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
#if (defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)) || !defined(USE_WEBKIT)
{-# LANGUAGE ForeignFunctionInterface, JavaScriptFFI #-}
#endif
-----------------------------------------------------------------------------
--
-- Module      :  Language.Javascript.JSaddle.Properties
-- Copyright   :  (c) Hamish Mackenzie
-- License     :  MIT
--
-- Maintainer  :  Hamish Mackenzie <Hamish.K.Mackenzie@googlemail.com>
--
-- | Low level JavaScript object property access.  In most cases you
--   should use "Language.Javascript.JSaddle.Object" instead.
--
--   This module is mostly here to implement functions needed to use
--   'JSPropRef'.
--
-----------------------------------------------------------------------------

module Language.Javascript.JSaddle.Properties (
  -- * Getting Property Values
    objGetPropertyByName
  , objGetPropertyAtIndex
  -- * Setting Property Values
  , objSetPropertyByName
  , objSetPropertyAtIndex
) where

import Control.Applicative ((<$>))
import Language.Javascript.JSaddle.Classes
       (MakeObject(..), MakeValueRef(..),
        MakeArgRefs(..), MakeStringRef(..))
import Language.Javascript.JSaddle.Monad (JSM)
import Language.Javascript.JSaddle.Types
       (JSValueRefRef, Object(..), JSPropertyAttributes,
        Index(..), JSStringRef)
#if (defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)) || !defined(USE_WEBKIT)
#else
import Graphics.UI.Gtk.WebKit.JavaScriptCore.JSObjectRef
       (jsobjectgetpropertyatindex, jsobjectgetproperty,
        jsobjectsetpropertyatindex, jsobjectsetproperty,
        JSPropertyAttributes)
#endif
import Control.Monad.Trans.Reader (ask)
import Control.Monad.IO.Class (MonadIO(..))
import Language.Javascript.JSaddle.Exception (rethrow)
import Language.Javascript.JSaddle.Value (JSValueRef)
import Language.Javascript.JSaddle.Arguments ()
import Language.Javascript.JSaddle.String ()

-- | Get a property value given the object and the name of the property.
objGetPropertyByName :: MakeStringRef name
                     => Object         -- ^ object to find the property on.
                     -> name           -- ^ name of the property.
                     -> JSValueRefRef  -- ^ exception if one is raised.
                     -> JSM JSValueRef -- ^ returns the property value.
#if defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)
objGetPropertyByName this name = liftIO . js_tryGetProp (makeStringRef name) this
{-# INLINE objGetPropertyByName #-}
foreign import javascript unsafe "try { $r=$2[$1] } catch(e) { $3[0] = e }"
    js_tryGetProp :: JSStringRef -> Object -> JSValueRefRef -> IO JSValueRef
#elif defined(USE_WEBKIT)
objGetPropertyByName (Object this) name exceptions = do
    gctxt <- ask
    liftIO $ jsobjectgetproperty gctxt this (makeStringRef name) exceptions
{-# INLINE objGetPropertyByName #-}
#else
objGetPropertyByName = undefined
#endif

-- | Get a property value given the object and the index of the property.
objGetPropertyAtIndex :: Object         -- ^ object to find the property on.
                      -> Index          -- ^ index of the property.
                      -> JSValueRefRef  -- ^ exception if one is raised.
                      -> JSM JSValueRef -- ^ returns the property value.
#if defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)
objGetPropertyAtIndex this index = liftIO . js_tryIndex index this
{-# INLINE objGetPropertyAtIndex #-}
foreign import javascript unsafe "try { $r=$2[$1] } catch(e) { $3[0] = e }"
    js_tryIndex :: Index -> Object -> JSValueRefRef -> IO JSValueRef
#elif defined(USE_WEBKIT)
objGetPropertyAtIndex (Object this) index exceptions = do
    gctxt <- ask
    liftIO $ jsobjectgetpropertyatindex gctxt this index exceptions
{-# INLINE objGetPropertyAtIndex #-}
#else
objGetPropertyAtIndex = undefined
#endif

-- | Set a property value given the object and the name of the property.
objSetPropertyByName :: (MakeStringRef name, MakeValueRef val)
                     => Object               -- ^ object to set the property on.
                     -> name                 -- ^ name of the property.
                     -> val                  -- ^ new value to set the property to.
                     -> JSPropertyAttributes -- ^ property attributes to give the property.
                     -> JSValueRefRef        -- ^ exception if one is raised.
                     -> JSM ()
#if defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)
objSetPropertyByName this name val attributes exceptions = do
    vref <- makeValueRef val
    liftIO $ js_trySetProp (makeStringRef name) this vref exceptions
{-# INLINE objSetPropertyByName #-}
foreign import javascript unsafe "try { $2[$1]=$3 } catch(e) { $4[0] = e }"
    js_trySetProp :: JSStringRef -> Object -> JSValueRef -> JSValueRefRef -> IO ()
#elif defined(USE_WEBKIT)
objSetPropertyByName (Object this) name val attributes exceptions = do
    gctxt <- ask
    vref <- makeValueRef val
    liftIO $ jsobjectsetproperty gctxt this (makeStringRef name) vref attributes exceptions
{-# INLINE objSetPropertyByName #-}
#else
objSetPropertyByName = undefined
#endif

-- | Set a property value given the object and the index of the property.
objSetPropertyAtIndex :: (MakeValueRef val)
                      => Object         -- ^ object to find property on.
                      -> Index          -- ^ index of the property.
                      -> val            -- ^ new value to set the property to.
                      -> JSValueRefRef  -- ^ exception if one is raised.
                      -> JSM ()
#if defined(ghcjs_HOST_OS) && defined(USE_JAVASCRIPTFFI)
objSetPropertyAtIndex this index val exceptions = do
    vref <- makeValueRef val
    liftIO $ js_trySetAtIndex index this vref exceptions
{-# INLINE objSetPropertyAtIndex #-}
foreign import javascript unsafe "try { $2[$1]=$3 } catch(e) { $4[0] = e }"
    js_trySetAtIndex :: Index -> Object -> JSValueRef -> JSValueRefRef -> IO ()
#elif defined(USE_WEBKIT)
objSetPropertyAtIndex (Object this) index val exceptions = do
    gctxt <- ask
    vref <- makeValueRef val
    liftIO $ jsobjectsetpropertyatindex gctxt this index vref exceptions
{-# INLINE objSetPropertyAtIndex #-}
#else
objSetPropertyAtIndex = undefined
#endif

