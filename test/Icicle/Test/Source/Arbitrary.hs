{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module Icicle.Test.Source.Arbitrary where

import           Icicle.Internal.Pretty
import           Icicle.Source.Checker.Checker
import           Icicle.Source.Checker.Error
import           Icicle.Source.Query
import           Icicle.Source.Type
import qualified Icicle.Source.Lexer.Token as T
import           Icicle.Common.Fresh
import qualified Icicle.Common.Base             as CB
import qualified Icicle.Common.Type             as CT

import qualified Icicle.Common.Exp.Prim.Minimal as Min
import qualified Icicle.Core.Exp.Combinators    as CE
import qualified Icicle.Core.Exp                as CE


import           Icicle.Source.ToCore.Context
import           Icicle.Source.ToCore.ToCore
import           Icicle.Source.Transform.Desugar
import           Icicle.Source.Transform.ReifyPossibility

import           Icicle.Test.Arbitrary.Base
import           Icicle.Test.Core.Arbitrary ()
import           Disorder.Corpus

import           Test.QuickCheck
import           Test.QuickCheck.Instances ()

import           P

import           Control.Monad.Trans.Either
import qualified Data.Text as Text
import qualified Data.List as List
import qualified Data.Map as Map
import           Data.Functor.Identity

import           Data.String (String)

import           Data.Either.Combinators


instance Arbitrary T.Variable where
 arbitrary
  = T.Variable <$> elements muppets

instance Arbitrary n => Arbitrary (Exp () n) where
 arbitrary
  = oneof_sized
        [ Var    () <$> arbitrary
        , Prim   () <$> arbitrary ]
        [ (simplifyNestedX . Nested ()) <$> arbitrary
        , App    () <$> arbitrary <*> arbitrary
        , Case   () <$> arbitrary
                    <*> arbitrary `suchThat` (not . null)
        , preop
        , inop ]

  where
   preop
    = App ()
    <$> (Prim () <$> operator_pre)
    <*> arbitrary

   inop
    = App ()
    <$> (App ()
            <$> (Prim () <$> operator_bin)
            <*> arbitrary)
    <*> arbitrary

   operator_bin
    = oneof_vals
        [ Op    (ArithDouble Div)
        , Op    (ArithBinary Mul)
        , Op    (ArithBinary Add)
        , Op    (ArithBinary Sub)
        , Op    (ArithBinary Pow)
        , Op    (Relation Gt)
        , Op    (Relation Eq)
        , Op    (LogicalBinary And)
        , Op    (LogicalBinary Or)
        , Op    (DateBinary DaysBefore)
        , Op    (DateBinary DaysAfter)
        , Op    (DateBinary MonthsBefore)
        , Op    (DateBinary MonthsAfter)
        , Fun   (DaysBetween)
        , Fun   (DaysEpoch)
        , Fun   (Seq) ]

   operator_pre
    = oneof_vals
        [ Op (ArithUnary Negate)
        , Op (LogicalUnary Not)]

instance Arbitrary Prim where
 arbitrary
  = oneof
        [ Lit . LitInt    <$> pos
        , Lit . LitDouble <$> pos'
        , Lit . LitString <$> (elements southpark)
        , Lit . LitDate   <$> arbitrary ]
    where
      -- Negative literals get parsed into negative, then a positive literal.
      -- This isn't a problem mathematically, but would break symmetry tests.
      pos  = abs <$> arbitrary
      pos' = abs <$> arbitrary

instance Arbitrary Constructor where
 arbitrary
  = oneof_vals [ ConSome, ConNone, ConTuple, ConTrue, ConFalse, ConLeft, ConRight ]

instance Arbitrary n => Arbitrary (Pattern n) where
 arbitrary
  = oneof_sized [ return PatDefault, PatVariable <$> arbitrary ]
                [ patcon ]
  where
   patcon
    = do con  <- arbitrary
         args <- List.take (arityOfConstructor con) <$> (infiniteList :: Gen [Pattern n])
         return (PatCon con args)


instance Arbitrary n => Arbitrary (Context () n) where
 arbitrary
  = oneof_sized
        [ Windowed () <$> arbitrary <*> arbitrary <*> arbitrary
        , Latest   () . abs <$> arbitrary ]
        [ GroupBy  () <$> arbitrary
        , Distinct () <$> arbitrary
        , Filter   () <$> arbitrary
        , LetFold  () <$> arbitrary
        , Let      () <$> arbitrary <*> arbitrary
        -- no reason to generate group-folds that are not on groups
        , GroupFold ()
            <$> arbitrary
            <*> arbitrary
            <*> (Nested () <$> arbitrary `suchThat` hasGroup)
        ]
  where
   hasGroup q
    | (GroupBy _ _ : _) <- contexts q = True
    | otherwise = False


instance Arbitrary n => Arbitrary (Fold (Query () n) () n) where
 arbitrary
  = Fold <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary FoldType where
 arbitrary
  = oneof
        [ return FoldTypeFoldl1
        , return FoldTypeFoldl ]


instance Arbitrary n => Arbitrary (Query () n) where
 arbitrary
  = Query <$> arbitrary <*> arbitrary

instance Arbitrary n => Arbitrary (QueryTop () n) where
 arbitrary
  = QueryTop <$> arbitrary <*> arbitrary <*> arbitrary


freshnamer t = counterPrefixNameState (T.Variable . Text.pack . show) (T.Variable t)

freshtest t p
 = snd <$> runFreshT p (freshnamer t)

freshcheck t
 = snd
 . flip runFresh (freshnamer t)
 . runEitherT

data QueryWithFeature
 = QueryWithFeature
 { qwfQuery     :: Query    () T.Variable
 , qwfNow       :: Maybe (CB.Name T.Variable)
 , qwfOutput    :: CB.OutputName
 , qwfFeatureT  :: CT.ValType
 , qwfFeatureN  :: CB.Name T.Variable
 }
 deriving Show


qwfFeatureMap :: QueryWithFeature -> Features () T.Variable
qwfFeatureMap qwf
 = Features
    (Map.singleton (qwfFeatureN qwf) (typeOfValType (qwfFeatureT qwf), Map.singleton (qwfFeatureN qwf) (FeatureVariable (typeOfValType (qwfFeatureT qwf)) (xfst (qwfFeatureT qwf)) False)))
     Map.empty
     (qwfNow qwf)

 where
  xfst tt
   = CE.xApp
   $ CE.xPrim     $ CE.PrimMinimal
   $ Min.PrimPair $ Min.PrimPairFst tt CT.DateTimeT

qwfQueryTop :: QueryWithFeature -> QueryTop () T.Variable
qwfQueryTop qwf
 = QueryTop (qwfFeatureN qwf) (qwfOutput qwf) (qwfQuery qwf)

instance Arbitrary QueryWithFeature where
 arbitrary
  = do q   <- arbitrary
       now <- arbitrary
       o   <- arbitrary
       -- Convert to Source type and back, because this filters out Bufs.
       -- (It actually converts them to Arrays)
       -- This is fine, because Buf can't be in feature types.
       --
       -- This was causing issues with conversion from Source, because
       -- part of the resulting Core was using the ValType with Bufs, and
       -- part was using the Source-converted type with Arrays.
       Just t <- (valTypeOfType . typeOfValType) <$> arbitrary
       nm  <- arbitrary `suchThat` (\n -> Just n /= now)
       return $ QueryWithFeature q now o t nm

qwfPretty :: QueryWithFeature -> String
qwfPretty qwf
 = show $ pretty $ qwfQueryTop qwf


data CheckErr
 = CheckErrTC (CheckError () T.Variable)
 | CheckErrDS (DesugarError () T.Variable)
 deriving Show

qwfCheck :: QueryWithFeature -> Either CheckErr (QueryTop (Annot () T.Variable) T.Variable)
qwfCheck qwf
 = do qd' <- qwfDesugar qwf
      (qt',_) <- mapLeft CheckErrTC $ freshcheck "check" $ checkQT (qwfFeatureMap qwf) qd'
      return qt'

qwfDesugar :: QueryWithFeature -> Either CheckErr (QueryTop () T.Variable)
qwfDesugar qwf
 = mapLeft CheckErrDS
 $ runDesugar (freshnamer "desugar")
 $ desugarQT
 $ qwfQueryTop qwf

qwfConvertToCore qwf qt
 = freshtest "core" $ convertQueryTop (qwfFeatureMap qwf)
  (runIdentity $ freshtest "reify" $ reifyPossibilityQT qt)
