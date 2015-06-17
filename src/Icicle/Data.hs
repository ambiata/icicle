{-# LANGUAGE NoImplicitPrelude #-}
module Icicle.Data (
    Entity (..)
  , Attribute (..)
  , Fact (..)
  , Fact' (..)
  , AsAt (..)
  , Value (..)
  , Struct (..)
  , List (..)
  , Date (..)
  , DateTime (..)
  , Encoding (..)
  , StructField (..)
  , StructFieldType (..)
  , attributeOfStructField
  ) where

import           Data.Text
import qualified Text.PrettyPrint.Leijen as PP

import           Icicle.Data.DateTime

import           P


newtype Entity =
  Entity {
      getEntity     :: Text
    } deriving (Eq, Ord, Show)

instance PP.Pretty Entity where
  pretty (Entity t) = PP.text (unpack t)

newtype Attribute =
  Attribute {
      getAttribute  :: Text
    } deriving (Eq, Ord, Show)


data Fact =
  Fact {
      entity        :: Entity
    , attribute     :: Attribute
    , value         :: Value
    } deriving (Eq, Show)


data Fact' =
  Fact' {
      entity'       :: Entity
    , attribute'    :: Attribute
    , value'        :: Text
    } deriving (Eq, Show)


data AsAt a =
  AsAt {
      fact          :: a
    , time          :: DateTime
    } deriving (Eq, Show)


data Value =
    StringValue     Text
  | IntValue        Int
  | DoubleValue     Double
  | BooleanValue    Bool
  | DateValue       Date
  | StructValue     Struct
  | ListValue       List
  | PairValue       Value Value
  | MapValue        [(Value, Value)]
  | Tombstone
  deriving (Eq, Show)

instance PP.Pretty Value where
  pretty v = case v of
    StringValue t  -> PP.text (unpack t)
    IntValue    i  -> PP.int i
    DoubleValue d  -> PP.double d
    BooleanValue b -> PP.pretty b
    -- I'm too lazy
    _              -> PP.text (show v)

data Struct =
  Struct    [(Attribute, Value)]
  deriving (Eq, Show)


data List =
  List      [Value]
  deriving (Eq, Show)


data Date =
  Date {
      getDate       :: Text -- FIX complete, make these real...
    } deriving (Eq, Show)



data Encoding =
    StringEncoding
  | IntEncoding
  | DoubleEncoding
  | BooleanEncoding
  | DateEncoding
  | StructEncoding  [StructField]
  | ListEncoding    Encoding
  deriving (Eq, Show)


data StructField =
    StructField StructFieldType Attribute Encoding
  deriving (Eq, Show)

attributeOfStructField :: StructField -> Attribute
attributeOfStructField (StructField _ attr _)
  = attr


data StructFieldType =
    Mandatory
  | Optional
  deriving (Eq, Show)
