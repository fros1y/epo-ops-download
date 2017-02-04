module Main where

import           Data.String.Conversions (convertString)
import qualified EPODOC                  as EPODOC
import qualified EPOOPS                  as EPOOPS
import           Options
import           Protolude
import           System.IO               (BufferMode (NoBuffering),
                                          hSetBuffering, stdout)
import Network.HTTP.Types.Status
import Network.HTTP.Client
import           Text.Printf        (printf)

data PatentOptions = PatentOptions
  {
    consumerKey :: [Char],
    secretKey   :: [Char],
    strict      :: Bool,
    debug       :: Bool
  }

instance Options PatentOptions where
  defineOptions = pure PatentOptions
    <*> simpleOption "consumerKey" ""
        "Consumer Key from EPO OPS"
    <*> simpleOption "secretKey" ""
        "Secret Key from EPO OPS"
    <*> simpleOption "strict" True
        "Limit retrived documents to specific EPODOC input"
    <*> simpleOption "debug" False
        "Display debugging messages"

pageProgress :: EPOOPS.PageProgress
pageProgress total curr = printf "[%i/%i] " curr total

perInstance :: EPOOPS.InstanceListing -> EPOOPS.OPSSession ()
perInstance epodocInstance = do
  liftIO $ printf "Downloading %s: " $ EPODOC.formatAsEPODOC $ snd epodocInstance
  EPOOPS.downloadEPODOCInstance pageProgress epodocInstance
  liftIO $ printf "Success!\n"

main :: IO ()
main = runCommand $ \opts args -> do
    hSetBuffering stdout NoBuffering
    when (length args == 0) $ do
      printf "You must enter at least one patent document number.\n"
      exitFailure
    let parse = EPODOC.parseToEPODOC . convertString $ headDef "" args
        onNotFoundError (StatusCodeException s _ _)
          | (statusCode s) == 404 = Just ("Not Found" :: [Char])
          | otherwise = Nothing
        onNotFoundError _ = Nothing
        credentials = EPOOPS.Credentials (consumerKey opts) (secretKey opts)
        logLevel = if debug opts then EPOOPS.LevelDebug else EPOOPS.LevelWarn
    case parse of
      (Left err) -> do
        printf "Input format error: %s\n" (show err :: [Char])
      (Right epodoc) ->
        handleJust onNotFoundError (putStrLn) $
          void $ EPOOPS.withOPSSession credentials logLevel $ do
            instances <- EPOOPS.getEPODOCInstances (strict opts) epodoc
            forM_ instances perInstance
