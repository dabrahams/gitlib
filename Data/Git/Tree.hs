{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}

module Data.Git.Tree where

import           Bindings.Libgit2
import           Control.Lens
import           Data.Git.Blob
import           Data.Git.Common
import           Data.Git.Errors
import           Data.Git.Internal hiding ((<.>))
import qualified Data.Map as M hiding (map)
import           Data.Text as T hiding (map)
import           Filesystem.Path.CurrentOS as F hiding ((<.>))
import           Prelude hiding (FilePath, sequence)

default (Text)

data TreeEntry = BlobEntry { blobEntry :: Blob
                           , blobEntryIsExe :: Bool }
               | TreeEntry { treeEntry :: Tree }

instance Eq TreeEntry where
  (BlobEntry x x2) == (BlobEntry y y2) = x == y && x2 == y2
  (TreeEntry x) == (TreeEntry y) = x == y
  _ == _ = False

type TreeMap = M.Map Text TreeEntry

data Tree = Tree { _treeInfo     :: Base Tree
                 , _treeContents :: TreeMap }

makeClassy ''Tree

instance Eq Tree where
  x == y = case (x^.treeInfo.gitId, y^.treeInfo.gitId) of
             (Stored x2, Stored y2) -> x2 == y2
             _ -> undefined

instance Show Tree where
  show x = case x^.treeInfo.gitId of
    Pending _ -> "Tree"
    Stored y  -> "Tree#" ++ show y

instance Updatable Tree where
  update     = writeTree
  objectId t = case t^.treeInfo.gitId of
    Pending f -> Oid <$> (f t)
    Stored x  -> return $ Oid x

newTreeBase :: Tree -> Base Tree
newTreeBase t =
  newBase (t^.treeInfo.gitRepo)
          (Pending (doWriteTree >=> return . snd)) Nothing

-- | Create a new tree, starting it with the contents at the given path.
--
--   Note that since empty trees cannot exist in Git, no means is provided for
--   creating one.
createTree :: Repository -> FilePath -> TreeEntry -> Tree
createTree repo path item = updateTree path item (emptyTree repo)

lookupTree :: Repository -> Oid -> IO (Maybe Tree)
lookupTree repo oid =
  lookupObject' repo oid c'git_tree_lookup c'git_tree_lookup_prefix
    (\coid obj _ ->
      return Tree { _treeInfo =
                       newBase repo (Stored coid) (Just obj)
                  , _treeContents = M.empty })

-- | Write out a tree to its repository.  If it has already been written,
--   nothing will happen.
writeTree :: Tree -> IO Tree
writeTree t@(Tree { _treeInfo = Base { _gitId = Stored _ } }) = return t
writeTree t = fst <$> doWriteTree t

doWriteTree :: Tree -> IO (Tree, COid)
doWriteTree t = alloca $ \ptr ->
  withForeignPtr repo $ \repoPtr -> do
    r <- c'git_treebuilder_create ptr nullPtr
    when (r < 0) $ throwIO TreeBuilderCreateFailed
    builder <- peek ptr

    newList <-
      for (M.toList (t^.treeContents)) $ \(k, v) -> do
        newObj <-
          case v of
            BlobEntry bl exe ->
              flip BlobEntry exe <$>
                insertObject builder k bl (if exe
                                           then 0o100755
                                           else 0o100644)
            TreeEntry tr ->
              TreeEntry <$> insertObject builder k tr 0o040000
        return (k, newObj)

    coid <- mallocForeignPtr
    withForeignPtr coid $ \coid' -> do
      r3 <- c'git_treebuilder_write coid' repoPtr builder
      when (r3 < 0) $ throwIO TreeBuilderWriteFailed

    return (treeInfo.gitId .~ Stored (COid coid) $
            treeContents   .~ M.fromList newList $ t, COid coid)

  where
    repo = fromMaybe (error "Repository invalid") $
                     t^.treeInfo.gitRepo.repoObj

    insertObject :: (CStringable a, Updatable b)
                 => Ptr C'git_treebuilder -> a -> b -> CUInt -> IO b
    insertObject builder key obj attrs = do
      obj'            <- update obj
      Oid (COid coid) <- objectId obj'

      withForeignPtr coid $ \coid' ->
        withCStringable key $ \name -> do
          r2 <- c'git_treebuilder_insert nullPtr builder name coid' attrs
          when (r2 < 0) $ throwIO TreeBuilderInsertFailed

      return obj'

emptyTree :: Repository -> Tree
emptyTree repo =
  Tree { _treeInfo     =
            newBase repo (Pending (doWriteTree >=> return . snd)) Nothing
       , _treeContents = M.empty }

doModifyPathInTree :: [Text] -> (TreeEntry -> Maybe TreeEntry) -> Bool -> Tree
                 -> Maybe TreeEntry
doModifyPathInTree [] _ _ _     = Nothing
doModifyPathInTree (x:xs) f createIfNotExist t = do
  y <- case M.lookup x (t^.treeContents) of
         Nothing ->
           if createIfNotExist && not (Prelude.null xs)
           then Just $ TreeEntry (emptyTree (t^.treeInfo.gitRepo))
           else Nothing
         j -> j

  if Prelude.null xs
    then do
      z <- f y
      if z == y
        then return z
        else
          case z of
            BlobEntry bl isExe ->
              return $ BlobEntry (blobInfo .~ newBlobBase bl $ bl) isExe
            TreeEntry tr ->
              return $ TreeEntry (treeInfo .~ newTreeBase tr $ tr)

    else
      case y of
        BlobEntry _ _ -> Nothing
        TreeEntry t'  -> do
          z <- doModifyPathInTree xs f createIfNotExist t'
          if z == y
            then return z
            else
              case z of
                BlobEntry _ _ -> Nothing
                TreeEntry tr  ->
                  return $ TreeEntry (treeInfo     .~ newTreeBase tr $
                                      treeContents .~ M.insert x z (tr^.treeContents) $ tr)

modifyPathInTree :: FilePath -> (TreeEntry -> Maybe TreeEntry) -> Bool -> Tree
                 -> Maybe TreeEntry
modifyPathInTree = doModifyPathInTree . splitPath

doUpdateTree :: [Text] -> TreeEntry -> Tree -> Tree
doUpdateTree xs item t =
  case doModifyPathInTree xs (const (Just item)) True t of
    Just (TreeEntry tr) -> tr
    _ -> undefined

updateTree :: FilePath -> TreeEntry -> Tree -> Tree
updateTree = doUpdateTree . splitPath

splitPath :: FilePath -> [Text]
splitPath path = splitOn "/" text
  where text = case F.toText path of
                 Left x  -> error $ "Invalid path: " ++ T.unpack x
                 Right y -> y

-- Tree.hs