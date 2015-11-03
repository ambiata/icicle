-- | Primitive functions, constant values and so on
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Icicle.Core.Exp.Prim (
      Prim          (..)
    , PrimFold      (..)
    , PrimArray     (..)
    , PrimMap       (..)
    , PrimLatest    (..)
    , typeOfPrim
    ) where

import              Icicle.Internal.Pretty
import              Icicle.Common.Type
import qualified    Icicle.Common.Exp.Prim.Minimal as Min

import              P


-- | Top-level primitive for Core expressions
-- Includes folds etc that won't be present in Avalanche
data Prim
 -- | Include a bunch of basic things common across languages
 = PrimMinimal  Min.Prim
 -- | Fold and return type
 | PrimFold     PrimFold ValType
 -- | Array primitives
 | PrimArray    PrimArray
 -- | Map primitives
 | PrimMap      PrimMap
 -- | Circular buffer for latest
 | PrimLatest   PrimLatest
 deriving (Eq, Ord, Show)


-- | Folds and destructing things
data PrimFold
 = PrimFoldBool
 | PrimFoldArray  ValType
 | PrimFoldOption ValType
 | PrimFoldSum    ValType ValType
 | PrimFoldMap    ValType ValType
 deriving (Eq, Ord, Show)


-- | Array primitives
data PrimArray
 = PrimArrayMap ValType ValType
 deriving (Eq, Ord, Show)


-- | Map primitives
data PrimMap
 = PrimMapInsertOrUpdate ValType ValType
 | PrimMapMapValues ValType ValType ValType
 deriving (Eq, Ord, Show)


-- | Latest buffer primitives
data PrimLatest
 = PrimLatestMake ValType
 | PrimLatestPush ValType
 | PrimLatestRead ValType
 deriving (Eq, Ord, Show)


-- | A primitive always has a well-defined type
typeOfPrim :: Prim -> Type
typeOfPrim p
 = case p of
    -- All arithmetics are int to int for now
    PrimMinimal m
     -> Min.typeOfPrim m

    -- Folds
    PrimFold PrimFoldBool ret
     -> FunT [funOfVal ret, funOfVal ret, funOfVal BoolT] ret
    PrimFold (PrimFoldArray a) ret
     -> FunT [FunT [funOfVal ret, funOfVal a] ret, funOfVal ret, funOfVal (ArrayT a)] ret
    PrimFold (PrimFoldOption a) ret
     -> FunT [FunT [funOfVal a] ret, funOfVal ret, funOfVal (OptionT a)] ret
    PrimFold (PrimFoldSum    a b) ret
     -> FunT [FunT [funOfVal a] ret, FunT [funOfVal b] ret, funOfVal (SumT a b)] ret
    PrimFold (PrimFoldMap k v) ret
     -> FunT [FunT [funOfVal ret, funOfVal k, funOfVal v] ret, funOfVal ret, funOfVal (MapT k v)] ret

    -- Array primitives
    PrimArray (PrimArrayMap a b)
     -> FunT [FunT [funOfVal a] b, funOfVal (ArrayT a)] (ArrayT b)

    -- Map primitives
    PrimMap (PrimMapInsertOrUpdate k v)
     -> FunT [FunT [funOfVal v] v, funOfVal v, funOfVal k, funOfVal (MapT k v)] (MapT k v)
    PrimMap (PrimMapMapValues k v v')
     -> FunT [FunT [funOfVal v] v', funOfVal (MapT k v)] (MapT k v')

    -- Latest buffer primitives
    PrimLatest (PrimLatestMake t)
     -> FunT [funOfVal IntT] (BufT t)
    PrimLatest (PrimLatestPush t)
     -> FunT [funOfVal (BufT t), funOfVal t] (BufT t)
    PrimLatest (PrimLatestRead t)
     -> FunT [funOfVal (BufT t)] (ArrayT t)


-- Pretty -------------

instance Pretty Prim where
 pretty (PrimMinimal m) = pretty m

 pretty (PrimFold f ret)
  = let f' = case f of
              PrimFoldBool
               -> "if#"
              PrimFoldArray a
               -> annotate (AnnType a) "Array_fold#"
              PrimFoldOption a
               -> annotate (AnnType a) "Option_fold#"
              PrimFoldSum    a b
               -> annotate (AnnType (a , b)) "Sum_fold#"
              PrimFoldMap k v
               -> annotate (AnnType (k , v)) "Map_fold#"
    in annotate (AnnType ret) f'

 pretty (PrimArray (PrimArrayMap a b))
  = annotate (AnnType (a, b)) "Array_map#"

 pretty (PrimMap (PrimMapInsertOrUpdate k v))
  = annotate (AnnType (k , v)) "Map_insertOrUpdate#"

 pretty (PrimMap (PrimMapMapValues k v v'))
  = annotate (AnnType (k , v , v')) "Map_mapValues#"

 pretty (PrimLatest (PrimLatestMake t))
  = annotate (AnnType t) "Latest_make#"

 pretty (PrimLatest (PrimLatestPush t))
  = annotate (AnnType t) "Latest_push#"

 pretty (PrimLatest (PrimLatestRead t))
  = annotate (AnnType t) "Latest_read#"

