{-# LANGUAGE OverloadedStrings, LambdaCase #-}
module Data.Winery.Term where

import Control.Monad
import Control.Monad.Trans
import Control.Monad.Trans.Cont
import Control.Monad.Reader
import qualified Data.ByteString as B
import Data.Int
import Data.Monoid
import qualified Data.Text as T
import Data.Winery
import Data.Winery.Internal
import Data.Word

data Term = TUnit
  | TBool !Bool
  | TWord8 !Word8
  | TWord16 !Word16
  | TWord32 !Word32
  | TWord64 !Word64
  | TInt8 !Int8
  | TInt16 !Int16
  | TInt32 !Int32
  | TInt64 !Int64
  | TInteger !Integer
  | TFloat !Float
  | TDouble !Double
  | TBytes !B.ByteString
  | TText !T.Text
  | TList [Term]
  | TProduct [Term]
  | TRecord [(T.Text, Term)]
  | TVariant !T.Text [Term]
  deriving Show

decodeTerm :: Plan (Decoder Term)
decodeTerm = go [] where
  go points = ReaderT $ \s -> case s of
    SSchema ver -> lift (bootstrapSchema ver) >>= runReaderT (go points)
    SUnit -> pure (pure TUnit)
    SBool -> p s TBool
    SWord8 -> p s TWord8
    SWord16 -> p s TWord16
    SWord32 -> p s TWord32
    SWord64 -> p s TWord64
    SInt8 -> p s TInt8
    SInt16 -> p s TInt16
    SInt32 -> p s TInt32
    SInt64 -> p s TInt64
    SInteger -> p s TInteger
    SFloat -> p s TFloat
    SDouble -> p s TDouble
    SBytes -> p s TBytes
    SText -> p s TText
    SList sch -> do
      dec <- go points `runReaderT` sch
      return $ evalContT $ case sizeFromSchema sch of
        Nothing -> do
          n <- decodeVarInt
          offsets <- replicateM (n - 1) decodeVarInt
          asks $ \bs -> TList [decodeAt ofs dec bs | ofs <- take n $ 0 : offsets]
        Just size -> do
          n <- decodeVarInt
          asks $ \bs -> TList [decodeAt (size * i) dec bs | i <- [0..n - 1]]
    SProduct schs -> do
      decoders <- traverse (runReaderT $ go points) schs
      return $ evalContT $ do
        offsets <- replicateM (length decoders - 1) decodeVarInt
        asks $ \bs -> TProduct [decodeAt ofs dec bs | (dec, ofs) <- zip decoders $ 0 : offsets]
    SRecord schs -> do
      decoders <- traverse (\(name, sch) -> (,) name <$> runReaderT (go points) sch) schs
      return $ evalContT $ do
        offsets <- replicateM (length decoders - 1) decodeVarInt
        asks $ \bs -> TRecord [(name, decodeAt ofs dec bs) | ((name, dec), ofs) <- zip decoders $ 0 : offsets]
    SVariant schs -> do
      decoders <- traverse (\(name, sch) -> (,) name <$> traverse (runReaderT (go points)) sch) schs
      return $ evalContT $ do
        tag <- decodeVarInt
        let (name, decs) = decoders !! tag
        offsets <- replicateM (length decs - 1) decodeVarInt
        asks $ \bs -> TVariant name [decodeAt ofs dec bs | (dec, ofs) <- zip decs $ 0 : offsets]
    SSelf i -> return $ points !! fromIntegral i
    SFix s' -> mfix $ \a -> go (a : points) `runReaderT` s'

  p s f = fmap f <$> runReaderT planDecoder s

-- | Deserialise a 'serialise'd 'B.Bytestring'.
deserialiseTerm :: B.ByteString -> Either String (Term, Term)
deserialiseTerm bs = do
  getSchema <- getDecoder $ SSchema 0
  getSchemaTerm <- getDecoderBy decodeTerm $ SSchema 0
  ($bs) $ evalContT $ do
    offB <- decodeVarInt
    sch <- lift getSchema
    schT <- lift getSchemaTerm
    body <- asks $ deserialiseWithSchemaBy decodeTerm sch . B.drop offB
    return ((,) schT <$> body)

data Doc = DStr T.Text | DDocs [Doc]
    | DCon T.Text Doc

termToDoc :: Term -> Doc
termToDoc TUnit = DStr "()"
termToDoc (TWord8 i) = DStr $ show' i
termToDoc (TWord16 i) = DStr $ show' i
termToDoc (TWord32 i) = DStr $ show' i
termToDoc (TWord64 i) = DStr $ show' i
termToDoc (TInt8 i) = DStr $ show' i
termToDoc (TInt16 i) = DStr $ show' i
termToDoc (TInt32 i) = DStr $ show' i
termToDoc (TInt64 i) = DStr $ show' i
termToDoc (TInteger i) = DStr $ show' i
termToDoc (TBytes s) = DStr $ show' s
termToDoc (TText s) = DStr $ show' s
termToDoc (TList xs) = DDocs (map termToDoc xs)
termToDoc (TBool x) = DStr $ show' x
termToDoc (TFloat x) = DStr $ show' x
termToDoc (TDouble x) = DStr $ show' x
termToDoc (TProduct xs) = DDocs $ map termToDoc xs
termToDoc (TRecord xs) = DDocs [DCon k (termToDoc v) | (k, v) <- xs]
termToDoc (TVariant tag xs) = DCon tag $ DDocs $ map termToDoc xs

show' :: Show a => a -> T.Text
show' = T.pack . show

showDoc :: Doc -> T.Text
showDoc = T.intercalate "\n" . go where
  go :: Doc -> [T.Text]
  go = \case
    DStr s -> [s]
    DCon str doc -> case go doc of
      [] -> [str]
      [x] -> [str <> ": " <> x]
      xs -> str <> ": " : map ("  "<>) xs
    DDocs [] -> []
    DDocs [x] -> go x
    DDocs ds -> case concatMap go ds of
      x : xs -> "- " <> x : map ("  "<>) xs
      [] -> []

prettyTerm :: Term -> T.Text
prettyTerm = showDoc . termToDoc