{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
module Data.Winery.Internal
  ( unsignedVarInt
  , varInt
  , Decoder
  , decodeVarInt
  , getWord8
  , getWord16
  , getWord32
  , getWord64
  , DecodeException(..)
  , unsafeIndex
  , unsafeIndexV
  , Strategy(..)
  , StrategyError
  , errorStrategy
  , TransFusion(..)
  )where

import Control.Applicative
import Control.Exception
import Control.Monad
import Control.Monad.Fix
import Control.Monad.Trans.Cont
import qualified Data.ByteString as B
import qualified Data.ByteString.FastBuilder as BB
import qualified Data.ByteString.Internal as B
import Data.Bits
import Data.Monoid ((<>))
import Data.Text.Prettyprint.Doc (Doc)
import Data.Text.Prettyprint.Doc.Render.Terminal (AnsiStyle)
import qualified Data.Vector.Unboxed as U
import Data.Word
import Foreign.ForeignPtr
import Foreign.Storable
import System.Endian

unsignedVarInt :: (Bits a, Integral a) => a -> BB.Builder
unsignedVarInt n
  | n < 0x80 = BB.word8 (fromIntegral n)
  | otherwise = BB.word8 (fromIntegral n `setBit` 7) <> uvarInt (unsafeShiftR n 7)
{-# INLINE unsignedVarInt #-}

varInt :: (Bits a, Integral a) => a -> BB.Builder
varInt n
  | n < 0 = case negate n of
    n'
      | n' < 0x40 -> BB.word8 (fromIntegral n' `setBit` 6)
      | otherwise -> BB.word8 (0xc0 .|. fromIntegral n') <> uvarInt (unsafeShiftR n' 6)
  | n < 0x40 = BB.word8 (fromIntegral n)
  | otherwise = BB.word8 (fromIntegral n `setBit` 7 `clearBit` 6) <> uvarInt (unsafeShiftR n 6)
{-# SPECIALISE varInt :: Int -> BB.Builder #-}
{-# INLINEABLE varInt #-}

uvarInt :: (Bits a, Integral a) => a -> BB.Builder
uvarInt = go where
  go m
    | m < 0x80 = BB.word8 (fromIntegral m)
    | otherwise = BB.word8 (setBit (fromIntegral m) 7) <> go (unsafeShiftR m 7)
{-# INLINE uvarInt #-}

type Decoder = (->) B.ByteString

getWord8 :: ContT r Decoder Word8
getWord8 = ContT $ \k bs -> case B.uncons bs of
  Nothing -> throw InsufficientInput
  Just (x, b) -> k x b
{-# INLINE getWord8 #-}

data DecodeException = InsufficientInput
  | InvalidTag deriving (Eq, Show, Read)
instance Exception DecodeException

decodeVarInt :: (Num a, Bits a) => ContT r Decoder a
decodeVarInt = getWord8 >>= \case
  n | testBit n 7 -> do
      m <- getWord8 >>= go
      if testBit n 6
        then return $! negate $ unsafeShiftL m 6 .|. fromIntegral n .&. 0x3f
        else return $! unsafeShiftL m 6 .|. clearBit (fromIntegral n) 7
    | testBit n 6 -> return $ negate $ fromIntegral $ clearBit n 6
    | otherwise -> return $ fromIntegral n
  where
    go n
      | testBit n 7 = do
        m <- getWord8 >>= go
        return $! unsafeShiftL m 7 .|. clearBit (fromIntegral n) 7
      | otherwise = return $ fromIntegral n
{-# INLINE decodeVarInt #-}

getWord16 :: Decoder Word16
getWord16 (B.PS fp ofs len) = if len >= 2
  then B.accursedUnutterablePerformIO $ withForeignPtr fp
    $ \ptr -> fromLE16 <$> peekByteOff ptr ofs
  else throw InsufficientInput

getWord32 :: Decoder Word32
getWord32 (B.PS fp ofs len) = if len >= 4
  then B.accursedUnutterablePerformIO $ withForeignPtr fp
    $ \ptr -> fromLE32 <$> peekByteOff ptr ofs
  else throw InsufficientInput

getWord64 :: Decoder Word64
getWord64 (B.PS fp ofs len) = if len >= 8
  then B.accursedUnutterablePerformIO $ withForeignPtr fp
    $ \ptr -> fromLE64 <$> peekByteOff ptr ofs
  else throw InsufficientInput

unsafeIndexV :: U.Unbox a => String -> U.Vector a -> Int -> a
unsafeIndexV err xs i
  | i >= U.length xs || i < 0 = error err
  | otherwise = U.unsafeIndex xs i
{-# INLINE unsafeIndexV #-}

unsafeIndex :: a -> [a] -> Int -> a
unsafeIndex err xs i = (xs ++ repeat err) !! i

type StrategyError = Doc AnsiStyle

newtype Strategy r a = Strategy { unStrategy :: [r] -> Either StrategyError a }
  deriving Functor

instance Applicative (Strategy r) where
  pure = return
  (<*>) = ap

instance Monad (Strategy r) where
  return = Strategy . const . Right
  m >>= k = Strategy $ \decs -> case unStrategy m decs of
    Right a -> unStrategy (k a) decs
    Left e -> Left e

instance Alternative (Strategy r) where
  empty = Strategy $ const $ Left "empty"
  Strategy a <|> Strategy b = Strategy $ \decs -> case a decs of
    Left _ -> b decs
    Right x -> Right x

instance MonadFix (Strategy r) where
  mfix f = Strategy $ \r -> mfix $ \a -> unStrategy (f a) r
  {-# INLINE mfix #-}

errorStrategy :: Doc AnsiStyle -> Strategy r a
errorStrategy = Strategy . const . Left

newtype TransFusion f g a = TransFusion { unTransFusion :: forall h. Applicative h => (forall x. f x -> h (g x)) -> h a }

instance Functor (TransFusion f g) where
  fmap f (TransFusion m) = TransFusion $ \k -> fmap f (m k)
  {-# INLINE fmap #-}

instance Applicative (TransFusion f g) where
  pure a = TransFusion $ \_ -> pure a
  TransFusion a <*> TransFusion b = TransFusion $ \k -> a k <*> b k
  {-# INLINE (<*>) #-}
