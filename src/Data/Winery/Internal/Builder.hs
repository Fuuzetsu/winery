{-# LANGUAGE CPP #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}
module Data.Winery.Internal.Builder
  ( Encoding
  , getSize
  , toByteString
  , hPutEncoding
  , word8
  , word16
  , word32
  , word64
  , bytes
  , varInt
  , unsignedVarInt
  ) where

import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as B
import Data.Word
#if !MIN_VERSION_base(4,11,0)
import Data.Semigroup
#endif
import Data.String
import Data.IORef
import Foreign.Ptr
import Foreign.ForeignPtr
import Foreign.Storable
import GHC.IO.Buffer
import GHC.IO.Handle.Internals
import GHC.IO.Handle.Types
import qualified GHC.IO.BufferedIO as Buffered
import System.IO.Unsafe
import System.Endian

data Encoding = Encoding {-# UNPACK #-}!Int Tree
  | Empty
  deriving Eq

instance Show Encoding where
  show = show . toByteString

instance IsString Encoding where
  fromString = bytes . fromString

data Tree = Bin Tree Tree
  | LWord8 {-# UNPACK #-} !Word8
  | LWord16 {-# UNPACK #-} !Word16
  | LWord32 {-# UNPACK #-} !Word32
  | LWord64 {-# UNPACK #-} !Word64
  | LBytes !B.ByteString
  deriving Eq

instance Semigroup Encoding where
  Empty <> a = a
  a <> Empty = a
  Encoding s a <> Encoding t b = Encoding (s + t) (Bin a b)

instance Monoid Encoding where
  mempty = Empty
  {-# INLINE mempty #-}
  mappend = (<>)
  {-# INLINE mappend #-}

getSize :: Encoding -> Int
getSize Empty = 0
getSize (Encoding s _) = s
{-# INLINE getSize #-}

pokeTree :: Ptr Word8 -> Tree -> IO ()
pokeTree ptr l = case l of
  LWord8 w -> poke ptr w
  LWord16 w -> poke (castPtr ptr) $ toBE16 w
  LWord32 w -> poke (castPtr ptr) $ toBE32 w
  LWord64 w -> poke (castPtr ptr) $ toBE64 w
  LBytes (B.PS fp ofs len) -> withForeignPtr fp
    $ \src -> B.memcpy ptr (src `plusPtr` ofs) len
  Bin a b -> rotateTree ptr a b

rotateTree :: Ptr Word8 -> Tree -> Tree -> IO ()
rotateTree ptr (LWord8 w) t = poke ptr w >> pokeTree (ptr `plusPtr` 1) t
rotateTree ptr (LWord16 w) t = poke (castPtr ptr) (toBE16 w) >> pokeTree (ptr `plusPtr` 2) t
rotateTree ptr (LWord32 w) t = poke (castPtr ptr) (toBE32 w) >> pokeTree (ptr `plusPtr` 4) t
rotateTree ptr (LWord64 w) t = poke (castPtr ptr) (toBE64 w) >> pokeTree (ptr `plusPtr` 8) t
rotateTree ptr (LBytes (B.PS fp ofs len)) t = do
  withForeignPtr fp
    $ \src -> B.memcpy ptr (src `plusPtr` ofs) len
  pokeTree (ptr `plusPtr` len) t
rotateTree ptr (Bin c d) t = rotateTree ptr c (Bin d t)

toByteString :: Encoding -> B.ByteString
toByteString Empty = B.empty
toByteString (Encoding _ (LBytes bs)) = bs
toByteString (Encoding len tree) = unsafeDupablePerformIO $ do
  fp <- B.mallocByteString len
  withForeignPtr fp $ \ptr -> pokeTree ptr tree
  return (B.PS fp 0 len)

word8 :: Word8 -> Encoding
word8 = Encoding 1 . LWord8
{-# INLINE word8 #-}

word16 :: Word16 -> Encoding
word16 = Encoding 2 . LWord16
{-# INLINE word16 #-}

word32 :: Word32 -> Encoding
word32 = Encoding 4 . LWord32
{-# INLINE word32 #-}

word64 :: Word64 -> Encoding
word64 = Encoding 8 . LWord64
{-# INLINE word64 #-}

bytes :: B.ByteString -> Encoding
bytes bs = Encoding (B.length bs) $ LBytes bs
{-# INLINE bytes #-}

unsignedVarInt :: (Bits a, Integral a) => a -> Encoding
unsignedVarInt n
  | n < 0x80 = word8 (fromIntegral n)
  | otherwise = uvarInt 1 (LWord8 (fromIntegral n `setBit` 7)) (unsafeShiftR n 7)
{-# SPECIALISE unsignedVarInt :: Int -> Encoding #-}

varInt :: (Bits a, Integral a) => a -> Encoding
varInt n
  | n < 0 = case negate n of
    n'
      | n' < 0x40 -> word8 (fromIntegral n' `setBit` 6)
      | otherwise -> uvarInt 1 (LWord8 (0xc0 .|. fromIntegral n')) (unsafeShiftR n' 6)
  | n < 0x40 = word8 (fromIntegral n)
  | otherwise = uvarInt 1 (LWord8 (fromIntegral n `setBit` 7 `clearBit` 6)) (unsafeShiftR n 6)
{-# SPECIALISE varInt :: Int -> Encoding #-}

uvarInt :: (Bits a, Integral a) => Int -> Tree -> a -> Encoding
uvarInt siz acc m
  | m < 0x80 = Encoding (siz + 1) (acc `Bin` LWord8 (fromIntegral m))
  | otherwise = uvarInt (siz + 1) (acc `Bin` LWord8 (setBit (fromIntegral m) 7)) (unsafeShiftR m 7)


pokeBuffer :: (Buffered.BufferedIO dev, Storable a) => dev -> Buffer Word8
  -> Int -> a
  -> (Int -> IO (Buffer Word8))
  -> (Buffer Word8 -> IO (Buffer Word8))
  -> IO (Buffer Word8)
pokeBuffer dev buf i x cont cont'
  | i + sizeOf x < bufSize buf = do
    withBuffer buf $ \ptr -> pokeByteOff ptr i x
    cont (i + sizeOf x)
  | otherwise = do
    buf' <- Buffered.flushWriteBuffer dev buf { bufR = i }
    withBuffer buf' $ \ptr -> pokeByteOff ptr (bufR buf') x
    cont' $ bufferAdd (sizeOf x) buf'
{-# INLINE pokeBuffer #-}

hPutEncoding :: Handle -> Encoding -> IO ()
hPutEncoding _ Empty = return ()
hPutEncoding h (Encoding _ t0) = wantWritableHandle "Data.Winery.Intenal.Builder.hPutEncoding" h
  $ \Handle__{..} -> do
    let loop tree buf = go tree (bufR buf) where
          go (LWord8 w) i = pokeBuffer haDevice buf i w (\j -> pure buf { bufR = j }) pure
          go (LWord16 w) i = pokeBuffer haDevice buf i (toBE16 w) (\j -> pure buf { bufR = j }) pure
          go (LWord32 w) i = pokeBuffer haDevice buf i (toBE32 w) (\j -> pure buf { bufR = j }) pure
          go (LWord64 w) i = pokeBuffer haDevice buf i (toBE64 w) (\j -> pure buf { bufR = j }) pure
          go t@(LBytes (B.PS fp ofs len)) i
            | i + len < bufSize buf = (buf { bufR = i + len } <$) $ withBuffer buf
              $ \ptr -> withForeignPtr fp
              $ \src -> B.memcpy (ptr `plusPtr` i) (src `plusPtr` ofs) len
            | bufSize buf >= len = Buffered.flushWriteBuffer haDevice buf { bufR = i }
              >>= loop t
            | otherwise = newByteBuffer len WriteBuffer >>= loop t
          go (Bin c d) i = rot c d i

          rot (LWord8 w) t i = pokeBuffer haDevice buf i w (go t) (loop t)
          rot (LWord16 w) t i = pokeBuffer haDevice buf i (toBE16 w) (go t) (loop t)
          rot (LWord32 w) t i = pokeBuffer haDevice buf i (toBE32 w) (go t) (loop t)
          rot (LWord64 w) t i = pokeBuffer haDevice buf i (toBE64 w) (go t) (loop t)
          rot t@(LBytes (B.PS fp ofs len)) t' i
            | i + len < bufSize buf = do
              withBuffer buf
                $ \ptr -> withForeignPtr fp
                $ \src -> B.memcpy (ptr `plusPtr` i) (src `plusPtr` ofs) len
              go t' (i + len)
            | bufSize buf >= len = Buffered.flushWriteBuffer haDevice buf { bufR = i }
              >>= loop (Bin t t')
            | otherwise = do
              _ <- Buffered.flushWriteBuffer haDevice buf { bufR = i }
              newByteBuffer len WriteBuffer >>= loop (Bin t t')
          rot (Bin c d) t i = rot c (Bin d t) i
    buf0 <- readIORef haByteBuffer
    buf' <- loop t0 buf0
    writeIORef haByteBuffer buf'
