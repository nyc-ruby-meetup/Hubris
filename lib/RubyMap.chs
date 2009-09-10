{-# LANGUAGE ForeignFunctionInterface #-}
-- {-# LANGUAGE TypeSynonymInstances #-}

module RubyMap where
#include "rshim.h"
#include <ruby.h>

import Control.Applicative
import Control.Monad
import Data.Word
import Foreign.Ptr
import Foreign.C.Types	
import Foreign.C.String
import Foreign.Storable
import System.IO.Unsafe (unsafePerformIO)
-- import Unsafe.Coerce    (unsafeCoerce)
import Foreign.Marshal.Array

-- import PackedString
{# context lib="rshim" #}
{# enum RubyType {} deriving (Eq, Show) #} -- maybe Ord?
{# enum ruby_special_consts as RubyConsts {} deriving (Eq,Show) #}

type Value = CULong -- FIXME, we'd prefer to import the type VALUE directly
foreign import ccall unsafe "ruby.h rb_str2cstr" rb_str2cstr :: Value -> CInt -> CString
foreign import ccall unsafe "ruby.h rb_str_new2" rb_str_new2 :: CString -> Value
foreign import ccall unsafe "ruby.h rb_ary_new2" rb_ary_new2 :: CLong -> IO Value
foreign import ccall unsafe "ruby.h rb_ary_push" rb_ary_push :: Value -> Value -> IO ()
--foreign import ccall unsafe "ruby.h rb_ary_store" rb_ary_store :: Value -> Int -> Value -> IO ()
-- this line crashes jhc
foreign import ccall unsafe "intern.h rb_ary_entry" rb_ary_entry :: Value -> CLong -> IO Value
foreign import ccall unsafe "rshim.h rb_ary_len" rb_ary_len :: Value -> CUInt
foreign import ccall unsafe "ruby.h rb_float_new" rb_float_new :: Double -> Value
foreign import ccall unsafe "ruby.h rb_big2str"   rb_big2str :: Value -> Int -> Value
foreign import ccall unsafe "ruby.h rb_str_to_inum"   rb_str_to_inum :: Value -> Int -> Int -> Value

-- we're being a bit filthy here - the interface is all macros, so we're digging in to find what it actually is
foreign import ccall unsafe "rshim.h rtype" rtype :: Value -> Int
foreign import ccall unsafe "rshim.h int2fix" int2fix :: Int -> Value
foreign import ccall unsafe "rshim.h fix2int" fix2int ::  Value -> Int

foreign import ccall unsafe "rshim.h num2dbl" num2dbl :: Value -> Double  -- technically CDoubles, but jhc promises they're the same

foreign import ccall unsafe "stdio.h puts" puts :: CString -> IO ()


-- all values in here need to be allocated and tracked by ruby.
-- ByteStrings... hm. Probably better to keep them as C-side ruby strings.
-- better come back and expand this later
data RValue = T_NIL  
--            | T_OBJECT 
--             | T_CLASS      
--             | T_MODULE     
            | T_FLOAT Double
            | T_STRING String
--            | T_REGEXP     
              -- the array needs to be managed by ruby
              -- so this is non-ideal, but hard to do much else without GHC libs.
            | T_ARRAY [RValue]
            | T_FIXNUM Int --fixme, probably
              -- the hash needs to be managed by ruby
            | T_HASH  Int -- definitely FIXME - native ruby hashes, or going to translitrate?
--            | T_STRUCT     
            | T_BIGNUM Integer    
--            | T_FILE
     -- technically, these are mapping over the types True and False,
     -- I'm going to treat them as values, though.
            | T_TRUE  
            | T_FALSE      
--            | T_DATA       
            | T_SYMBOL Word -- interned string
          --     deriving Show
--instance Show RValue where
--  show _ = "no real show instance, sorry"

-- instance Storable RValue where
--   peek = undefined
--   poke = undefined
-- qnil = 4
-- qfalse = 0
-- qtrue = 2

toRuby :: RValue -> Value
toRuby r = case r of
           T_FLOAT d -> rb_float_new d
           -- need to take the address of the cstr, just cast it to a value
           -- sadly no bytestrings yet - unpack it to a list. yeah it's ugly.
           T_STRING str -> rb_str_new2 $ unsafePerformIO $ newCAString str
           T_FIXNUM i -> int2fix i
           -- so this is just bizarre - there's no boolean type. True and False have their own types
           -- as well as their own values.
           T_TRUE  ->  fromIntegral $ fromEnum RUBY_Qtrue
           T_FALSE ->  fromIntegral $ fromEnum RUBY_Qfalse
           T_NIL   ->  fromIntegral $ fromEnum RUBY_Qnil
           T_ARRAY l -> unsafePerformIO $ do
                           ary <- rb_ary_new2 $ fromIntegral $ length l
                           mapM_ (rb_ary_push ary . toRuby) l
                           return ary
                           -- return undefined -- ary
           T_BIGNUM b -> rb_str_to_inum (rb_str_new2 $ unsafePerformIO $ newCAString $ show b) 10 1
                         -- _          -> undefined -- error ("sorry, haven't implemented that yet." ) -- ++ show r)

fromRuby :: Value -> RValue
fromRuby v = case target of
               RT_NIL -> T_NIL
               RT_FIXNUM -> T_FIXNUM $ fix2int v
               RT_STRING -> T_STRING $ unsafePerformIO $ peekCString $ rb_str2cstr v 0
               RT_FLOAT ->  T_FLOAT $ num2dbl v
               RT_BIGNUM -> T_BIGNUM $ read  $ unsafePerformIO $ peekCString $ rb_str2cstr (rb_big2str v 10) 0
               RT_TRUE -> T_TRUE
               RT_FALSE -> T_FALSE
                           -- yes i know this is filthy
               RT_ARRAY -> T_ARRAY $ map fromRuby $ unsafePerformIO  $ mapM (rb_ary_entry v . fromIntegral) [0..(rb_ary_len v) - 1]

               _ -> error (show target)
      where target :: RubyType
            target = toEnum $ rtype v