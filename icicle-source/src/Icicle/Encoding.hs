-- | Working with values and their encodings.
-- Parsing, rendering etc.
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards     #-}
{-# LANGUAGE ViewPatterns      #-}

module Icicle.Encoding (
    DecodeError (..)
  , renderDecodeError
  , renderValue
  , parseValue
  , valueSatisfiesEncoding
  , primitiveEncoding
  , valueOfJSON
  , jsonOfValue
  , sourceTypeOfEncoding
  , normaliseSparseState
  , normaliseSparseStates
  ) where

import           Data.Attoparsec.ByteString
import           Data.Text              as T
import           Data.Text.Read         as T
import           Data.Text.Encoding     as T

import qualified Data.Aeson             as A
import qualified Data.Scientific        as S

import qualified Data.ByteString.Lazy   as BS
import qualified Data.HashMap.Strict    as HM
import qualified Data.Map               as Map
import qualified Data.Set               as Set
import qualified Data.Vector            as V

import qualified Icicle.Common.Type     as IT
import           Icicle.Data
import           Icicle.Data.Time

import           P



data DecodeError =
   DecodeErrorBadInput           Text Encoding
 | DecodeErrorMissingStructField Attribute
 | DecodeErrorNotInDictionary    Attribute
 | DecodeErrorValueForVirtual    Attribute
 | DecodeErrorMismatchedState    Attribute Value Value
   deriving (Eq, Show)


renderDecodeError :: DecodeError -> Text
renderDecodeError (DecodeErrorBadInput val enc) =
  "Could not decode value '" <> val <> "' of type " <> T.pack (show enc)
renderDecodeError (DecodeErrorMissingStructField attr) =
  "Missing struct field " <> getAttribute attr
renderDecodeError (DecodeErrorNotInDictionary attr) =
  "Given attribute is not in dictionary: " <> getAttribute attr
renderDecodeError (DecodeErrorValueForVirtual attr) =
  "Cannot set values for virtual features: " <> getAttribute attr
renderDecodeError (DecodeErrorMismatchedState attr x y) =
  "Mismatched sparse state values of " <> getAttribute attr
                                       <> ": "    <> T.pack (show x)
                                       <> " and " <> T.pack (show y)

primitiveEncoding :: Encoding -> Bool
primitiveEncoding e
 = case e of
   StringEncoding   -> True
   IntEncoding      -> True
   DoubleEncoding   -> True
   BooleanEncoding  -> True
   TimeEncoding     -> True
   StructEncoding _ -> False
   ListEncoding   _ -> False


-- | Check whether a value satisfies given encoding.
-- This is only really useful for testing.
valueSatisfiesEncoding :: Value -> Encoding -> Bool
valueSatisfiesEncoding val enc
 = case val of
    StringValue  _
     -> enc == StringEncoding
    IntValue     _
     -> enc == IntEncoding
    DoubleValue  _
     -> enc == DoubleEncoding
    BooleanValue _
     -> enc == BooleanEncoding
    TimeValue    _
     -> enc == TimeEncoding

    StructValue  (Struct vals)
     | StructEncoding fields <- enc
     -> P.all (valueHasField fields) vals
     && P.all (fieldHasValue vals)   fields
     | otherwise
     -> False

    ListValue    (List ls)
     | ListEncoding le <- enc
     -> P.all (flip valueSatisfiesEncoding le) ls
     | otherwise
     -> False

    Tombstone
     -> True

    -- TODO: add pair and map encodings
    PairValue{}
     -> False
    MapValue{}
     -> False
 where
  valueHasField fields (attr,v)
   | Just f <- P.find ((==attr).attributeOfStructField) fields
   , StructField _ _ e <- f
   = valueSatisfiesEncoding v e
   | otherwise
   = False

  fieldHasValue vals (StructField Mandatory attr _)
   | Just _ <- P.find ((==attr).fst)                    vals
   = True
   | otherwise
   = False

  fieldHasValue _    (StructField Optional _ _)
   = True




-- | Render value in a form readable by "parseValue".
renderValue :: Text -> Value -> Text
renderValue tombstone val
 = case val of
   StringValue v
    -> v
   IntValue v
    -> T.pack $ show v
   DoubleValue v
    -> T.pack $ show v
   BooleanValue False
    -> "false"
   BooleanValue True
    -> "true"
   TimeValue v
    -> renderTime v

   StructValue _
    -> json
   ListValue _
    -> json
   Tombstone
    -> tombstone

   PairValue{}
    -> json
   MapValue{}
    -> json
 where
  json
   = T.decodeUtf8
   $ BS.toStrict
   $ A.encode
   $ jsonOfValue tombstone val


-- | Attempt to decode value with given encoding.
-- Some values may fit multiple encodings.
parseValue :: Encoding -> Set.Set Text -> Text -> Either DecodeError Value
parseValue e tombstone t
 | Set.member t tombstone
 = return Tombstone
 | otherwise
 = case e of
    StringEncoding
     -> return (StringValue t)

    IntEncoding
     -> tryDecode IntValue      (T.signed T.decimal)
    DoubleEncoding
     -> tryDecode DoubleValue   (T.signed T.double)

    BooleanEncoding
     | T.toLower t == "true"
     -> return $ BooleanValue True
     | T.toLower t == "false"
     -> return $ BooleanValue False
     | otherwise
     -> Left err

    TimeEncoding
     | Just v <- timeOfText t
     -> return $ TimeValue v
     | otherwise
     -> Left err

    StructEncoding _
     | Right v <- parsed
     -> valueOfJSON e v
     | otherwise
     -> Left err

    ListEncoding _
     | Right v <- parsed
     -> valueOfJSON e v
     | otherwise
     -> Left err

 where
  tryDecode f p
   = f <$> maybeToRight err (readAll p t)
  err
   = DecodeErrorBadInput t e

  parsed
   = parseOnly A.json
   $ T.encodeUtf8 t

-- | Attempt to decode value from JSON
valueOfJSON :: Encoding -> A.Value -> Either DecodeError Value
valueOfJSON _ A.Null
 = return Tombstone
valueOfJSON e v
 = case e of
    StringEncoding
     | A.String t <- v
     -> return $ StringValue t
     | A.Number n <- v
     -> return $ StringValue $ T.pack $ show n
     | otherwise
     -> Left err

    IntEncoding
     | A.Number n <- v
     , Just   i <- S.toBoundedInteger n
     -> return $ IntValue $ i
     | otherwise
     -> Left err

    DoubleEncoding
     | A.Number n <- v
     -> return $ DoubleValue $ S.toRealFloat n
     | otherwise
     -> Left err

    BooleanEncoding
     | A.Bool b <- v
     -> return $ BooleanValue b
     | otherwise
     -> Left err

    TimeEncoding
     | A.String t <- v
     , Just d <- timeOfText t
     -> return $ TimeValue d
     | otherwise
     -> Left err

    StructEncoding fields
     | A.Object obj <- v
     ->  StructValue . Struct . P.concat
     <$> mapM (getStructField obj) fields
     | otherwise
     -> Left err

    ListEncoding l
     | A.Array arr <- v
     ->  ListValue . List
     <$> mapM (valueOfJSON l) (V.toList arr)
     | otherwise
     -> Left err

 where
  err
   = DecodeErrorBadInput (T.pack $ show v) e

  getStructField obj field
   = case field of
      StructField Mandatory attr enc
       | Just val <- getField obj attr
       -> do    v' <- valueOfJSON enc val
                return [(attr, v')]
       | otherwise
       -> Left  (DecodeErrorMissingStructField attr)

      StructField Optional  attr enc
       | Just val <- getField obj attr
       -> do    v' <- valueOfJSON enc val
                return [(attr, v')]
       | otherwise
       -> return []

  getField obj attr
   = HM.lookup (getAttribute attr) obj

-- Render as json. This is as close to Ivory output as
-- is possible. "No Value" or "Tombstoned" values are
-- rendered as the json null type.
-- Map and pair values are encoded as a json struct
-- with the first items as the json keys. This has the
-- obvious downside that all encoding are rendered as
-- strings. The tombstone value from renderValue is
-- used as the key if this is required (as one can't
-- use json null as the key).
jsonOfValue :: Text -> Value -> A.Value
jsonOfValue t val
 = case val of
    StringValue v
     -> A.String v
    IntValue v
     -> A.Number $ P.fromIntegral v
    DoubleValue v
     -> A.Number $ S.fromFloatDigits v
    BooleanValue v
     -> A.Bool   v
    TimeValue    v
     -> A.String $ renderTime v
    StructValue (Struct sfs)
     -> A.Object $ P.foldl insert HM.empty sfs
    ListValue (List l)
     -> A.Array  $ V.fromList $ fmap (jsonOfValue t) l
    Tombstone
     -> A.Null
    PairValue k v
      -> A.Object $ pair k v
    MapValue kvs
     -> A.Array $ V.fromList $ fmap (jsonOfValue t . uncurry PairValue) kvs
 where
  insert hm (attr,v)
   = HM.insert (getAttribute attr) (jsonOfValue t v) hm
  pair k v
   = HM.singleton (renderValue t k) (jsonOfValue t v)


-- | Perform read, only succeed if all input is used
readAll :: T.Reader a -> T.Text -> Maybe a
readAll r t
 | Right (v, rest) <- r t
 , T.null rest
 = Just v

 | otherwise
 = Nothing

sourceTypeOfEncoding :: Encoding -> IT.ValType
sourceTypeOfEncoding e
 = case e of
    StringEncoding
     -> IT.StringT
    IntEncoding
     -> IT.IntT
    DoubleEncoding
     -> IT.DoubleT
    BooleanEncoding
     -> IT.BoolT
    TimeEncoding
     -> IT.TimeT
    StructEncoding fs
     -> IT.StructT
      $ IT.StructType
      $ Map.fromList
      $ fmap goStructField fs
    ListEncoding e'
     -> IT.ArrayT
      $ sourceTypeOfEncoding e'

 where

  goStructField (StructField Mandatory attr enc)
    = ( IT.StructField $ getAttribute attr
      , sourceTypeOfEncoding enc)

  goStructField (StructField Optional attr enc)
    = ( IT.StructField $ getAttribute attr
      , IT.OptionT $ sourceTypeOfEncoding enc)


normaliseSparseState :: NormalisedFact -> Fact Value -> Maybe NormalisedFact
normaliseSparseState st fact = do
  v <- upd (get st) (factValue fact)
  pure $ NormalisedFact (fact { factValue = v}) (factMode st)
  where
    get = factValue . factNormalised

    upd (StructValue (Struct xs)) (StructValue (Struct ys))
     = Just $ StructValue $ Struct $ Map.toList $ Map.union (Map.fromList ys) (Map.fromList xs)
    upd _ _
     = Nothing

-- | Normalise all facts. All raw facts must be provided at once.
normaliseSparseStates :: [AsAt (Fact Value, FactMode)] -> Either DecodeError [AsAt NormalisedFact]
normaliseSparseStates facts = P.reverse . snd <$> foldM go mempty facts
  where
    go (states, xs) (fmap norm -> fact)
      | modeOf fact == FactModeStateSparse
      , a <- attrOf fact
      = case Map.lookup a states of
          Nothing
            -> return (Map.insert a fact states, fact : xs)
          Just st
            -> do f <- maybeToRight (DecodeErrorMismatchedState a (valOf st) (valOf fact))
                     $ normaliseSparseState (atFact st) (factOf fact)
                  let st' = st { atFact = f }
                  return (Map.insert a st' states, st' : xs)
      | otherwise
      = return (states, fact : xs)

    attrOf = factAttribute  . factOf
    valOf  = factValue      . factOf
    factOf = factNormalised . atFact
    modeOf = factMode       . atFact

    norm = uncurry NormalisedFact
