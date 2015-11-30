{-# LANGUAGE DoAndIfThenElse   #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards     #-}
{-# LANGUAGE TupleSections     #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

import           Control.Monad.IO.Class
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Either

import           Data.List                        (nubBy, replicate, words)
import           Data.Monoid
import           Data.String                      (String, lines)
import qualified Data.Text                        as T
import qualified Data.Text.IO                     as T

import qualified System.Console.ANSI              as ANSI
import           System.Console.Haskeline         as HL
import qualified System.Console.Terminal.Size     as TS
import           System.Directory
import           System.Environment               (getArgs)
import           System.IO

import qualified Text.ParserCombinators.Parsec    as Parsec

import qualified Icicle.Pipeline                  as P

import qualified Icicle.Internal.Pretty           as PP

import qualified Icicle.Avalanche.ToJava          as AJ

import qualified Icicle.Core.Program.Check        as CP

import           Icicle.Data
import           Icicle.Data.DateTime
import           Icicle.Dictionary

import qualified Icicle.Repl                      as SR

import qualified Icicle.Sea.Eval                  as Sea
import qualified Icicle.Sea.FromAvalanche.Program as Sea
import qualified Icicle.Sea.Preamble              as Sea

import qualified Icicle.Source.PrettyAnnot        as SPretty


import           P



main :: IO ()
main
 = do   as <- getArgs
        runRepl as

runRepl :: [String] -> IO ()
runRepl inits
  = do putStrLn "welcome to iREPL"
       h <- getHomeDirectory
       c <- getCurrentDirectory
       s <- settings h
       HL.runInputT s
        $ do dot1   <- liftIO $ dotfile (h <> "/.icicle")
             dot2   <- liftIO $ dotfile (c <> "/.icicle")
             state' <- foldM handleLine defaultState (dot1 <> dot2 <> inits)
             withInterrupt $ loop state'
  where
    settings home
      = return $ HL.defaultSettings
          { historyFile    = Just $ home <> "/.icicle-repl.history"
          , autoAddHistory = True}
    dotfile fp
      = do b <- doesFileExist fp
           if b
           then lines <$> readFile fp
           else return []
    loop state
      = handleInterrupt (loop state)
      $ do line <- HL.getInputLine "> "
           case line of
             Nothing      -> return ()
             Just ":quit" -> return ()
             Just ":q"    -> return ()
             Just str     -> handleLine state str >>= loop

--------------------------------------------------------------------------------

data ReplState
   = ReplState
   { facts            :: [AsAt Fact]
   , dictionary       :: Dictionary
   , currentDate      :: DateTime
   , hasType          :: Bool
   , hasAnnotated     :: Bool
   , hasInlined       :: Bool
   , hasDesugar       :: Bool
   , hasCore          :: Bool
   , hasCoreType      :: Bool
   , hasCoreEval      :: Bool
   , hasAvalanche     :: Bool
   , hasAvalancheEval :: Bool
   , hasFlatten       :: Bool
   , hasJava          :: Bool
   , hasSeaPreamble   :: Bool
   , hasSea           :: Bool
   , hasSeaAssembly   :: Bool
   , hasSeaEval       :: Bool
   , doCoreSimp       :: Bool }

-- | Settable REPL states
data Set
   = ShowType           Bool
   | ShowAnnotated      Bool
   | ShowInlined        Bool
   | ShowDesugar        Bool
   | ShowCore           Bool
   | ShowCoreType       Bool
   | ShowCoreEval       Bool
   | ShowAvalanche      Bool
   | ShowAvalancheEval  Bool
   | ShowFlatten        Bool
   | ShowJava           Bool
   | ShowSeaPreamble    Bool
   | ShowSea            Bool
   | ShowSeaAssembly    Bool
   | ShowSeaEval        Bool
   | CurrentDate        DateTime
   | PerformCoreSimp    Bool

-- | REPL commands
data Command
   = CommandBlank
   | CommandHelp
   | CommandSet  [Set]
   | CommandLoad FilePath
   | CommandLoadDictionary SR.DictionaryLoadType
   | CommandImportLibrary FilePath
   -- It's rather odd to have comments in a REPL.
   -- However, I want these printed out in the test output
   | CommandComment String
   | CommandUnknown String
   | CommandSetShow

defaultState :: ReplState
defaultState
  = (ReplState [] demographics (unsafeDateOfYMD 1970 1 1) False False False False False False False False False False False False False False False False)
    { hasCoreEval = True
    , doCoreSimp  = True }

readCommand :: String -> Maybe Command
readCommand ss = case words ss of
  []                               -> Just CommandBlank
  ":h":_                           -> Just CommandHelp
  ":help":_                        -> Just CommandHelp
  [":set"]                         -> Just $ CommandSetShow
  (":set":rest)                    -> CommandSet <$> readSetCommands rest
  [":load", f]                     -> Just $ CommandLoad f
  [":dictionary-deprecated", f]    -> Just $ CommandLoadDictionary $ SR.DictionaryLoadTextV1 f
  [":dictionary", f]               -> Just $ CommandLoadDictionary $ SR.DictionaryLoadToml f
  [":import", f]                   -> Just $ CommandImportLibrary f
  ('-':'-':_):_                    -> Just $ CommandComment $ ss
  (':':_):_                        -> Just $ CommandUnknown $ ss
  _                                -> Nothing

readSetCommands :: [String] -> Maybe [Set]
readSetCommands ss
 = case ss of
    ("+type":rest)         -> (:) (ShowType True)          <$> readSetCommands rest
    ("-type":rest)         -> (:) (ShowType False)         <$> readSetCommands rest

    ("+annotated":rest)    -> (:) (ShowAnnotated True)     <$> readSetCommands rest
    ("-annotated":rest)    -> (:) (ShowAnnotated False)    <$> readSetCommands rest

    ("+inlined":rest)      -> (:) (ShowInlined   True)     <$> readSetCommands rest
    ("-inlined":rest)      -> (:) (ShowInlined   False)    <$> readSetCommands rest

    ("+desugar":rest)      -> (:) (ShowDesugar   True)     <$> readSetCommands rest
    ("-desugar":rest)      -> (:) (ShowDesugar   False)    <$> readSetCommands rest

    ("+core":rest)         -> (:) (ShowCore True)          <$> readSetCommands rest
    ("-core":rest)         -> (:) (ShowCore False)         <$> readSetCommands rest

    ("+core-type":rest)    -> (:) (ShowCoreType True)      <$> readSetCommands rest
    ("-core-type":rest)    -> (:) (ShowCoreType False)     <$> readSetCommands rest

    ("+core-simp":rest)    -> (:) (PerformCoreSimp True)   <$> readSetCommands rest
    ("-core-simp":rest)    -> (:) (PerformCoreSimp False)  <$> readSetCommands rest

    ("+core-eval":rest)    -> (:) (ShowCoreEval    True)  <$> readSetCommands rest
    ("-core-eval":rest)    -> (:) (ShowCoreEval    False) <$> readSetCommands rest

    ("+avalanche":rest)    -> (:) (ShowAvalanche True)     <$> readSetCommands rest
    ("-avalanche":rest)    -> (:) (ShowAvalanche False)    <$> readSetCommands rest

    ("+avalanche-eval":rest) -> (:) (ShowAvalancheEval True)  <$> readSetCommands rest
    ("-avalanche-eval":rest) -> (:) (ShowAvalancheEval False) <$> readSetCommands rest

    ("+flatten":rest)      -> (:) (ShowFlatten   True)     <$> readSetCommands rest
    ("-flatten":rest)      -> (:) (ShowFlatten   False)    <$> readSetCommands rest

    ("+java":rest)         -> (:) (ShowJava      True)     <$> readSetCommands rest
    ("-java":rest)         -> (:) (ShowJava      False)    <$> readSetCommands rest

    ("+c-preamble":rest)   -> (:) (ShowSeaPreamble True)  <$> readSetCommands rest
    ("-c-preamble":rest)   -> (:) (ShowSeaPreamble False) <$> readSetCommands rest

    ("+c":rest)            -> (:) (ShowSea         True)  <$> readSetCommands rest
    ("-c":rest)            -> (:) (ShowSea         False) <$> readSetCommands rest

    ("+c-assembly":rest)   -> (:) (ShowSeaAssembly True)  <$> readSetCommands rest
    ("-c-assembly":rest)   -> (:) (ShowSeaAssembly False) <$> readSetCommands rest

    ("+c-eval":rest)       -> (:) (ShowSeaEval     True)  <$> readSetCommands rest
    ("-c-eval":rest)       -> (:) (ShowSeaEval     False) <$> readSetCommands rest

    ("date" : y : m : d : rest)
       | Just y' <- readMaybe y
       , Just m' <- readMaybe m
       , Just d' <- readMaybe d
       , Just x' <- dateOfYMD y' m' d'
       -> (:) (CurrentDate x') <$> readSetCommands rest

    [] -> Just []
    _  -> Nothing


handleLine :: ReplState -> String -> HL.InputT IO ReplState
handleLine state line = case readCommand line of
  Just CommandBlank          -> do
    return state
  Just (CommandUnknown s)    -> do
    HL.outputStrLn $ "unknown command '" <> s <> "'"
    HL.outputStrLn $ "use :h for help"
    return state
  Just CommandHelp           -> do
    usage
    return state

  Just CommandSetShow        -> do
    showState state
    return state

  Just (CommandSet sets)    -> foldM handleSetCommand state sets

  Just (CommandLoad fp)      -> do
    s  <- liftIO $ T.readFile fp
    case SR.readFacts (dictionary state) s of
      Left e   -> prettyHL e >> return state
      Right fs -> do
        HL.outputStrLn $ "ok, loaded " <> fp <> ", " <> show (length fs) <> " rows"
        return $ state { facts = fs }

  Just (CommandLoadDictionary load) -> do
    s  <- liftIO $ runEitherT $ SR.loadDictionary load
    case s of
      Left e   -> prettyHL e >> return state
      Right d -> do
        HL.outputStrLn $ "ok, loaded dictionary with " <> show (length $ dictionaryEntries d) <> " features and " <> show (length $ dictionaryFunctions d) <> " functions"
        return $ state { dictionary = d }

  Just (CommandImportLibrary fp) -> do
    s  <- liftIO $ T.readFile fp
    case SR.readIcicleLibrary fp s of
      Left e   -> prettyHL e >> return state
      Right is -> do
        HL.outputStrLn $ "ok, loaded " <> show (length is) <> " functions from " <> fp
        let d = dictionary state
        -- Merge in the new functions with new functions taking precedence over existing ones
        let f = nubBy ((==) `on` fst) $ is <> (dictionaryFunctions d)
        return $ state { dictionary = d { dictionaryFunctions = f } }

  Just (CommandComment comment) -> do
    HL.outputStrLn comment
    return state


  -- We use the simulator to evaluate the Icicle expression.
  Nothing -> do

    let hoist c = hoistEither c
    let prettyOut setting heading p
            = lift
            $ when (setting state)
            $ do    HL.outputStrLn heading
                    prettyHL p
                    nl

    checked <- runEitherT $ do
      parsed    <- hoist $ SR.sourceParse (T.pack line)
      (annot, typ)
                <- hoist $ SR.sourceCheck (dictionary state) parsed

      prettyOut hasType "- Type:" typ

      prettyOut hasAnnotated "- Annotated:" (SPretty.PrettyAnnot annot)

      let inlined= SR.sourceInline (dictionary state) annot

      blanded     <- hoist $ SR.sourceDesugar inlined

      prettyOut hasInlined "- Inlined:" inlined
      prettyOut hasDesugar "- Desugar:" blanded

      (annobland, _) <- hoist $ SR.sourceCheck (dictionary state) blanded
      prettyOut hasInlined "- Annotated desugar:" (SPretty.PrettyAnnot annobland)


      let reified       = SR.sourceReify annobland
      prettyOut hasInlined "- Reified:"                      reified
      prettyOut hasInlined "- Reified:" (SPretty.PrettyAnnot reified)
      let finalSource   = reified


      core      <- hoist $ SR.sourceConvert (dictionary state) finalSource
      let core'  | doCoreSimp state
                 = SR.coreSimp core
                 | otherwise
                 = core

      prettyOut hasCore "- Core:" core'

      case CP.checkProgram core' of
       Left  e -> prettyOut (const True) "- Core type error:" e
       Right t -> prettyOut hasCoreType "- Core type:" t

      prettyOut hasAvalanche "- Avalanche:" (SR.coreAvalanche core')

      let flat = SR.coreFlatten core'
      case flat of
       Left  e -> prettyOut (const True) "- Flatten error:" e
       Right f -> do
        prettyOut hasFlatten "- Flattened:" f

        case P.avalancheEval (currentDate state) (facts state) finalSource f of
         Left  e -> prettyOut hasAvalancheEval "- Avalanche error:" e
         Right r -> prettyOut hasAvalancheEval "- Avalanche evaluation:" r

        let flatChecked = SR.checkAvalanche f
        case flatChecked of
         Left  e  -> prettyOut (const True) "- Avalanche type error:" e
         Right f' -> do
           prettyOut hasJava "- Java:" (AJ.programToJava f')

           prettyOut hasSeaPreamble "- C preamble:" Sea.seaPreamble

           when (hasSea state) $ do
             let seaProgram = Sea.seaOfProgram 0 (mkAttribute "repl") f'
             case seaProgram of
               Left  e -> prettyOut (const True) "- C error:" e
               Right r -> prettyOut (const True) "- C:" r

           when (hasSeaAssembly state) $ do
             result <- liftIO . runEitherT $ Sea.assemblyOfPrograms Sea.NoPsv [(mkAttribute "repl", f')]
             case result of
               Left  e -> prettyOut (const True) "- C assembly error:" e
               Right r -> prettyOut (const True) "- C assembly:" r

           when (hasSeaEval state) $ do
             result <- liftIO . runEitherT $ P.seaEval (currentDate state) (facts state) finalSource f'
             case result of
               Left  e -> prettyOut (const True) "- C error:" e
               Right r -> prettyOut (const True) "- C evaluation:" r

      case P.coreEval (currentDate state) (facts state) finalSource core' of
       Left  e -> prettyOut hasCoreEval "- Core error:" e
       Right r -> prettyOut hasCoreEval "- Core evaluation:" r

      return ()

    case checked of
      Left  e -> prettyE e
      Right _ -> return ()

    return state

handleSetCommand :: ReplState -> Set -> HL.InputT IO ReplState
handleSetCommand state set
 = case set of
    ShowType b -> do
        HL.outputStrLn $ "ok, type is now " <> showFlag b
        return $ state { hasType = b }

    ShowAnnotated b -> do
        HL.outputStrLn $ "ok, annotated is now " <> showFlag b
        return $ state { hasAnnotated = b }

    ShowInlined b -> do
        HL.outputStrLn $ "ok, inlined is now " <> showFlag b
        return $ state { hasInlined = b }

    ShowDesugar b -> do
        HL.outputStrLn $ "ok, desugar is now " <> showFlag b
        return $ state { hasDesugar = b }

    ShowCore b -> do
        HL.outputStrLn $ "ok, core is now " <> showFlag b
        return $ state { hasCore = b }

    ShowCoreType b -> do
        HL.outputStrLn $ "ok, core-type is now " <> showFlag b
        return $ state { hasCoreType = b }

    ShowCoreEval b -> do
        HL.outputStrLn $ "ok, core evaluation is now " <> showFlag b
        return $ state { hasCoreEval = b }

    ShowAvalanche b -> do
        HL.outputStrLn $ "ok, avalanche is now " <> showFlag b
        return $ state { hasAvalanche = b }

    ShowAvalancheEval b -> do
        HL.outputStrLn $ "ok, avalanche eval is now " <> showFlag b
        return $ state { hasAvalancheEval = b }

    ShowFlatten b -> do
        HL.outputStrLn $ "ok, flatten is now " <> showFlag b
        return $ state { hasFlatten = b }

    ShowJava b -> do
        HL.outputStrLn $ "ok, java is now " <> showFlag b
        return $ state { hasJava = b }

    ShowSeaPreamble b -> do
        HL.outputStrLn $ "ok, c preamble is now " <> showFlag b
        return $ state { hasSeaPreamble = b }

    ShowSea b -> do
        HL.outputStrLn $ "ok, c is now " <> showFlag b
        return $ state { hasSea = b }

    ShowSeaAssembly b -> do
        HL.outputStrLn $ "ok, c assembly is now " <> showFlag b
        return $ state { hasSeaAssembly = b }

    ShowSeaEval b -> do
        HL.outputStrLn $ "ok, c evaluation now " <> showFlag b
        when b $ do
          HL.outputStrLn "                   _________-----_____"
          HL.outputStrLn "        _____------           __      ----_"
          HL.outputStrLn " ___----             ___------              \\"
          HL.outputStrLn "    ----________        ----                 \\"
          HL.outputStrLn "                -----__    |             _____)"
          HL.outputStrLn "                     __-                /     \\"
          HL.outputStrLn "         _______-----    ___--          \\    /)\\"
          HL.outputStrLn "   ------_______      ---____            \\__/  /"
          HL.outputStrLn "                -----__    \\ --    _          /\\"
          HL.outputStrLn "                       --__--__     \\_____/   \\_/\\"
          HL.outputStrLn "                               ----|   /          |"
          HL.outputStrLn "                                   |  |___________|"
          HL.outputStrLn "                                   |  | ((_(_)| )_)"
          HL.outputStrLn "                                   |  \\_((_(_)|/(_)"
          HL.outputStrLn "                                   \\             ("
          HL.outputStrLn "                                    \\_____________)"
        return $ state { hasSeaEval = b }

    CurrentDate d -> do
        HL.outputStrLn $ "ok, date set to " <> T.unpack (renderDate d)
        return $ state { currentDate = d }

    PerformCoreSimp b -> do
        HL.outputStrLn $ "ok, core-simp is now " <> showFlag b
        return $ state { doCoreSimp = b }

--------------------------------------------------------------------------------

--------------------------------------------------------------------------------

nl :: HL.InputT IO ()
nl = HL.outputStrLn ""

prettyE :: SR.ReplError -> HL.InputT IO ()
prettyE e
 = ppos >> HL.outputStrLn "REPL Error:" >> prettyHL e >> nl
 where
  ppos
   | Just sp <- SR.annotOfError e
   = HL.outputStrLn
   $ replicate (Parsec.sourceColumn sp + 1) ' '
     <> ANSI.setSGRCode [ANSI.SetColor ANSI.Foreground ANSI.Dull ANSI.Blue]
     <> "λλλλ"
     <> ANSI.setSGRCode [ANSI.Reset]
   | otherwise
   = return ()

prettyHL :: PP.Pretty a => a -> HL.InputT IO ()
prettyHL x
 = do   width <- terminalWidth
        let width' = maybe 80 id width
        HL.outputStrLn $ PP.displayDecorated withColour (PP.renderPretty 0.4 width' $ PP.pretty x)
    where
      withColour a'@(PP.AnnVariable) str = sgrAttr a' <> str <> sgrReset
      withColour a'@(PP.AnnType a)   str = str <> sgrAttr a' <> "@{" <> (PP.display . PP.renderCompact . PP.pretty) a <> "}" <> sgrReset

      sgrReset = ANSI.setSGRCode [ANSI.Reset]

      sgrAttr = \case
        PP.AnnVariable    -> ANSI.setSGRCode [ANSI.SetColor ANSI.Foreground ANSI.Dull ANSI.Green]
        PP.AnnType _      -> ANSI.setSGRCode [ANSI.SetColor ANSI.Foreground ANSI.Dull ANSI.Red]


terminalWidth :: HL.InputT IO (Maybe Int)
terminalWidth
 = fmap (fmap TS.width)
 $ liftIO TS.size

showFlag :: Bool -> String
showFlag True  = "on"
showFlag False = "off"


showState :: ReplState -> HL.InputT IO ()
showState state
 = mapM_ HL.outputStrLn
    [ flag "type:         " hasType
    , flag "annotated:    " hasAnnotated
    , flag "inlined:      " hasInlined
    , flag "desugar:      " hasDesugar
    , flag "core:         " hasCore
    , flag "core-type:    " hasCoreType
    , flag "core-simp:    " doCoreSimp
    , flag "core-eval:    " hasCoreEval
    , flag "avalanche:    " hasAvalanche
    , flag "flatten:      " hasFlatten
    , flag "java:         " hasJava
    , flag "c-preamble:   " hasSeaPreamble
    , flag "c:            " hasSea
    , flag "c-assembly:   " hasSeaAssembly
    , flag "c-eval:       " hasSeaEval
    ,      "now:          " <> T.unpack (renderDate $ currentDate state)
    ,      "data:         " <> show (length $ facts state) <> " rows"
    ,      "dictionary:   " <> show (prettyDictionarySummary (dictionary state))
    ]
 where
  flag nm setting
   = nm <> showFlag (setting state)


usage :: HL.InputT IO ()
usage
 = mapM_ HL.outputStrLn
      [ "Usage:"
      , ":help or :h           -- shows this message"
      , ":quit or :q           -- quits the REPL"
      , ":load <filepath>      -- loads a data set"
      , ":dictionary <path>    -- loads a dictionary"
      , ":import <filepath>    -- imports functions from a file"
      , ":set  +/-type         -- whether to show the checked expression type"
      , ":set  +/-desugar      -- whether to show the desugar-ed Source"
      , ":set  +/-core         -- whether to show the Core conversion"
      , ":set  +/-core-type    -- whether to show the Core conversion's type"
      , ":set  +/-core-simp    -- whether to simplify the result of Core conversion"
      , ":set  +/-core-eval    -- whether to show the result (using Core evaluation)"
      , ":set  +/-avalanche    -- whether to show the Avalanche conversion"
      , ":set  +/-flatten      -- whether to show flattened Avalanche conversion"
      , ":set  +/-java         -- whether to show the Java result"
      , ":set  +/-c-preamble   -- whether to show the C preamble"
      , ":set  +/-c            -- whether to show the C conversion"
      , ":set  +/-c-assembly   -- whether to show the C assembly"
      , ":set  +/-c-eval       -- whether to show the result (using C evaluation)" ]

