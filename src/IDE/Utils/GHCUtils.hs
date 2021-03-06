{-# OPTIONS_GHC -XCPP -fno-warn-orphans #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Utils.GHCUtils
-- Copyright   :  2007-2011 Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GPL
--
-- Maintainer  :  Jutaro <jutaro@leksah.org>
-- Stability   :  provisional
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------
module IDE.Utils.GHCUtils (
    inGhcIO
,   getInstalledPackageInfos
,   findFittingPackages
,   myParseModule
,   myParseHeader
) where

#if MIN_VERSION_Cabal(1,8,0)
#else
import UniqFM (eltsUFM)
#endif
import Distribution.Simple (withinRange,PackageIdentifier(..),Dependency(..))
#if MIN_VERSION_Cabal(1,8,0)
import qualified Distribution.InstalledPackageInfo as IPI  (sourcePackageId)
#else
import qualified Distribution.InstalledPackageInfo as IPI  (package)
#endif
import GHC
import DriverPipeline(preprocess)
import StringBuffer (StringBuffer(..),hGetStringBuffer)
import FastString (mkFastString)
import Lexer (mkPState,ParseResult(..),getMessages,unP)
import Outputable (ppr)
#if MIN_VERSION_ghc(7,2,0)
import ErrUtils (dumpIfSet_dyn,printBagOfErrors,printBagOfWarnings,errorsFound,mkPlainErrMsg,showPass,ErrMsg(..))
import Control.Monad (unless)
#else
import ErrUtils (dumpIfSet_dyn,printErrorsAndWarnings,mkPlainErrMsg,showPass,ErrMsg(..))
#endif
import PackageConfig (PackageConfig)
import Data.Foldable (maximumBy)
import qualified Parser as P (parseModule,parseHeader)
import HscStats (ppSourceStats)
#if MIN_VERSION_ghc(7,2,0)
import GhcMonad (Ghc(..))
import SrcLoc (mkRealSrcLoc)
#else
import HscTypes (Ghc(..))
#endif
import IDE.Utils.FileUtils (getSysLibDir)
import DynFlags (dopt_set)
import System.Log.Logger(debugM)
import Control.Monad.IO.Class (MonadIO(..), MonadIO)

-- this should not be repeated here, why is it necessary?
instance MonadIO Ghc where
  liftIO ioA = Ghc $ \_ -> ioA

inGhcIO :: [String] -> [DynFlag] -> (DynFlags -> Ghc a) -> IO a
inGhcIO flags' udynFlags ghcAct = do
    debugM "leksah-server" $ "inGhcIO called with: " ++ show flags'
    libDir         <-   getSysLibDir
--    (restFlags, _) <-   parseStaticFlags (map noLoc flags')
    runGhc (Just libDir) $ do
        dynflags  <- getSessionDynFlags
        let dynflags' = foldl (\ flags'' flag' -> dopt_set flags'' flag') dynflags udynFlags
        let dynflags'' = dynflags' {
            hscTarget = HscNothing,
            ghcMode   = CompManager,
            ghcLink   = NoLink
            }
        dynflags''' <- parseGhcFlags dynflags'' (map noLoc flags') flags'
        res <- defaultCleanupHandler dynflags''' $ do
            setSessionDynFlags dynflags'''
            ghcAct dynflags'''
        unload
        return res
    where
        parseGhcFlags :: DynFlags -> [Located String]
                  -> [String] -> Ghc DynFlags
        parseGhcFlags dynflags flags_ _origFlags = do
        (dynflags', rest, _) <- parseDynamicFlags dynflags flags_
        if not (null rest)
            then do
                liftIO $ debugM "leksah-server" ("No dynamic GHC options: " ++ (unwords (map unLoc rest)))
                return dynflags'
            else return dynflags'

-- | Unload whatever is currently loaded.
unload :: Ghc ()
unload = do
   setTargets []
   load LoadAllTargets
   return ()

getInstalledPackageInfos :: Ghc [PackageConfig]
getInstalledPackageInfos = do
    dflags1         <-  getSessionDynFlags
    setSessionDynFlags $ dopt_set dflags1 Opt_ReadUserPackageConf
    pkgInfos        <-  case pkgDatabase dflags1 of
                            Nothing -> return []
#if MIN_VERSION_Cabal(1,8,0)
                            Just fm -> return fm
#else
                            Just fm -> return (eltsUFM fm)
#endif
    return pkgInfos

findFittingPackages :: [Dependency] -> Ghc [PackageIdentifier]
findFittingPackages dependencyList = do
    knownPackages   <-  getInstalledPackageInfos
#if MIN_VERSION_Cabal(1,8,0)
    let packages    =   map IPI.sourcePackageId knownPackages
#else
    let packages    =   map IPI.package knownPackages
#endif
    return (concatMap (fittingKnown packages) dependencyList)
    where
    fittingKnown packages (Dependency dname versionRange) =
        let filtered =  filter (\ (PackageIdentifier name version) ->
                                    name == dname && withinRange version versionRange)
                        packages
        in  if length filtered > 1
                then [maximumBy (\a b -> compare (pkgVersion a) (pkgVersion b)) filtered]
                else filtered

 ---------------------------------------------------------------------
--  | Parser function copied here, because it is not exported

myParseModule :: DynFlags -> FilePath -> Maybe StringBuffer
              -> IO (Either ErrMsg (Located (HsModule RdrName)))
myParseModule dflags src_filename maybe_src_buf
 =    --------------------------  Parser  ----------------
      showPass dflags "Parser" >>
      {-# SCC "Parser" #-} do

	-- sometimes we already have the buffer in memory, perhaps
	-- because we needed to parse the imports out of it, or get the
	-- module name.
      buf' <- case maybe_src_buf of
		Just b  -> return b
		Nothing -> hGetStringBuffer src_filename

#if MIN_VERSION_ghc(7,2,0)
      let loc  = mkRealSrcLoc (mkFastString src_filename) 1 0
#else
      let loc  = mkSrcLoc (mkFastString src_filename) 1 0
#endif

#if MIN_VERSION_ghc(7,0,1)
      case unP P.parseModule (mkPState dflags buf' loc) of {
#else
      case unP P.parseModule (mkPState buf' loc dflags) of {
#endif

	PFailed span' err -> return (Left (mkPlainErrMsg span' err));

	POk pst rdr_module -> do {

#if MIN_VERSION_ghc(7,2,0)
      let {ms@(warnings, errors) = getMessages pst};
      printBagOfErrors dflags errors;
      unless (errorsFound dflags ms) $ printBagOfWarnings dflags warnings;
#else
      let {ms = getMessages pst};
      printErrorsAndWarnings dflags ms;
#endif
      -- when (errorsFound dflags ms) $ exitWith (ExitFailure 1);

      dumpIfSet_dyn dflags Opt_D_dump_parsed "Parser" (ppr rdr_module) ;

      dumpIfSet_dyn dflags Opt_D_source_stats "Source Statistics"
			   (ppSourceStats False rdr_module) ;

      return (Right rdr_module)
	-- ToDo: free the string buffer later.
      }}

myParseHeader :: FilePath -> String -> [String] -> IO (Either String (HsModule RdrName))
myParseHeader fp _str opts = inGhcIO (opts++["-cpp"]) [] $ \ _dynFlags -> do
    session   <- getSession
#if MIN_VERSION_ghc(7,2,0)
    (dynFlags',fp')    <-  liftIO $ preprocess session (fp,Nothing)
#else
    (dynFlags',fp')    <-  preprocess session (fp,Nothing)
#endif
    liftIO $ do
        stringBuffer  <-  hGetStringBuffer fp'
        parseResult   <-  myParseModuleHeader dynFlags' fp (Just stringBuffer)
        case parseResult of
            Right (L _ mod') -> return (Right mod')
            Left errMsg         -> do
                let str =  "Failed to parse " ++ show errMsg
                return (Left str)

 ---------------------------------------------------------------------
--  | Parser function copied here, because it is not exported

myParseModuleHeader :: DynFlags -> FilePath -> Maybe StringBuffer
              -> IO (Either ErrMsg (Located (HsModule RdrName)))
myParseModuleHeader dflags src_filename maybe_src_buf
 =    --------------------------  Parser  ----------------
      showPass dflags "Parser" >>
      {-# SCC "Parser" #-} do

	-- sometimes we already have the buffer in memory, perhaps
	-- because we needed to parse the imports out of it, or get the
	-- module name.
      buf' <- case maybe_src_buf of
		Just b  -> return b
		Nothing -> hGetStringBuffer src_filename

#if MIN_VERSION_ghc(7,2,0)
      let loc  = mkRealSrcLoc (mkFastString src_filename) 1 0
#else
      let loc  = mkSrcLoc (mkFastString src_filename) 1 0
#endif

#if MIN_VERSION_ghc(7,0,1)
      case unP P.parseHeader (mkPState dflags buf' loc) of {
#else
      case unP P.parseHeader (mkPState buf' loc dflags) of {
#endif

	PFailed span' err -> return (Left (mkPlainErrMsg span' err));

	POk pst rdr_module -> do {

#if MIN_VERSION_ghc(7,2,0)
      let {ms@(warnings, errors) = getMessages pst};
      printBagOfErrors dflags errors;
      unless (errorsFound dflags ms) $ printBagOfWarnings dflags warnings;
#else
      let {ms = getMessages pst};
      printErrorsAndWarnings dflags ms;
#endif
      -- when (errorsFound dflags ms) $ exitWith (ExitFailure 1);

      dumpIfSet_dyn dflags Opt_D_dump_parsed "Parser" (ppr rdr_module) ;

      dumpIfSet_dyn dflags Opt_D_source_stats "Source Statistics"
			   (ppSourceStats False rdr_module) ;

      return (Right rdr_module)
	-- ToDo: free the string buffer later.
      }}

