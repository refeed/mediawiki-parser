{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}

module Data.MediaWiki.Markup where

import qualified Control.Lens as L
import           Control.Lens ((&), (.~), (^.))
import           Data.Bits.Lens (bitAt)
import GHC.Generics
import Data.Char
import Control.Monad (replicateM_, void)
import Data.Monoid
import Control.Applicative

import Text.Trifecta hiding (doc)
import qualified Data.CharSet as CS
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS

newtype PageName = PageName ByteString
                 deriving (Show, Generic)
newtype Url = Url ByteString
            deriving (Show, Generic)

data Doc = Text !ByteString
         | NewPara
         | Comment !ByteString
         | Header !Int !ByteString
         | InternalLink !PageName [Doc]
         | ExternalLink !Url [Doc]
         | Template !ByteString [(Maybe ByteString, ByteString)]
         | XmlOpenClose String
         | XmlOpen String
         | XmlClose String
         | BoldItalic [Doc]
         | Bold [Doc]
         | Italic [Doc]
         | CodeLine !ByteString
         | NoWiki !ByteString
         deriving (Show)

named :: String -> Parser a -> Parser a
named = flip (<?>)

data Context = Context { _ctxFlags :: !Int }

L.makeLenses ''Context

insideBold, insideItalic, insideBoldItalic, insideInternalLink :: L.Lens' Context Bool
insideBold = ctxFlags . bitAt 0
insideItalic = ctxFlags . bitAt 1
insideBoldItalic = ctxFlags . bitAt 2
insideInternalLink = ctxFlags . bitAt 3

doc :: Parser Doc
doc = doc' (Context 0)

doc' :: Context -> Parser Doc
doc' ctx = named "document element"
    $ endSingleQuote
    $ header <|> codeLine <|> try noWiki <|> try comment <|> try xmlish
   <|> internalLink ctx <|> externalLink ctx <|> template
   <|> boldItalic <|> bold <|> italic
   <|> try newPara <|> text_
  where
    endSingleQuote x
      | ctx ^. insideBoldItalic = notFollowedBy (text "'''''") >> x
      | ctx ^. insideBold = notFollowedBy (text "'''") >> x
      | ctx ^. insideItalic = notFollowedBy (text "''") >> x
      | otherwise = x
    boldItalic
      | ctx ^. insideBoldItalic = empty
      | otherwise  = named "bold italic"
                   $ do let sym = text "'''''"
                        fmap BoldItalic $ between sym sym $ some $ doc' (ctx & insideBoldItalic .~ True)

    bold
      | ctx ^. insideBold = empty
      | otherwise  = named "bold"
                   $ do let sym = notFollowedBy (text "''''") >> text "'''"
                        fmap Bold $ between sym sym $ some $ doc' (ctx & insideBold .~ True)

    italic
      | ctx ^. insideItalic = empty
      | otherwise  = named "italic"
                   $ do let sym = notFollowedBy (text "'''") >> text "''"
                        fmap Italic $ between sym sym $ some $ doc' (ctx & insideItalic .~ True)

    codeLine   = fmap CodeLine   $ try $ newline >> space >> restOfLine <* newline
    noWiki     = fmap NoWiki     $ try $ between' (text "<nowiki>") (text "</nowiki>")
    comment    = Comment <$> between' (text "<!--") (text "-->")
    newPara    = do
        newline
        many $ oneOf " \t"
        newline
        return NewPara
    text_      = Text <$> do
      sliced (some (noneOf "[]{}&|\\<\"'\n"))
        <|> sliced (if ctx ^. insideInternalLink then empty else oneOf "|]")
        <|> sliced (oneOf "[]{}&\\<\"'\n")

    header     = named "header" $ try $ do
      n <- length <$> some (char '=')
      spaces
      title <- sliced $ some $ noneOf "="
      replicateM_ n (char '=')
      skipMany $ char ' '
      newline
      return $ Header n title

xmlish :: Parser Doc
xmlish = named "xmlish" $ do
    char '<'
    closeTag <|> openTag
  where
    closeTag = do
        char '/' >> spaces
        tag <- some letter
        char '>'
        return $ XmlClose tag

    openTag = do
        spaces
        tag <- some letter
        spaces
        many attribute
        selfClosing tag <|> withContent tag
      where
        attribute = do
            some letter
            spaces
            char '='
            spaces
            (between' (char '"') (char '"'))
                <|> (between' (char '\'') (char '\''))
                <|> sliced (some $ noneOf "/> \t\n")
            spaces

        withContent tag = do
            char '>'
            return $ XmlOpen tag

        selfClosing tag = do
            text "/>"
            return $ XmlOpenClose tag

template :: Parser Doc
template = named "template" $ do
    text "{{"
    title <- balancedText
    pairs <- many $ char '|' >> (try keyValuePair <|> onlyValue <|> emptyPair)
    text "}}"
    return $ Template title pairs
  where
    balancedText = named "balanced text" $ sliced content
      where
        content = some $  void template
                      <|> void (some $ noneOf "}|")
                      <|> void (notFollowedBy (text "}}") >> char '}')

    emptyPair = return (Nothing, mempty)

    onlyValue = do
      val <- balancedText
      return (Nothing, val)

    keyValuePair = do
      key <- sliced $ some $ noneOf "}|="
      char '='
      value <- balancedText
      return (Just key, value)

internalLink :: Context -> Parser Doc
internalLink ctx = named "internal link" $ do
    text "[["
    page <- PageName <$> sliced (some $ noneOf "|]" <|> singleClose)
    attrs <- many $ do
        char '|'
        many $ notFollowedBy (text "]]") >> doc' (ctx & insideInternalLink .~ True)
    let body = case attrs of [] -> []
                             xs -> last xs
    text "]]"
    return $ InternalLink page body
  where
    singleClose = notFollowedBy (text "]]") >> char ']'

-- | This can backtrack since sometimes you find things like @hello [world]@ in
-- markup, which Wikipedia simply renders as plain text.
externalLink :: Context -> Parser Doc
externalLink ctx = try $ named "external link" $ do
    notFollowedBy $ text "[["
    char '['
    u <- url
    spaces
    body <- many $ notFollowedBy (notFollowedBy (text "]]") >> char ']') >> doc' ctx
    char ']'
    return $ ExternalLink u body

between' :: Parser bra -> Parser ket -> Parser ByteString
between' bra ket = do
    bra
    start <- mark
    let go = end <|> (anyChar >> go)
        end = do d <- mark
                 ket
                 release d
    ret <- sliced go
    ket
    return ret

url :: DeltaParsing m => m Url
url = fmap Url $ sliced $ do
    some $ oneOfSet asciiLetters
    text "://"
    some $ oneOfSet urlChars

asciiLetters :: CS.CharSet
asciiLetters = CS.range 'a' 'z' <> CS.range 'A' 'Z'

urlChars :: CS.CharSet
urlChars = asciiLetters <> CS.range '0' '9' <> CS.fromList "-_.~!*'();:@&=+$,/?%#"