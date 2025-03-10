{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveLift #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DataKinds #-}
{- |
This module provides a parser for <https://docs.python.org/3.4/library/string.html#formatspec python format string mini language>.
-}
module PyF.Internal.PythonSyntax
  ( parseGenericFormatString
  , Item(..)
  , FormatMode(..)
  , Padding(..)
  , Precision(..)
  , TypeFormat(..)
  , AlternateForm(..)
  , pattern DefaultFormatMode
  , Parser
  , ParsingContext(..)
  , ExprOrValue(..)
  )
where

import Language.Haskell.TH.Syntax

import Text.Megaparsec
import qualified Text.Megaparsec.Char.Lexer as L
import Text.Megaparsec.Char
import Data.Void (Void)
import Control.Monad.Reader

import qualified Data.Char

import Data.Maybe (fromMaybe)

import qualified Data.Set as Set -- For fancyFailure
import qualified Language.Haskell.Meta.Syntax.Translate as SyntaxTranslate
import qualified Language.Haskell.Exts.Parser as ParseExp
import qualified Language.Haskell.Exts.Extension as ParseExtension
import qualified Language.Haskell.Exts.SrcLoc as SrcLoc
import PyF.Formatters

type Parser t = ParsecT Void String (Reader ParsingContext) t

data ParsingContext = ParsingContext
  { delimiters :: (Char, Char)
  , enabledExtensions :: [ParseExtension.Extension]
  }
  deriving (Show)

{-
-- TODO:
- Better parsing of integer
- Recursive replacement field, so "{string:.{precision}} can be parsed
- f_expression / conversion
- Not (Yet) implemented:
     - types: n
-}


{-
f_string          ::=  (literal_char | "{{" | "}}" | replacement_field)*
replacement_field ::=  "{" f_expression ["!" conversion] [":" format_spec] "}"
f_expression      ::=  (conditional_expression | "*" or_expr)
                         ("," conditional_expression | "," "*" or_expr)* [","]
                       | yield_expression
conversion        ::=  "s" | "r" | "a"
format_spec       ::=  (literal_char | NULL | replacement_field)*
literal_char      ::=  <any code point except "{", "}" or NULL>
-}

-- | A format string is composed of many chunks of raw string or replacement
data Item = Raw String -- ^ A raw string
           | Replacement Exp (Maybe FormatMode) -- ^ A replacement string, composed of an arbitrary Haskell expression followed by an optional formatter
           deriving (Show)

{- |
Parse a string, returns a list of raw string or replacement fields

>>> import Text.Megaparsec
>>> parse parsePythonFormatString "" "hello {1+1:>10.2f}"
Right [
       Raw "hello ",
       Replacement "1+1"
       (
       Just (FormatMode
                      (Padding 10 (Just (Nothing,AnyAlign AlignRight)))
                      (FixedF (Precision 2) NormalForm Minus)
                       Nothing))]
-}

parseGenericFormatString :: Parser [Item]
parseGenericFormatString = do
  many (rawString <|> escapedParenthesis <|> replacementField) <* eof

rawString :: Parser Item
rawString = do
  (openingChar, closingChar) <- delimiters <$> ask
  chars <- some (noneOf ([openingChar, closingChar]))
  case escapeChars chars of
    Left remaining -> do
      offset <- getOffset
      setOffset (offset - length remaining)
      fancyFailure (Set.singleton (ErrorFail "lexical error in literal section"))
    Right escaped -> return (Raw escaped)

escapedParenthesis :: Parser Item
escapedParenthesis = do
  (openingChar, closingChar) <- delimiters <$> ask

  Raw <$> (parseRaw openingChar <|> parseRaw closingChar)
  where parseRaw c = c:[] <$ string (replicate 2 c)

{- | Replace escape chars with their value. Results in a Left with the
remainder of the string on encountering a lexical error (such as a bad escape
sequence).
>>> escapeChars "hello \\n"
Right "hello \n"
>>> escapeChars "hello \\x"
Left "\\x"
-}
escapeChars :: String -> Either String String
escapeChars "" = Right ""
escapeChars ('\\':'\n':xs) = escapeChars xs
escapeChars ('\\':'\\':xs) = ('\\' :) <$> escapeChars xs
escapeChars s = case Data.Char.readLitChar s of
                  ((c, xs):_) -> (c :) <$> escapeChars xs
                  _ -> Left s

replacementField :: Parser Item
replacementField = do
  exts <- enabledExtensions <$> ask
  (charOpening, charClosing) <- delimiters <$> ask

  _ <- char charOpening
  expr <- evalExpr exts (many (noneOf (charClosing:":" :: [Char])))
  fmt <- optional $ do
    _ <- char ':'
    format_spec
  _ <- char charClosing

  pure (Replacement expr fmt)

-- | Default formating mode, no padding, default precision, no grouping, no sign handling
pattern DefaultFormatMode :: FormatMode
pattern DefaultFormatMode = FormatMode PaddingDefault (DefaultF PrecisionDefault Minus) Nothing

-- | A Formatter, listing padding, format and and grouping char
data FormatMode = FormatMode Padding TypeFormat (Maybe Char)
                deriving (Show)

-- | Padding, containing the padding width, the padding char and the alignement mode
data Padding = PaddingDefault
             | Padding Integer (Maybe (Maybe Char, AnyAlign))
             deriving (Show)

-- | Represents a value of type @t@ or an Haskell expression supposed to represents that value
data ExprOrValue t
  = Value t
  | HaskellExpr Exp
  deriving (Show)

-- | Floating point precision
data Precision = PrecisionDefault
               | Precision (ExprOrValue Integer)
               deriving (Show)
{-

Python format mini language

format_spec     ::=  [[fill]align][sign][#][0][width][grouping_option][.precision][type]
fill            ::=  <any character>
align           ::=  "<" | ">" | "=" | "^"
sign            ::=  "+" | "-" | " "
width           ::=  integer
grouping_option ::=  "_" | ","
precision       ::=  integer
type            ::=  "b" | "c" | "d" | "e" | "E" | "f" | "F" | "g" | "G" | "n" | "o" | "s" | "x" | "X" | "%"
-}

data TypeFlag = Flagb | Flagc | Flagd | Flage | FlagE | Flagf | FlagF | Flagg | FlagG | Flagn | Flago | Flags | Flagx | FlagX | FlagPercent
  deriving (Show)

-- | All formating type
data TypeFormat =
    DefaultF Precision SignMode -- ^ Default, depends on the infered type of the expression
  | BinaryF AlternateForm SignMode -- ^ Binary, such as `0b0121`
  | CharacterF -- ^ Character, will convert an integer to its character representation
  | DecimalF SignMode -- ^ Decimal, base 10 integer formatting
  | ExponentialF Precision AlternateForm SignMode -- ^ Exponential notation for floatting points
  | ExponentialCapsF Precision AlternateForm SignMode -- ^ Exponential notation with capitalised @e@
  | FixedF Precision AlternateForm SignMode -- ^ Fixed number of digits floating point
  | FixedCapsF Precision AlternateForm SignMode -- ^ Capitalized version of the previous
  | GeneralF Precision AlternateForm SignMode -- ^ General formatting: `FixedF` or `ExponentialF` depending on the number magnitude
  | GeneralCapsF Precision AlternateForm SignMode -- ^ Same as `GeneralF` but with upper case @E@ and infinite / NaN
  | OctalF AlternateForm SignMode -- ^ Octal, such as 00245
  | StringF Precision -- ^ Simple string
  | HexF AlternateForm SignMode -- ^ Hexadecimal, such as 0xaf3e
  | HexCapsF AlternateForm SignMode -- ^ Hexadecimal with capitalized letters, such as 0XAF3E
  | PercentF Precision AlternateForm SignMode -- ^ Percent representation
  deriving (Show)

-- | If the formatter use its alternate form
data AlternateForm = AlternateForm | NormalForm
  deriving (Show)

lastCharFailed :: String -> Parser t
lastCharFailed err = do
  offset <- getOffset
  setOffset (offset - 1)

  fancyFailure (Set.singleton (ErrorFail err))

evalExpr :: [ParseExtension.Extension] -> Parser String -> Parser Exp
evalExpr exts exprParser = do
  offset <- getOffset
  s <- exprParser

  -- Setup the parser using the provided list of extensions
  -- Which are detected by template haskell at splice position
  let parseMode = ParseExp.defaultParseMode { ParseExp.extensions = exts }

  case SyntaxTranslate.toExp <$> ParseExp.parseExpWithMode parseMode s of
    ParseExp.ParseOk expr -> pure expr
    ParseExp.ParseFailed (SrcLoc.SrcLoc _name' line col) err -> do
      let
        linesBefore = take (line - 1) (lines s)
        currentOffset = length (unlines linesBefore) + col - 1

      setOffset (offset + currentOffset)
      fancyFailure (Set.singleton (ErrorFail err))

overrideAlignmentIfZero :: Bool -> Maybe (Maybe Char, AnyAlign) -> Maybe (Maybe Char, AnyAlign)
overrideAlignmentIfZero True Nothing = Just (Just '0', AnyAlign AlignInside)
overrideAlignmentIfZero True (Just (Nothing, al)) = Just (Just '0', al)
overrideAlignmentIfZero _ v = v

format_spec :: Parser FormatMode
format_spec = do
  al' <- optional alignment
  s <- optional sign
  alternateForm <- option NormalForm (AlternateForm <$ char '#')

  hasZero <- option False (True <$ char '0')

  let al = overrideAlignmentIfZero hasZero al'

  w <- optional width

  grouping <- optional grouping_option

  prec <- option PrecisionDefault parsePrecision
  t <- optional type_

  let padding = case w of
        Just p -> Padding p al
        Nothing -> PaddingDefault

  case t of
    Nothing -> pure (FormatMode padding (DefaultF prec (fromMaybe Minus s)) grouping)
    Just flag -> case evalFlag flag padding grouping prec alternateForm s of
      Right fmt -> pure (FormatMode padding fmt grouping)
      Left typeError -> do
        lastCharFailed typeError

parsePrecision :: Parser Precision
parsePrecision = do
  exts <- enabledExtensions <$> ask
  (charOpening, charClosing) <- delimiters <$> ask

  _ <- char '.'
  choice [
    Precision . Value <$> precision,
    char charOpening *> (Precision . HaskellExpr <$> evalExpr exts (manyTill anySingle (char charClosing)))
    ]

evalFlag :: TypeFlag -> Padding -> Maybe Char -> Precision -> AlternateForm -> Maybe SignMode -> Either String TypeFormat
evalFlag Flagb _pad _grouping prec alt s = failIfPrec prec (BinaryF alt (defSign s))
evalFlag Flagc _pad _grouping prec alt s = failIfS s =<< failIfPrec prec =<< failIfAlt alt CharacterF
evalFlag Flagd _pad _grouping prec alt s = failIfPrec prec =<< failIfAlt alt (DecimalF (defSign s))
evalFlag Flage _pad _grouping prec alt s = pure $ExponentialF prec alt (defSign s)
evalFlag FlagE _pad _grouping prec alt s = pure $ ExponentialCapsF prec alt (defSign s)
evalFlag Flagf _pad _grouping prec alt s = pure $ FixedF prec alt (defSign s)
evalFlag FlagF _pad _grouping prec alt s = pure $ FixedCapsF prec alt (defSign s)
evalFlag Flagg _pad _grouping prec alt s = pure $ GeneralF prec alt (defSign s)
evalFlag FlagG _pad _grouping prec alt s = pure $ GeneralCapsF prec alt (defSign s)
evalFlag Flagn _pad _grouping _prec _alt _s = Left ("Type 'n' not handled (yet). " ++ errgGn)
evalFlag Flago _pad _grouping prec alt s = failIfPrec prec $ OctalF alt (defSign s)
evalFlag Flags pad grouping prec alt s = failIfGrouping grouping =<< failIfInsidePadding pad =<< failIfS s =<< (failIfAlt alt $ StringF prec)
evalFlag Flagx _pad _grouping prec alt s = failIfPrec prec $ HexF alt (defSign s)
evalFlag FlagX _pad _grouping prec alt s = failIfPrec prec $ HexCapsF alt (defSign s)
evalFlag FlagPercent _pad _grouping prec alt s = pure $ PercentF prec alt (defSign s)

defSign :: Maybe SignMode -> SignMode
defSign Nothing = Minus
defSign (Just s) = s

failIfGrouping :: Maybe Char -> TypeFormat -> Either String TypeFormat
failIfGrouping (Just _) _t = Left "String type is incompatible with grouping (_ or ,)."
failIfGrouping Nothing t = Right t

failIfInsidePadding :: Padding -> TypeFormat -> Either String TypeFormat
failIfInsidePadding (Padding _ (Just (_, AnyAlign AlignInside))) _t = Left "String type is incompatible with inside padding (=)."
failIfInsidePadding _ t = Right t

errgGn :: String
errgGn = "Use one of {'b', 'c', 'd', 'e', 'E', 'f', 'F', 'g', 'G', 'n', 'o', 's', 'x', 'X', '%'}."

failIfPrec :: Precision -> TypeFormat -> Either String TypeFormat
failIfPrec PrecisionDefault i = Right i
failIfPrec (Precision e) _ = Left ("Type incompatible with precision (." ++ showExpr ++ "), use any of {'e', 'E', 'f', 'F', 'g', 'G', 'n', 's', '%'} or remove the precision field.")
  where
    showExpr = case e of
      Value v -> show v
      HaskellExpr expr -> show expr

failIfAlt :: AlternateForm -> TypeFormat -> Either String TypeFormat
failIfAlt NormalForm i = Right i
failIfAlt _ _ = Left "Type incompatible with alternative form (#), use any of {'e', 'E', 'f', 'F', 'g', 'G', 'n', 'o', 'x', 'X', '%'} or remove the alternative field."

failIfS :: Maybe SignMode -> TypeFormat -> Either String TypeFormat
failIfS Nothing i = Right i
failIfS (Just s) _ = Left ("Type incompatible with sign field (" ++ [toSignMode s] ++ "), use any of {'b', 'd', 'e', 'E', 'f', 'F', 'g', 'G', 'n', 'o', 'x', 'X', '%'} or remove the sign field.")

toSignMode :: SignMode -> Char
toSignMode Plus = '+'
toSignMode Minus = '-'
toSignMode Space = ' '

alignment :: Parser (Maybe Char, AnyAlign)
alignment = choice [
    try $ do
        c <- fill
        mode <- align
        pure (Just c, mode)
    , do
        mode <- align
        pure (Nothing, mode)
    ]

fill :: Parser Char
fill = anySingle

align :: Parser AnyAlign
align = choice [
  AnyAlign AlignLeft <$ char '<',
  AnyAlign AlignRight <$ char '>',
  AnyAlign AlignCenter <$ char '^',
  AnyAlign AlignInside <$ char '='
  ]

sign :: Parser SignMode
sign = choice
  [Plus <$ char '+',
   Minus <$ char '-',
   Space <$ char ' '
  ]

width :: Parser Integer
width = integer

integer :: Parser Integer
integer = L.decimal -- incomplete: see: https://docs.python.org/3/reference/lexical_analysis.html#grammar-token-integer

grouping_option :: Parser Char
grouping_option = oneOf ("_," :: [Char])

precision :: Parser Integer
precision = integer

type_ :: Parser TypeFlag
type_ = choice [
  Flagb <$ char 'b',
  Flagc <$ char 'c',
  Flagd <$ char 'd',
  Flage <$ char 'e',
  FlagE <$ char 'E',
  Flagf <$ char 'f',
  FlagF <$ char 'F',
  Flagg <$ char 'g',
  FlagG <$ char 'G',
  Flagn <$ char 'n',
  Flago <$ char 'o',
  Flags <$ char 's',
  Flagx <$ char 'x',
  FlagX <$ char 'X',
  FlagPercent <$ char '%'
  ]
