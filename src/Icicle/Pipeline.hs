{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards     #-}
{-# LANGUAGE ViewPatterns      #-}
{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE DeriveGeneric     #-}
module Icicle.Pipeline
  ( CompileError(..)
  , SourceVar
  , QueryTop'
  , QueryTop'T
  , CoreProgram'
  , freshNamer
  , annotOfError

  , sourceParseQT
  , sourceParseF
  , sourceDesugarQT
  , sourceDesugarF
  , sourceReifyQT
  , sourceCheckQT
  , sourceCheckF
  , sourceConvert
  , sourceInline

  , coreSimp
  , coreFlatten
  , coreAvalanche

  , flattenAvalanche
  , checkAvalanche
  , simpAvalanche
  , simpFlattened

  , coreEval
  , avalancheEval
  , seaEval

  , unName
  , unVar
  ) where

import qualified Icicle.Avalanche.Annot                   as AA
import qualified Icicle.Avalanche.Check                   as AC
import qualified Icicle.Avalanche.FromCore                as AC
import qualified Icicle.Avalanche.Prim.Flat               as APF
import qualified Icicle.Avalanche.Program                 as AP
import qualified Icicle.Avalanche.Simp                    as AS
import qualified Icicle.Avalanche.Statement.Flatten       as AS

import qualified Icicle.Common.Annot                      as CA
import           Icicle.Common.Base                       (Name)
import qualified Icicle.Common.Base                       as CommonBase
import qualified Icicle.Common.Fresh                      as Fresh
import qualified Icicle.Common.Type                       as CT

import qualified Icicle.Core.Exp.Prim                     as Core
import qualified Icicle.Core.Program.Condense             as Core
import qualified Icicle.Core.Program.Program              as Core
import qualified Icicle.Core.Program.Simp                 as Core

import qualified Icicle.Dictionary                        as D

import           Icicle.Internal.Pretty
import           Icicle.Internal.Rename

import qualified Icicle.Source.Checker                    as SC
import qualified Icicle.Source.Parser                     as SP
import qualified Icicle.Source.Query                      as SQ
import qualified Icicle.Source.ToCore.Base                as STC
import qualified Icicle.Source.ToCore.ToCore              as STC
import qualified Icicle.Source.Transform.Desugar          as STD
import qualified Icicle.Source.Transform.Inline           as STI
import qualified Icicle.Source.Transform.ReifyPossibility as STR
import qualified Icicle.Source.Type                       as ST

import           Icicle.Data

import qualified Icicle.Sea.Eval                          as Sea

import qualified Icicle.Simulator                         as S


import           Data.Functor.Identity
import qualified Data.Map                                 as M
import           Data.Monoid
import           Data.String
import           Data.Text                                (Text)
import           Data.Hashable                            (Hashable)


import           Text.ParserCombinators.Parsec            (SourcePos)
import qualified Text.ParserCombinators.Parsec            as Parsec

import           GHC.Generics                             (Generic)

import           P

import           System.IO                                (IO)

import           X.Control.Monad.Trans.Either


unVar :: SP.Variable -> Text
unVar (SP.Variable x) = x

unName :: Name a -> a
unName = go . CommonBase.nameBase
  where
   go (CommonBase.NameBase  x) = x
   go (CommonBase.NameMod _ x) = go x

--------------------------------------------------------------------------------

data CompileError a b c
 = CompileErrorParse   Parsec.ParseError
 | CompileErrorDesugar (STD.DesugarError a b)
 | CompileErrorCheck   (SC.CheckError a b)
 | CompileErrorConvert (STC.ConvertError a b)
 | CompileErrorFlatten (AS.FlattenError a b)
 | CompileErrorProgram (AC.ProgramError a b c)
 deriving (Show, Generic)

instance (NFData a, NFData b, NFData c) => NFData (CompileError a b c)


annotOfError :: CompileError SourcePos b c -> Maybe SourcePos
annotOfError e
 = case e of
    CompileErrorParse sp
     -> Just
      $ Parsec.errorPos sp
    CompileErrorDesugar e'
     -> STD.annotOfError e'
    CompileErrorCheck       e'
     -> SC.annotOfError  e'
    CompileErrorConvert     e'
     -> STC.annotOfError e'
    CompileErrorFlatten _
     -> Nothing
    CompileErrorProgram _
     -> Nothing

instance (Hashable b, Eq b, IsString b, Pretty a, Pretty b, Show a, Show b, Show c) => Pretty (CompileError a b c) where
 pretty e
  = case e of
     CompileErrorParse p
      -> "Parse error:" <> line
      <> indent 2 (text $ show p)
     CompileErrorDesugar d
      -> "Desugar error:" <> line
      <> indent 2 (pretty d)
     CompileErrorCheck ce
      -> "Check error:" <> line
      <> indent 2 (pretty ce)
     CompileErrorConvert ce
      -> "Convert error:" <> line
      <> indent 2 (pretty ce)
     CompileErrorFlatten d
      -> "Flatten error:" <> line
      <> indent 2 (text $ show d)
     CompileErrorProgram d
      -> "Program error:" <> line
      <> indent 2 (text $ show d)

--------------------------------------------------------------------------------

-- * Compile

type SourceVar  = SP.Variable
type AnnotT a   = ST.Annot a SourceVar

type CoreProgram' v = Core.Program () v
type AvalProgram' v = AP.Program () v
type AvalProgram a v= AP.Program a v

type QueryTop'  v = SQ.QueryTop SourcePos v
type QueryTop'T v = SQ.QueryTop (AnnotT SourcePos) v


type Funs a b = [((a, Name b), SQ.Function a b)]
type FunEnvT a b = [ ( Name b
                   , ( ST.FunctionType b
                     , SQ.Function (AnnotT a) b )) ]

----------------------------------------
-- * source

sourceParseQT
 :: Text -> Text
 -> Either (CompileError SourcePos SourceVar ()) (QueryTop' SourceVar)
sourceParseQT base t
 = first CompileErrorParse
 $ SP.parseQueryTop (CommonBase.OutputName base) t

sourceParseF
  :: Parsec.SourceName -> Text
  -> Either (CompileError SourcePos SourceVar ()) (Funs SourcePos SourceVar)
sourceParseF env t
 = first CompileErrorParse
 $ SP.parseFunctions env t

sourceDesugarQT
 :: QueryTop' SourceVar
 -> Either (CompileError SourcePos SourceVar ()) (QueryTop' SourceVar)
sourceDesugarQT q
 = runIdentity . runEitherT . bimapEitherT CompileErrorDesugar snd
 $ Fresh.runFreshT
     (STD.desugarQT q)
     (freshNamer "desugar_q")

sourceDesugarF :: Funs a SourceVar -> Either (CompileError a SourceVar ()) (Funs a SourceVar)
sourceDesugarF fun
 = runIdentity . runEitherT . bimapEitherT CompileErrorDesugar snd
 $ Fresh.runFreshT
     (mapM (mapM STD.desugarFun) fun)
     (freshNamer "desugar_f")

sourceReifyQT :: QueryTop'T SourceVar -> QueryTop'T SourceVar
sourceReifyQT q
 = snd
 $ runIdentity
 $ Fresh.runFreshT
     (STR.reifyPossibilityQT q)
     (freshNamer "reify")

sourceCheckQT
 :: SC.CheckOptions -> D.Dictionary -> QueryTop' SourceVar
 -> Either (CompileError SourcePos SourceVar ()) (QueryTop'T SourceVar, ST.Type SourceVar)
sourceCheckQT opts d q
 = let d' = D.featureMapOfDictionary d
   in  first CompileErrorCheck
     $ snd
     $ flip Fresh.runFresh (freshNamer "check")
     $ runEitherT
     $ SC.checkQT opts d' q

sourceCheckF
 :: FunEnvT a SourceVar
 -> Funs a SourceVar
 -> Either (CompileError a SourceVar ()) (FunEnvT a SourceVar)
sourceCheckF env parsedImport
 = first CompileErrorCheck
 $ snd
 $ flip Fresh.runFresh (freshNamer "check")
 $ runEitherT
 $ SC.checkFs env parsedImport

sourceInline
 :: D.Dictionary -> QueryTop'T SourceVar -> QueryTop' SourceVar
sourceInline d q
 = SQ.reannotQT ST.annAnnot
 $ inline q
 where
  funs      = M.map snd
            $ M.fromList
            $ D.dictionaryFunctions d
  inline q' = snd
            $ Fresh.runFresh
                (STI.inlineQT funs q')
                (freshNamer "inline")


----------------------------------------
-- * core

sourceConvert
  :: D.Dictionary
  -> QueryTop'T SourceVar
  -> Either (CompileError SourcePos SourceVar ()) (CoreProgram' SourceVar)
sourceConvert d q
 = second snd
 $ first CompileErrorConvert conv
 where
  d'        = D.featureMapOfDictionary d
  conv      = Fresh.runFreshT
                (STC.convertQueryTop d' q)
                (freshNamer "conv")

coreSimp
 :: (Hashable v, Eq v, IsString v, NFData v)
 => CoreProgram' v
 -> CoreProgram' v
coreSimp p
 = Core.condenseProgram ()
 $!! snd
 $!! Fresh.runFresh (Core.simpProgram () p) (freshNamer "simp")

coreFlatten
  :: (Hashable v, Eq v, IsString v, Pretty v, Show v, NFData v)
  => CoreProgram' v
  -> Either (CompileError () v APF.Prim) (AvalProgram' v APF.Prim)
coreFlatten prog
 =   second simpFlattened
 $!! flattenAvalanche
 $!! coreAvalanche prog

flattenAvalanche
  :: (IsString v, Pretty v, Hashable v, Eq v, NFData v)
  => AvalProgram () v Core.Prim
  -> Either (CompileError () v APF.Prim) (AvalProgram (CA.Annot ()) v APF.Prim)
flattenAvalanche av
 = join
 . second snd
 . first CompileErrorFlatten
 $!! Fresh.runFreshT go (freshNamer "flat")
 where
  go = do s' <- AS.flatten () (AP.statements av)
          return $ checkAvalanche (av { AP.statements = force s' })

checkAvalanche
  :: (Hashable v, Eq v)
  => AvalProgram' v APF.Prim
  -> Either (CompileError () v APF.Prim) (AvalProgram (CA.Annot ()) v APF.Prim)
checkAvalanche prog
 = first CompileErrorProgram
 $ AC.checkProgram APF.flatFragment prog

coreAvalanche
  :: (Eq v, Hashable v, Show v, IsString v)
  => CoreProgram' v
  -> AvalProgram () v Core.Prim
coreAvalanche prog
 = simpAvalanche
 $ snd
 $ Fresh.runFresh (AC.programFromCore (AC.namerText id) prog) (freshNamer "aval")

simpAvalanche
  :: (Eq v, Hashable v, Show v, IsString v)
  => AvalProgram () v Core.Prim
  -> AvalProgram () v Core.Prim
simpAvalanche av
 = snd
 $ Fresh.runFresh go (freshNamer "anf")
 where
  go = AS.simpAvalanche () av

simpFlattened
  :: (Eq v, Hashable v, Show v, IsString v)
  => AvalProgram (CA.Annot ()) v APF.Prim
  -> AvalProgram' v APF.Prim
simpFlattened av
 = AA.eraseAnnotP
 $ snd
 $ Fresh.runFresh go' (freshNamer "simp")
 where
  go'
   = go av
  -- Thread through a dummy annotation
  go
   = AS.simpFlattened (CA.Annot (CT.FunT [] CT.ErrorT) ())


freshNamer :: IsString v => v -> Fresh.NameState v
freshNamer prefix
 = Fresh.counterPrefixNameState (fromString . show) prefix


--------------------------------------------------------------------------------

-- * Eval

type SimError = S.SimulateError () SourceVar

newtype Result   = Result (Entity, Value)
  deriving (Eq, Show)

instance Pretty Result where
  pretty (Result (ent, val))
    = pretty ent <> comma <> space <> pretty val

coreEval
  :: Time
  -> [AsAt Fact]
  -> QueryTop'T SourceVar
  -> CoreProgram' SourceVar
  -> Either SimError [Result]
coreEval t fs (renameQT unVar -> query) prog
 = do let partitions = S.streams fs
      let feat       = SQ.feature query
      let results    = fmap (evalP feat) partitions

      res' <- sequence results

      return $ concat res'

  where
    evalP feat (S.Partition ent attr values)
      | CommonBase.NameBase feat' <- CommonBase.nameBase feat
      , attr == Attribute feat'
      = do  (vs',_) <- evalV values
            return $ fmap (\v -> Result (ent, snd v)) vs'

      | otherwise
      = return []

    evalV
      = S.evaluateVirtualValue prog t

avalancheEval
  :: Time
  -> [AsAt Fact]
  -> QueryTop'T SourceVar
  -> AP.Program () SourceVar APF.Prim
  -> Either SimError [Result]
avalancheEval t fs (renameQT unVar -> query) prog
 = do let partitions = S.streams fs
      let feat       = SQ.feature query
      let results    = fmap (evalP feat) partitions

      res' <- sequence results

      return $ concat res'

  where
    evalP feat (S.Partition ent attr values)
      | CommonBase.NameBase feat' <- CommonBase.nameBase feat
      , attr == Attribute feat'
      = do  (vs',_) <- evalV values
            return $ fmap (\v -> Result (ent, snd v)) vs'

      | otherwise
      = return []

    evalV
      = S.evaluateVirtualValue' prog t

seaEval :: Time
        -> [AsAt Fact]
        -> QueryTop'T SourceVar
        -> AP.Program (CA.Annot ()) SP.Variable APF.Prim
        -> EitherT Sea.SeaError IO [Result]
seaEval t newFacts (renameQT unVar -> query) program =
  fmap Result . mconcat <$> sequence results
  where
    partitions :: [S.Partition]
    partitions  = S.streams newFacts

    results :: [EitherT Sea.SeaError IO [(Entity, Value)]]
    results = fmap (evalP (SQ.feature query)) partitions

    evalP :: CommonBase.Name Text
          -> S.Partition
          -> EitherT Sea.SeaError IO [(Entity, Value)]
    evalP featureName (S.Partition entityName attributeName values)
      | CommonBase.NameBase name <- CommonBase.nameBase featureName
      , Attribute name == attributeName
      = do outputs <- Sea.seaEvalAvalanche program t values
           return $ fmap (\out -> (entityName, snd out)) outputs

      | otherwise
      = return []
