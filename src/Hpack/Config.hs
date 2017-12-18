{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RankNTypes #-}
module Hpack.Config (
  packageConfig
, readPackageConfig
, renamePackage
, packageDependencies
, package
, section
, Package(..)
, Dependencies(..)
, DependencyVersion(..)
, SourceDependency(..)
, GitRef
, GitUrl
, GhcOption
, CustomSetup(..)
, Section(..)
, Library(..)
, Executable(..)
, Conditional(..)
, Flag(..)
, SourceRepository(..)
#ifdef TEST
, renameDependencies
, Empty(..)
, getModules
, pathsModuleFromPackageName
, determineModules
, BuildType(..)

, LibrarySection(..)
, fromLibrarySectionInConditional
#endif
) where

import           Control.Applicative
import           Control.Monad
import           Data.Data
import           Data.Bifunctor
import           Data.Bifoldable
import           Data.Bitraversable
import           Data.Map.Lazy (Map)
import qualified Data.Map.Lazy as Map
import qualified Data.HashMap.Lazy as HashMap
import           Data.List (nub, (\\), sortBy)
import           Data.Maybe
import           Data.Monoid hiding (Product)
import           Data.Ord
import           Data.String
import           Data.Text (Text)
import qualified Data.Text as T
import           System.Directory
import           System.FilePath
import           Data.Functor.Identity
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Writer
import           Control.Monad.Trans.Except
import           Control.Monad.IO.Class

import           Hpack.Syntax.Util
import           Hpack.Syntax.UnknownFields
import           Hpack.Util hiding (expandGlobs)
import qualified Hpack.Util as Util
import qualified Hpack.Yaml as Yaml
import           Hpack.Dependency

package :: String -> String -> Package
package name version = Package {
    packageName = name
  , packageVersion = version
  , packageSynopsis = Nothing
  , packageDescription = Nothing
  , packageHomepage = Nothing
  , packageBugReports = Nothing
  , packageCategory = Nothing
  , packageStability = Nothing
  , packageAuthor = []
  , packageMaintainer = []
  , packageCopyright = []
  , packageBuildType = Simple
  , packageLicense = Nothing
  , packageLicenseFile = []
  , packageTestedWith = Nothing
  , packageFlags = []
  , packageExtraSourceFiles = []
  , packageExtraDocFiles = []
  , packageDataFiles = []
  , packageSourceRepository = Nothing
  , packageCustomSetup = Nothing
  , packageLibrary = Nothing
  , packageInternalLibraries = mempty
  , packageExecutables = mempty
  , packageTests = mempty
  , packageBenchmarks = mempty
  }

renamePackage :: String -> Package -> Package
renamePackage name p@Package{..} = p {
    packageName = name
  , packageExecutables = fmap (renameDependencies packageName name) packageExecutables
  , packageTests = fmap (renameDependencies packageName name) packageTests
  , packageBenchmarks = fmap (renameDependencies packageName name) packageBenchmarks
  }

renameDependencies :: String -> String -> Section a -> Section a
renameDependencies old new sect@Section{..} = sect {sectionDependencies = (Dependencies . Map.fromList . map rename . Map.toList . unDependencies) sectionDependencies, sectionConditionals = map renameConditional sectionConditionals}
  where
    rename dep@(name, version)
      | name == old = (new, version)
      | otherwise = dep

    renameConditional :: Conditional (Section a) -> Conditional (Section a)
    renameConditional (Conditional condition then_ else_) = Conditional condition (renameDependencies old new then_) (renameDependencies old new <$> else_)

packageDependencies :: Package -> [(String, DependencyVersion)]
packageDependencies Package{..} = nub . sortBy (comparing (lexicographically . fst)) $
     (concatMap deps packageExecutables)
  ++ (concatMap deps packageTests)
  ++ (concatMap deps packageBenchmarks)
  ++ maybe [] deps packageLibrary
  where
    deps xs = [(name, version) | (name, version) <- (Map.toList . unDependencies . sectionDependencies) xs]

section :: a -> Section a
section a = Section a [] mempty [] [] [] [] [] [] [] [] [] [] [] [] [] [] [] [] [] Nothing [] mempty

packageConfig :: FilePath
packageConfig = "package.yaml"

data CustomSetupSection = CustomSetupSection {
  customSetupSectionDependencies :: Maybe Dependencies
} deriving (Eq, Show, Generic)

instance HasFieldNames CustomSetupSection

instance FromJSON CustomSetupSection where
  parseJSON = genericParseJSON

data LibrarySection = LibrarySection {
  librarySectionExposed :: Maybe Bool
, librarySectionExposedModules :: Maybe (List String)
, librarySectionOtherModules :: Maybe (List String)
, librarySectionReexportedModules :: Maybe (List String)
, librarySectionSignatures :: Maybe (List String)
} deriving (Eq, Show, Generic)

emptyLibrarySection :: LibrarySection
emptyLibrarySection = LibrarySection Nothing Nothing Nothing Nothing Nothing

instance HasFieldNames LibrarySection

instance FromJSON LibrarySection where
  parseJSON = genericParseJSON

data ExecutableSection = ExecutableSection {
  executableSectionMain :: Maybe FilePath
, executableSectionOtherModules :: Maybe (List String)
} deriving (Eq, Show, Generic)

emptyExecutableSection :: ExecutableSection
emptyExecutableSection = ExecutableSection Nothing Nothing

instance HasFieldNames ExecutableSection

instance FromJSON ExecutableSection where
  parseJSON = genericParseJSON

data CommonOptions capture cSources jsSources a = CommonOptions {
  commonOptionsSourceDirs :: Maybe (List FilePath)
, commonOptionsDependencies :: Maybe Dependencies
, commonOptionsPkgConfigDependencies :: Maybe (List String)
, commonOptionsDefaultExtensions :: Maybe (List String)
, commonOptionsOtherExtensions :: Maybe (List String)
, commonOptionsGhcOptions :: Maybe (List GhcOption)
, commonOptionsGhcProfOptions :: Maybe (List GhcProfOption)
, commonOptionsGhcjsOptions :: Maybe (List GhcjsOption)
, commonOptionsCppOptions :: Maybe (List CppOption)
, commonOptionsCcOptions :: Maybe (List CcOption)
, commonOptionsCSources :: cSources
, commonOptionsJsSources :: jsSources
, commonOptionsExtraLibDirs :: Maybe (List FilePath)
, commonOptionsExtraLibraries :: Maybe (List FilePath)
, commonOptionsExtraFrameworksDirs :: Maybe (List FilePath)
, commonOptionsFrameworks :: Maybe (List String)
, commonOptionsIncludeDirs :: Maybe (List FilePath)
, commonOptionsInstallIncludes :: Maybe (List FilePath)
, commonOptionsLdOptions :: Maybe (List LdOption)
, commonOptionsBuildable :: Maybe Bool
, commonOptionsWhen :: Maybe (List (ConditionalSection capture cSources jsSources a))
, commonOptionsBuildTools :: Maybe Dependencies
} deriving (Functor, Generic)

instance (Monoid cSources, Monoid jsSources) => Monoid (CommonOptions capture cSources jsSources a) where
  mempty = CommonOptions {
    commonOptionsSourceDirs = Nothing
  , commonOptionsDependencies = Nothing
  , commonOptionsPkgConfigDependencies = Nothing
  , commonOptionsDefaultExtensions = Nothing
  , commonOptionsOtherExtensions = Nothing
  , commonOptionsGhcOptions = Nothing
  , commonOptionsGhcProfOptions = Nothing
  , commonOptionsGhcjsOptions = Nothing
  , commonOptionsCppOptions = Nothing
  , commonOptionsCcOptions = Nothing
  , commonOptionsCSources = mempty
  , commonOptionsJsSources = mempty
  , commonOptionsExtraLibDirs = Nothing
  , commonOptionsExtraLibraries = Nothing
  , commonOptionsExtraFrameworksDirs = Nothing
  , commonOptionsFrameworks = Nothing
  , commonOptionsIncludeDirs = Nothing
  , commonOptionsInstallIncludes = Nothing
  , commonOptionsLdOptions = Nothing
  , commonOptionsBuildable = Nothing
  , commonOptionsWhen = Nothing
  , commonOptionsBuildTools = Nothing
  }
  mappend a b = CommonOptions {
    commonOptionsSourceDirs = commonOptionsSourceDirs a <> commonOptionsSourceDirs b
  , commonOptionsDependencies = commonOptionsDependencies b <> commonOptionsDependencies a
  , commonOptionsPkgConfigDependencies = commonOptionsPkgConfigDependencies a <> commonOptionsPkgConfigDependencies b
  , commonOptionsDefaultExtensions = commonOptionsDefaultExtensions a <> commonOptionsDefaultExtensions b
  , commonOptionsOtherExtensions = commonOptionsOtherExtensions a <> commonOptionsOtherExtensions b
  , commonOptionsGhcOptions = commonOptionsGhcOptions a <> commonOptionsGhcOptions b
  , commonOptionsGhcProfOptions = commonOptionsGhcProfOptions a <> commonOptionsGhcProfOptions b
  , commonOptionsGhcjsOptions = commonOptionsGhcjsOptions a <> commonOptionsGhcjsOptions b
  , commonOptionsCppOptions = commonOptionsCppOptions a <> commonOptionsCppOptions b
  , commonOptionsCcOptions = commonOptionsCcOptions a <> commonOptionsCcOptions b
  , commonOptionsCSources = commonOptionsCSources a <> commonOptionsCSources b
  , commonOptionsJsSources = commonOptionsJsSources a <> commonOptionsJsSources b
  , commonOptionsExtraLibDirs = commonOptionsExtraLibDirs a <> commonOptionsExtraLibDirs b
  , commonOptionsExtraLibraries = commonOptionsExtraLibraries a <> commonOptionsExtraLibraries b
  , commonOptionsExtraFrameworksDirs = commonOptionsExtraFrameworksDirs a <> commonOptionsExtraFrameworksDirs b
  , commonOptionsFrameworks = commonOptionsFrameworks a <> commonOptionsFrameworks b
  , commonOptionsIncludeDirs = commonOptionsIncludeDirs a <> commonOptionsIncludeDirs b
  , commonOptionsInstallIncludes = commonOptionsInstallIncludes a <> commonOptionsInstallIncludes b
  , commonOptionsLdOptions = commonOptionsLdOptions a <> commonOptionsLdOptions b
  , commonOptionsBuildable = commonOptionsBuildable b <|> commonOptionsBuildable a
  , commonOptionsWhen = commonOptionsWhen a <> commonOptionsWhen b
  , commonOptionsBuildTools = commonOptionsBuildTools b <> commonOptionsBuildTools a
  }

type ParseCommonOptions = CommonOptions CaptureUnknownFields ParseCSources ParseJsSources

instance HasFieldNames (ParseCommonOptions a)

instance (FromJSON a, HasFieldNames a) => FromJSON (ParseCommonOptions a) where
  parseJSON = genericParseJSON

type ParseCSources = Maybe (List FilePath)
type ParseJsSources = Maybe (List FilePath)

type CSources = [FilePath]
type JsSources = [FilePath]

type WithCommonOptions capture cSources jsSources a = Product (CommonOptions capture cSources jsSources a) a

data Traverse m capture capture_ cSources cSources_ jsSources jsSources_ = Traverse {
  traverseCapture :: forall a. capture a -> m (capture_ a)
, traverseCSources :: cSources -> m cSources_
, traverseJsSources :: jsSources -> m jsSources_
}

defaultTraverse :: Applicative m => Traverse m capture capture cSources cSources jsSources jsSources
defaultTraverse = Traverse {
  traverseCapture = pure
, traverseCSources = pure
, traverseJsSources = pure
}

type Traversal t = forall m capture capture_ cSources cSources_ jsSources jsSources_. (Monad m, Traversable capture_)
  => Traverse m capture capture_ cSources cSources_ jsSources jsSources_
  -> t capture cSources jsSources
  -> m (t capture_ cSources_ jsSources_)

type Traversal_ t = forall m capture capture_ cSources cSources_ jsSources jsSources_ a. (Monad m, Traversable capture_)
  => Traverse m capture capture_ cSources cSources_ jsSources jsSources_
  -> t capture cSources jsSources a
  -> m (t capture_ cSources_ jsSources_ a)

traverseCommonOptions :: Traversal_ CommonOptions
traverseCommonOptions t@Traverse{..} c@CommonOptions{..} = do
  cSources <- traverseCSources commonOptionsCSources
  jsSources <- traverseJsSources commonOptionsJsSources
  xs <- traverse (traverse (traverseConditionalSection t)) commonOptionsWhen
  return c {
      commonOptionsCSources = cSources
    , commonOptionsJsSources = jsSources
    , commonOptionsWhen = xs
    }

traverseConditionalSection :: Traversal_ ConditionalSection
traverseConditionalSection t@Traverse{..} = \ case
  ThenElseConditional c -> ThenElseConditional <$> (traverseCapture c >>= traverse (traverseThenElse t))
  FlatConditional c -> FlatConditional <$> (traverseCapture c >>= traverse (bitraverse (traverseWithCommonOptions t) return))

traverseThenElse :: Traversal_ ThenElse
traverseThenElse t@Traverse{..} c@ThenElse{..} = do
  then_ <- traverseCapture thenElseThen >>= traverse (traverseWithCommonOptions t)
  else_ <- traverseCapture thenElseElse >>= traverse (traverseWithCommonOptions t)
  return c{thenElseThen = then_, thenElseElse = else_}

traverseWithCommonOptions :: Traversal_ WithCommonOptions
traverseWithCommonOptions t = bitraverse (traverseCommonOptions t) return

data Product a b = Product a b
  deriving (Eq, Show)

instance Bifunctor Product where
  bimap fa fb (Product a b) = Product (fa a) (fb b)

instance Bifoldable Product where
  bifoldMap = bifoldMapDefault

instance Bitraversable Product where
  bitraverse fa fb (Product a b) = Product <$> fa a <*> fb b

instance (FromJSON a, FromJSON b) => FromJSON (Product a b) where
  parseJSON value = Product <$> parseJSON value <*> parseJSON value

instance (HasFieldNames a, HasFieldNames b) => HasFieldNames (Product a b) where
  fieldNames Proxy =
       fieldNames (Proxy :: Proxy a)
    ++ fieldNames (Proxy :: Proxy b)
  ignoreUnderscoredUnknownFields Proxy =
       ignoreUnderscoredUnknownFields (Proxy :: Proxy a)
    || ignoreUnderscoredUnknownFields (Proxy :: Proxy b)

data ConditionalSection capture cSources jsSources a =
    ThenElseConditional (capture (ThenElse capture cSources jsSources a))
  | FlatConditional (capture (Product (WithCommonOptions capture cSources jsSources a) Condition))

instance Functor capture => Functor (ConditionalSection capture cSources jsSources) where
  fmap f = \ case
    ThenElseConditional c -> ThenElseConditional (fmap f <$> c)
    FlatConditional c -> FlatConditional (bimap (bimap (fmap f) f) id <$> c)

type ParseConditionalSection = ConditionalSection CaptureUnknownFields ParseCSources ParseJsSources

instance (FromJSON a, HasFieldNames a) => FromJSON (ParseConditionalSection a) where
  parseJSON v
    | hasKey "then" v || hasKey "else" v = ThenElseConditional <$> parseJSON v
    | otherwise = FlatConditional <$> parseJSON v

hasKey :: Text -> Value -> Bool
hasKey key (Object o) = HashMap.member key o
hasKey _ _ = False

newtype Condition = Condition {
  conditionCondition :: String
} deriving (Eq, Show, Generic)

instance FromJSON Condition where
  parseJSON = genericParseJSON

instance HasFieldNames Condition

data ThenElse capture cSources jsSources a = ThenElse {
  _thenElseCondition :: String
, thenElseThen :: capture (WithCommonOptions capture cSources jsSources a)
, thenElseElse :: capture (WithCommonOptions capture cSources jsSources a)
} deriving Generic

instance Functor capture => Functor (ThenElse capture cSources jsSources) where
  fmap f c@ThenElse{..} = c{thenElseThen = map_ thenElseThen, thenElseElse = map_ thenElseElse}
    where
      map_ = fmap (bimap (fmap f) f)

type ParseThenElse = ThenElse CaptureUnknownFields ParseCSources ParseJsSources

instance HasFieldNames (ParseThenElse a)

instance (FromJSON a, HasFieldNames a) => FromJSON (ParseThenElse a) where
  parseJSON = genericParseJSON

data Empty = Empty
  deriving (Eq, Show)

instance FromJSON Empty where
  parseJSON _ = return Empty

instance HasFieldNames Empty where
  fieldNames _ = []

-- From Cabal the library, copied here to avoid a dependency on Cabal.
data BuildType
  = Simple
  | Configure
  | Make
  | Custom
  deriving (Eq, Show, Generic)

instance FromJSON BuildType where
  parseJSON = withText "String" $ \case
    "Simple"    -> return Simple
    "Configure" -> return Configure
    "Make"      -> return Make
    "Custom"    -> return Custom
    _           -> fail "build-type must be one of: Simple, Configure, Make, Custom"

type SectionConfig capture cSources jsSources a = capture (WithCommonOptions capture cSources jsSources a)

data PackageConfig capture cSources jsSources = PackageConfig {
  packageConfigName :: Maybe String
, packageConfigVersion :: Maybe String
, packageConfigSynopsis :: Maybe String
, packageConfigDescription :: Maybe String
, packageConfigHomepage :: Maybe (Maybe String)
, packageConfigBugReports :: Maybe (Maybe String)
, packageConfigCategory :: Maybe String
, packageConfigStability :: Maybe String
, packageConfigAuthor :: Maybe (List String)
, packageConfigMaintainer :: Maybe (List String)
, packageConfigCopyright :: Maybe (List String)
, packageConfigBuildType :: Maybe BuildType
, packageConfigLicense :: Maybe String
, packageConfigLicenseFile :: Maybe (List String)
, packageConfigTestedWith :: Maybe String
, packageConfigFlags :: Maybe (Map String (capture FlagSection))
, packageConfigExtraSourceFiles :: Maybe (List FilePath)
, packageConfigExtraDocFiles :: Maybe (List FilePath)
, packageConfigDataFiles :: Maybe (List FilePath)
, packageConfigGithub :: Maybe Text
, packageConfigGit :: Maybe String
, packageConfigCustomSetup :: Maybe (capture CustomSetupSection)
, packageConfigLibrary :: Maybe (SectionConfig capture cSources jsSources LibrarySection)
, packageConfigInternalLibraries :: Maybe (Map String (SectionConfig capture cSources jsSources LibrarySection))
, packageConfigExecutable :: Maybe (SectionConfig capture cSources jsSources ExecutableSection)
, packageConfigExecutables :: Maybe (Map String (SectionConfig capture cSources jsSources ExecutableSection))
, packageConfigTests :: Maybe (Map String (SectionConfig capture cSources jsSources ExecutableSection))
, packageConfigBenchmarks :: Maybe (Map String (SectionConfig capture cSources jsSources ExecutableSection))
} deriving Generic

traversePackageConfig :: Traversal PackageConfig
traversePackageConfig t@Traverse{..} p@PackageConfig{..} = do
  flags <- traverse (traverse traverseCapture) packageConfigFlags
  customSetup <- traverse traverseCapture packageConfigCustomSetup
  library <- traverse (traverseSectionConfig t) packageConfigLibrary
  internalLibraries <- traverseNamedConfigs t packageConfigInternalLibraries
  executable <- traverse (traverseSectionConfig t) packageConfigExecutable
  executables <- traverseNamedConfigs t packageConfigExecutables
  tests <- traverseNamedConfigs t packageConfigTests
  benchmarks <- traverseNamedConfigs t packageConfigBenchmarks
  return p {
      packageConfigFlags = flags
    , packageConfigCustomSetup = customSetup
    , packageConfigLibrary = library
    , packageConfigInternalLibraries = internalLibraries
    , packageConfigExecutable = executable
    , packageConfigExecutables = executables
    , packageConfigTests = tests
    , packageConfigBenchmarks = benchmarks
    }
  where
    traverseNamedConfigs = traverse . traverse . traverseSectionConfig

traverseSectionConfig :: Traversal_ SectionConfig
traverseSectionConfig t = traverseCapture t >=> traverse (traverseWithCommonOptions t)

type ParsePackageConfig = PackageConfig CaptureUnknownFields ParseCSources ParseJsSources

instance HasFieldNames ParsePackageConfig where
  ignoreUnderscoredUnknownFields _ = True

instance FromJSON ParsePackageConfig where
  parseJSON value = handleNullValues <$> genericParseJSON value
    where
      handleNullValues :: ParsePackageConfig -> ParsePackageConfig
      handleNullValues =
          ifNull "homepage" (\p -> p {packageConfigHomepage = Just Nothing})
        . ifNull "bug-reports" (\p -> p {packageConfigBugReports = Just Nothing})

      ifNull :: String -> (a -> a) -> a -> a
      ifNull name f
        | isNull name value = f
        | otherwise = id

isNull :: String -> Value -> Bool
isNull name value = case parseMaybe p value of
  Just Null -> True
  _ -> False
  where
    p = parseJSON >=> (.: fromString name)

decodeYaml :: FromJSON a => FilePath -> Warnings (ExceptT String IO) a
decodeYaml = lift . ExceptT . Yaml.decodeYaml

readPackageConfig :: FilePath -> IO (Either String (Package, [String]))
readPackageConfig file = runExceptT $ runWriterT $ do
  config <- decodeYaml file
  dir <- liftIO $ takeDirectory <$> canonicalizePath file
  toPackage dir config

data Package = Package {
  packageName :: String
, packageVersion :: String
, packageSynopsis :: Maybe String
, packageDescription :: Maybe String
, packageHomepage :: Maybe String
, packageBugReports :: Maybe String
, packageCategory :: Maybe String
, packageStability :: Maybe String
, packageAuthor :: [String]
, packageMaintainer :: [String]
, packageCopyright :: [String]
, packageBuildType :: BuildType
, packageLicense :: Maybe String
, packageLicenseFile :: [FilePath]
, packageTestedWith :: Maybe String
, packageFlags :: [Flag]
, packageExtraSourceFiles :: [FilePath]
, packageExtraDocFiles :: [FilePath]
, packageDataFiles :: [FilePath]
, packageSourceRepository :: Maybe SourceRepository
, packageCustomSetup :: Maybe CustomSetup
, packageLibrary :: Maybe (Section Library)
, packageInternalLibraries :: Map String (Section Library)
, packageExecutables :: Map String (Section Executable)
, packageTests :: Map String (Section Executable)
, packageBenchmarks :: Map String (Section Executable)
} deriving (Eq, Show)

data CustomSetup = CustomSetup {
  customSetupDependencies :: Dependencies
} deriving (Eq, Show)

data Library = Library {
  libraryExposed :: Maybe Bool
, libraryExposedModules :: [String]
, libraryOtherModules :: [String]
, libraryReexportedModules :: [String]
, librarySignatures :: [String]
} deriving (Eq, Show)

data Executable = Executable {
  executableMain :: Maybe FilePath
, executableOtherModules :: [String]
} deriving (Eq, Show)

data Section a = Section {
  sectionData :: a
, sectionSourceDirs :: [FilePath]
, sectionDependencies :: Dependencies
, sectionPkgConfigDependencies :: [String]
, sectionDefaultExtensions :: [String]
, sectionOtherExtensions :: [String]
, sectionGhcOptions :: [GhcOption]
, sectionGhcProfOptions :: [GhcProfOption]
, sectionGhcjsOptions :: [GhcjsOption]
, sectionCppOptions :: [CppOption]
, sectionCcOptions :: [CcOption]
, sectionCSources :: [FilePath]
, sectionJsSources :: [FilePath]
, sectionExtraLibDirs :: [FilePath]
, sectionExtraLibraries :: [FilePath]
, sectionExtraFrameworksDirs :: [FilePath]
, sectionFrameworks :: [FilePath]
, sectionIncludeDirs :: [FilePath]
, sectionInstallIncludes :: [FilePath]
, sectionLdOptions :: [LdOption]
, sectionBuildable :: Maybe Bool
, sectionConditionals :: [Conditional (Section a)]
, sectionBuildTools :: Dependencies
} deriving (Eq, Show, Functor, Foldable, Traversable)

data Conditional a = Conditional {
  conditionalCondition :: String
, conditionalThen :: a
, conditionalElse :: Maybe a
} deriving (Eq, Show, Functor, Foldable, Traversable)

data FlagSection = FlagSection {
  _flagSectionDescription :: Maybe String
, _flagSectionManual :: Bool
, _flagSectionDefault :: Bool
} deriving (Eq, Show, Generic)

instance HasFieldNames FlagSection

instance FromJSON FlagSection where
  parseJSON = genericParseJSON

data Flag = Flag {
  flagName :: String
, flagDescription :: Maybe String
, flagManual :: Bool
, flagDefault :: Bool
} deriving (Eq, Show)

toFlag :: (String, FlagSection) -> Flag
toFlag (name, FlagSection description manual def) = Flag name description manual def

data SourceRepository = SourceRepository {
  sourceRepositoryUrl :: String
, sourceRepositorySubdir :: Maybe String
} deriving (Eq, Show)

type Config capture cSources jsSources =
  Product (CommonOptions capture cSources jsSources Empty) (PackageConfig capture cSources jsSources)

traverseConfig :: Traversal Config
traverseConfig t = bitraverse (traverseCommonOptions t) (traversePackageConfig t)

type ParseConfig = CaptureUnknownFields (Config CaptureUnknownFields ParseCSources ParseJsSources)

toPackage :: MonadIO m => FilePath -> ParseConfig -> Warnings m Package
toPackage dir = extractUnknownFieldWarnings >=> expandForeignSources dir >=> uncurry (toPackage_ dir) . globalOptionsToSection

globalOptionsToSection :: Config Identity CSources JsSources -> (Section Empty, PackageConfig Identity CSources JsSources)
globalOptionsToSection (Product (toSection . (`Product` Empty) -> global) c) = (global, c)

toPackage_ :: MonadIO m => FilePath -> Section Empty -> PackageConfig Identity CSources JsSources -> Warnings m Package
toPackage_ dir globalOptions PackageConfig{..} = do
  mLibrary <- liftIO $ mapM (toLibrary dir packageName_ globalOptions) mLibrarySection

  let
    executableSections :: Map String (Section ExecutableSection)
    (executableWarning, executableSections) = (warning, sections)
      where
        sections :: Map String (Section ExecutableSection)
        sections = case mExecutable of
          Just executable -> Map.fromList [(packageName_, executable)]
          Nothing -> executables

        warning = case mExecutable of
          Just _ | not (null executables) -> ["Ignoring field \"executables\" in favor of \"executable\""]
          _ -> []

        executables = toSections packageConfigExecutables

        mExecutable :: Maybe (Section ExecutableSection)
        mExecutable = toSectionI <$> packageConfigExecutable

  internalLibraries <- liftIO $ toInternalLibraries dir packageName_ globalOptions internalLibrariesSections
  executables <- liftIO $ toExecutables dir packageName_ globalOptions executableSections
  tests <- liftIO $ toExecutables dir packageName_ globalOptions testSections
  benchmarks <- liftIO $ toExecutables dir packageName_ globalOptions benchmarkSections

  licenseFileExists <- liftIO $ doesFileExist (dir </> "LICENSE")

  missingSourceDirs <- liftIO $ nub . sort <$> filterM (fmap not <$> doesDirectoryExist . (dir </>)) (
       maybe [] sectionSourceDirs mLibrary
    ++ concatMap sectionSourceDirs internalLibraries
    ++ concatMap sectionSourceDirs executables
    ++ concatMap sectionSourceDirs tests
    ++ concatMap sectionSourceDirs benchmarks
    )

  extraSourceFiles <- expandGlobs "extra-source-files" dir (fromMaybeList packageConfigExtraSourceFiles)
  extraDocFiles <- expandGlobs "extra-doc-files" dir (fromMaybeList packageConfigExtraDocFiles)
  dataFiles <- expandGlobs "data-files" dir (fromMaybeList packageConfigDataFiles)

  let defaultBuildType :: BuildType
      defaultBuildType = maybe Simple (const Custom) mCustomSetup

      configLicenseFiles :: Maybe (List String)
      configLicenseFiles = packageConfigLicenseFile <|> do
        guard licenseFileExists
        Just (List ["LICENSE"])

      pkg = Package {
        packageName = packageName_
      , packageVersion = fromMaybe "0.0.0" packageConfigVersion
      , packageSynopsis = packageConfigSynopsis
      , packageDescription = packageConfigDescription
      , packageHomepage = homepage
      , packageBugReports = bugReports
      , packageCategory = packageConfigCategory
      , packageStability = packageConfigStability
      , packageAuthor = fromMaybeList packageConfigAuthor
      , packageMaintainer = fromMaybeList packageConfigMaintainer
      , packageCopyright = fromMaybeList packageConfigCopyright
      , packageBuildType = fromMaybe defaultBuildType packageConfigBuildType
      , packageLicense = packageConfigLicense
      , packageLicenseFile = fromMaybeList configLicenseFiles
      , packageTestedWith = packageConfigTestedWith
      , packageFlags = flags
      , packageExtraSourceFiles = extraSourceFiles
      , packageExtraDocFiles = extraDocFiles
      , packageDataFiles = dataFiles
      , packageSourceRepository = sourceRepository
      , packageCustomSetup = mCustomSetup
      , packageLibrary = mLibrary
      , packageInternalLibraries = internalLibraries
      , packageExecutables = executables
      , packageTests = tests
      , packageBenchmarks = benchmarks
      }

  tell nameWarnings
  tell (formatMissingSourceDirs missingSourceDirs)
  tell executableWarning
  return pkg
  where
    nameWarnings :: [String]
    packageName_ :: String
    (nameWarnings, packageName_) = case packageConfigName of
      Nothing -> let inferredName = takeBaseName dir in
        (["Package name not specified, inferred " ++ show inferredName], inferredName)
      Just n -> ([], n)

    mCustomSetup :: Maybe CustomSetup
    mCustomSetup = toCustomSetup . runIdentity <$> packageConfigCustomSetup

    mLibrarySection :: Maybe (Section LibrarySection)
    mLibrarySection = toSectionI <$> packageConfigLibrary

    toSections :: Maybe (Map String (Identity (WithCommonOptions Identity CSources JsSources a))) -> Map String (Section a)
    toSections = fmap toSectionI . fromMaybe mempty

    internalLibrariesSections :: Map String (Section LibrarySection)
    internalLibrariesSections = toSections packageConfigInternalLibraries

    testSections :: Map String (Section ExecutableSection)
    testSections = toSections packageConfigTests

    benchmarkSections :: Map String (Section ExecutableSection)
    benchmarkSections = toSections packageConfigBenchmarks

    flags = map (toFlag . fmap runIdentity) $ toList packageConfigFlags

    toList :: Maybe (Map String a) -> [(String, a)]
    toList = Map.toList . fromMaybe mempty

    formatMissingSourceDirs = map f
      where
        f name = "Specified source-dir " ++ show name ++ " does not exist"

    sourceRepository :: Maybe SourceRepository
    sourceRepository = github <|> (`SourceRepository` Nothing) <$> packageConfigGit

    github :: Maybe SourceRepository
    github = parseGithub <$> packageConfigGithub
      where
        parseGithub :: Text -> SourceRepository
        parseGithub input = case map T.unpack $ T.splitOn "/" input of
          [user, repo, subdir] ->
            SourceRepository (githubBaseUrl ++ user ++ "/" ++ repo) (Just subdir)
          _ -> SourceRepository (githubBaseUrl ++ T.unpack input) Nothing

    homepage :: Maybe String
    homepage = case packageConfigHomepage of
      Just Nothing -> Nothing
      _ -> join packageConfigHomepage <|> fromGithub
      where
        fromGithub = (++ "#readme") . sourceRepositoryUrl <$> github

    bugReports :: Maybe String
    bugReports = case packageConfigBugReports of
      Just Nothing -> Nothing
      _ -> join packageConfigBugReports <|> fromGithub
      where
        fromGithub = (++ "/issues") . sourceRepositoryUrl <$> github

type Warnings m = WriterT [String] m

extractUnknownFieldWarnings :: forall m. Monad m => ParseConfig -> Warnings m (Config Identity ParseCSources ParseJsSources)
extractUnknownFieldWarnings = warnGlobal >=> bitraverse return warnSections
  where
    t :: Monad capture => Traverse capture capture Identity cSources cSources jsSources jsSources
    t = defaultTraverse{traverseCapture = fmap Identity}

    warnGlobal c = warnUnknownFields In "package description" (c >>= bitraverse (traverseCommonOptions t) return)

    warnSections :: ParsePackageConfig -> Warnings m (PackageConfig Identity ParseCSources ParseJsSources)
    warnSections p@PackageConfig{..} = do
      flags <- traverse (warnNamed For "flag" . fmap (traverseCapture t)) packageConfigFlags
      customSetup <- warnUnknownFields In "custom-setup section" (traverse (traverseCapture t) packageConfigCustomSetup)
      library <- warnUnknownFields In "library section" (traverse (traverseSectionConfig t) packageConfigLibrary)
      internalLibraries <- warnNamedSection "internal-libraries" packageConfigInternalLibraries
      executable <- warnUnknownFields In "executable section" (traverse (traverseSectionConfig t) packageConfigExecutable)
      executables <- warnNamedSection "executable" packageConfigExecutables
      tests <- warnNamedSection "test" packageConfigTests
      benchmarks <- warnNamedSection "benchmark" packageConfigBenchmarks
      return p {
          packageConfigFlags = flags
        , packageConfigCustomSetup = customSetup
        , packageConfigLibrary = library
        , packageConfigInternalLibraries = internalLibraries
        , packageConfigExecutable = executable
        , packageConfigExecutables = executables
        , packageConfigTests = tests
        , packageConfigBenchmarks = benchmarks
        }

    warnNamedSection
      :: String
      -> Maybe (Map String (SectionConfig CaptureUnknownFields cSources jsSources a))
      -> Warnings m (Maybe (Map String (SectionConfig Identity cSources jsSources a)))
    warnNamedSection sectionType = traverse (warnNamed In (sectionType ++ " section") . fmap (traverseSectionConfig t))

    warnNamed :: Preposition -> String -> Map String (CaptureUnknownFields a) -> Warnings m (Map String a)
    warnNamed preposition sect = fmap Map.fromList . mapM f . Map.toList
      where
        f (name, fields) = (,) name <$> (warnUnknownFields preposition (sect ++ " " ++ show name) fields)

    warnUnknownFields :: Preposition -> String -> CaptureUnknownFields a -> Warnings m a
    warnUnknownFields preposition name = fmap snd . bitraverse tell return . formatUnknownFields preposition name

expandForeignSources
  :: MonadIO m
  => FilePath
  -> Config Identity ParseCSources ParseJsSources
  -> Warnings m (Config Identity CSources JsSources)
expandForeignSources dir = traverseConfig t
  where
    t = defaultTraverse{
      traverseCSources = expand "c-sources"
    , traverseJsSources = expand "js-sources"
    }

    expand fieldName xs = do
      expandGlobs fieldName dir (fromMaybeList xs)

expandGlobs :: MonadIO m => String -> FilePath -> [String] -> Warnings m [FilePath]
expandGlobs name dir patterns = do
  (warnings, files) <- liftIO $ Util.expandGlobs name dir patterns
  tell warnings
  return files

toCustomSetup :: CustomSetupSection -> CustomSetup
toCustomSetup CustomSetupSection{..} = CustomSetup
  { customSetupDependencies = fromMaybe mempty customSetupSectionDependencies }

traverseSectionAndConditionals :: Monad m
  => (acc -> Section a -> m (acc, b))
  -> (acc -> Section a -> m (acc, b))
  -> acc
  -> Section a
  -> m (Section b)
traverseSectionAndConditionals fData fConditionals acc0 sect@Section{..} = do
  (acc1, x) <- fData acc0 sect
  xs <- traverseConditionals acc1 sectionConditionals
  return sect{sectionData = x, sectionConditionals = xs}
  where
    traverseConditionals = traverse . traverse . traverseSectionAndConditionals fConditionals fConditionals

getMentionedLibraryModules :: LibrarySection -> [String]
getMentionedLibraryModules LibrarySection{..} =
  fromMaybeList librarySectionExposedModules ++ fromMaybeList librarySectionOtherModules

listModules :: FilePath -> Section a -> IO [String]
listModules dir Section{..} = concat <$> mapM (getModules dir) sectionSourceDirs

inferModules ::
     FilePath
  -> String
  -> (a -> [String])
  -> (b -> [String])
  -> ([String] -> [String] -> a -> b)
  -> ([String] -> a -> b)
  -> Section a
  -> IO (Section b)
inferModules dir packageName_ getMentionedModules getInferredModules fromData fromConditionals = traverseSectionAndConditionals
  (fromConfigSection fromData [pathsModuleFromPackageName packageName_])
  (fromConfigSection (\ [] -> fromConditionals) [])
  []
  where
    fromConfigSection fromConfig pathsModule_ outerModules sect@Section{sectionData = conf} = do
      modules <- listModules dir sect
      let
        mentionedModules = concatMap getMentionedModules sect
        inferableModules = (modules \\ outerModules) \\ mentionedModules
        pathsModule = (pathsModule_ \\ outerModules) \\ mentionedModules
        r = fromConfig pathsModule inferableModules conf
      return (outerModules ++ getInferredModules r, r)

toLibrary :: FilePath -> String -> Section global -> Section LibrarySection -> IO (Section Library)
toLibrary dir name globalOptions =
    inferModules dir name getMentionedLibraryModules getLibraryModules fromLibrarySectionTopLevel fromLibrarySectionInConditional
  . mergeSections emptyLibrarySection globalOptions
  where
    getLibraryModules :: Library -> [String]
    getLibraryModules Library{..} = libraryExposedModules ++ libraryOtherModules

    fromLibrarySectionTopLevel pathsModule inferableModules LibrarySection{..} =
      Library librarySectionExposed exposedModules otherModules reexportedModules signatures
      where
        (exposedModules, otherModules) =
          determineModules pathsModule inferableModules librarySectionExposedModules librarySectionOtherModules
        reexportedModules = fromMaybeList librarySectionReexportedModules
        signatures = fromMaybeList librarySectionSignatures

determineModules :: [String] -> [String] -> Maybe (List String) -> Maybe (List String) -> ([String], [String])
determineModules pathsModule inferableModules mExposedModules mOtherModules = case (mExposedModules, mOtherModules) of
  (Nothing, Nothing) -> (inferableModules, pathsModule)
  _ -> (exposedModules, otherModules)
    where
      exposedModules = maybe (inferableModules \\ otherModules) fromList mExposedModules
      otherModules   = maybe ((inferableModules ++ pathsModule) \\ exposedModules) fromList mOtherModules

fromLibrarySectionInConditional :: [String] -> LibrarySection -> Library
fromLibrarySectionInConditional inferableModules lib@(LibrarySection _ exposedModules otherModules _ _) = do
  case (exposedModules, otherModules) of
    (Nothing, Nothing) -> (fromLibrarySectionPlain lib) {libraryOtherModules = inferableModules}
    _ -> fromLibrarySectionPlain lib

fromLibrarySectionPlain :: LibrarySection -> Library
fromLibrarySectionPlain LibrarySection{..} = Library {
    libraryExposed = librarySectionExposed
  , libraryExposedModules = fromMaybeList librarySectionExposedModules
  , libraryOtherModules = fromMaybeList librarySectionOtherModules
  , libraryReexportedModules = fromMaybeList librarySectionReexportedModules
  , librarySignatures = fromMaybeList librarySectionSignatures
  }

toInternalLibraries :: FilePath -> String -> Section global -> Map String (Section LibrarySection) -> IO (Map String (Section Library))
toInternalLibraries dir packageName_ globalOptions = traverse (toLibrary dir packageName_ globalOptions)

toExecutables :: FilePath -> String -> Section global -> Map String (Section ExecutableSection) -> IO (Map String (Section Executable))
toExecutables dir packageName_ globalOptions = traverse (toExecutable dir packageName_ globalOptions)

getMentionedExecutableModules :: ExecutableSection -> [String]
getMentionedExecutableModules ExecutableSection{..} =
  fromMaybeList executableSectionOtherModules ++ maybe [] return (executableSectionMain >>= toModule . splitDirectories)

toExecutable :: FilePath -> String -> Section global -> Section ExecutableSection -> IO (Section Executable)
toExecutable dir packageName_ globalOptions =
    inferModules dir packageName_ getMentionedExecutableModules executableOtherModules fromExecutableSection (fromExecutableSection [])
  . expandMain
  . mergeSections emptyExecutableSection globalOptions
  where
    fromExecutableSection :: [String] -> [String] -> ExecutableSection -> Executable
    fromExecutableSection pathsModule inferableModules ExecutableSection{..} =
      (Executable executableSectionMain otherModules)
      where
        otherModules = maybe (inferableModules ++ pathsModule) fromList executableSectionOtherModules

expandMain :: Section ExecutableSection -> Section ExecutableSection
expandMain = flatten . expand
  where
    expand :: Section ExecutableSection -> Section ([GhcOption], ExecutableSection)
    expand = fmap go
      where
        go exec@ExecutableSection{..} =
          let
            (mainSrcFile, ghcOptions) = maybe (Nothing, []) (first Just . parseMain) executableSectionMain
          in
            (ghcOptions, exec{executableSectionMain = mainSrcFile})

    flatten :: Section ([GhcOption], ExecutableSection) -> Section ExecutableSection
    flatten sect@Section{sectionData = (ghcOptions, exec), ..} = sect{
        sectionData = exec
      , sectionGhcOptions = sectionGhcOptions ++ ghcOptions
      , sectionConditionals = map (fmap flatten) sectionConditionals
      }

mergeSections :: a -> Section global -> Section a -> Section a
mergeSections a globalOptions options
  = Section {
    sectionData = sectionData options
  , sectionSourceDirs = sectionSourceDirs globalOptions ++ sectionSourceDirs options
  , sectionDefaultExtensions = sectionDefaultExtensions globalOptions ++ sectionDefaultExtensions options
  , sectionOtherExtensions = sectionOtherExtensions globalOptions ++ sectionOtherExtensions options
  , sectionGhcOptions = sectionGhcOptions globalOptions ++ sectionGhcOptions options
  , sectionGhcProfOptions = sectionGhcProfOptions globalOptions ++ sectionGhcProfOptions options
  , sectionGhcjsOptions = sectionGhcjsOptions globalOptions ++ sectionGhcjsOptions options
  , sectionCppOptions = sectionCppOptions globalOptions ++ sectionCppOptions options
  , sectionCcOptions = sectionCcOptions globalOptions ++ sectionCcOptions options
  , sectionCSources = sectionCSources globalOptions ++ sectionCSources options
  , sectionJsSources = sectionJsSources globalOptions ++ sectionJsSources options
  , sectionExtraLibDirs = sectionExtraLibDirs globalOptions ++ sectionExtraLibDirs options
  , sectionExtraLibraries = sectionExtraLibraries globalOptions ++ sectionExtraLibraries options
  , sectionExtraFrameworksDirs = sectionExtraFrameworksDirs globalOptions ++ sectionExtraFrameworksDirs options
  , sectionFrameworks = sectionFrameworks globalOptions ++ sectionFrameworks options
  , sectionIncludeDirs = sectionIncludeDirs globalOptions ++ sectionIncludeDirs options
  , sectionInstallIncludes = sectionInstallIncludes globalOptions ++ sectionInstallIncludes options
  , sectionLdOptions = sectionLdOptions globalOptions ++ sectionLdOptions options
  , sectionBuildable = sectionBuildable options <|> sectionBuildable globalOptions
  , sectionDependencies = sectionDependencies options <> sectionDependencies globalOptions
  , sectionPkgConfigDependencies = sectionPkgConfigDependencies globalOptions ++ sectionPkgConfigDependencies options
  , sectionConditionals = map (fmap (a <$)) (sectionConditionals globalOptions) ++ sectionConditionals options
  , sectionBuildTools = sectionBuildTools options <> sectionBuildTools globalOptions
  }

toSectionI :: Identity (WithCommonOptions Identity CSources JsSources a) -> Section a
toSectionI = toSection . runIdentity

toSection :: WithCommonOptions Identity CSources JsSources a -> Section a
toSection (Product CommonOptions{..} a) = Section {
        sectionData = a
      , sectionSourceDirs = fromMaybeList commonOptionsSourceDirs
      , sectionDefaultExtensions = fromMaybeList commonOptionsDefaultExtensions
      , sectionOtherExtensions = fromMaybeList commonOptionsOtherExtensions
      , sectionGhcOptions = fromMaybeList commonOptionsGhcOptions
      , sectionGhcProfOptions = fromMaybeList commonOptionsGhcProfOptions
      , sectionGhcjsOptions = fromMaybeList commonOptionsGhcjsOptions
      , sectionCppOptions = fromMaybeList commonOptionsCppOptions
      , sectionCcOptions = fromMaybeList commonOptionsCcOptions
      , sectionCSources = commonOptionsCSources
      , sectionJsSources = commonOptionsJsSources
      , sectionExtraLibDirs = fromMaybeList commonOptionsExtraLibDirs
      , sectionExtraLibraries = fromMaybeList commonOptionsExtraLibraries
      , sectionExtraFrameworksDirs = fromMaybeList commonOptionsExtraFrameworksDirs
      , sectionFrameworks = fromMaybeList commonOptionsFrameworks
      , sectionIncludeDirs = fromMaybeList commonOptionsIncludeDirs
      , sectionInstallIncludes = fromMaybeList commonOptionsInstallIncludes
      , sectionLdOptions = fromMaybeList commonOptionsLdOptions
      , sectionBuildable = commonOptionsBuildable
      , sectionDependencies = fromMaybe mempty commonOptionsDependencies
      , sectionPkgConfigDependencies = fromMaybeList commonOptionsPkgConfigDependencies
      , sectionConditionals = conditionals
      , sectionBuildTools = fromMaybe mempty commonOptionsBuildTools
      }
  where
    conditionals = map toConditional (fromMaybeList commonOptionsWhen)

    toConditional :: ConditionalSection Identity CSources JsSources a -> Conditional (Section a)
    toConditional x = case x of
      FlatConditional (Identity (Product sect c)) -> Conditional (conditionCondition c) (toSection sect) Nothing
      ThenElseConditional (Identity (ThenElse condition then_ else_)) -> Conditional condition (toSectionI then_) (Just $ toSectionI else_)

pathsModuleFromPackageName :: String -> String
pathsModuleFromPackageName name = "Paths_" ++ map f name
  where
    f '-' = '_'
    f x = x

getModules :: FilePath -> FilePath -> IO [String]
getModules dir src_ = sort <$> do
  exists <- doesDirectoryExist (dir </> src_)
  if exists
    then do
      src <- canonicalizePath (dir </> src_)
      removeSetup src . toModules <$> getModuleFilesRecursive src
    else return []
  where
    toModules :: [[FilePath]] -> [String]
    toModules = catMaybes . map toModule

    removeSetup :: FilePath -> [String] -> [String]
    removeSetup src
      | src == dir = filter (/= "Setup")
      | otherwise = id

fromMaybeList :: Maybe (List a) -> [a]
fromMaybeList = maybe [] fromList
