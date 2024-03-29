{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Data.Git.Tag where

import           Control.Lens
import           Data.Git.Common
import           Data.Git.Internal
import qualified Data.Text as T
import qualified Prelude

default (Text)

data Tag = Tag { _tagInfo :: Base Tag
               , _tagRef  :: Oid }

makeClassy ''Tag

instance Show Tag where
  show x = case x^.tagInfo.gitId of
    Pending _ -> "Tag"
    Stored y  -> "Tag#" ++ show y

-- Tag.hs
