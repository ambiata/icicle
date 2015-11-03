-- | Types of primitives.
-- It is odd that we need to look up inside a Fresh monad.
-- However, because the types are polymorphic in the variable type, we have no way of saying "forall a".
-- So we must generate a fresh name for any forall binders.
{-# LANGUAGE NoImplicitPrelude #-}
module Icicle.Source.Checker.Prim (
    primLookup
  , primLookup'
  ) where

import                  Icicle.Source.Checker.Base

import                  Icicle.Source.Query
import                  Icicle.Source.Type

import                  P



primLookup
 :: Ord n
 => a -> Prim
 -> Gen a n (FunctionType n, [Type n], Type n, GenConstraintSet a n)
primLookup ann p
 = do ft <- primLookup' p
      introForalls ann ft

primLookup' :: Prim -> Gen a n (FunctionType n)
primLookup' p
 = case p of
    Op (ArithUnary _)
     -> fNum $ \at -> ([at], at)
    Op (ArithBinary _)
     -> fNum $ \at -> ([at, at], at)
    Op (ArithDouble Div)
     -> f0 [DoubleT, DoubleT] DoubleT

    Op (Relation _)
     -> f1 $ \a at -> FunctionType [a] [] [at, at] BoolT

    Op (LogicalUnary _)
     -> f0 [BoolT] BoolT
    Op (LogicalBinary _)
     -> f0 [BoolT, BoolT] BoolT
    Op (DateBinary _)
     -> f0 [IntT, DateTimeT] DateTimeT

    Op  TupleComma
     -> do a <- fresh
           b <- fresh
           let at = TypeVar a
           let bt = TypeVar b
           return $ FunctionType [a,b] [] [at, bt] (PairT at bt)

    Lit (LitInt _)
     -> fNum $ \at -> ([], at)
    Lit (LitDouble _)
     -> f0 [] DoubleT
    Lit (LitString _)
     -> f0 [] StringT
    Lit (LitDate _)
     -> f0 [] DateTimeT

    Fun Log
     -> f0 [DoubleT] DoubleT
    Fun Exp
     -> f0 [DoubleT] DoubleT
    Fun ToDouble
     -> fNum $ \at -> ([at], DoubleT)
    Fun ToInt
     -> fNum $ \at -> ([at], IntT)
    Fun DaysBetween
     -> f0 [DateTimeT, DateTimeT] IntT
    Fun DaysEpoch
     -> f0 [DateTimeT] IntT
    Fun Seq
     -> f2 $ \a at b bt -> FunctionType [a,b] [] [at,bt] bt

    PrimCon ConSome
     -> f1 $ \a at -> FunctionType [a] [] [at] (OptionT at)

    PrimCon ConNone
     -> f1 $ \a at -> FunctionType [a] [] [] (OptionT at)

    PrimCon ConTuple
     -> f2 $ \a at b bt -> FunctionType [a, b] [] [at, bt] (PairT at bt)

    PrimCon ConTrue
     -> f0 [] BoolT
    PrimCon ConFalse
     -> f0 [] BoolT

    PrimCon ConLeft
     -> f2 $ \a at b bt -> FunctionType [a, b] [] [at] (SumT at bt)
    PrimCon ConRight
     -> f2 $ \a at b bt -> FunctionType [a, b] [] [bt] (SumT at bt)

    PrimCon (ConError _)
     -> f0 [] ErrorT

 where

  f0 argsT resT
   = return $ FunctionType [] [] argsT resT

  fNum f
   = f1 (\a at -> uncurry (FunctionType [a] [CIsNum at]) (f at))

  f1 f
   = do n <- fresh
        return $ f n (TypeVar n)

  f2 f
   = do n1 <- fresh
        n2 <- fresh
        return $ f n1 (TypeVar n1) n2 (TypeVar n2)


