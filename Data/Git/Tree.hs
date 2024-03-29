{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}

module Data.Git.Tree where

import           Bindings.Libgit2
import           Data.Git.Blob
import           Data.Git.Common
import           Data.Git.Errors
import           Data.Git.Internal
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Filesystem.Path.CurrentOS as F
import qualified Prelude

default (Text)

data TreeEntry = BlobEntry { blobEntry      :: ObjRef Blob
                           , blobEntryIsExe :: Bool }
               | TreeEntry { treeEntry      :: ObjRef Tree }

blobRefWithMode :: Bool -> Blob -> TreeEntry
blobRefWithMode mode b = BlobEntry (ObjRef b) mode

blobRef :: Blob -> TreeEntry
blobRef = blobRefWithMode False

exeBlobRef :: Blob -> TreeEntry
exeBlobRef = blobRefWithMode True

blobIdRef :: Oid -> Bool -> TreeEntry
blobIdRef (Oid coid)      = BlobEntry (IdRef coid)
blobIdRef (PartialOid {}) = throw ObjectRefRequiresFullOid

treeRef :: Tree -> TreeEntry
treeRef t = TreeEntry (ObjRef t)

treeIdRef :: Oid -> TreeEntry
treeIdRef (Oid coid)      = TreeEntry (IdRef coid)
treeIdRef (PartialOid {}) = throw ObjectRefRequiresFullOid

-- instance Eq TreeEntry where
--   (BlobEntry x x2) == (BlobEntry y y2) = x == y && x2 == y2
--   (TreeEntry x) == (TreeEntry y) = x == y
--   _ == _ = False

type TreeMap = M.Map Text TreeEntry

data Tree = Tree { _treeInfo     :: Base Tree
                 , _treeContents :: TreeMap }

makeClassy ''Tree

instance Show Tree where
  show x = case x^.treeInfo.gitId of
    Pending _ -> "Tree"
    Stored y  -> "Tree#" ++ show y

instance Updatable Tree where
  getId x        = x^.treeInfo.gitId
  objectRepo x   = x^.treeInfo.gitRepo
  objectPtr x    = x^.treeInfo.gitObj
  update         = writeTree
  lookupFunction = lookupTree

newTreeBase :: Tree -> Base Tree
newTreeBase t =
  newBase (t^.treeInfo.gitRepo)
          (Pending (doWriteTree >=> return . snd)) Nothing

-- | Create a new, empty tree.
--
--   Since empty trees cannot exist in Git, attempting to write out an empty
--   tree is a no-op.
createTree :: Repository -> Tree
createTree repo =
  Tree { _treeInfo     =
            newBase repo (Pending (doWriteTree >=> return . snd)) Nothing
       , _treeContents = M.empty }

lookupTree :: Oid -> Repository -> IO (Maybe Tree)
lookupTree oid repo =
  lookupObject' oid repo c'git_tree_lookup c'git_tree_lookup_prefix $
    \coid obj _ ->
      return Tree { _treeInfo =
                       newBase repo (Stored coid) (Just obj)
                  , _treeContents = M.empty }

