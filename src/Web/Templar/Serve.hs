{-#LANGUAGE NoImplicitPrelude #-}
{-#LANGUAGE OverloadedStrings #-}
{-#LANGUAGE OverloadedLists #-}
{-#LANGUAGE TemplateHaskell #-}
{-#LANGUAGE GeneralizedNewtypeDeriving #-}
{-#LANGUAGE LambdaCase #-}
{-#LANGUAGE ScopedTypeVariables #-}
{-#LANGUAGE FlexibleInstances #-}
{-#LANGUAGE MultiParamTypeClasses #-}
module Web.Templar.Serve
( serveProject
)
where

import ClassyPrelude
import Text.Ginger
        ( parseGinger
        , Template
        , runGingerT
        , GingerContext
        , GVal (..)
        , ToGVal (..)
        , (~>)
        )
import Text.Ginger.Html (Html, htmlSource)
import qualified Text.Ginger as Ginger
import Data.Aeson as JSON
import Data.Aeson.TH as JSON
import Data.Yaml as YAML
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Network.Wai as Wai
import Network.HTTP.Types (Status, status200, status302, status400, status404, status500)
import qualified Network.Wai.Handler.Warp as Warp
import Data.Default (def)
import Data.ByteString.Builder (stringUtf8)
import qualified Data.ByteString.UTF8 as UTF8
import qualified Data.ByteString.Lazy.UTF8 as LUTF8
import qualified Data.CaseInsensitive as CI

import Web.Templar.Backends
import Web.Templar.Rule
import Web.Templar.ProjectConfig
import Web.Templar.Project

serveProject :: Project -> Int -> IO ()
serveProject project port =
    Warp.run port (appFromProject project)

instance ToGVal m ByteString where
    toGVal = toGVal . UTF8.toString

instance ToGVal m (CI.CI ByteString) where
    toGVal = toGVal . CI.original

instance ToGVal m Wai.Request where
    toGVal rq =
        Ginger.dict
            [ "method" ~> show (Wai.requestMethod rq)
            , "httpVersion" ~> show (Wai.httpVersion rq)
            , "headers" ~> Wai.requestHeaders rq
            , "pathInfo" ~> Wai.pathInfo rq
            , "path" ~> Wai.rawPathInfo rq
            , "query" ~> Wai.rawQueryString rq
            ]

appFromProject :: Project -> Wai.Application
appFromProject project request respond = do
    handleRequest project request respond `catch` handleException
    where
        handleException (e :: SomeException) = do
            hPutStrLn stderr $ show e
            respond $ Wai.responseLBS status500 [] "Something went pear-shaped."

respondTemplate :: Project -> Status -> Text -> HashMap Text (GVal (Ginger.Run IO Html)) -> Wai.Application
respondTemplate project status templateName contextMap request respond = do
    let contextMap' =
            contextMap <>
            mapFromList
                [ "request" ~> request
                , "load" ~> Ginger.fromFunction gfnLoadBackendData
                , "ellipse" ~> Ginger.fromFunction gfnEllipse
                ]
        contextLookup key = return . fromMaybe def $ lookup key contextMap'
        headers = [("Content-type", "text/html;charset=utf8")]
    template <- getTemplate project templateName
    respond . Wai.responseStream status200 headers $ \write flush -> do
        let writeHtml = write . stringUtf8 . unpack . htmlSource
            context :: GingerContext IO Html
            context = Ginger.makeContextHtmlM contextLookup writeHtml
        runGingerT context template
        flush
    where
        gfnLoadBackendData :: Ginger.Function (Ginger.Run IO Html)
        gfnLoadBackendData args =
            Ginger.dict <$> forM (zip [0..] args) loadPair
        loadPair :: (Int, (Maybe Text, GVal (Ginger.Run IO Html)))
                 -> Ginger.Run IO Html (Text, GVal (Ginger.Run IO Html))
        loadPair (index, (keyMay, gBackendURL)) = do
            let backendURL = Ginger.asText $ gBackendURL
            backendData :: Items (BackendData IO Html) <- liftIO $
                loadBackendData =<< parseBackendURI backendURL
            return
                ( fromMaybe (tshow index) keyMay
                , toGVal backendData
                )

        gfnEllipse :: Ginger.Function (Ginger.Run IO Html)
        gfnEllipse [] = return def
        gfnEllipse [(Nothing, str)] =
            gfnEllipse [(Nothing, str), (Nothing, toGVal (100 :: Int))]
        gfnEllipse [(Nothing, str), (Nothing, len)] = do
            let txt = Ginger.asText str
                actualLen = ClassyPrelude.length txt
                targetLen = fromMaybe 100 $ ceiling <$> Ginger.asNumber len
                txt' = if actualLen + 3 > targetLen
                            then take (targetLen - 3) txt <> "..."
                            else txt
            return . toGVal $ txt'
        gfnEllipse ((Nothing, str):xs) = do
            let len = fromMaybe (toGVal (100 :: Int)) $ lookup (Just "len") xs
            gfnEllipse [(Nothing, str), (Nothing, len)]
        gfnEllipse xs = do
            let str = fromMaybe def $ lookup (Just "str") xs
            gfnEllipse $ (Nothing, str):xs


data NotFoundException = NotFoundException
    deriving (Show)

instance Exception NotFoundException where

handleRequest :: Project -> Wai.Application
handleRequest project request respond = do
    go `catchIOError` serve500
    where
        serve500 err = do
            hPutStrLn stderr . show $ err
            respondTemplate
                project
                status500
                "500.html"
                (mapFromList [])
                request
                respond
        go = do
            let queryPath =
                    (pack . UTF8.toString $ Wai.rawPathInfo request) <>
                    (pack . UTF8.toString $ Wai.rawQueryString request)
            case applyRules (pcRules . projectConfig $ project) queryPath of
                Nothing ->
                    respondTemplate
                        project
                        status404
                        "404.html"
                        (mapFromList [])
                        request
                        respond
                Just (backendPaths, required, target) -> do
                    case target of
                        RedirectTarget redirectPath -> do
                            respond $ Wai.responseLBS
                                status302
                                [("Location", UTF8.fromString . unpack $ redirectPath)]
                                ""

                        StaticTarget -> do
                            let go = do
                                    backendPath <-
                                        maybe (throwM NotFoundException) return $
                                            lookup "file" backendPaths
                                    backendData <- loadBackendData backendPath
                                    backendItem <- case backendData of
                                        NotFound -> throwM NotFoundException
                                        SingleItem item -> return item
                                        MultiItem [] -> throwM NotFoundException
                                        MultiItem (x:_) -> return x
                                    respond $ Wai.responseLBS
                                        status200
                                        [("Content-type", bmMimeType . bdMeta $ backendItem)]
                                        (bdRaw $ backendItem)
                                handle :: NotFoundException -> IO Wai.ResponseReceived
                                handle _ =
                                    respondTemplate
                                        project
                                        status404
                                        "404.html"
                                        (mapFromList [])
                                        request
                                        respond
                            go `catch` handle

                        JSONTarget -> do
                            backendData <- fmap (JSON.Object . mapFromList) $
                                forM (mapToList backendPaths) $ \(key, backendPath) -> do
                                    value <- loadBackendData backendPath
                                    return $ key .= toJSON value
                            respond $ Wai.responseLBS
                                status200
                                [("Content-type", "application/json")]
                                (JSON.encode backendData)

                        TemplateTarget templateName -> do
                            let handleNotFound :: NotFoundException -> IO Wai.ResponseReceived
                                handleNotFound _ =
                                    respondTemplate
                                        project
                                        status404
                                        "404.html"
                                        (mapFromList [])
                                        request
                                        respond
                            let go = do
                                    backendData <-
                                        forM (mapToList backendPaths) $ \(key, backendPath) -> do
                                            bd :: Items (BackendData IO Html) <- loadBackendData backendPath
                                            case bd of
                                                NotFound ->
                                                    if key `elem` required
                                                        then throwM NotFoundException
                                                        else return $ (key, def)
                                                _ -> return (key, toGVal bd)
                                    respondTemplate
                                        project
                                        status200
                                        templateName
                                        (mapFromList backendData)
                                        request
                                        respond
                            go `catch` handleNotFound
