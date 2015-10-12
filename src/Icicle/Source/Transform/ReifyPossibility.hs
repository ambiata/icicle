{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PatternGuards #-}
module Icicle.Source.Transform.ReifyPossibility (
    reifyPossibilityTransform
  ) where

import Icicle.Source.Query
import Icicle.Source.Type
import Icicle.Source.Transform.Base
import Icicle.Source.Transform.SubstX

import Icicle.Common.Base
import Icicle.Common.Fresh

import P

import Data.Functor.Identity
import qualified Data.Map as Map

reifyPossibilityTransform
        :: Ord n
        => Transform (Fresh n) () (Annot a n) n
reifyPossibilityTransform
 = Transform
 { transformExp         = tranx
 , transformPat         = \_ p -> return ((), p)
 , transformContext     = tranc
 , transformState       = ()
 }
 where
  tranx _ x
   = return ((), x)
  tranc _ c
   = case c of
      LetFold a f
       | FoldTypeFoldl1 <- foldType f
       -> do  nError <- fresh
              nValue <- fresh
              let b  = foldBind f
                  a' = a { annResult = canonT $ SumT ErrorT $ annResult a }

                  z' = con1 a' ConLeft $ con0 a' $ ConError ExceptFold1NoValue

                  -- Will need to desugar after this
                  k' = Case a' (Var a' b)
                     [ ( PatCon ConLeft  [ PatCon (ConError ExceptFold1NoValue) [] ]
                       , wrapRight $ foldInit f )
                     , ( PatCon ConLeft  [ PatVariable nError ]
                       , con1 a' ConLeft $ Var a' nError )
                     , ( PatCon ConRight [ PatVariable nValue ]
                       , wrapRight
                       $ substIntoIfDefinitely b (Var a nValue)
                       $ foldWork f ) ]

                  f' = f { foldType = FoldTypeFoldl
                         , foldInit = z'
                         , foldWork = k' }

              return ((), LetFold a' f')

      _
       -> return ((), c)

  con0 a c   =        Prim a (PrimCon c)
  con1 a c x = App a (Prim a (PrimCon c)) x

  wrapRight x
   | ann        <- annotOfExp x
   , t          <- annResult  ann
   , PossibilityDefinitely <- getPossibilityOrDefinitely t
   = con1 (ann { annResult = canonT $ SumT ErrorT t } ) ConRight x
   | otherwise
   = x

  substIntoIfDefinitely var payload into
   | PossibilityDefinitely <- getPossibilityOrDefinitely $ annResult $ annotOfExp into
   = substInto var payload into
   | otherwise
   = into

  substInto var payload into
   = runIdentity
   $ transformX
     unsafeSubstTransform
   { transformState = Map.singleton var payload }
     into
