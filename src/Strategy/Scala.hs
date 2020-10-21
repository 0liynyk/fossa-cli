-- | The scala strategy leverages the machinery from maven-pom.
--
-- Sbt has a command to export pom files, with one caveat -- in multi-project
-- setups, parent/child relationships are not present in the generated poms.
--
-- The only non-trivial logic that exists in this strategy is adding edges
-- between poms in the maven "global closure", before building the individual
-- multi-project closures.
module Strategy.Scala
  ( discover,
  )
where

import qualified Algebra.Graph.AdjacencyMap as AM
import Control.Carrier.Diagnostics
import Control.Monad.IO.Class (MonadIO)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.Text.Lazy.Encoding (decodeUtf8)
import Discovery.Walk
import Effect.Exec
import Effect.Logger hiding (group)
import Effect.ReadFS
import Path
import Strategy.Maven (mkProject)
import Strategy.Maven.Pom.Closure (MavenProjectClosure, buildProjectClosures)
import Strategy.Maven.Pom.PomFile (MavenCoordinate (..), Pom (..))
import Strategy.Maven.Pom.Resolver (GlobalClosure (..), buildGlobalClosure)
import Types

discover :: (Has Exec sig m, Has ReadFS sig m, Has Logger sig m, MonadIO m) => Path Abs Dir -> m [DiscoveredProject]
discover dir = map (mkProject dir) <$> findProjects dir

pathToText :: Path ar fd -> Text
pathToText = T.pack . toFilePath

findProjects :: (Has Exec sig m, Has ReadFS sig m, Has Logger sig m, MonadIO m) => Path Abs Dir -> m [MavenProjectClosure]
findProjects = walk' $ \dir _ files -> do
  case findFileNamed "build.sbt" files of
    Nothing -> pure ([], WalkContinue)
    Just _ -> do

      projectsRes <-
        runDiagnostics
          . context ("getting sbt projects rooted at " <> pathToText dir)
          $ genPoms dir

      case projectsRes of
        Left err -> do
          logWarn $ renderFailureBundle err
          pure ([], WalkContinue)
        Right projects -> pure (resultValue projects, WalkSkipAll)

makePomCmd :: Command
makePomCmd =
  Command
    { cmdName = "sbt",
      cmdArgs = ["makePom", "-no-colors"],
      cmdAllowErr = Never
    }

genPoms :: (Has Exec sig m, Has ReadFS sig m, Has Diagnostics sig m) => Path Abs Dir -> m [MavenProjectClosure]
genPoms projectDir = do
  stdoutBL <- execThrow projectDir makePomCmd

  -- stdout for "sbt makePom" looks something like:
  --
  -- > ...
  -- > [info] Wrote /absolute/path/to/pom.xml
  -- > [info] Wrote /absolute/path/to/other/pom.xml
  -- > ...
  let stdoutLText = decodeUtf8 stdoutBL
      stdout = TL.toStrict stdoutLText
      --
      stdoutLines :: [Text]
      stdoutLines = T.lines stdout
      --
      pomLines :: [Text]
      pomLines = catMaybes $ map (T.stripPrefix "[info] Wrote ") stdoutLines
      --
      pomLocations :: Maybe [Path Abs File]
      pomLocations = traverse (parseAbsFile . T.unpack) pomLines

  case pomLocations of
    Nothing -> fatalText ("Could not parse pom paths from:\n" <> T.unlines pomLines)
    Just [] -> fatalText ("No sbt projects found")
    Just paths -> do
      globalClosure <- buildGlobalClosure paths

      -- The pom files generated by sbt do not include the proper <parent> references.
      -- We need to introduce these edges ourselves.
      let pomEdges :: AM.AdjacencyMap MavenCoordinate
          pomEdges =
            AM.edges
              [ (parentPom, childPom)
                | -- build references to any pom
                  parentPom <- AM.vertexList (globalGraph globalClosure),
                  -- from any other pom
                  childPom <- AM.vertexList (globalGraph globalClosure),
                  parentPom /= childPom,
                  -- when the other pom has it as a dependency
                  Just (_, pom) <- [M.lookup childPom (globalPoms globalClosure)],
                  let deps = M.keys (pomDependencies pom),
                  any
                    ( \(group, artifact) ->
                        coordGroup parentPom == group && coordArtifact parentPom == artifact
                    )
                    deps
              ]
          globalClosure' = globalClosure {globalGraph = AM.overlay pomEdges (globalGraph globalClosure)}
          projects = buildProjectClosures projectDir globalClosure'

      pure projects