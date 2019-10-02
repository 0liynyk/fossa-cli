
module Strategy.Python.Util
  ( requirementParser
  , buildGraph

  , Version(..)
  , Marker(..)
  , MarkerOp(..)
  , Operator(..)
  , Req(..)
  ) where

import Prologue hiding (many, some)

import           Data.Char
import qualified Data.Text as T
import           Text.Megaparsec
import           Text.Megaparsec.Char
import qualified Text.URI as URI

import           Effect.GraphBuilder (unfold)
import qualified Graph as G

buildGraph :: [Req] -> G.Graph
buildGraph xs = unfold xs (const []) toDependency
  where
  toDependency req =
    G.Dependency { dependencyType = G.PipType
                 , dependencyName = depName req
                 , dependencyVersion = depVersion req
                 , dependencyLocations = []
                 }

  depName (NameReq nm _ _ _) = nm
  depName (UrlReq nm _ _ _) = nm

  depVersion (NameReq _ _ (Just (x:_)) _) = Just (versionVersion x) -- TODO: lol. this mirrors current cli
  depVersion _ = Nothing

type Parser = Parsec Void Text

data Version = Version
  { versionOperator :: Operator
  , versionVersion  :: Text
  } deriving (Eq, Ord, Show, Generic)

data Marker =
    MarkerAnd  Marker Marker
  | MarkerOr   Marker Marker
  | MarkerExpr Text MarkerOp Text -- marker_var marker_op marker_var
  deriving (Eq, Ord, Show, Generic)

data MarkerOp =
    MarkerIn
  | MarkerNotIn
  | MarkerOperator Operator
  deriving (Eq, Ord, Show, Generic)

data Operator = Operator Text -- TODO: actual sum type
  deriving (Eq, Ord, Show, Generic)

data Req =
    NameReq Text (Maybe [Text]) (Maybe [Version]) (Maybe Marker) -- name, extras, ...
  | UrlReq Text (Maybe [Text]) URI.URI (Maybe Marker) -- name extras, ...
  deriving (Eq, Ord, Show, Generic)

-- TODO: move this to test suite
test :: IO ()
test = traverse_ (parseTest requirementParser)
  [ "A", "A.B-C_D", "aa", "name", "name<=1", "name>=3", "name>=3,<2", "name@http://foo.com", "name [fred,bar] @ http://foo.com ; python_version=='2.7'", "name[quux, strange];python_version<'2.7' and platform_version=='2'", "name; os_name=='a' or os_name=='b'", "name; os_name=='a' and os_name=='b' or os_name=='c'", "name; os_name=='a' and (os_name=='b' or os_name=='c')", "name; os_name=='a' or os_name=='b' and os_name=='c'", "name; (os_name=='a' or os_name=='b') and os_name=='c'" ]

-- grammar extracted from https://www.python.org/dev/peps/pep-0508/
requirementParser :: Parser Req
requirementParser = specification
  where
  oneOfS = asum . map string

  whitespace = takeWhileP (Just "whitespace") (\c -> c == ' ' || c == '\t') :: Parser Text
  whitespace1 = label "whitespace1" $ takeWhile1P (Just "whitespace1") isSpace :: Parser Text
  letterOrDigit = label "letterOrDigit" $ satisfy (\c -> isLetter c || isDigit c)

  version_cmp = label "version_cmp" $ whitespace *> (Operator <$> oneOfS ["<=", "<", "!=", "===", "==", ">=", ">", "~="])

  version = label "version" $ whitespace *> some (letterOrDigit <|> oneOf ['-', '_', '.', '*', '+', '!'])
  version_one = label "version_one" $ Version <$> version_cmp <*> (T.pack <$> version) <* whitespace
  version_many = label "version_many" $ version_one `sepBy` (whitespace *> char ',')
  versionspec = label "versionspec" $ between (char '(') (char ')') version_many <|> version_many
  urlspec = label "urlspec" $ char '@' *> whitespace *> URI.parser

  marker_op = label "marker_op" $
              MarkerOperator <$> version_cmp
          <|> MarkerIn <$ whitespace <* string "in"
          <|> MarkerNotIn <$ whitespace <* string "not" <* whitespace1 <* string "in"
  python_str_c :: Parser Char
  python_str_c = label "python_str_c" $
                 satisfy isSpace <|> satisfy isLetter <|> satisfy isDigit
             <|> oneOf ("().{}-_*#:;,/?[]!~`@$%^&=+|<>" :: String)

  dquote :: Parser Char
  dquote = label "dquote" $ char '\"'
  squote :: Parser Char
  squote = label "squote" $ char '\''

  python_str = label "python_str" $
               (squote *> many (python_str_c <|> dquote) <* squote)
           <|> (dquote *> many (python_str_c <|> squote) <* dquote)

  env_var :: Parser Text
  env_var = label "env_var" $ oneOfS ["python_version", "python_full_version",
                 "os_name", "sys_platform", "platform_release",
                 "platform_system", "platform_version",
                 "platform_machine", "platform_python_implementation",
                 "implementation_name", "implementation_version", "extra"]
  marker_var :: Parser Text
  marker_var = label "marker_var" $ whitespace *> (env_var <|> fmap T.pack python_str)
  marker_expr = label "marker_expr" $
                MarkerExpr <$> marker_var <*> marker_op <*> marker_var
            <|> whitespace *> char '(' *> marker_or <* char ')'

  marker_and = label "marker_and" $
               try (MarkerAnd <$> marker_expr <* whitespace <* string "and" <*> marker_expr)
           <|> marker_expr

  marker_or :: Parser Marker
  marker_or = label "marker_or" $
              try (MarkerOr <$> marker_and <* whitespace <* string "or" <*> marker_and)
          <|> marker_and

  marker = label "marker" $ marker_or
  quoted_marker = label "quoted_marker" $ char ';' *> whitespace *> marker

  identifier_end = label "identifier_end" $
                   pure <$> letterOrDigit
               <|> do
                  special <- many (oneOf ['-', '_', '.'])
                  lod     <- letterOrDigit
                  pure (special ++ [lod])
  identifier = label "identifier" $ (:) <$> letterOrDigit <*> (concat <$> many identifier_end)
  name = label "name" $ T.pack <$> identifier
  extras_list :: Parser [Text]
  extras_list = label "extras_list" $
                (T.pack <$> identifier)
                `sepBy` (whitespace *> char ',' <* whitespace)
  extras = label "extras" $ char '[' *> whitespace *> optional extras_list <* whitespace <* char ']'

  name_req = label "name_req" $ NameReq <$> name <* whitespace <*> (join <$> optional extras) <* whitespace <*> optional versionspec <* whitespace <*> optional quoted_marker
  url_req = label "url_req" $ UrlReq <$> name <* whitespace <*> (join <$> optional extras) <* whitespace <*> urlspec <* whitespace1 <*> optional quoted_marker

  specification = label "specification" $ whitespace *> (try url_req <|> name_req) <* whitespace