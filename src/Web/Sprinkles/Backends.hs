{-#LANGUAGE NoImplicitPrelude #-}
{-#LANGUAGE OverloadedStrings #-}
{-#LANGUAGE TypeFamilies #-}
{-#LANGUAGE MultiParamTypeClasses #-}
{-#LANGUAGE FlexibleInstances #-}
{-#LANGUAGE FlexibleContexts #-}
{-#LANGUAGE LambdaCase #-}

-- | Main Backend module.
module Web.Sprinkles.Backends
(
-- * Defining backends
  BackendSpec (..)
, makeBackendSpecPathsAbsolute
, parseBackendURI
-- * Fetching backend data
, BackendData (..)
, BackendMeta (..)
, Items (..)
, loadBackendData
, RawBackendCache
, rawToLBS
, rawFromLBS
)
where

import ClassyPrelude
import System.Random.Shuffle (shuffleM)
import Web.Sprinkles.Cache
import qualified Data.Serialize as Cereal
import Control.MaybeEitherMonad (eitherFailS)
import Web.Sprinkles.Logger (LogLevel (..))
import Network.Mime (MimeType)

import Web.Sprinkles.Backends.Spec
        ( BackendSpec (..)
        , makeBackendSpecPathsAbsolute
        , BackendType (..)
        , AscDesc (..)
        , FetchMode (..)
        , FetchOrder (..)
        , FetchOrderField (..)
        , parseBackendURI
        , CachePolicy (..)
        , cachePolicy
        )
import Web.Sprinkles.Backends.Parsers
        ( parseBackendData
        )
import Web.Sprinkles.Backends.Data
        ( BackendData (..)
        , BackendMeta (..)
        , BackendSource (..)
        , Items (..)
        , reduceItems
        , serializeBackendSource
        , deserializeBackendSource
        , rawFromLBS
        , rawToLBS
        )
import Web.Sprinkles.Backends.Loader
import Web.Sprinkles.Backends.Loader.Type (RequestContext)
import Data.Expandable

-- | Cache for raw backend data, stored as bytestrings.
type RawBackendCache = Cache ByteString ByteString

-- | Well-typed backend cache.
type BackendCache = Cache BackendSpec [BackendSource]

-- | Execute a backend query, with caching.
loadBackendData :: Monad m
                => (LogLevel -> Text -> IO ())
                -> RequestContext
                -> RawBackendCache
                -> BackendSpec
                -> IO (Items (BackendData p m h))
loadBackendData writeLog cache loadPost bspec =
    fmap (reduceItems (bsFetchMode bspec)) $
        fetchBackendData writeLog cache loadPost bspec >>=
        mapM parseBackendData >>=
        sorter
    where
        sorter :: [BackendData p m h] -> IO [BackendData p m h]
        sorter = fmap reverter . baseSorter
        reverter :: [a] -> [a]
        reverter = case fetchAscDesc (bsOrder bspec) of
            Ascending -> id
            Descending -> reverse
        baseSorter :: [BackendData p m h] -> IO [BackendData p m h]
        baseSorter = case fetchField (bsOrder bspec) of
            ArbitraryOrder -> return
            RandomOrder -> shuffleM
            OrderByName -> return . sortOn (bmName . bdMeta)
            OrderByMTime -> return . sortOn (bmMTime . bdMeta)

-- | What the type says: expose a raw backend cache (bytestrings) as a
-- well-typed backend cache.
wrapBackendCache :: RawBackendCache -> BackendCache
wrapBackendCache =
    transformCache
        Cereal.encode
        (eitherFailS . Cereal.decode)
        (fmap (Just . Cereal.encode) . mapM serializeBackendSource)
        (fmap Just . fmap (map deserializeBackendSource) . eitherFailS . Cereal.decode)

-- | Fetch raw backend data from a backend source, with caching.
fetchBackendData :: (LogLevel -> Text -> IO ()) -> RequestContext -> RawBackendCache -> BackendSpec -> IO [BackendSource]
fetchBackendData writeLog loadPost rawCache spec =
    cacheWrap (fetchBackendData' writeLog loadPost) spec
    where
        cacheWrap = case cachePolicy spec of
            CacheForever -> cached cache
            NoCaching -> id
        cache :: BackendCache
        cache = wrapBackendCache rawCache

-- | Fetch raw backend data from a backend source, without caching.
fetchBackendData' :: (LogLevel -> Text -> IO ()) -> RequestContext -> BackendSpec -> IO [BackendSource]
fetchBackendData'
        writeLog
        loadPost
        (BackendSpec backendType fetchMode fetchOrder mimeOverride) =
    map (overrideMime mimeOverride) <$> loader backendType writeLog loadPost fetchMode fetchOrder

overrideMime :: Maybe MimeType -> BackendSource -> BackendSource
overrideMime Nothing s = s
overrideMime (Just m) s =
    s { bsMeta = (bsMeta s) { bmMimeType = m } }
