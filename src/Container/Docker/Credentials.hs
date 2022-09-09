{-# LANGUAGE TemplateHaskell #-}

module Container.Docker.Credentials (
  useCredentialFromConfig,

  -- * For Testing
  DockerConfig (..),
  DockerCredentialHelperGetResponse (..),
) where

import Container.Docker.SourceParser (RegistryImageSource (RegistryImageSource))
import Control.Algebra (Has)
import Control.Effect.Diagnostics (Diagnostics)
import Control.Effect.Lift (Lift, sendIO)
import Data.Aeson (FromJSON (parseJSON), withObject, (.!=), (.:), (.:?))
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Effect.Exec (
  AllowErr (Never),
  Command (Command, cmdAllowErr, cmdArgs, cmdName),
  Exec,
  execJson',
 )
import Effect.ReadFS (ReadFS, getCurrentDir, readContentsJson)
import Path (Abs, File, Path, mkRelFile, (</>))
import Path.IO qualified as PIO

data DockerConfig = DockerConfig
  { credStore :: Text
  , -- With Docker 1.13.0 or greater, Docker lets you configure different credential helpers
    -- for different registries. These are stored in Credential Helpers.
    -- Refer to: https://docs.docker.com/engine/reference/commandline/login/#credential-helpers
    credHelpers :: Map Text Text
  }
  deriving (Show, Eq, Ord)

instance FromJSON DockerConfig where
  parseJSON = withObject "DockerConfig" $ \o ->
    DockerConfig
      <$> o .: "credsStore"
      <*> o .:? "credHelpers" .!= mempty

getCredentialStore :: Text -> DockerConfig -> Text
getCredentialStore host (DockerConfig defaultStore hostToCred) =
  Map.findWithDefault defaultStore host withoutUriScheme
  where
    -- Docker Config considers quay.io and https://quay.io to be equivalent
    -- for credentials. Remove URI scheme to ensure compatibility
    withoutUriScheme :: Map Text Text
    withoutUriScheme = Map.mapKeys (withoutHttp . withoutHttps) hostToCred

    withoutHttp :: Text -> Text
    withoutHttp = Text.replace "http://" ""

    withoutHttps :: Text -> Text
    withoutHttps = Text.replace "https://" ""

-- | Uses Credentials from Credential Helpers and Config File.
--
-- Retrieves Docker Config File From:
--  - Linux & macOs: $HOME/.docker/config.json
--  - Windows: %USERPROFILE%/.docker/config.json
--
-- Identifies credential store, and uses credential store, to
-- retrieve server's credentials.
useCredentialFromConfig ::
  ( Has ReadFS sig m
  , Has Exec sig m
  , Has (Lift IO) sig m
  , Has Diagnostics sig m
  ) =>
  RegistryImageSource ->
  m (RegistryImageSource)
useCredentialFromConfig (RegistryImageSource host scheme _ repo repoRef arch) = do
  homeDir <- sendIO PIO.getHomeDir

  let configFile :: Path Abs File
      configFile = homeDir </> $(mkRelFile ".docker/config.json")

  dockerConfig <- readContentsJson configFile

  let credStore = getCredentialStore host dockerConfig
  (user, pass) <- getCredential host credStore

  pure $
    RegistryImageSource
      host
      scheme
      (Just (user, pass))
      repo
      repoRef
      arch

-- | Gets credential of a host from a given credential store.
--
-- It uses docker-credential-helper utilities. For example,
-- for a desktop credStore, invokes following command:
--
--  >> echo "index.docker.io" | docker-credential-desktop get
--  {
--    "ServerURL": "https://index.docker.io",
--    "Username": "username",
--    "Secret": "secret"
--  }
--
-- Per convention, executables name are `docker-credential-<credStore>`.
--
-- Refer to,
--  https://docs.docker.com/engine/reference/commandline/login/#credentials-store
--
-- These credential helpers by default are accessible from $PATH.
--
-- -
getCredential ::
  ( Has ReadFS sig m
  , Has Exec sig m
  , Has Diagnostics sig m
  ) =>
  Text ->
  Text ->
  m (Text, Text)
getCredential host credStore = do
  dir <- getCurrentDir
  (DockerCredentialHelperGetResponse user pass) <- execJson' dir (execCredHelper credStore) host
  pure (user, pass)
  where
    execCredHelper :: Text -> Command
    execCredHelper credHelperName =
      Command
        { cmdName = "docker-credential-" <> credHelperName
        , cmdArgs = ["get"]
        , cmdAllowErr = Never
        }

data DockerCredentialHelperGetResponse = DockerCredentialHelperGetResponse
  { registryUsername :: Text
  , registrySecret :: Text
  }
  deriving (Show, Eq, Ord)

instance FromJSON DockerCredentialHelperGetResponse where
  parseJSON = withObject "" $ \o ->
    DockerCredentialHelperGetResponse
      <$> o .: "Username"
      <*> o .: "Secret"