withGitTree :: Updatable b
            => ObjRef Tree -> b -> (Ptr C'git_tree -> IO a) -> IO a
withGitTree tref obj f =
  withForeignPtr (repositoryPtr (objectRepo obj)) $ \repoPtr ->
    case tref of
      IdRef (COid oid) -> withGitTreeOid repoPtr oid

      ObjRef (Tree { _treeInfo = Base { _gitId = Stored (COid oid) } }) ->
        withGitTreeOid repoPtr oid

      ObjRef (Tree { _treeInfo = Base { _gitObj = Just t } }) ->
        withForeignPtr t (f . castPtr)

      ObjRef t -> do t' <- update t
                     withGitTree (ObjRef t') obj f

  where withGitTreeOid repoPtr oid =
          withForeignPtr oid $ \tree_id ->
            alloca $ \ptr -> do
              r <- c'git_tree_lookup ptr repoPtr tree_id
              when (r < 0) $ throwIO TreeLookupFailed
              f =<< peek ptr

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
                 => Ptr C'git_treebuilder -> a -> ObjRef b -> CUInt
                 -> IO (ObjRef b)
    insertObject builder key obj attrs = do
      coid <- case obj of
        IdRef (COid x) -> return x
        ObjRef x -> do
          oid <- objectId x
          case oid of
            Oid (COid y) -> return y
            _ -> error "Unexpected"

      withForeignPtr coid $ \coid' ->
        withCStringable key $ \name -> do
          r2 <- c'git_treebuilder_insert nullPtr builder name coid' attrs
          when (r2 < 0) $ throwIO TreeBuilderInsertFailed

      return (IdRef (COid coid))

doModifyTree
  :: [Text] -> (Maybe TreeEntry -> Either a (Maybe TreeEntry)) -> Bool
  -> Tree -> IO (Either a Tree)
doModifyTree [] _ _ _     = throw TreeLookupFailed
doModifyTree (name:names) f createIfNotExist t = do
  -- Lookup the current name in this tree.  If it doesn't exist, and there are
  -- more names in the path and 'createIfNotExist' is True, create a new Tree
  -- and descend into it.  Otherwise, if it exists we'll have @Just (TreeEntry
  -- {})@, and if not we'll have Nothing.
  y <- case M.lookup name (t^.treeContents) of
    Nothing ->
      return $
        if createIfNotExist && not (null names)
        then Just . TreeEntry . ObjRef . createTree
             $ t^.treeInfo.gitRepo
        else Nothing
    Just j -> case j of
      BlobEntry b mode -> do
        bl <- loadObject b t
        for bl $ \x -> return $ BlobEntry (ObjRef x) mode
      TreeEntry t' -> do
        tr <- loadObject t' t
        for tr $ \x -> return $ TreeEntry (ObjRef x)

  if null names
    then do
      -- If there are no further names in the path, call the transformer
      -- function, f.  It receives a @Maybe TreeEntry@ to indicate if there
      -- was a previous entry at this path.  It should return a 'Left' value
      -- to propagate out a user-defined error, or a @Maybe TreeEntry@ to
      -- indicate whether the entry at this path should be deleted or
      -- replaced with something new.
      --
      -- NOTE: There is no provision for leaving the entry unchanged!  It is
      -- assumed to always be changed, as we have no reliable method of
      -- testing object equality that is not O(n).
    let ze = f y
    case ze of
      Left err -> return $ Left err
      Right z ->
        return $ Right $
          treeInfo     .~ newTreeBase t $
          treeContents .~
            (case z of
               Nothing -> M.delete name (t^.treeContents)
               Just z' -> M.insert name z' (t^.treeContents)) $ t

    else
      -- If there are further names in the path, descend them now.  If
      -- 'createIfNotExist' was False and there is no 'Tree' under the
      -- current name, or if we encountered a 'Blob' when a 'Tree' was
      -- required, throw an exception to avoid colliding with user-defined
      -- 'Left' values.
      case y of
        Just (BlobEntry {}) -> throw TreeCannotTraverseBlob
        Just (TreeEntry (ObjRef t')) -> do
          st <- doModifyTree names f createIfNotExist t'
          case st of
            err@(Left _) -> return err
            Right st' ->
              return $ Right $
                treeInfo     .~ newTreeBase t $
                treeContents .~
                  (if M.null (st'^.treeContents)
                   then M.delete name (t^.treeContents)
                   else M.insert name (TreeEntry (ObjRef st'))
                                 (t^.treeContents)) $ t
        _ -> throw TreeLookupFailed

modifyTree
  :: FilePath -> (Maybe TreeEntry -> Either a (Maybe TreeEntry)) -> Bool
  -> Tree -> IO (Either a Tree)
modifyTree = doModifyTree . splitPath

doUpdateTree :: [Text] -> TreeEntry -> Tree -> IO Tree
doUpdateTree xs item t = do
  t' <- doModifyTree xs (const (Right (Just item))) True t
  case t' of
    Right tr -> return tr
    _ -> undefined

updateTree :: FilePath -> TreeEntry -> Tree -> IO Tree
updateTree = doUpdateTree . splitPath

removeFromTree :: FilePath -> Tree -> IO Tree
removeFromTree p tr = do
  t' <- modifyTree p (const (Right Nothing)) False tr
  case t' of
    Right tr' -> return tr'
    _ -> undefined

splitPath :: FilePath -> [Text]
splitPath path = T.splitOn "/" text
  where text = case F.toText path of
                 Left x  -> error $ "Invalid path: " ++ T.unpack x
                 Right y -> y

-- Tree.hs
