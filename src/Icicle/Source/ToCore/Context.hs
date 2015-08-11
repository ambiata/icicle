{-# LANGUAGE NoImplicitPrelude #-}
module Icicle.Source.ToCore.Context (
    Features
  , FeatureContext

  , envOfFeatureContext
  ) where

import                  Icicle.Source.Type
import qualified        Icicle.Core as C

import                  P
import qualified        Data.Map as Map


type Features n
 = Map.Map n (Type n, FeatureContext n)

type FeatureContext n
 = Map.Map n (Type n, C.Exp n -> C.Exp n)

envOfFeatureContext :: FeatureContext n -> Map.Map n (Type n)
envOfFeatureContext ff
 = Map.map (\(t,_) -> Temporality TemporalityElement $ Possibility PossibilityDefinitely t)
 $ ff

