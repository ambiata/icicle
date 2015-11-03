{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module Icicle.Storage.Dictionary.Toml (
    DictionaryImportError (..)
  , loadDictionary
  ) where

import           Icicle.Common.Base
import           Icicle.Data                                   (Attribute)
import           Icicle.Dictionary.Data
import           Icicle.Internal.Pretty                        hiding ((</>))
import qualified Icicle.Pipeline                               as P
import qualified Icicle.Source.Parser                          as SP
import qualified Icicle.Source.Query                           as SQ
import qualified Icicle.Source.Type                            as ST
import           Icicle.Storage.Dictionary.Toml.Toml
import           Icicle.Storage.Dictionary.Toml.TomlDictionary

import qualified Control.Arrow                                 as A
import qualified Control.Exception                             as E
import           Control.Monad.Trans.Either

import           System.FilePath
import           System.IO

import           Data.Either.Combinators
import qualified Data.Set                                      as S
import qualified Data.Text                                     as T
import qualified Data.Text.IO                                  as T

import qualified Text.Parsec                                   as Parsec

import           P


data DictionaryImportError
  = DictionaryErrorIO          E.SomeException
  | DictionaryErrorParsecTOML  Parsec.ParseError
  | DictionaryErrorCompilation (P.CompileError Parsec.SourcePos SP.Variable ())
  | DictionaryErrorParse       [DictionaryValidationError]
  deriving (Show)

type Funs a  = [((a, Name SP.Variable), SQ.Function a SP.Variable)]
type FunEnvT = [ ( Name SP.Variable
                 , ( ST.FunctionType SP.Variable
                   , SQ.Function (ST.Annot Parsec.SourcePos SP.Variable) SP.Variable ) ) ]


-- Top level IO function which loads all dictionaries and imports
loadDictionary :: FilePath
  -> EitherT DictionaryImportError IO Dictionary
loadDictionary dictionary
 = loadDictionary' [] mempty [] dictionary

loadDictionary'
  :: FunEnvT
  -> DictionaryConfig
  -> [DictionaryEntry]
  -> FilePath
  -> EitherT DictionaryImportError IO Dictionary
loadDictionary' parentFuncs parentConf parentConcrete fp
 = do
  inputText
    <- EitherT
     $ (A.left DictionaryErrorIO)
     <$> (E.try (readFile fp))

  rawToml
    <- hoistEither
     $ (A.left DictionaryErrorParsecTOML)
     $ Parsec.parse tomlDoc fp inputText

  (conf, definitions')
    <- hoistEither
     $ (A.left DictionaryErrorParse)
     $ toEither
     $ tomlDict parentConf rawToml

  parsedImports     <- parseImports conf rp
  importedFunctions <- loadImports parentFuncs parsedImports

  -- Functions available for virtual features, and visible in sub-dictionaries.
  let availableFunctions = parentFuncs <> importedFunctions

  let concreteDefinitions = foldr remakeConcrete [] definitions'
  let virtualDefinitions' = foldr remakeVirtuals [] definitions'

  let d' = Dictionary (concreteDefinitions <> parentConcrete) availableFunctions

  virtualDefinitions <- checkDefs d' virtualDefinitions'

  loadedChapters
    <- (\fp' ->
         loadDictionary' availableFunctions conf concreteDefinitions (rp </> (T.unpack fp'))
       ) `traverse` (chapter conf)

  -- Dictionaries loaded after one another can see the functions of previous dictionaries. So sub-dictionaries imports can use
  -- prelude functions. Export the dictionaries loaded here, and in sub dictionaries (but not parent functions, as the parent
  -- already knows about those).
  let functions = join $ [importedFunctions] <> (dictionaryFunctions <$> loadedChapters)
  let totaldefinitions = concreteDefinitions <> virtualDefinitions <> (join $ dictionaryEntries <$> loadedChapters)

  pure $ Dictionary totaldefinitions functions

    where
      rp = (takeDirectory fp)

      remakeConcrete (DictionaryEntry' a (ConcreteDefinition' _ e t)) cds = (DictionaryEntry a (ConcreteDefinition e $ S.fromList $ toList t)) : cds
      remakeConcrete _ cds = cds

      remakeVirtuals (DictionaryEntry' a (VirtualDefinition' (Virtual' v))) vds = (a, v) : vds
      remakeVirtuals _ vds = vds

parseImports
  :: DictionaryConfig
  -> FilePath
  -> EitherT DictionaryImportError IO [Funs Parsec.SourcePos]
parseImports conf rp
 = go `traverse` imports conf
 where
  go fp
   = do let fp'' = T.unpack fp
        importsText
          <- EitherT
           $ A.left DictionaryErrorIO
          <$> E.try (T.readFile (rp </> fp''))
        hoistEither
           $ A.left DictionaryErrorCompilation
           $ P.sourceParseF fp'' importsText

loadImports
  :: FunEnvT
  -> [Funs Parsec.SourcePos]
  -> EitherT DictionaryImportError IO FunEnvT
loadImports parentFuncs parsedImports
 = hoistEither . mapLeft DictionaryErrorCompilation
 $ foldlM (go parentFuncs) [] parsedImports
 where
  go env acc f
   = do -- Run desugar to ensure pattern matches are complete.
        _  <- P.sourceDesugarF f
        -- Type check the function (allowing it to use parents and previous).
        f' <- P.sourceCheckF (env <> acc) f
        -- Return these functions at the end of the accumulator.
        return $ acc <> f'

checkDefs
  :: Dictionary
  -> [(Attribute, P.QueryTop')]
  -> EitherT DictionaryImportError IO [DictionaryEntry]
checkDefs d defs
 = hoistEither . mapLeft DictionaryErrorCompilation
 $ go `traverse` defs
 where
  go (a, q)
   = do  -- Run desugar to ensure pattern matches are complete.
         _             <- P.sourceDesugarQT q
         -- Type check the virtual definition.
         (checked, _)  <- P.sourceCheckQT d q
         pure $ DictionaryEntry a (VirtualDefinition (Virtual checked))



instance Pretty DictionaryImportError where
  pretty (DictionaryErrorIO e)
   = "IO Exception:" <+> (text . show) e
  pretty (DictionaryErrorParsecTOML e)
   = "TOML parse error:" <+> (text . show) e
  pretty (DictionaryErrorCompilation e)
   = pretty e
  pretty (DictionaryErrorParse es)
   = "Validation error:" <+> align (vcat (pretty <$> es))

