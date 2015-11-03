{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Icicle.Repl (
    ReplError (..)
  , P.QueryTop', P.QueryTop'T, P.Program'
  , annotOfError
  , sourceParse
  , sourceDesugar
  , sourceReify
  , sourceCheck
  , sourceConvert
  , checkAvalanche
  , P.coreAvalanche
  , coreFlatten
  , P.simpAvalanche
  , P.simpFlattened
  , P.sourceInline
  , P.coreSimp
  , readFacts
  , readIcicleLibrary

  , DictionaryLoadType(..)
  , loadDictionary
  ) where

import qualified Icicle.Avalanche.Program         as AP
import qualified Icicle.Avalanche.Prim.Flat       as APF

import qualified Icicle.Common.Base               as CommonBase
import qualified Icicle.Common.Annot              as CommonAnnotation
import qualified Icicle.Common.Fresh              as Fresh
import           Icicle.Data
import qualified Icicle.Dictionary                as D
import           Icicle.Internal.Pretty
import qualified Icicle.Pipeline                  as P
import qualified Icicle.Serial                    as S
import qualified Icicle.Simulator                 as S
import qualified Icicle.Source.Checker            as SC
import qualified Icicle.Source.Parser             as SP
import qualified Icicle.Source.Query              as SQ
import qualified Icicle.Source.Type               as ST
import qualified Icicle.Storage.Dictionary.TextV1 as DictionaryText
import qualified Icicle.Storage.Dictionary.Toml   as DictionaryToml

import           P

import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Either
import           X.Control.Monad.Trans.Either

import           Data.Either.Combinators
import           Data.Text                        (Text)
import qualified Data.Text                        as T
import qualified Data.Text.IO                     as T
import qualified Data.Traversable                 as TR

import           System.IO

import qualified Text.ParserCombinators.Parsec    as Parsec

data ReplError
 = ReplErrorCompileCore      (P.CompileError  Parsec.SourcePos SP.Variable ())
 | ReplErrorCompileAvalanche (P.CompileError  ()               SP.Variable APF.Prim)
 | ReplErrorRuntime          (S.SimulateError ()               SP.Variable)
 | ReplErrorDictionaryLoad   DictionaryToml.DictionaryImportError
 | ReplErrorDecode           S.ParseError
 deriving (Show)

annotOfError :: ReplError -> Maybe Parsec.SourcePos
annotOfError e
 = case e of
    ReplErrorCompileCore d
     -> P.annotOfError d
    ReplErrorCompileAvalanche _
     -> Nothing
    ReplErrorRuntime _
     -> Nothing
    ReplErrorDictionaryLoad _
     -> Nothing
    ReplErrorDecode  _
     -> Nothing

instance Pretty ReplError where
 pretty e
  = case e of
     ReplErrorCompileCore d
      -> pretty d
     ReplErrorCompileAvalanche d
      -> pretty d
     ReplErrorRuntime d
      -> "Runtime error:" <> line
      <> indent 2 (pretty d)
     ReplErrorDictionaryLoad d
      -> "Dictionary load error:" <> line
      <> indent 2 (pretty d)
     ReplErrorDecode d
      -> "Decode error:" <> line
      <> indent 2 (pretty d)

type Var        = SP.Variable

data DictionaryLoadType
 = DictionaryLoadTextV1 FilePath
 | DictionaryLoadToml   FilePath
 deriving (Eq, Ord, Show)

--------------------------------------------------------------------------------

-- * Check and Convert

sourceParse :: Text -> Either ReplError P.QueryTop'
sourceParse = mapLeft ReplErrorCompileCore . P.sourceParseQT "repl"

sourceDesugar :: P.QueryTop' -> Either ReplError P.QueryTop'
sourceDesugar = mapLeft ReplErrorCompileCore . P.sourceDesugarQT

sourceReify :: P.QueryTop'T -> P.QueryTop'T
sourceReify = P.sourceReifyQT

sourceCheck :: D.Dictionary -> P.QueryTop' -> Either ReplError (P.QueryTop'T, ST.Type Var)
sourceCheck d
 = mapLeft ReplErrorCompileCore . P.sourceCheckQT d

sourceConvert :: D.Dictionary -> P.QueryTop'T -> Either ReplError P.Program'
sourceConvert d
 = mapLeft ReplErrorCompileCore . P.sourceConvert d

coreFlatten :: P.Program' -> Either ReplError (AP.Program () Var APF.Prim)
coreFlatten
 = mapLeft ReplErrorCompileAvalanche . P.coreFlatten

checkAvalanche :: AP.Program () Var APF.Prim
               -> Either ReplError (AP.Program (CommonAnnotation.Annot ()) Var APF.Prim)
checkAvalanche
 = mapLeft ReplErrorCompileAvalanche . P.checkAvalanche

readFacts :: D.Dictionary -> Text -> Either ReplError [AsAt Fact]
readFacts dict raw
  = mapLeft ReplErrorDecode
  $ TR.traverse (S.decodeEavt dict) $ T.lines raw

loadDictionary :: DictionaryLoadType -> EitherT ReplError IO D.Dictionary
loadDictionary load
 = case load of
    DictionaryLoadTextV1 fp
     -> do  raw <- lift $ T.readFile fp
            ds  <- firstEitherT ReplErrorDecode
                 $ hoistEither
                 $ TR.traverse DictionaryText.parseDictionaryLineV1
                 $ T.lines raw

            return $ D.Dictionary ds []

    DictionaryLoadToml fp
     -> firstEitherT ReplErrorDictionaryLoad $ DictionaryToml.loadDictionary fp

readIcicleLibrary
    :: Parsec.SourceName
    -> Text
    -> Either ReplError
          [ (CommonBase.Name Var
            , ( ST.FunctionType Var
              , SQ.Function (ST.Annot Parsec.SourcePos Var) Var)) ]
readIcicleLibrary source input
 = do input' <- mapLeft (ReplErrorCompileCore . P.CompileErrorParse) $ SP.parseFunctions source input
      mapLeft (ReplErrorCompileCore . P.CompileErrorCheck)
             $ snd
             $ flip Fresh.runFresh (P.freshNamer "repl")
             $ runEitherT
             $ SC.checkFs [] input'
