{-#LANGUAGE NoImplicitPrelude #-}
{-#LANGUAGE OverloadedStrings #-}
{-#LANGUAGE TypeFamilies #-}
{-#LANGUAGE MultiParamTypeClasses #-}
{-#LANGUAGE FlexibleInstances #-}
{-#LANGUAGE FlexibleContexts #-}
{-#LANGUAGE LambdaCase #-}
module Web.Templar.Backends
where

import ClassyPrelude
import Data.Aeson as JSON
import Data.Aeson.TH as JSON
import Data.Yaml as YAML
import qualified Network.HTTP as HTTP
import Network.Mime
            ( MimeType
            , MimeMap
            , defaultMimeLookup
            , defaultMimeMap
            , mimeByExt
            , defaultMimeType
            , FileName
            )
import Network.URI (parseURI, URI)
import qualified Text.Pandoc as Pandoc
import Text.Pandoc (Pandoc)
import Text.Pandoc.Error (PandocError)
import Text.Ginger (ToGVal (..), GVal, Run (..), dict, (~>))
import Web.Templar.PandocGVal
import System.FilePath (takeFileName, takeBaseName)
import System.FilePath.Glob (glob)
import System.PosixCompat.Files
import Foreign.C.Types (CTime (..))
import Data.Char (ord)
import qualified Text.Ginger as Ginger
import Data.Default (def)
import System.Random.Shuffle (shuffleM)
import Data.Default

mimeMap :: MimeMap
mimeMap =
    defaultMimeMap <>
    mapFromList
        [ ("yml", "application/x-yaml")
        , ("yaml", "application/x-yaml")
        , ("md", "application/x-markdown")
        , ("rst", "text/x-rst")
        , ("markdown", "application/x-markdown")
        , ("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        ]

mimeLookup :: FileName -> MimeType
mimeLookup = mimeByExt mimeMap defaultMimeType

data BackendType = HttpBackend Text Credentials
                 | FileBackend Text
                 deriving (Show)

type instance Element BackendType = Text

instance MonoFunctor BackendType where
    omap f (HttpBackend t c) = HttpBackend (f t) c
    omap f (FileBackend t) = FileBackend (f t)

data BackendSpec =
    BackendSpec
        { bsType :: BackendType
        , bsFetchMode :: FetchMode
        , bsOrder :: FetchOrder
        }
        deriving (Show)

type instance Element BackendSpec = Text

instance MonoFunctor BackendSpec where
    omap f (BackendSpec t m o) = BackendSpec (omap f t) m o

data FetchMode = FetchOne | FetchAll | FetchN Int
    deriving (Show, Read, Eq)

instance FromJSON FetchMode where
    parseJSON (String "one") = return FetchOne
    parseJSON (String "all") = return FetchAll
    parseJSON (Number n) = return . FetchN . ceiling $ n
    parseJSON _ = fail "Invalid fetch mode (want 'one' or 'all')"

data FetchOrderField = ArbitraryOrder -- ^ Do not impose any ordering at all
                     | RandomOrder -- ^ Shuffle randomly
                     | OrderByName -- ^ Order by reported name
                     | OrderByMTime -- ^ Order by modification time
                     deriving (Show, Read, Eq)

instance Default FetchOrderField where
    def = ArbitraryOrder

data AscDesc = Ascending | Descending
    deriving (Show, Read, Eq)

instance Default AscDesc where
    def = Ascending

data FetchOrder =
    FetchOrder
        { fetchField :: FetchOrderField
        , fetchAscDesc :: AscDesc
        }
        deriving (Show, Read, Eq)

instance Default FetchOrder where
    def = FetchOrder def def

instance FromJSON FetchOrder where
    parseJSON Null = return $ FetchOrder ArbitraryOrder Ascending
    parseJSON (String str) = do
        let (order, core) = case take 1 str of
                "-" -> (Descending, drop 1 str)
                "+" -> (Ascending, drop 1 str)
                _ -> (Ascending, str)
        field <- case core of
            "arbitrary" -> return ArbitraryOrder
            "random" -> return RandomOrder
            "shuffle" -> return RandomOrder
            "name" -> return OrderByName
            "mtime" -> return OrderByMTime
            x -> fail $ "Invalid order field: " ++ show x
        return $ FetchOrder field order
    parseJSON val = fail $ "Invalid fetch order specifier: " ++ show val

instance FromJSON BackendSpec where
    parseJSON = backendSpecFromJSON

data Items a = NotFound | SingleItem a | MultiItem [a]

reduceItems :: FetchMode -> [a] -> Items a
reduceItems FetchOne [] = NotFound
reduceItems FetchOne (x:_) = SingleItem x
reduceItems FetchAll xs = MultiItem xs
reduceItems (FetchN n) xs = MultiItem $ take n xs

instance ToGVal m a => ToGVal m (Items a) where
    toGVal NotFound = def
    toGVal (SingleItem x) = toGVal x
    toGVal (MultiItem xs) = toGVal xs

instance ToJSON a => ToJSON (Items a) where
    toJSON NotFound = Null
    toJSON (SingleItem x) = toJSON x
    toJSON (MultiItem xs) = toJSON xs

backendSpecFromJSON (String uri) =
    parseBackendURI uri
backendSpecFromJSON (Object obj) = do
    bsTypeStr <- obj .: "type"
    (t, defFetchMode) <- case bsTypeStr :: Text of
            "http" -> parseHttpBackendSpec
            "https" -> parseHttpBackendSpec
            "file" -> parseFileBackendSpec FetchOne
            "glob" -> parseFileBackendSpec FetchAll
            "dir" -> parseDirBackendSpec
    fetchMode <- obj .:? "fetch" .!= defFetchMode
    fetchOrder <- obj .:? "order" .!= def
    return $ BackendSpec t fetchMode fetchOrder
    where
        parseHttpBackendSpec = do
            t <- obj .: "uri"
            return (HttpBackend t AnonymousCredentials, FetchOne)
        parseFileBackendSpec m = do
            path <- obj .: "path"
            return (FileBackend (pack path), m)
        parseDirBackendSpec = do
            path <- obj .: "path"
            return (FileBackend (pack $ path </> "*"), FetchAll)

parseBackendURI :: Monad m => Text -> m BackendSpec
parseBackendURI t = do
    let protocol = takeWhile (/= ':') t
        path = drop (length protocol + 3) t
    case protocol of
        "http" ->
            return $
                BackendSpec
                    (HttpBackend t AnonymousCredentials)
                    FetchOne
                    def
        "https" ->
            return $
                BackendSpec
                    (HttpBackend t AnonymousCredentials)
                    FetchOne
                    def
        "dir" -> return $ BackendSpec (FileBackend (pack $ unpack path </> "*")) FetchAll def
        "glob" -> return $ BackendSpec (FileBackend path) FetchAll def
        "file" -> return $ BackendSpec (FileBackend path) FetchOne def
        _ -> fail $ "Unknown protocol: " <> show protocol

data Credentials = AnonymousCredentials
    deriving (Show)

instance FromJSON Credentials where
    parseJSON Null = return AnonymousCredentials
    parseJSON (String "anonymous") = return AnonymousCredentials
    parseJSON _ = fail "Invalid credentials"

data BackendData m h =
    BackendData
        { bdJSON :: JSON.Value
        , bdGVal :: GVal (Run m h)
        , bdRaw :: LByteString
        , bdMeta :: BackendMeta
        }

data BackendSource =
    BackendSource
        { bsMeta :: BackendMeta
        , bsSource :: LByteString
        }

loadBackendData :: BackendSpec -> IO (Items (BackendData m h))
loadBackendData bspec =
    fmap (reduceItems (bsFetchMode bspec)) $
        fetchBackendData bspec >>=
        mapM parseBackendData >>=
        sorter
    where
        sorter :: [BackendData m h] -> IO [BackendData m h]
        sorter = fmap reverter . baseSorter
        reverter :: [a] -> [a]
        reverter = case fetchAscDesc (bsOrder bspec) of
            Ascending -> id
            Descending -> reverse
        baseSorter :: [BackendData m h] -> IO [BackendData m h]
        baseSorter = case fetchField (bsOrder bspec) of
            ArbitraryOrder -> return
            RandomOrder -> shuffleM
            OrderByName -> return . sortOn (bmName . bdMeta)
            OrderByMTime -> return . sortOn (bmMTime . bdMeta)

toBackendData :: (ToJSON a, ToGVal (Run m h) a) => BackendSource -> a -> BackendData m h
toBackendData src val =
    BackendData
        { bdJSON = toJSON val
        , bdGVal = toGVal val
        , bdRaw = bsSource src
        , bdMeta = bsMeta src
        }

instance ToJSON (BackendData m h) where
    toJSON = bdJSON

instance ToGVal (Run m h) (BackendData m h) where
    toGVal bd =
        let baseVal = bdGVal bd
            baseLookup = fromMaybe (const def) $ Ginger.asLookup baseVal
            baseDictItems = Ginger.asDictItems baseVal
        in baseVal
            { Ginger.asLookup = Just $ \case
                "props" -> return . toGVal . bdMeta $ bd
                k -> baseLookup k
            , Ginger.asDictItems =
                (("props" ~> bdMeta bd):) <$> baseDictItems
            }

data BackendMeta =
    BackendMeta
        { bmMimeType :: MimeType
        , bmMTime :: Maybe CTime
        , bmName :: Text
        , bmPath :: Text
        , bmSize :: Maybe Integer
        }
        deriving (Show)

instance ToJSON BackendMeta where
    toJSON bm =
        JSON.object
            [ "mimeType" .= decodeUtf8 (bmMimeType bm)
            , "mtime" .= (fromIntegral . unCTime <$> bmMTime bm :: Maybe Integer)
            , "name" .= bmName bm
            , "path" .= bmPath bm
            , "size" .= bmSize bm
            ]

instance Ginger.ToGVal m BackendMeta where
    toGVal bm = Ginger.dict
        [ "type" ~> decodeUtf8 (bmMimeType bm)
        , "mtime" ~> (fromIntegral . unCTime <$> bmMTime bm :: Maybe Integer)
        , "name" ~> bmName bm
        , "path" ~> bmPath bm
        , "size" ~> bmSize bm
        ]

fetchBackendData :: BackendSpec -> IO [BackendSource]
fetchBackendData (BackendSpec (FileBackend filepath) fetchMode fetchOrder) =
    fetch `catchIOError` handle
    where
        filename = unpack filepath
        fetch = do
            candidates <- if '*' `elem` filename
                then glob filename
                else return [filename]
            mapM fetchOne candidates
        handle err
            | isDoesNotExistError err = return []
            | otherwise = ioError err

        fetchOne candidate = do
            let mimeType = mimeLookup . pack $ candidate
            contents <- readFile candidate `catchIOError` \err -> do
                hPutStrLn stderr $ show err
                return ""
            status <- getFileStatus candidate
            let mtimeUnix = modificationTime status
                meta = BackendMeta
                        { bmMimeType = mimeType
                        , bmMTime = Just mtimeUnix
                        , bmName = pack $ takeBaseName candidate
                        , bmPath = pack candidate
                        , bmSize = (Just . fromIntegral $ fileSize status :: Maybe Integer)
                        }
            return $ BackendSource meta contents
fetchBackendData (BackendSpec (HttpBackend uriText credentials) fetchMode fetchOrder) = do
    backendURL <- maybe
        (fail $ "Invalid backend URL: " ++ show uriText)
        return
        (parseURI $ unpack uriText)
    let backendRequest =
            HTTP.Request
                backendURL
                HTTP.GET
                []
                ""
    response <- HTTP.simpleHTTP backendRequest
    body <- HTTP.getResponseBody response
    headers <- case response of
                    Left err -> fail (show err)
                    Right resp -> return $ HTTP.getHeaders resp
    let mimeType = encodeUtf8 . pack . fromMaybe "text/plain" . lookupHeader HTTP.HdrContentType $ headers
        contentLength = lookupHeader HTTP.HdrContentLength headers >>= readMay
        meta = BackendMeta
                { bmMimeType = mimeType
                , bmMTime = Nothing
                , bmName = pack . takeBaseName . unpack $ uriText
                , bmPath = uriText
                , bmSize = contentLength
                }
    return [BackendSource meta body]

unCTime :: CTime -> Int64
unCTime (CTime i) = i

lookupHeader :: HTTP.HeaderName -> [HTTP.Header] -> Maybe String
lookupHeader name headers =
    headMay [ v | HTTP.Header n v <- headers, n == name ]

parseBackendData :: Monad m => BackendSource -> m (BackendData n h)
parseBackendData item@(BackendSource meta body) = do
    let t = takeWhile (/= fromIntegral (ord ';')) (bmMimeType meta)
        parse = fromMaybe parseRawData $ lookup t parsersTable
    parse item

parsersTable :: Monad m => HashMap MimeType (BackendSource -> m (BackendData n h))
parsersTable = mapFromList . mconcat $
    [ zip mimeTypes (repeat parser) | (mimeTypes, parser) <- parsers ]

parsers :: Monad m => [([MimeType], (BackendSource -> m (BackendData n h)))]
parsers =
    [ ( ["application/json", "text/json"]
      , parseJSONData
      )
    , ( ["application/x-yaml", "text/x-yaml", "application/yaml", "text/yaml"]
      , parseYamlData
      )
    , ( ["application/x-markdown", "text/x-markdown"]
      , parsePandocDataString (Pandoc.readMarkdown Pandoc.def)
      )
    , ( ["application/x-textile", "text/x-textile"]
      , parsePandocDataString (Pandoc.readTextile Pandoc.def)
      )
    , ( ["application/x-rst", "text/x-rst"]
      , parsePandocDataString (Pandoc.readRST Pandoc.def)
      )
    , ( ["application/html", "text/html"]
      , parsePandocDataString (Pandoc.readHtml Pandoc.def)
      )
    , ( ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"]
      , parsePandocDataLBS (fmap fst . Pandoc.readDocx Pandoc.def)
      )
    ]

parseRawData :: Monad m => BackendSource -> m (BackendData n h)
parseRawData (BackendSource meta body) =
    return $ BackendData
        { bdJSON = JSON.Null
        , bdGVal = toGVal JSON.Null
        , bdMeta = meta
        , bdRaw = body
        }

parseJSONData :: Monad m => BackendSource -> m (BackendData n h)
parseJSONData item@(BackendSource meta body) =
    case JSON.eitherDecode body of
        Left err -> fail $ err ++ "\n" ++ show body
        Right json -> return . toBackendData item $ (json :: JSON.Value)

parseYamlData :: Monad m => BackendSource -> m (BackendData n h)
parseYamlData item@(BackendSource meta body) =
    case YAML.decodeEither (toStrict body) of
        Left err -> fail $ err ++ "\n" ++ show body
        Right json -> return . toBackendData item $ (json :: JSON.Value)

parsePandocDataLBS :: Monad m
                   => (LByteString -> Either PandocError Pandoc)
                   -> BackendSource
                   -> m (BackendData n h)
parsePandocDataLBS reader input@(BackendSource meta body) = do
    case reader body of
        Left err -> fail . show $ err
        Right pandoc -> return $ toBackendData input pandoc

parsePandocDataString :: Monad m
                   => (String -> Either PandocError Pandoc)
                   -> BackendSource
                   -> m (BackendData n h)
parsePandocDataString reader =
    parsePandocDataLBS (reader . unpack . decodeUtf8)