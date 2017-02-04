{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}

{-|
Module      : EPOOPS
Description : EPOOPS's main module

-}
module EPOOPS
    ( withOPSSession,
      epoRequest,
      OPSService (..),
      Credentials (..),
      InstanceListing,
      getEPODOCInstances,
      downloadEPODOCInstance,
      silentProgress,
      PageProgress,
      OPSSession,
      LogLevel (..)
    )
    where

import           Control.Arrow
import           Control.Lens       hiding ((&))
import           Data.Aeson.Lens
import qualified Data.ByteString    as B
import           Data.String.Here
import qualified Data.Text.Encoding as T
import           EPODOC
import           Lib.Prelude
import qualified Network.Wreq       as Wreq
import           System.IO.Streams  (fromLazyByteString)
import qualified System.IO.Streams  as S
import qualified System.IO.Temp     as Temp
import qualified Text.Parsec        as Parsec
import           Text.Printf        (printf)
import           Text.Read          (readMaybe)
import qualified Turtle             hiding ((<>))

import qualified Data.Map.Strict    as Map
import qualified Text.XML           as XML
import           Text.XML.Cursor    (($//), (>=>))
import qualified Text.XML.Cursor    as XML
import qualified Control.Monad.Catch as Catch

import Control.Monad.Logger

opsEndPoint :: [Char]
opsEndPoint = "https://ops.epo.org/3.1"

newtype OAuth2Token = OAuth2Token { _rawtoken :: B.ByteString } deriving (Show, Eq)

newtype OPSSession a = OPSSession {
  runOPSSession :: LoggingT (ReaderT Credentials (StateT SessionState IO)) a
} deriving (Applicative, Functor, Monad, MonadIO, MonadReader Credentials, MonadState SessionState, Catch.MonadThrow, Catch.MonadCatch, Catch.MonadMask, MonadLogger)


data Credentials = Credentials {
  consumerKey :: [Char],
  secretKey   :: [Char]
}

data SessionState = SessionState {quotaState :: Quotas, tokenState :: Maybe OAuth2Token}

data OPSServiceState = Idle | Busy | Overloaded deriving (Eq, Ord, Show)
data OPSServiceTraffic = Green | Yellow | Red | Black deriving (Eq, Ord, Show)
data OPSServiceQuota = RetrievalQuota | SearchQuota | INPADOCQuota | ImagesQuota | OtherQuota deriving (Eq, Ord, Show)
data OPSService = Biblio | Abstract | FullCycle | FullText | Description | Claims | Equivalents | Images
  deriving (Eq, Ord, Show)

type Quotas = (OPSServiceState, Map OPSServiceQuota (OPSServiceTraffic, Int))
type InstanceListing = (Int, EPODOC)

initialState :: SessionState
initialState = SessionState
                (Idle, Map.fromList [
                (RetrievalQuota, (Green, 200)),
                (SearchQuota, (Green, 30)),
                (INPADOCQuota, (Green, 60)),
                (ImagesQuota, (Green, 200)),
                (OtherQuota, (Green, 1000))])
                Nothing

withOPSSession :: Credentials -> LogLevel -> OPSSession a -> IO (a, SessionState)
withOPSSession credentials minLevel k = runStateT (runReaderT (runStderrLoggingT (filterLogger logFilter (runOPSSession k))) credentials) initialState where
  logFilter _ level = level >= minLevel

authenticate :: OPSSession OAuth2Token
authenticate = do
  sessionState <- get
  settings <- ask
  let token = tokenState sessionState
      client_id = consumerKey settings
      client_secret = secretKey settings
  case token of
      Just t -> return t
      Nothing -> do
        $(logInfo) "Getting OAuth2 token"
        newtoken <- liftIO $ requestOAuthToken client_id client_secret
        put sessionState {tokenState = Just newtoken}
        return newtoken

potentiallyThrottle :: OPSService -> OPSSession ()
potentiallyThrottle service = do
  quota <- quotaState <$> get
  let (trafficLight, requests) = fromMaybe (Black, 0) $
                                    Map.lookup  (opsServiceToServiceQuota service)
                                    (snd quota)
      serviceStatus = fst quota
  delayForServiceStatus serviceStatus
  delayForTrafficLight trafficLight
  delayForRate requests

delayForServiceStatus :: OPSServiceState -> OPSSession ()
delayForServiceStatus Overloaded = do
    $(logWarn) "System: Overloaded."
    liftIO $ threadDelay $ 2 * 1000

delayForServiceStatus Busy = do
    $(logInfo) "System: Busy."
    liftIO $ threadDelay 100

delayForServiceStatus Idle = do
  $(logDebug) "System: Idle."
  return ()

delayForTrafficLight :: OPSServiceTraffic -> OPSSession ()
delayForTrafficLight Black = do
  $(logWarn) "Service Traffic: Black"
  liftIO $ threadDelay $ 60 * 1000

delayForTrafficLight Red = do
  $(logWarn) "Service Traffic: Red"
  liftIO $ threadDelay $ 30 * 1000

delayForTrafficLight Yellow = do
  $(logInfo) "Service Traffic: Yellow"
  liftIO $ threadDelay $ 10 * 1000

delayForTrafficLight Green = do
  $(logDebug) "Service Traffic: Green"
  return ()

delayForRate :: Int -> OPSSession ()
delayForRate rate = do
  let delay = floor $ (( 1.0/((fromIntegral rate) / 60.0) * 0.2) * 1000.0 :: Double)
  $(logDebug) [i|Service rate limit is ${rate}. Delaying ${delay} milliseconds|]
  liftIO $ threadDelay delay

epoRequest :: EPODOC -> OPSService -> OPSSession XML.Document
epoRequest epodoc service = do
  sessionState <- get
  token <- authenticate
  potentiallyThrottle service
  let opts =  Wreq.defaults
            & Wreq.auth ?~ Wreq.oauth2Bearer (_rawtoken token)
      query = [i|${opsEndPoint}/rest-services/published-data/publication/${opsSearchString epodoc}/${opsServiceToEndPoint service}|]
  r <- liftIO $ Wreq.getWith opts query
  let body = r ^. Wreq.responseBody
      xml = XML.parseLBS_ XML.def body
      rawThrottle :: Text
      rawThrottle = convertString $ r ^. Wreq.responseHeader "X-Throttling-Control"
  throttle <- parseThrottleStatement rawThrottle
  $(logDebug) [i|rawThrottle: '${rawThrottle}'|]
  $(logDebug) [i|parsedThrottle: '${throttle}'|]
  put sessionState {quotaState = throttle}
  return xml

downloadEPODOCPageAsPDF :: EPODOC -> [Char] -> (CurrPage -> IO ()) -> Int -> OPSSession ()
downloadEPODOCPageAsPDF epodoc path progressFn page = do
  token <- authenticate
  potentiallyThrottle Images
  let imageLink = rebuildImageLink epodoc
      query = [i|${opsEndPoint}/rest-services/${imageLink}.pdf?Range=${page}|]
      epokey = (convertString $ fromEPODOC epodoc) :: [Char]
      file = printf "%s/%s-%04d.pdf" path epokey page
  liftIO $ downloadFile token query file
  liftIO $ progressFn page

getEPODOCInstances :: Bool -> EPODOC -> OPSSession [InstanceListing]
getEPODOCInstances strictly epodoc = do
  imagedata <- epoRequest epodoc Images
  let rawinstances = getLinksAndCounts imagedata
      filteredInstances = filter allow rawinstances
      unwantedKind e (c, k) = countryCode e == c && (kind epodoc /= Just k && kind e == Just k)
      allow (l, e)
       | l <= 1 = False
       | strictly && not (e `equivEPODOC` epodoc) = False
       | e `unwantedKind` ("EP", "A3") = False -- exclude search reports, unless we ask for them
       | e `unwantedKind` ("EP", "A4") = False
       | otherwise = True
  $(logDebug) [i|Found ${length rawinstances} total instances. After filtering, ${length filteredInstances} are left.|]
  return filteredInstances

type TotalPages = Int
type CurrPage = Int
type PageProgress = TotalPages -> CurrPage -> IO ()

silentProgress :: PageProgress
silentProgress _ _ = return ()

downloadEPODOCInstance :: PageProgress -> InstanceListing -> OPSSession ()
downloadEPODOCInstance progressFn (count, instanceEPODOC) = do
  let pages = [1..count]
      epokey = formatAsEPODOC instanceEPODOC
      output :: [Char]
      output = [i|${epokey}.pdf|]
  _ <- Temp.withTempDirectory "." "pat-download." $ \tmpDir -> do
        mapM_ (downloadEPODOCPageAsPDF instanceEPODOC tmpDir (progressFn count)) pages
        liftIO $ Turtle.shell [i|gs -dBATCH -dNOPAUSE -q -sDEVICE=pdfwrite -sOutputFile=${output} "${tmpDir}"/*.pdf|] Turtle.empty
  return ()

downloadFile :: OAuth2Token -> [Char] -> FilePath -> IO ()
downloadFile token url name = do
  let opts =  Wreq.defaults
            & Wreq.auth ?~ Wreq.oauth2Bearer (_rawtoken token)
  r <- Wreq.getWith opts url
  output <- fromLazyByteString $ r ^. Wreq.responseBody
  S.withFileAsOutput name (S.connect output)

requestOAuthToken :: [Char] -> [Char] -> IO OAuth2Token
requestOAuthToken client_id client_secret = do
    let opts = Wreq.defaults
            & Wreq.header "Accept" .~ ["application/json"]
            & Wreq.header "Content-Type" .~ ["application/x-www-form-urlencoded"]
    let body =
          [ "grant_type" Wreq.:= ("client_credentials" :: [Char])
          , "client_id" Wreq.:= client_id
          , "client_secret" Wreq.:= client_secret]
    resp <- Wreq.postWith opts (opsEndPoint <> "/auth/accesstoken") body
    let token = resp ^. Wreq.responseBody . key "access_token" . _String
    return $ (T.encodeUtf8 >>> OAuth2Token) token

opsSearchString :: EPODOC -> [Char]
opsSearchString epodoc = case kind epodoc of
  Nothing -> [i|epodoc/${formatAsEPODOC epodoc}|]
  Just _  -> [i|docdb/${formatAsDOCDB epodoc}|]

opsServiceToServiceQuota :: OPSService -> OPSServiceQuota
opsServiceToServiceQuota s
  | s == Images = ImagesQuota
  | otherwise = RetrievalQuota

opsServiceToEndPoint :: OPSService -> [Char]
opsServiceToEndPoint s
  | s == Biblio = "biblio"
  | s == Abstract = "abstract"
  | s == FullCycle = "full-cycle"
  | s == FullText = "full-text"
  | s == Description = "description"
  | s == Claims = "claims"
  | s == Equivalents = "equivalents"
  | s == Images = "images"

opsServiceStateFromString :: [Char] -> OPSServiceState
opsServiceStateFromString "idle" = Idle
opsServiceStateFromString "busy" = Busy
opsServiceStateFromString _      = Overloaded

opsServiceTrafficFromString :: [Char] -> OPSServiceTraffic
opsServiceTrafficFromString "green"  = Green
opsServiceTrafficFromString "yellow" = Yellow
opsServiceTrafficFromString "red"    = Red
opsServiceTrafficFromString _        = Black

opsServiceQuotaFromString :: [Char] -> OPSServiceQuota
opsServiceQuotaFromString "retrieval" = RetrievalQuota
opsServiceQuotaFromString "search"    = SearchQuota
opsServiceQuotaFromString "inpadoc"   = INPADOCQuota
opsServiceQuotaFromString "images"    = ImagesQuota
opsServiceQuotaFromString _           = OtherQuota

readDef :: Read a => a -> [Char] -> a
readDef def input = fromMaybe def (readMaybe input)

throttleStatement :: Parsec.Parsec Text () Quotas
throttleStatement = do
  let service_state = do
        service_name <- Parsec.many1 Parsec.letter
        void $ Parsec.char '='
        traffic_light <- Parsec.many1 Parsec.letter
        void $ Parsec.char ':'
        request_limit <- Parsec.many1 Parsec.digit
        void $ Parsec.optional $ Parsec.char ','
        void $ Parsec.optional Parsec.spaces
        return (opsServiceQuotaFromString service_name, (opsServiceTrafficFromString traffic_light, readDef 0 request_limit))
  system_state <- Parsec.choice [Parsec.try $ Parsec.string "idle", Parsec.try $ Parsec.string "busy", Parsec.string "overloaded"]
  void Parsec.spaces
  services <- Parsec.between (Parsec.char '(') (Parsec.char ')') (Parsec.many1 service_state)
  let service_states = Map.fromList services
  return (opsServiceStateFromString system_state, service_states)

parseThrottleStatement :: Text -> OPSSession Quotas
parseThrottleStatement input = case Parsec.parse throttleStatement (convertString input) input of
    (Right result) -> return result
    (Left err) -> do
      $(logError) [i|X-Throttle parsing failure: ${err}|]
      return (Overloaded, Map.empty)

rebuildImageLink :: EPODOC -> [Char]
rebuildImageLink epodoc = printf "published-data/images/%s/%s/%s/fullimage"
                                  (convertString (countryCode epodoc)::[Char])
                                  (convertString (serial epodoc)::[Char])
                                  (convertString (fromMaybe "%" $ kind epodoc)::[Char])

imageLinktoEPODOC :: Text -> Maybe EPODOC
imageLinktoEPODOC imageLink = hush $ Parsec.parse opsImageFormat "opsImageFormat" imageLink where
  opsImageFormat :: Parsec.Parsec Text () EPODOC
  opsImageFormat = do
    void $ Parsec.string "published-data/images/"
    countryPart <- Parsec.count 2 Parsec.letter
    void $ Parsec.char '/'
    serialPart <- Parsec.many1 Parsec.digit
    void $ Parsec.char '/'
    kindPart <- Parsec.many1 (Parsec.letter <|> Parsec.digit)
    return $ EPODOC (convertString countryPart)
                    (convertString serialPart)
                    (Just (convertString kindPart))
                    Nothing

getLinksAndCounts :: XML.Document -> [InstanceListing]
getLinksAndCounts xml = catMaybes (getLinkAndCount <$> instances)
  where
    cursor = XML.fromDocument xml
    instances = cursor $// XML.laxElement "document-instance" >=> XML.attributeIs "desc" "FullDocument"
    getLinkAndCount instanceCursor =
      let
        instanceEPODOC = imageLinktoEPODOC $ headDef "" (XML.attribute "link" instanceCursor)
        pageCount = join $ (readMaybe . convertString) <$> headMay (XML.attribute "number-of-pages" instanceCursor)
      in case (pageCount, instanceEPODOC) of
          (Just pg, Just iEPODOC) -> Just (pg, iEPODOC)
          (_, _)            -> Nothing