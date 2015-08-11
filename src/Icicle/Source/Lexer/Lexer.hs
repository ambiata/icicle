{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PatternGuards #-}
module Icicle.Source.Lexer.Lexer (
    lexer
  , lexerPositions
  ) where

import Icicle.Source.Lexer.Token

import                  P

import qualified        Data.Char as C
import qualified        Data.List as L
import qualified        Data.Text as T

import qualified        Text.Read as R

import qualified        Text.Parsec.Pos as Pos



-- | Lex a string into tokens.
-- The SourceName is used for annotating tokens with their file positions
lexer :: Pos.SourceName -> T.Text -> [TOK]
lexer file inp
 = lexerString file $ T.unpack inp

lexerString :: Pos.SourceName -> [Char] -> [TOK]
lexerString file inp
 = let pos  = L.scanl Pos.updatePosChar (Pos.initialPos file) inp
       -- Annotate each character with its source position
       -- This makes keeping track of source position trivial,
       -- but disallows us from using Data.Text.
       both = inp `L.zip` pos
   in  lexerPositions both

lexerPositions :: [(Char, Pos.SourcePos)] -> [TOK]
lexerPositions ts
 -- Throw away whitespace before looking at it
 = go $ L.dropWhile (C.isSpace . fst) ts
 where
  -- The end
  go []
   = []
  -- Look at the first character and decide what to do
  go ((c,pos) : t')

   -- Variables
   | isVarStart c
   =  let (a,b) = L.span (isVarRest . fst) t'
          v     = cons c a
      in  (keywordOrVar v, pos) : lexerPositions b

   -- Numbers must start with a digit. This means ".5" is not a valid number.
   -- Instead of reimplementing this, try to use the Read instances.
   | C.isDigit c
   = case tryLex c t' of
      Right (num, rest)
       -> let lit
               -- Try Int first because it's more specific
               | Just i <- R.readMaybe num
               = TLiteral $ LitInt i
               -- Now try Double
               | Just d <- R.readMaybe num
               = TLiteral $ LitDouble d
               -- Something funky happened
               | otherwise
               = TUnexpected $ T.pack num
          in  (lit, pos) : lexerPositions rest
      Left tok
       -> [(tok, pos)]

   -- String literals start with a quote.
   -- Use Read instance for Strings to cope with escapes
   | c == '"'
   = case tryLex c t' of
      Right (str, rest)
       -> let lit
               | Just i <- R.readMaybe str
               = TLiteral $ LitString $ T.pack i
               | otherwise
               = TUnexpected $ T.pack str
          in  (lit, pos) : lexerPositions rest
      Left tok
       -> [(tok, pos)]

   -- Parens are easy
   | c == '('
   =  (TParenL, pos) : lexerPositions t'
   | c == ')'
   =  (TParenR, pos) : lexerPositions t'

   -- Anything else might as well be treated as an operator
   | otherwise
   =  let (a,b) = L.span (isOperator . fst) t'
          v     = cons c a
      in  (operator v, pos) : lexerPositions b


  -- Try to pull a token off according to Haskell's token rules.
  -- This is lazy, but real parsing for Doubles and for string escaping
  -- has already been implemented far too many times;
  -- I don't particularly feel like doing it again.
  tryLex c t'
   | (lex, _) : _ <- R.lex (c : fmap fst t')
   -- We need the remaining stream with source positions.
   -- So instead of using the remainder of R.lex,
   -- throw away the part we used, taking into account that lex should include the "c"
   = Right (lex, drop (length lex - 1) t')
   | otherwise
   -- If this couldn't read a token, something is wrong
   = Left $ TUnexpected $ T.pack (c : fmap fst t')

  cons a b = T.pack (a : fmap fst b)

  isVarStart c
   = C.isAlpha c || c == '_'
  isVarRest c
   = C.isAlphaNum c || c == '_'

  isOperator c
   =  not (isVarRest c)
   && not (C.isSpace c)
   && c /= '(' && c /= ')'


