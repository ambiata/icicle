{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards     #-}
{-# LANGUAGE TupleSections     #-}
module Icicle.Sea.IO.Psv.Input
  ( seaOfReadAnyFactPsv
  , seaInputPsv
  , PsvInputDenseDict (..)
  , PsvInputFormat (..)
  , PsvInputConfig (..)
  ) where


import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Set as Set
import           Data.Set (Set)

import           Icicle.Common.Type (ValType(..), StructType(..), StructField(..))

import           Icicle.Data (Attribute(..), StructFieldType(..))

import           Icicle.Storage.Dictionary.Toml.Dense (PsvInputDenseDict(..), MissingValue, PsvInputDenseFeedName)

import           Icicle.Internal.Pretty
import qualified Icicle.Internal.Pretty as Pretty

import           Icicle.Sea.Error (SeaError(..))
import           Icicle.Sea.FromAvalanche.State
import           Icicle.Sea.FromAvalanche.Type
import           Icicle.Sea.IO.Psv.Base
import qualified Icicle.Sea.IO.Base.Input as Base

import           P


data PsvInputConfig = PsvInputConfig {
    inputPsvMode        :: PsvMode
  , inputPsvFormat      :: PsvInputFormat
  } deriving (Eq, Ord, Show)

data PsvInputFormat
  = PsvInputSparse
  | PsvInputDense  PsvInputDenseDict PsvInputDenseFeedName
  deriving (Eq, Ord, Show)

--------------------------------------------------------------------------------

-- * Psv input "interface"

seaInputPsv :: Base.SeaInput
seaInputPsv = Base.SeaInput
  { Base.cstmtReadFact     = seaOfReadFact
  , Base.cstmtReadTime     = seaOfReadTime
  , Base.cfunReadTombstone = seaOfReadTombstone
  , Base.cnameFunReadFact  = nameOfReadFact
  }

nameOfReadFact :: SeaProgramState -> Base.CName
nameOfReadFact state = pretty ("psv_read_fact_" <> show (stateName state))

seaOfReadTime :: Base.CBlock
seaOfReadTime
  = vsep
  [ "ierror_loc_t error = fixed_read_itime (input_fd, time_ptr, time_size, &time);"
  , "if (error) return error;"
  ]

seaOfReadInputFields :: ValType -> [(Text, ValType)] -> Either SeaError Base.CStmt
seaOfReadInputFields inType inVars
 = case (inVars, inType) of
    ([(nx, BoolT)], BoolT)
     -> pure (readValue "text" Base.assignVar nx BoolT)

    ([(nx, DoubleT)], DoubleT)
     -> pure (readValue "text" Base.assignVar nx DoubleT)

    ([(nx, IntT)], IntT)
     -> pure (readValue "text" Base.assignVar nx IntT)

    ([(nx, TimeT)], TimeT)
     -> pure (readValue "text" Base.assignVar nx TimeT)

    ([(nx, StringT)], StringT)
     -> pure (readValuePool "text" Base.assignVar nx StringT)

    (_, t@(ArrayT _))
     -> seaOfReadJsonValue Base.assignVar t inVars

    (_, t@(StructT _))
     -> seaOfReadJsonValue Base.assignVar t inVars

    (_, t)
     -> Left (SeaUnsupportedInputType t)

seaOfReadTombstone :: Base.CheckedInput -> [Text] -> Doc
seaOfReadTombstone input = \case
  []     -> Pretty.empty
  (t:ts) -> "if (" <> Base.seaOfStringEq t "value_ptr" (Just "value_size") <> ") {" <> line
         <> "    " <> pretty (Base.inputSumError input) <> " = ierror_tombstone;" <> line
         <> "} else " <> seaOfReadTombstone input ts

seaOfReadFact
  :: SeaProgramState
  -> Set Text
  -> Base.CheckedInput
  -> Base.CStmt -- C block that reads the input value
  -> Base.CStmt -- C block that performs some check after reading
  -> Base.CFun
seaOfReadFact state tombstones input readInput checkCount =
  vsep
    [ "#line 1 \"read fact" <+> seaOfStateInfo state <> "\""
    , "static ierror_loc_t INLINE"
        <+> pretty (nameOfReadFact state) <+> "("
        <> "const char *value_ptr, const size_t value_size, itime_t time, "
        <> "imempool_t *mempool, iint_t chord_count, "
        <> pretty (nameOfStateType state) <+> "*programs, "
        <> "const iint_t input_fd)"
    , "{"
    , "    ierror_loc_t error;"
    , ""
    , "    char *p  = (char *) value_ptr;"
    , "    char *pe = (char *) value_ptr + value_size;"
    , ""
    , "    ierror_t " <> pretty (Base.inputSumError input) <> ";"
    , indent 4 . vsep . fmap seaOfDefineInput $ Base.inputVars input
    , ""
    , "    " <> align (seaOfReadTombstone input (Set.toList tombstones)) <> "{"
    , "        " <> pretty (Base.inputSumError input) <> " = ierror_not_an_error;"
    , ""
    , indent 8 readInput
    , "    }"
    , ""
    , "    for (iint_t chord_ix = 0; chord_ix < chord_count; chord_ix++) {"
    , "        " <> pretty (nameOfStateType state) <+> "*program = &programs[chord_ix];"
    , ""
    , "        /* don't read values after the chord time */"
    , "        if (time > program->input." <> pretty (stateTimeVar state) <> ")"
    , "            continue;"
    , ""
    , "        iint_t new_count = program->input.new_count;"
    , ""
    , "        program->input." <> pretty (Base.inputSumError input) <> "[new_count] = " <> pretty (Base.inputSumError input) <> ";"
    , indent 8 . vsep . fmap seaOfAssignInput $ Base.inputVars input
    , "        program->input." <> pretty (Base.inputTime input) <> "[new_count] = time;"
    , ""
    , "        new_count++;"
    , ""
    , indent 8 checkCount
               -- checkCount sets the program count if it needs to execute,
               -- but otherwise we still need to update it to the incremented value
    , "        program->input.new_count = new_count;"
    , ""
    , "    }"
    , ""
    , "    return 0; /* no error */"
    , "}"
    , ""
    ]


seaOfAssignInput :: (Text, ValType) -> Doc
seaOfAssignInput (n, _)
 = "program->input." <> pretty n <> "[new_count] = " <> pretty n <> ";"

seaOfDefineInput :: (Text, ValType) -> Doc
seaOfDefineInput (n, t)
 = seaOfValType t <+> pretty n <> Base.initType t


seaOfReadAnyFactPsv
  :: Base.InputOpts
  -> PsvInputConfig
  -> [SeaProgramState]
  -> Either SeaError Doc
seaOfReadAnyFactPsv opts config states = do
  case inputPsvFormat config of
    PsvInputSparse
      -> do let tss  = fmap (lookupTombstones opts) states
            readStates_sea <- zipWithM seaOfReadFactSparse states tss
            pure $ vsep
              [ vsep readStates_sea
              , ""
              , "#line 1 \"read any sparse fact\""
              , "static ierror_loc_t psv_read_fact"
              , "  ( const char   *entity_ptr"
              , "  , const size_t  entity_size"
              , "  , const char   *attrib_ptr"
              , "  , const size_t  attrib_size"
              , "  , const char   *value_ptr"
              , "  , const size_t  value_size"
              , "  , const char   *time_ptr"
              , "  , const size_t  time_size"
              , "  , ifleet_t     *fleet"
              , "  , const size_t  facts_limit"
              , "  , const iint_t  input_fd)"
              , "{"
              , indent 4 (vsep (fmap (seaOfReadNamedFactSparse opts) states))
              , "    return 0;"
              , "}"
              ]
    PsvInputDense dict feed
      -> do state     <- maybeToRight (SeaDenseFeedNotUsed feed)
                       $ List.find ((==) feed . getAttribute . stateAttribute) states
            let ts     = lookupTombstones opts state
            read_sea  <- seaOfReadFactDense dict state ts
            pure $ vsep
              [ read_sea
              , ""
              , "#line 1 \"read any dense fact\""
              , "static ierror_loc_t psv_read_fact"
              , "  ( const char   *entity_ptr"
              , "  , const size_t  entity_size"
              , "  , const char   *value_ptr"
              , "  , const size_t  value_size"
              , "  , const char   *time_ptr"
              , "  , const size_t  time_size"
              , "  , ifleet_t     *fleet"
              , "  , const size_t  facts_limit"
              , "  , const iint_t  input_fd)"
              , "{"
              , indent 4 (seaOfReadNamedFactDense opts state)
              , "    return 0;"
              , "}"
              ]

--------------------------------------------------------------------------------

-- * Dense PSV

seaOfReadNamedFactDense :: Base.InputOpts -> SeaProgramState -> Doc
seaOfReadNamedFactDense opts state
 = let attrib = getAttribute (stateAttribute state)
       errs   = Base.SeaInputError
                ( vsep
                [ "return ierror_loc_format"
                , "   ( input_fd"
                , "   , time_ptr + time_size"
                , "   , time_ptr"
                , "   , \"%s: time is out of order: %.*s must be later than %.*s\""
                , "   , \"" <> pretty attrib <> "\""
                , "   , curr_time_size"
                , "   , curr_time_ptr"
                , "   , last_time_size"
                , "   , last_time_ptr );"
                ])
                ( vsep
                [ "return ierror_loc_tag_format"
                , "   ( IERROR_LIMIT_EXCEEDED"
                , "   , input_fd"
                , "   , entity_ptr + entity_size"
                , "   , entity_ptr"
                , "   , \"%.*s had too many %s facts, they have been dropped starting from here\\n\""
                , "   , entity_size"
                , "   , entity_ptr"
                , "   , \"" <> pretty attrib <> "\");"
                ])
   in vsep
      [ "/* " <> pretty attrib <> " */"
      , Base.seaOfReadNamedFact seaInputPsv errs (Base.inputAllowDupTime opts) state
      ]


seaOfReadFactDense :: PsvInputDenseDict -> SeaProgramState -> Set Text -> Either SeaError Doc
seaOfReadFactDense dict state tombstones = do
  let feeds  = denseDict dict
  let attr   = getAttribute $ stateAttribute state
  fields    <- maybeToRight (SeaDenseFeedNotDefined attr $ fmap (fmap (second snd)) feeds)
             $ Map.lookup attr feeds
  input     <- Base.checkInputType state
  let mv     = Map.lookup attr (denseMissingValue dict)
  readInput <- seaOfReadFactValueDense mv fields (Base.inputVars input)
  pure $ Base.cstmtReadFact seaInputPsv state tombstones input readInput (seaOfCheckCount state)

seaOfReadFactValueDense
  :: Maybe MissingValue
  -> [(Text, (StructFieldType, ValType))]
  -> [(Text, ValType)]
  -> Either SeaError Doc
seaOfReadFactValueDense m fields vars = do
  -- Input variables are ordered lexicographically by field names, we need to re-order them
  -- to fit the dense format.
  --
  -- e.g. a struct with fields @(f2:int,f3:string,f1:(x:string,y:double))@ (in that order)
  -- will have input variable types @string,double,int,string@, we need to re-order this to
  -- @int,string,string,double@.
  --
  let mismatch  = SeaDenseFieldsMismatch (fmap (second snd) fields) vars
      fields'   = fmap expandOptional fields

  -- Get the mapping from the struct encoding in map order
  let mapOrder  = Map.toList $ Map.fromList fields'
      userOrder = fmap fst fields'
  mappings     <- maybe (Left mismatch) Right (mappingOfDenseFields mapOrder vars)

  -- Generate C code for fields in user order
  mappings_sea <- traverse (seaOfDenseFieldMapping m mappings) userOrder

  pure $ vsep
    [ "for (;;) {"
    , indent 4 (vsep mappings_sea)
    , "    return ierror_loc_format (input_fd, p-1, p-1, \"invalid dense field start\");"
    , "}"
    ]
  where
    expandOptional (n, (op, t))
      = case op of
          Optional  -> (n,OptionT t)
          Mandatory -> (n,t)

seaOfReadDenseInput
 :: Maybe MissingValue
 -> ValType
 -> [(Text, ValType)]
 -> Either SeaError Doc
seaOfReadDenseInput missing inType inVars
  = case (inVars, inType) of
     ((nb, BoolT) : nx, OptionT t)
       -> do val_sea <- seaOfReadInputFields t nx
             let body_true  = indent 4
                            $ vsep [ Base.assignVar (pretty nb) BoolT "true"
                                   , val_sea ]
                 body_false = indent 4
                            $ Base.assignVar (pretty nb) BoolT "false"
             case missing of
               Just m
                 -> pure $ vsep
                     [ "if (" <> Base.seaOfStringEq m "p" (Just "pe - p") <> ") {"
                     , "    p = pe;"
                     , body_false
                     , "} else {"
                     , body_true
                     , "}"
                     ]
               Nothing
                 -> pure $ vsep
                     [ "if (*p != '|') {"
                     , body_true
                     , "} else {"
                     , body_false
                     , "}"
                     ]
     _ -> seaOfReadInputFields inType inVars

seaOfDenseFieldMapping :: Maybe MissingValue -> [Base.FieldMapping] -> Text -> Either SeaError Doc
seaOfDenseFieldMapping m mappings field = do
  Base.FieldMapping fname ftype vars
    <- maybeToRight (SeaDenseFieldNotDefined field (fmap Base._fieldName mappings))
                    (List.find ((== field) . Base._fieldName) mappings)
  fieldSea <- seaOfReadDenseInput m ftype vars
  let sea   = Base.wrapInBlock
            $ vsep [ "char *ent_pe = pe;"
                   , "char *pe     = memchr(p, '|', ent_pe - p);"
                   , "if (pe == NULL)"
                   , "    pe = ent_pe;"
                   , ""
                   , fieldSea ]

  pure $ Base.wrapInBlock $ vsep
    [ "/* " <> pretty fname <> " */"
    , sea
    , ""
    , "char *term_ptr = p++;"
    , "if (*term_ptr != '|')"
    , "    return ierror_loc_format (input_fd, p-1, p-1, \"expect field separator '|'\");"
    , ""
    , "if (term_ptr == pe)"
    , "    break;"
    , ""
    ]

mappingOfDenseFields :: [(Text, ValType)] -> [(Text, ValType)] -> Maybe [Base.FieldMapping]
mappingOfDenseFields fields varsoup
  = Base.mappingOfFields (fmap (first StructField) fields) varsoup

--------------------------------------------------------------------------------

-- * Sparse PSV

seaOfReadNamedFactSparse :: Base.InputOpts -> SeaProgramState -> Doc
seaOfReadNamedFactSparse opts state
 = let attrib = getAttribute (stateAttribute state)
       errs   = Base.SeaInputError
                ( vsep
                [ "return ierror_loc_format"
                , "   ( input_fd"
                , "   , time_ptr + time_size"
                , "   , time_ptr"
                , "   , \"%.*s: time is out of order: %.*s must be later than %.*s\""
                , "   , attrib_size"
                , "   , attrib_ptr"
                , "   , curr_time_size"
                , "   , curr_time_ptr"
                , "   , last_time_size"
                , "   , last_time_ptr );"
                ])
                ( vsep
                [ "return ierror_loc_tag_format"
                , "   ( IERROR_LIMIT_EXCEEDED"
                , "   , input_fd"
                , "   , entity_ptr + entity_size"
                , "   , entity_ptr"
                , "   , \"entity %.*s had too many %.*s facts, they have been dropped starting from here\\n\""
                , "   , entity_size"
                , "   , entity_ptr"
                , "   , attrib_size"
                , "   , attrib_ptr );"
                ])

   in vsep
      [ "/* " <> pretty attrib <> " */"
      , "if (" <> Base.seaOfStringEq attrib "attrib_ptr" (Just "attrib_size") <> ")"
      , Base.seaOfReadNamedFact seaInputPsv errs (Base.inputAllowDupTime opts) state
      ]

seaOfReadFactSparse
  :: SeaProgramState
  -> Set Text
  -> Either SeaError Doc
seaOfReadFactSparse state tombstones = do
  input     <- Base.checkInputType state
  readInput <- seaOfReadInputFields (Base.inputType input) (Base.inputVars input)
  pure $ Base.cstmtReadFact seaInputPsv state tombstones input readInput (seaOfCheckCount state)

------------------------------------------------------------------------

-- * Generic reading of JSON and stuff in PSV

seaOfCheckCount :: SeaProgramState -> Base.CStmt
seaOfCheckCount state = vsep
  [ "if (new_count == psv_max_row_count) {"
  -- We need to set the program count before executing it.
  -- Otherwise, it won't evaluate the last row
  , "     program->input.new_count = new_count;"
  , "     " <> pretty (nameOfProgram state) <> " (program);"
  , "     new_count = 0;"
  , "} else if (new_count > psv_max_row_count) {"
  , "     return ierror_loc_format (input_fd, 0, 0, \"" <> pretty (Base.cnameFunReadFact seaInputPsv state) <> ": new_count > max_count\");"
  , "}"
  ]

seaOfReadJsonValue :: Base.Assignment -> ValType -> [(Text, ValType)] -> Either SeaError Doc
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

readValue :: Doc -> Base.Assignment -> Text -> ValType -> Doc
readValue
 = readValueArg ""

readValuePool :: Doc -> Base.Assignment -> Text -> ValType -> Doc
readValuePool
 = readValueArg "mempool, "

readValueArg :: Doc -> Doc -> Base.Assignment -> Text -> ValType -> Doc
readValueArg arg fmt assign n vt
 = vsep
 [ seaOfValType vt <+> "value;"
 , "error = " <> fmt <> "_read_" <> baseOfValType vt <> " (input_fd, " <> arg <> "&p, pe, &value);"
 , "if (error) return error;"
 , assign (pretty n) vt "value"
 ]

seaOfReadJsonList :: ValType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonList vtype avars = do
  vars      <- traverse Base.unArray avars
  value_sea <- seaOfReadJsonValue Base.assignArrayMutable vtype vars
  pure $ vsep
    [ "if (*p++ != '[')"
    , "    return ierror_loc_format (input_fd, p-1, p-1, \"array missing '['\");"
    , ""
    , "char term = *p;"
    , ""
    , "for (iint_t ix = 0; term != ']'; ix++) {"
    , indent 4 value_sea
    , "    "
    , "    term = *p++;"
    , "    if (term != ',' && term != ']')"
    , "        return ierror_loc_format (input_fd, p-1, p-1, \"array separator ',' or terminator ']' not found\");"
    , "}"
    ]

seaOfReadJsonObject :: Base.Assignment -> StructType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonObject assign st@(StructType fs) vars
 = case vars of
    [(nx, UnitT)] | Map.null fs -> seaOfReadJsonUnit   assign nx
    _                           -> seaOfReadJsonStruct assign st vars

seaOfReadJsonUnit :: Base.Assignment -> Text -> Either SeaError Doc
seaOfReadJsonUnit assign name = do
  pure $ vsep
    [ "if (*p++ != '{')"
    , "    return ierror_loc_format (input_fd, p-1, p-1, \"unit missing '{'\");"
    , ""
    , "if (*p++ != '}')"
    , "    return ierror_loc_format (input_fd, p-1, p-1, \"unit missing '}'\");"
    , ""
    , assign (pretty name) UnitT "iunit"
    ]

seaOfReadJsonStruct :: Base.Assignment -> StructType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonStruct assign st@(StructType fields) vars = do
  let mismatch = SeaStructFieldsMismatch st vars
  mappings     <- maybe (Left mismatch) Right (Base.mappingOfFields (Map.toList fields) vars)
  mappings_sea <- traverse (seaOfFieldMapping assign) mappings
  pure $ vsep
    [ "if (*p++ != '{')"
    , "    return ierror_loc_format (input_fd, p-1, p-1, \"struct missing '{'\");"
    , ""
    , "for (;;) {"
    , "    if (*p++ != '\"')"
    , "        return ierror_loc_format (input_fd, p-1, p-1, \"field name missing opening quote\");"
    , ""
    , indent 4 (vsep mappings_sea)
    , "    return ierror_loc_format (input_fd, p-1, p-1, \"invalid json field start\");"
    , "}"
    ]

seaOfFieldMapping :: Base.Assignment -> Base.FieldMapping -> Either SeaError Doc
seaOfFieldMapping assign (Base.FieldMapping fname ftype vars) = do
  let needle = fname <> "\""
  field_sea <- seaOfReadJsonField assign ftype vars
  pure $ vsep
    [ "/* " <> pretty fname <> " */"
    , "if (" <> Base.seaOfStringEq needle "p" Nothing <> ") {"
    , "    p += " <> int (Base.sizeOfString needle) <> ";"
    , ""
    , indent 4 field_sea
    , ""
    , "    continue;"
    , "}"
    , ""
    ]

seaOfReadJsonField :: Base.Assignment -> ValType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonField assign ftype vars = do
  value_sea <- seaOfReadJsonValue assign ftype vars
  pure $ vsep
    [ "if (*p++ != ':')"
    , "    return ierror_loc_format (input_fd, p-1, p-1, \"field missing ':'\");"
    , ""
    , value_sea
    , ""
    , "char term = *p++;"
    , "if (term != ',' && term != '}')"
    , "    return ierror_loc_format (input_fd, p-1, p-1, \"field separator ',' or terminator '}' not found\");"
    , ""
    , "if (term == '}')"
    , "    break;"
    ]

lookupTombstones :: Base.InputOpts -> SeaProgramState -> Set Text
lookupTombstones opts state =
  fromMaybe Set.empty (Map.lookup (stateAttribute state) (Base.inputTombstones opts))
