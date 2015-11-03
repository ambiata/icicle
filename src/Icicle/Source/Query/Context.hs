-- | Contexts that filter, group, and do stuff on the input
-- before they hit the expression.
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Icicle.Source.Query.Context (
    Context'  (..)
  , Fold      (..)
  , FoldType  (..)
  , annotOfContext
  ) where

import                  Icicle.Source.Query.Exp
import                  Icicle.Internal.Pretty
import                  Icicle.Common.Base

import                  P


data Context' q a n
 = Windowed a WindowUnit (Maybe WindowUnit) WindowFrame
 | Latest a Int
 | GroupBy   a          (Exp' q a n)
 | Distinct  a          (Exp' q a n)
 | Filter    a          (Exp' q a n)
 | LetFold   a          (Fold q a n)
 | Let       a (Name n) (Exp' q a n)
 | GroupFold a (Name n) (Name n) (Exp' q a n)
 deriving (Show, Eq, Ord)

data Fold q a n
 = Fold
 { foldBind :: Name n
 , foldInit :: Exp' q a n
 , foldWork :: Exp' q a n
 , foldType :: FoldType }
 deriving (Show, Eq, Ord)

data FoldType
 = FoldTypeFoldl1
 | FoldTypeFoldl
 deriving (Show, Eq, Ord)


annotOfContext :: Context' q a n -> a
annotOfContext c
 = case c of
    Windowed  a _ _ _ -> a
    Latest    a _     -> a
    GroupBy   a _     -> a
    GroupFold a _ _ _ -> a
    Distinct  a _     -> a
    Filter    a _     -> a
    LetFold   a _     -> a
    Let       a _ _   -> a

instance (Pretty n, Pretty q) => Pretty (Context' q a n) where
 pretty cc
  = case cc of
     Windowed _ newer Nothing Framed
      -> "framed" <+> "windowed" <+> pretty newer
     Windowed _ newer (Just older) Framed
      -> "framed" <+> "windowed between" <+> pretty older
                  <+> "and" <+> pretty newer
     Windowed _ newer Nothing Unframed
      -> "windowed" <+> pretty newer
     Windowed _ newer (Just older) Unframed
      -> "windowed between" <+> pretty older
                  <+> "and" <+> pretty newer
     Latest   _ i
      -> "latest"   <+> pretty i
     GroupBy  _ x
      -> "group"    <+> pretty x
     GroupFold  _ n1 n2 x
      ->  "group fold"
      <+> pretty (n1, n2)
      <+> "="
      <+> pretty x
     Distinct _ x
      -> "distinct" <+> pretty x
     Filter   _ x
      -> "filter"   <+> pretty x
     LetFold  _ f
      ->  pretty (foldType f)
      <+> pretty (foldBind f)
      <+> "="
      <+> pretty (foldInit f)
      <+> ":"
      <+> pretty (foldWork f)

     Let _ b x
      ->  "let"
      <+> pretty b
      <+> "="
      <+> pretty x


instance Pretty FoldType where
 pretty FoldTypeFoldl1
  = "fold1"
 pretty FoldTypeFoldl
  = "fold"
