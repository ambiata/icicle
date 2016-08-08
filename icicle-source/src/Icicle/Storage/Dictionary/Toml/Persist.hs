{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE PatternGuards     #-}
module Icicle.Storage.Dictionary.Toml.Persist (
    normalisedTomlDictionary
  , normalisedFunctions
  ) where

import qualified Data.Text as T

import           Icicle.Data
import           Icicle.Dictionary.Data
import           Icicle.Storage.Encoding

import           Icicle.Internal.Pretty hiding ((</>))

import           P hiding (empty)

normalisedFunctions :: Dictionary -> Doc
normalisedFunctions dictionary
  =  "# Autogenerated Imports File -- Do Not Edit"
  <> line
  <> vcat (prettyFun <$> (dictionaryFunctions dictionary))
    where
      prettyFun (n,(_,v)) = pretty n <+> pretty v <> "."

normalisedTomlDictionary :: Dictionary -> Doc
normalisedTomlDictionary dictionary
  =  "# Autogenerated Dictionary File -- Do Not Edit"
  <> line
  <> "name" <+> "=" <+> dquotes "autogen"
  <> line
  <> "namespace" <+> "=" <+> dquotes "autogen"
  -- Everything is inlined, so we don't need an imports file.
  <> line
  <> "version" <+> "=" <+> "1"
  <> line
  <> "import" <+> "=" <+> brackets (dquotes "normalised_imports.icicle")
  <> line
  <> vcat (normalisedTomlDictionaryEntry <$> dictionaryEntries dictionary)

normalisedTomlDictionaryEntry :: DictionaryEntry -> Doc
normalisedTomlDictionaryEntry (DictionaryEntry attr (ConcreteDefinition enc ts mo) namespace) =
  brackets ("fact." <> (text $ T.unpack $ getAttribute attr))
  <> line
  <> indent 2 ("encoding" <+> "=" <+> tquotes (text $ T.unpack $ prettyConcrete enc))
  <> line
  <> indent 2 ("namespace" <+> "=" <+> tquotes (pretty namespace))
  <> line
  <> indent 2 ("mode" <+> "=" <+> tquotes (pretty mo))
  <> line
  <> tombstoneDoc
    where
      tombstoneDoc | t:[] <- toList ts
                   = indent 2 ("tombstone" <+> "=" <+> tquotes (text $ T.unpack $ t))
                   | otherwise
                   = empty

normalisedTomlDictionaryEntry (DictionaryEntry attr (VirtualDefinition virtual) _) =
  brackets ("feature." <> (text $ T.unpack $ getAttribute attr))
  <> line
  <> indent 2  "expression" <+> "=" <+> tquotes (pretty virtual)

tquotes :: Doc -> Doc
tquotes = dquotes . dquotes . dquotes
