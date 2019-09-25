
{-# language QuasiQuotes #-}

module Config
  ( ConfiguredStrategy(..)
  , loadConfig
  ) where

import           Data.Traversable
import           Data.Aeson
import           Data.Map (Map)
import qualified Data.Map as M
import           Data.Text (Text)
import qualified Data.Yaml as Yaml
import           GHC.Generics (Generic)
import           Path
import           Polysemy
import           Polysemy.Error

import           Discovery
import           Effect.ReadFS
import           Strategy

configPath :: Path Rel File
configPath = [relfile|.strategies.yml|]

loadConfig :: Members '[Error DiscoverErr, ReadFS] r => Map String SomeStrategy -> Path Abs Dir -> Sem r [ConfiguredStrategy]
loadConfig strategiesByName dir = do
  exists <- doesFileExist (dir </> configPath)
  if not exists
    then pure []
    else do
      contents <- readContents configPath

      -- code is disgusting, but it's using three different failure types:
      -- - Either ParseException (yaml)
      -- - Maybe
      -- - Result (aeson)
      case Yaml.decodeEither' contents of
        Left err -> throw (ConfigParseFailed (Yaml.prettyPrintParseException err))
        Right Config{configStrategies} -> do
          for configStrategies $ \ConfigStrategy{..} -> do
            case M.lookup configStrategyName strategiesByName of
              Nothing -> throw (UnknownStrategyName configStrategyName)
              Just (SomeStrategy strat) -> case fromJSON configStrategyOptions of
                Error err -> throw (StrategyOptionsParseFailed configStrategyName err)
                Success a -> pure $ ConfiguredStrategy strat a

data ConfiguredStrategy where
  ConfiguredStrategy :: (FromJSON options, ToJSON options) => !(Strategy options) -> !options -> ConfiguredStrategy

instance ToJSON ConfiguredStrategy where
  toJSON (ConfiguredStrategy strategy options) = object ["name" .= strategyName strategy, "options" .= options]

{-
instance FromJSON ConfiguredStrategy where
  parseJSON = withObject "ConfiguredStrategy" $ \obj -> do
    name    <- obj .: "name"
    options <- obj .: "options"
    case M.lookup name strategiesByName of
      Nothing -> fail ("Couldn't find strategy with name " <> T.unpack name)
      Just (SomeStrategy strat) -> case fromJSON options of
        Error e   -> fail e
        Success a -> pure $ ConfiguredStrategy strat a
-}

data Config = Config
  { configStrategies :: [ConfigStrategy]
  } deriving (Generic)

instance FromJSON Config where
  parseJSON = withObject "Config" $ \obj -> Config <$> obj .: "strategies"

instance FromJSON ConfigStrategy where
  parseJSON = withObject "ConfigStrategy" $ \obj ->
    ConfigStrategy <$> obj .: "name"
                   <*> obj .:? "options"
                           .!= object [] -- default to empty object

data ConfigStrategy = ConfigStrategy
  { configStrategyName    :: String
  , configStrategyOptions :: Value
  } deriving (Show, Generic)