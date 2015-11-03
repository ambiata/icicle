-- | Core types.
-- There is a split between "value types" and "function types" to simplify code generation.
-- The only higher-order functions should be those passed to primitives.
--
-- We also have no parametric polymorphism or type arguments:
-- at the moment I'm betting that the only polymorphism will be in primitives,
-- so not putting any polymorphism in the primitives should make typechecking
-- and everything simpler.
--
{-# LANGUAGE NoImplicitPrelude #-}
module Icicle.Common.Type (
      ValType (..)
    , FunType (..)
    , StructType (..)
    , StructField (..)
    , Type
    , funOfVal
    , arrow
    , defaultOfType

    , ArithType (..)
    , valTypeOfArithType
    , arithTypeOfValType

    , Env
    , lookupOrDie
    , insertOrDie

    , functionArguments
    , functionReturns
    , canApply
    , requireSame

    , valueMatchesType

    ) where

import              Icicle.Internal.Pretty
import              Icicle.Common.Base
import              Icicle.Data.DateTime (dateOfDays)

import              P

import qualified    Data.Map as Map
import qualified    Data.Text as T


-- | Real values.
-- No functions here, because we don't want higher order functions in the generated code.
-- This restriction should simplify code generation, because we won't need to
-- deal with lambda lifting arbitrary functions.
data ValType
 = BoolT
 | DateTimeT
 | DoubleT
 | IntT
 | StringT
 | UnitT
 | ErrorT
 | ArrayT  ValType
 | MapT    ValType    ValType
 | OptionT ValType
 | PairT   ValType    ValType
 | SumT    ValType    ValType
 | StructT StructType
 | BufT    ValType
 deriving (Eq,Ord,Show)


data ArithType
 = ArithIntT
 | ArithDoubleT
 deriving (Eq, Ord, Show)

valTypeOfArithType :: ArithType -> ValType
valTypeOfArithType ArithIntT    = IntT
valTypeOfArithType ArithDoubleT = DoubleT

arithTypeOfValType :: ValType -> Maybe ArithType
arithTypeOfValType IntT         = Just ArithIntT
arithTypeOfValType DoubleT      = Just ArithDoubleT
arithTypeOfValType _            = Nothing


defaultOfType :: ValType -> BaseValue
defaultOfType typ
 = case typ of
     BoolT     -> VBool False
     DateTimeT -> VDateTime (dateOfDays 0)
     DoubleT   -> VDouble 0
     IntT      -> VInt 0
     StringT   -> VString T.empty
     UnitT     -> VUnit
     ErrorT    -> VError ExceptTombstone
     ArrayT  _ -> VArray []
     MapT  _ _ -> VMap Map.empty
     OptionT _ -> VNone
     PairT a b -> VPair (defaultOfType a)
                        (defaultOfType b)
     SumT  a _ -> VLeft (defaultOfType a)
     StructT t -> VStruct (Map.map defaultOfType (getStructType t))
     BufT _    -> VBuf 0 []


data StructType
 = StructType
 { getStructType :: Map.Map StructField ValType }
 deriving (Eq, Ord)

instance Show StructType where
 showsPrec p (StructType x)
  = showParen (p > 10) (showString "StructType " . showsPrec 11 x)


-- | Function types.
-- These are the types of an entire expression, or types of arguments passed to primitives.
--
-- The list is the arguments of the function, and the return type must be a primitive value.
-- This means there can be no curried functions.
-- If there are no arguments, it is just a value - not a function.
--
-- We need the list of arguments to be FunTypes to express the types of primitives:
-- for example, array fold would have type
-- > FunT
-- >      [ FunT [b, a] b       ##    (b -> a -> b)
-- >      , FunT [] b           ##  -> b
-- >      , FunT [] (Array a)   ##  -> [a]
-- >      ]                     ##
-- >        b                   ##  -> b
--
data FunType =
 FunT [FunType] ValType
 deriving (Eq,Ord,Show)


-- | The top-level type of an expression can be a function type.
type Type = FunType


-- | Promote a value type to a zero-argument function type.
funOfVal :: ValType -> FunType
funOfVal = FunT []

-- | Construct a function type.
-- First is argument type, second is return type.
arrow :: FunType -> FunType -> FunType
arrow from (FunT args to)
 = FunT (from:args) to


-- | Get list of arguments to function type
functionArguments :: Type -> [Type]
functionArguments (FunT args _)
 = args

-- | Get final return type of function
functionReturns :: Type -> ValType
functionReturns (FunT _ r)
 = r

-- | Check if a function type can be applied to an argument.
-- If successful, returns the result type; otherwise Nothing.
canApply :: Type -> Type -> Maybe Type
canApply (FunT args p) q
 = case args of
    (b:bs)
     | b == q
     -> Just (FunT bs p)
    _
     -> Nothing


-- | Type environments: just a mapping from variable names to types.
-- Parametric in type because it could be a function type or a value type.
type Env n t = Map.Map (Name n) t


-- | Get from environment or return given error
lookupOrDie :: Ord n => (Name n -> err) -> Env n t -> Name n -> Either err t
lookupOrDie err e n
 = maybeToRight
        (err n)
        (Map.lookup n e)


-- | Attempt to insert a name into the environment.
-- However, core expressions cannot have name shadowing, so if it already exists return an error.
--
-- The rationale for disallowing shadowing is so:
--  - nobody will write in core, so we lose no expressivity;
--  - capture-avoiding substitution is hard to get right.
--
-- I think by disallowing shadowing and general lambdas, substitution should be a lot simpler.
--
insertOrDie :: Ord n => (Name n -> err) -> Env n t -> Name n -> t -> Either err (Env n t)
insertOrDie err e n t
 = case Map.lookup n e of
    Just _
     -> Left   $ err n
    _
     -> return $ Map.insert n t e


-- | Require two types to be equal, or return given error if not.
requireSame 
    :: Eq a
    => (a -> a -> err)
    ->  a -> a -> Either err ()
requireSame err p q
 | p == q
 = return ()
 | otherwise
 = Left $ err p q


valueMatchesType :: BaseValue -> ValType -> Bool
valueMatchesType v t
 = case (t,v) of
    (IntT, VInt{})
     -> True
    (IntT, _)
     -> False

    (DoubleT, VDouble{})
     -> True
    (DoubleT, _)
     -> False

    (UnitT, VUnit{})
     -> True
    (UnitT, _)
     -> False

    (ErrorT, VError _)
     -> True
    (ErrorT, _)
     -> False

    (BoolT, VBool{})
     -> True
    (BoolT, _)
     -> False

    (DateTimeT, VDateTime{})
     -> True
    (DateTimeT, _)
     -> False

    (StringT, VString _)
     -> True
    (StringT, _)
     -> False

    (ArrayT t', VArray vs')
     -> all (flip valueMatchesType t') vs'
    (ArrayT _, _)
     -> False

    (PairT p q, VPair a b)
     -> valueMatchesType a p && valueMatchesType b q
    (PairT _ _, _)
     -> False

    (SumT p _, VLeft a)
     -> valueMatchesType a p
    (SumT _ q, VRight b)
     -> valueMatchesType b q
    (SumT _ _, _)
     -> False

    (OptionT p, VSome a)
     -> valueMatchesType a p
    (OptionT _, VNone)
     -> True
    (OptionT _, _)
     -> False

    (MapT p q, VMap mv)
     -> all (flip valueMatchesType p) (Map.keys  mv)
     && all (flip valueMatchesType q) (Map.elems mv)
    (MapT _ _, _)
     -> False

    (StructT (StructType ts), VStruct vs)
     -> all (\(f,t') -> maybe False (flip valueMatchesType t') $ Map.lookup f vs) (Map.toList ts)
     && all (\(f,v') -> maybe False (     valueMatchesType v') $ Map.lookup f ts) (Map.toList vs)
    (StructT _, _)
     -> False

    (BufT t', VBuf _ vs')
     -> all (flip valueMatchesType t') vs'
    (BufT _, _)
     -> False


-- Pretty printing ---------------

instance Pretty ValType where
 pretty = ppTop

instance Pretty StructType where
 pretty (StructType fs) = text "Struct" <+> pretty (Map.toList fs)

instance Pretty FunType where
 pretty (FunT [] t)     = pretty t
 pretty (FunT (b:bs) t) = inner b <> text " -> " <> pretty (FunT bs t)
  where
   inner i@(FunT [] _) = pretty i
   inner i             = parens (pretty i)


ppTop :: ValType -> Doc
ppTop = ppValType False

ppSub :: ValType -> Doc
ppSub = ppValType True

ppValType :: Bool -> ValType -> Doc
ppValType needParens vt =
  case vt of
    IntT       -> text "Int"
    DoubleT    -> text "Double"
    UnitT      -> text "Unit"
    ErrorT     -> text "Error"
    BoolT      -> text "Bool"
    DateTimeT  -> text "DateTime"
    StringT    -> text "String"
    ArrayT t   -> parens' (text "Array " <>  ppSub t)
    MapT k v   -> parens' (text "Map"    <+> ppSub k <+> ppSub v)
    OptionT a  -> parens' (text "Option" <+> ppSub a)
    PairT a b  -> parens  (ppTop a <> text ", " <> ppTop b)
    SumT  a b  -> parens  (text "Sum" <+> ppSub a <+> ppSub b)
    StructT fs -> parens' (pretty fs)
    BufT t     -> parens' (text "Buf " <> ppSub t)
  where
    parens' | needParens = parens
            | otherwise  = id
