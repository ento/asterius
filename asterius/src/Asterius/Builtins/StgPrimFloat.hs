{-# LANGUAGE OverloadedStrings #-}

module Asterius.Builtins.StgPrimFloat
  ( stgPrimFloatCBits,
  )
where

import Asterius.EDSL
import Asterius.Types

stgPrimFloatCBits :: AsteriusModule
stgPrimFloatCBits = wordEncodeDouble <> wordEncodeFloat

wordEncodeDouble, wordEncodeFloat :: AsteriusModule
wordEncodeDouble = runEDSL "__word_encodeDouble" $ do
  setReturnTypes [F64]
  [j, e] <- params [I64, I64]
  emit $
    Binary
      MulFloat64
      (Unary ConvertUInt64ToFloat64 j)
      (Unary ConvertUInt64ToFloat64 (Binary ShlInt64 (ConstI64 1) e))
wordEncodeFloat = runEDSL "__word_encodeFloat" $ do
  setReturnTypes [F32]
  [j, e] <- params [I64, I64]
  r <- call' "__word_encodeDouble" [j, e] F64
  emit $ Unary DemoteFloat64 r
