{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP                 #-}
module Devel
    ( devel
    ) where


import qualified Distribution.Simple.Utils as D
import qualified Distribution.Verbosity as D
import qualified Distribution.PackageDescription.Parse as D
import qualified Distribution.PackageDescription as D

import           Control.Concurrent (forkIO, threadDelay)
import qualified Control.Exception as Ex
import           Control.Monad (forever)

import qualified Data.List as L
import qualified Data.Map as Map
import           Data.Maybe (listToMaybe)

import           System.Directory (createDirectoryIfMissing, removeFile,
                                           getDirectoryContents)
import           System.Exit (exitFailure, exitSuccess)
import           System.Posix.Types (EpochTime)
import           System.PosixCompat.Files (modificationTime, getFileStatus)
import           System.Process (runCommand, terminateProcess,
                                           waitForProcess, rawSystem)

import Build (recompDeps, getDeps,findHaskellFiles)

#if __GLASGOW_HASKELL__ >= 700
#define ST st
#else
#define ST $st
#endif

lockFile :: FilePath
lockFile = "dist/devel-terminate"

writeLock :: IO ()
writeLock = do
    createDirectoryIfMissing True "dist"
    writeFile lockFile ""

removeLock :: IO ()
removeLock = try_ (removeFile lockFile)

devel :: Bool -> IO ()
devel isCabalDev = do
    writeLock

    putStrLn "Yesod devel server. Press ENTER to quit"
    _ <- forkIO $ do
      cabal <- D.findPackageDesc "."
      gpd   <- D.readPackageDescription D.normal cabal

      checkCabalFile gpd

      _ <- if isCabalDev
        then rawSystem "cabal-dev"
            [ "configure"
            , "--cabal-install-arg=-fdevel" -- legacy
            , "--cabal-install-arg=-flibrary-only"
            , "--disable-library-profiling"
            ]
        else rawSystem "cabal"
            [ "configure"
            , "-fdevel" -- legacy
            , "-flibrary-only"
            , "--disable-library-profiling"
            ]

      mainLoop isCabalDev

    _ <- getLine
    writeLock
    exitSuccess



mainLoop :: Bool -> IO ()
mainLoop isCabalDev = forever $ do
   putStrLn "Rebuilding application..."

   recompDeps

   list <- getFileList
   _ <- if isCabalDev
     then rawSystem "cabal-dev" ["build"]
     else rawSystem "cabal"     ["build"]

   removeLock
   pkg <- pkgConfigs isCabalDev
   let start = concat ["runghc ", pkg, " devel.hs"]
   putStrLn $ "Starting development server: " ++ start
   ph <- runCommand start
   watchTid <- forkIO . try_ $ do
     watchForChanges list
     putStrLn "Stopping development server..."
     writeLock
     threadDelay 1000000
     putStrLn "Terminating development server..."
     terminateProcess ph
   ec <- waitForProcess ph
   putStrLn $ "Exit code: " ++ show ec
   Ex.throwTo watchTid (userError "process finished")
   watchForChanges list

try_ :: forall a. IO a -> IO ()
try_ x = (Ex.try x :: IO (Either Ex.SomeException a)) >> return ()

pkgConfigs :: Bool -> IO String
pkgConfigs isDev
  | isDev = do
      devContents <- getDirectoryContents "cabal-dev"
      let confs = filter isConfig devContents
      return . unwords $ inplacePkg :
             map ("-package-confcabal-dev/"++) confs
  | otherwise = return inplacePkg
  where
    inplacePkg = "-package-confdist/package.conf.inplace"
    isConfig dir = "packages-" `L.isPrefixOf` dir &&
                   ".conf"     `L.isSuffixOf` dir

type FileList = Map.Map FilePath EpochTime

getFileList :: IO FileList
getFileList = do
    files <- findHaskellFiles "."
    deps <- getDeps
    let files' = files ++ map fst (Map.toList deps)
    fmap Map.fromList $ flip mapM files' $ \f -> do
        fs <- getFileStatus f
        return (f, modificationTime fs)

watchForChanges :: FileList -> IO ()
watchForChanges list = do
    newList <- getFileList
    if list /= newList
      then return ()
      else threadDelay 1000000 >> watchForChanges list

checkCabalFile :: D.GenericPackageDescription -> IO ()
checkCabalFile gpd = case D.condLibrary gpd of
    Nothing -> do
      putStrLn "Error: incorrect cabal file, no library"
      exitFailure
    Just ct ->
      case lookupDevelLib ct of
        Nothing   -> do
          putStrLn "Error: no development flag found in your configuration file. Expected a 'library-only' flag or the older 'devel' flag"
          exitFailure
        Just dLib ->
         case (D.hsSourceDirs . D.libBuildInfo) dLib of
           []     -> return ()
           ["."]  -> return ()
           _      ->
             putStrLn $ "WARNING: yesod devel may not work correctly with " ++
                        "custom hs-source-dirs"

lookupDevelLib :: D.CondTree D.ConfVar c a -> Maybe a
lookupDevelLib ct = listToMaybe . map (\(_,x,_) -> D.condTreeData x) .
                    filter isDevelLib . D.condTreeComponents  $ ct
  where
    isDevelLib ((D.Var (D.Flag (D.FlagName f))), _, _) = f `elem` ["library-only", "devel"]
    isDevelLib _                                       = False


