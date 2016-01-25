{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards     #-}
module Icicle.Sea.Psv.Input where


import qualified Data.ByteString as B
import qualified Data.Map as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Data.Word (Word8)

import           Icicle.Avalanche.Prim.Flat (Prim(..), PrimUpdate(..))
import           Icicle.Avalanche.Prim.Flat (meltType)

import           Icicle.Common.Type (ValType(..), StructType(..), StructField(..))
import           Icicle.Common.Type (defaultOfType)

import           Icicle.Data (Attribute(..))

import           Icicle.Internal.Pretty
import qualified Icicle.Internal.Pretty as Pretty

import           Icicle.Sea.Error (SeaError(..))
import           Icicle.Sea.FromAvalanche.Prim
import           Icicle.Sea.FromAvalanche.Program (seaOfXValue)
import           Icicle.Sea.FromAvalanche.State
import           Icicle.Sea.FromAvalanche.Type
import Icicle.Sea.Psv.Base

import           P


seaOfReadAnyFact :: PsvConfig -> [SeaProgramState] -> Either SeaError Doc
seaOfReadAnyFact config states = do
  let tss = fmap (lookupTombstones config) states
  readStates_sea <- zipWithM seaOfReadFact states tss
  pure $ vsep
    [ vsep readStates_sea
    , ""
    , "#line 1 \"read any fact\""
    , "static ierror_loc_t psv_read_fact"
    , "  ( const char   *attrib_ptr"
    , "  , const size_t  attrib_size"
    , "  , const char   *value_ptr"
    , "  , const size_t  value_size"
    , "  , const char   *time_ptr"
    , "  , const size_t  time_size"
    , "  , ifleet_t     *fleet )"
    , "{"
    , indent 4 (vsep (fmap seaOfReadNamedFact states))
    , "    return 0;"
    , "}"
    ]

seaOfReadNamedFact :: SeaProgramState -> Doc
seaOfReadNamedFact state
 = let attrib = getAttribute (stateAttribute state)
       fun    = pretty (nameOfReadFact state)
       pname  = pretty (nameOfProgram  state)
       tname  = pretty (nameOfLastTime state)
   in vsep
      [ "/* " <> pretty attrib <> " */"
      , "if (" <> seaOfStringEq attrib "attrib_ptr" (Just "attrib_size") <> ") {"
      , "    itime_t time;"
      , "    ierror_loc_t error = fixed_read_itime (time_ptr, time_size, &time);"
      , "    if (error) return error;"
      , ""
      , "    ibool_t        ignore_time = itrue;"
      , "    iint_t         chord_count = fleet->chord_count;"
      , "    const itime_t *chord_times = fleet->chord_times;"
      , ""
      , "    /* ignore this time if it comes after all the chord times */"
      , "    for (iint_t chord_ix = 0; chord_ix < chord_count; chord_ix++) {"
      , "        if (chord_times[chord_ix] >= time) {"
      , "            ignore_time = ifalse;"
      , "            break;"
      , "        }"
      , "    }"
      , ""
      , "    if (ignore_time) return 0;"
      , ""
      , "    itime_t last_time = fleet->" <> tname <> ";"
      , ""
      , "    if (time <= last_time) {"
      , "        char curr_time_ptr[text_itime_max_size];"
      , "        size_t curr_time_size = text_write_itime (time, curr_time_ptr);"
      , ""
      , "        char last_time_ptr[text_itime_max_size];"
      , "        size_t last_time_size = text_write_itime (last_time, last_time_ptr);"
      , ""
      , "        return ierror_loc_format"
      , "           ( time_ptr + time_size"
      , "           , time_ptr"
      , "           , \"%.*s: time is out of order: %.*s must be later than %.*s\""
      , "           , attrib_size"
      , "           , attrib_ptr"
      , "           , curr_time_size"
      , "           , curr_time_ptr"
      , "           , last_time_size"
      , "           , last_time_ptr );"
      , "    }"
      , ""
      , "    fleet->" <> tname <> " = time;"
      , ""
      , "    return " <> fun <> " (value_ptr, value_size, time, fleet->mempool, chord_count, fleet->" <> pname <> ");"
      , "}"
      , ""
      ]

------------------------------------------------------------------------

nameOfReadFact :: SeaProgramState -> Text
nameOfReadFact state = T.pack ("psv_read_fact_" <> show (stateName state))

seaOfReadFact :: SeaProgramState -> Set Text -> Either SeaError Doc
seaOfReadFact state tombstones = do
  input     <- checkInputType state
  readInput <- seaOfReadInput input
  pure $ vsep
    [ "#line 1 \"read fact" <+> seaOfStateInfo state <> "\""
    , "static ierror_loc_t INLINE"
        <+> pretty (nameOfReadFact state) <+> "("
        <> "const char *value_ptr, const size_t value_size, itime_t time, "
        <> "imempool_t *mempool, iint_t chord_count, "
        <> pretty (nameOfStateType state) <+> "*programs)"
    , "{"
    , "    ierror_loc_t error;"
    , ""
    , "    char *p  = (char *) value_ptr;"
    , "    char *pe = (char *) value_ptr + value_size;"
    , ""
    , "    ierror_t " <> pretty (inputSumError input) <> ";"
    , indent 4 . vsep . fmap seaOfDefineInput $ inputVars input
    , ""
    , "    " <> align (seaOfReadTombstone input (Set.toList tombstones)) <> "{"
    , "        " <> pretty (inputSumError input) <> " = ierror_not_an_error;"
    , ""
    , indent 8 readInput
    , "    }"
    , ""
    , "    for (iint_t chord_ix = 0; chord_ix < chord_count; chord_ix++) {"
    , "        " <> pretty (nameOfStateType state) <+> "*program = &programs[chord_ix];"
    , ""
    , "        /* don't read values after the chord time */"
    , "        if (time > program->" <> pretty (stateTimeVar state) <> ")"
    , "            continue;"
    , ""
    , "        iint_t new_count = program->new_count;"
    , ""
    , "        program->" <> pretty (inputSumError  input) <> "[new_count] = " <> pretty (inputSumError input) <> ";"
    , indent 8 . vsep . fmap seaOfAssignInput $ inputVars input
    , "        program->" <> pretty (inputTime     input) <> "[new_count] = time;"
    , ""
    , "        new_count++;"
    , ""
    , "        if (new_count == psv_max_row_count) {"
    , "             " <> pretty (nameOfProgram state) <> " (program);"
    , "             new_count = 0;"
    , "        } else if (new_count > psv_max_row_count) {"
    , "             return ierror_loc_format (0, 0, \"" <> pretty (nameOfReadFact state) <> ": new_count > max_count\");"
    , "        }"
    , ""
    , "        program->new_count = new_count;"
    , "    }"
    , ""
    , "    return 0; /* no error */"
    , "}"
    , ""
    ]

seaOfAssignInput :: (Text, ValType) -> Doc
seaOfAssignInput (n, _)
 = "program->" <> pretty n <> "[new_count] = " <> pretty n <> ";"

seaOfDefineInput :: (Text, ValType) -> Doc
seaOfDefineInput (n, t)
 = seaOfValType t <+> pretty n <> initType t

initType :: ValType -> Doc
initType vt = " = " <> seaOfXValue (defaultOfType vt) vt <> ";"

------------------------------------------------------------------------

seaOfReadTombstone :: CheckedInput -> [Text] -> Doc
seaOfReadTombstone input = \case
  []     -> Pretty.empty
  (t:ts) -> "if (" <> seaOfStringEq t "value_ptr" (Just "value_size") <> ") {" <> line
         <> "    " <> pretty (inputSumError input) <> " = ierror_tombstone;" <> line
         <> "} else " <> seaOfReadTombstone input ts

------------------------------------------------------------------------

data CheckedInput = CheckedInput {
    inputSumError :: Text
  , inputTime     :: Text
  , inputType     :: ValType
  , inputVars     :: [(Text, ValType)]
  } deriving (Eq, Ord, Show)

checkInputType :: SeaProgramState -> Either SeaError CheckedInput
checkInputType state
 = case stateInputType state of
     PairT (SumT ErrorT t) TimeT
      | (sumError, ErrorT) : xs0 <- stateInputVars state
      , Just vars                <- init xs0
      , Just (time, TimeT)       <- last xs0
      -> Right CheckedInput {
             inputSumError = newPrefix <> sumError
           , inputTime     = newPrefix <> time
           , inputType     = t
           , inputVars     = fmap (first (newPrefix <>)) vars
           }

     t
      -> Left (SeaUnsupportedInputType t)

seaOfReadInput :: CheckedInput -> Either SeaError Doc
seaOfReadInput input
 = case (inputVars input, inputType input) of
    ([(nx, BoolT)], BoolT)
     -> pure (readValue "text" assignVar nx BoolT)

    ([(nx, DoubleT)], DoubleT)
     -> pure (readValue "text" assignVar nx DoubleT)

    ([(nx, IntT)], IntT)
     -> pure (readValue "text" assignVar nx IntT)

    ([(nx, TimeT)], TimeT)
     -> pure (readValue "text" assignVar nx TimeT)

    ([(nx, StringT)], StringT)
     -> pure (readValuePool "text" assignVar nx StringT)

    (_, t@(ArrayT _))
     -> seaOfReadJsonValue assignVar t (inputVars input)

    (_, t@(StructT _))
     -> seaOfReadJsonValue assignVar t (inputVars input)

    (_, t)
     -> Left (SeaUnsupportedInputType t)

------------------------------------------------------------------------

-- Describes how to assign to a C struct member, this changes for arrays
type Assignment = Doc -> ValType -> Doc -> Doc

assignVar :: Assignment
assignVar n _ x = pretty n <+> "=" <+> x <> ";"

assignArray :: Assignment
assignArray n t x = n <+> "=" <+> seaOfArrayPut n "ix" x t <> ";"

seaOfArrayPut :: Doc -> Doc -> Doc -> ValType -> Doc
seaOfArrayPut arr ix val typ
 = seaOfPrimDocApps (seaOfXPrim (PrimUpdate (PrimUpdateArrayPut typ)))
                    [ arr, ix, val ]

------------------------------------------------------------------------

seaOfReadJsonValue :: Assignment -> ValType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonValue assign vtype vars
 = case (vars, vtype) of
     ([(nb, BoolT), nx], OptionT t) -> do
       val_sea <- seaOfReadJsonValue assign t [nx]
       pure $ vsep
         [ "ibool_t is_null;"
         , "error = json_try_read_null (&p, pe, &is_null);"
         , "if (error) return error;"
         , ""
         , "if (is_null) {"
         , indent 4 (assign (pretty nb) BoolT "ifalse")
         , "} else {"
         , indent 4 (assign (pretty nb) BoolT "itrue")
         , ""
         , indent 4 val_sea
         , "}"
         ]

     ([(nx, BoolT)], BoolT)
      -> pure (readValue "json" assign nx BoolT)

     ([(nx, IntT)], IntT)
      -> pure (readValue "json" assign nx IntT)

     ([(nx, DoubleT)], DoubleT)
      -> pure (readValue "json" assign nx DoubleT)

     ([(nx, TimeT)], TimeT)
      -> pure (readValue "json" assign nx TimeT)

     ([(nx, StringT)], StringT)
      -> pure (readValuePool "json" assign nx StringT)

     (ns, StructT t)
      -> seaOfReadJsonObject assign t ns

     (ns, ArrayT t)
      -> seaOfReadJsonList t ns

     _
      -> Left (SeaInputTypeMismatch vtype vars)

------------------------------------------------------------------------

readValue :: Doc -> Assignment -> Text -> ValType -> Doc
readValue
 = readValueArg ""

readValuePool :: Doc -> Assignment -> Text -> ValType -> Doc
readValuePool
 = readValueArg "mempool, "

readValueArg :: Doc -> Doc -> Assignment -> Text -> ValType -> Doc
readValueArg arg fmt assign n vt
 = vsep
 [ seaOfValType vt <+> "value;"
 , "error = " <> fmt <> "_read_" <> baseOfValType vt <> " (" <> arg <> "&p, pe, &value);"
 , "if (error) return error;"
 , assign (pretty n) vt "value"
 ]

------------------------------------------------------------------------

seaOfReadJsonList :: ValType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonList vtype avars = do
  vars      <- traverse unArray avars
  value_sea <- seaOfReadJsonValue assignArray vtype vars
  pure $ vsep
    [ "if (*p++ != '[')"
    , "    return ierror_loc_format (p-1, p-1, \"array missing '['\");"
    , ""
    , "char term = *p;"
    , ""
    , "for (iint_t ix = 0; term != ']'; ix++) {"
    , indent 4 value_sea
    , "    "
    , "    term = *p++;"
    , "    if (term != ',' && term != ']')"
    , "        return ierror_loc_format (p-1, p-1, \"array separator ',' or terminator ']' not found\");"
    , "}"
    ]

unArray :: (Text, ValType) -> Either SeaError (Text, ValType)
unArray (n, ArrayT t) = Right (n, t)
unArray (n, t)        = Left (SeaInputTypeMismatch t [(n, t)])

------------------------------------------------------------------------

seaOfReadJsonObject :: Assignment -> StructType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonObject assign st@(StructType fs) vars
 = case vars of
    [(nx, UnitT)] | Map.null fs -> seaOfReadJsonUnit   assign nx
    _                           -> seaOfReadJsonStruct assign st vars

seaOfReadJsonUnit :: Assignment -> Text -> Either SeaError Doc
seaOfReadJsonUnit assign name = do
  pure $ vsep
    [ "if (*p++ != '{')"
    , "    return ierror_loc_format (p-1, p-1, \"unit missing '{'\");"
    , ""
    , "if (*p++ != '}')"
    , "    return ierror_loc_format (p-1, p-1, \"unit missing '}'\");"
    , ""
    , assign (pretty name) UnitT "iunit"
    ]

seaOfReadJsonStruct :: Assignment -> StructType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonStruct assign st@(StructType fields) vars = do
  let mismatch = SeaStructFieldsMismatch st vars
  mappings     <- maybe (Left mismatch) Right (mappingOfFields (Map.toList fields) vars)
  mappings_sea <- traverse (seaOfFieldMapping assign) mappings
  pure $ vsep
    [ "if (*p++ != '{')"
    , "    return ierror_loc_format (p-1, p-1, \"struct missing '{'\");"
    , ""
    , "for (;;) {"
    , "    if (*p++ != '\"')"
    , "        return ierror_loc_format (p-1, p-1, \"field name missing opening quote\");"
    , ""
    , indent 4 (vsep mappings_sea)
    , "    return ierror_loc_format (p-1, p-1, \"invalid field start\");"
    , "}"
    ]

seaOfFieldMapping :: Assignment -> FieldMapping -> Either SeaError Doc
seaOfFieldMapping assign (FieldMapping fname ftype vars) = do
  let needle = fname <> "\""
  field_sea <- seaOfReadJsonField assign ftype vars
  pure $ vsep
    [ "/* " <> pretty fname <> " */"
    , "if (" <> seaOfStringEq needle "p" Nothing <> ") {"
    , "    p += " <> int (sizeOfString needle) <> ";"
    , ""
    , indent 4 field_sea
    , ""
    , "    continue;"
    , "}"
    , ""
    ]

seaOfReadJsonField :: Assignment -> ValType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonField assign ftype vars = do
  value_sea <- seaOfReadJsonValue assign ftype vars
  pure $ vsep
    [ "if (*p++ != ':')"
    , "    return ierror_loc_format (p-1, p-1, \"field missing ':'\");"
    , ""
    , value_sea
    , ""
    , "char term = *p++;"
    , "if (term != ',' && term != '}')"
    , "    return ierror_loc_format (p-1, p-1, \"field separator ',' or terminator '}' not found\");"
    , ""
    , "if (term == '}')"
    , "    break;"
    ]

seaOfStringEq :: Text -> Doc -> Maybe Doc -> Doc
seaOfStringEq str ptr msize
 | Just size <- msize = align (vsep [szdoc size, cmpdoc])
 | otherwise          = align cmpdoc
 where
   nbytes = length bytes
   bytes  = B.unpack (T.encodeUtf8 str)

   szdoc size = size <+> "==" <+> int nbytes <+> "&&"
   cmpdoc     = seaOfBytesEq bytes ptr

seaOfBytesEq :: [Word8] -> Doc -> Doc
seaOfBytesEq bs ptr
 = vsep . punctuate " &&" . fmap go $ wordsOfBytes bs
 where
   go (StringWord off _ mask bits)
    = "(*(uint64_t *)(" <> ptr <+> "+" <+> int off <> ") &" <+> mask <> ") ==" <+> bits

------------------------------------------------------------------------

data FieldMapping = FieldMapping {
    _fieldName :: Text
  , _fieldType :: ValType
  , _fieldVars :: [(Text, ValType)]
  } deriving (Eq, Ord, Show)

mappingOfFields :: [(StructField, ValType)] -> [(Text, ValType)] -> Maybe [FieldMapping]
mappingOfFields []     []  = pure []
mappingOfFields []     _   = Nothing
mappingOfFields (f:fs) vs0 = do
  (m,  vs1) <- mappingOfField  f  vs0
  ms        <- mappingOfFields fs vs1
  pure (m : ms)

mappingOfField :: (StructField, ValType) -> [(Text, ValType)] -> Maybe (FieldMapping, [(Text, ValType)])
mappingOfField (StructField fname, ftype) vars0 = do
  let go t (n, t')
       | t == t'   = Just (n, t)
       | otherwise = Nothing

  ns <- zipWithM go (meltType ftype) vars0

  let mapping = FieldMapping fname ftype ns
      vars1   = drop (length ns) vars0

  return (mapping, vars1)

------------------------------------------------------------------------

lookupTombstones :: PsvConfig -> SeaProgramState -> Set Text
lookupTombstones config state =
  fromMaybe Set.empty (Map.lookup (stateAttribute state) (psvTombstones config))

nameOfLastTime :: SeaProgramState -> Text
nameOfLastTime state = "last_time_" <> T.pack (show (stateName state))

sizeOfString :: Text -> Int
sizeOfString = B.length . T.encodeUtf8

------------------------------------------------------------------------
-- Should be in P?

last :: [a] -> Maybe a
last []     = Nothing
last (x:[]) = Just x
last (_:xs) = last xs

init :: [a] -> Maybe [a]
init []     = Nothing
init (_:[]) = Just []
init (x:xs) = (x:) <$> init xs
