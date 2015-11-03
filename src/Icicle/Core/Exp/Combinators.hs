-- | Helper combinators for constructing core expressions
-- These are quite useful until we have a real source language and parser.
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Icicle.Core.Exp.Combinators where

import              Icicle.Common.Base
import              Icicle.Common.Type
import              Icicle.Core.Exp.Prim
import qualified    Icicle.Core.Exp.Exp     as X
import              Icicle.Common.Exp.Exp
import              Icicle.Common.Exp.Compounds
import qualified    Icicle.Common.Exp.Prim.Minimal as Min

import              P hiding (error)
import qualified    Data.Text   as T
import              Data.Text   (Text)
import qualified    Data.Set    as Set
import qualified    Data.Map    as Map

import              Prelude (error)

-- | Right-associative application
($~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
($~) x y = xApp x y
infixr 0 $~

-- | Left-associative application
(@~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
(@~) x y = xApp x y
infixl 0 @~


var  :: n -> X.Exp () n
var = xVar . Name


constI :: Int -> X.Exp () n
constI = xValue IntT  . VInt

some :: ValType -> X.Exp () n -> X.Exp () n
some t x
 = xPrim (PrimMinimal $ Min.PrimConst $ Min.PrimConstSome t)
    @~ x

negate :: X.Exp () n -> X.Exp () n
negate x = xPrim (PrimMinimal $ Min.PrimArithUnary Min.PrimArithNegate ArithIntT) @~ x

constB :: Bool -> X.Exp () n
constB = xValue BoolT . VBool

emptyMap :: ValType -> ValType -> X.Exp () n
emptyMap tk tv = xValue (MapT tk tv) (VMap Map.empty)

fstOfSource :: ValType -> X.Exp () Text -> X.Exp () Text
fstOfSource ty p
 = xPrim (PrimMinimal $ Min.PrimPair $ Min.PrimPairFst ty DateTimeT)
    @~ p


prim2 :: Prim -> X.Exp () n -> X.Exp () n -> X.Exp () n
prim2 p x y = xPrim p @~ x @~ y

(+~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
(+~) = prim2 (PrimMinimal $ Min.PrimArithBinary Min.PrimArithPlus ArithIntT)
infixl 6 +~

(-~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
(-~) = prim2 (PrimMinimal $ Min.PrimArithBinary Min.PrimArithMinus ArithIntT)
infixl 6 -~

(*~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
(*~) = prim2 (PrimMinimal $ Min.PrimArithBinary Min.PrimArithMul ArithIntT)
infixl 7 *~

(/~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
(/~) = prim2 (PrimMinimal $ Min.PrimDouble Min.PrimDoubleDiv)
infixl 7 /~

(>~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
(>~) = prim2 (PrimMinimal $ Min.PrimRelation Min.PrimRelationGt IntT)
infix 4 >~

(>=~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
(>=~) = prim2 (PrimMinimal $ Min.PrimRelation Min.PrimRelationGe IntT)
infix 4 >=~

(<~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
(<~) = prim2 (PrimMinimal $ Min.PrimRelation Min.PrimRelationLt IntT)
infix 4 <~

(<=~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
(<=~) = prim2 (PrimMinimal $ Min.PrimRelation Min.PrimRelationLe IntT)
infix 4 <=~

(==~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
(==~) = prim2 (PrimMinimal $ Min.PrimRelation Min.PrimRelationEq IntT)
infix 4 ==~

(/=~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
(/=~) = prim2 (PrimMinimal $ Min.PrimRelation Min.PrimRelationNe IntT)
infix 4 /=~

(&&~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
(&&~) = prim2 (PrimMinimal $ Min.PrimLogical Min.PrimLogicalAnd)
infix 3 &&~

(||~) :: X.Exp () n -> X.Exp () n -> X.Exp () n
(||~) = prim2 (PrimMinimal $ Min.PrimLogical Min.PrimLogicalOr)
infix 2 ||~

doubleOfInt :: X.Exp () n -> X.Exp () n
doubleOfInt x
 = xPrim (PrimMinimal $ Min.PrimCast Min.PrimCastDoubleOfInt) @~ x

intOfDouble :: X.Exp () n -> X.Exp () n
intOfDouble x
 = xPrim (PrimMinimal $ Min.PrimCast Min.PrimCastIntOfDouble) @~ x

lam :: ValType -> (X.Exp () Text -> X.Exp () Text) -> X.Exp () Text
lam t f
 = let -- Try with a bad name - this won't necessarily be fresh,
       -- but it will allow us to get the variables in the expression
       init = f (xVar $ Name "$$$")
       vars = allvars init

       -- Look through all the numbers, and find one that isn't already
       -- used in the expression
       free = filter (not . flip Set.member vars)
            $ fmap varOfInt [0..]

       -- Take the head; free should be a practically infinite list.
       -- If it is empty, that means there are at least 2^64 variables
       -- in the expression and it isn't going to fit in memory.
       -- In that case, we might as well die anyway.
       v    = head_error free
   in  xLam v t (f $ xVar v)

 where
  head_error (x:_)
   = x
  head_error []
   = error "Icicle/Core/Exp/Combinators.hs: lam: this is impossible; taking the head of a nearly-infinite list should not fail"

  -- Convert an int to a variable name
  varOfInt :: Int -> Name Text
  varOfInt i
   = NameMod "_" $ Name $ T.pack $ show i

emptyBuf :: ValType -> X.Exp () n
emptyBuf = xPrim . PrimLatest . PrimLatestMake

pushBuf :: ValType -> X.Exp () n
pushBuf = xPrim . PrimLatest . PrimLatestPush

readBuf :: ValType -> X.Exp () n
readBuf = xPrim . PrimLatest . PrimLatestRead

-- Constructors with () annotations ------------------------

xVar :: Name n -> X.Exp () n
xVar = XVar ()

xPrim :: Prim -> X.Exp () n
xPrim = XPrim ()

xValue :: ValType -> BaseValue -> X.Exp () n
xValue = XValue ()

xApp :: X.Exp () n -> X.Exp () n -> X.Exp () n
xApp = XApp ()

xLam :: Name n -> ValType -> X.Exp () n -> X.Exp () n
xLam = XLam ()

xLet :: Name n -> X.Exp () n -> X.Exp () n -> X.Exp () n
xLet = XLet ()
