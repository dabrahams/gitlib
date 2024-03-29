{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Data.Git.Blob
       ( Blob(..), HasBlob(..)
       , newBlobBase
       , createBlob
       , getBlobContents
       , writeBlob )
       where

import           Data.ByteString as B hiding (map)
import           Data.ByteString.Unsafe
import           Data.Git.Common
import           Data.Git.Errors
import           Data.Git.Internal
import qualified Prelude

default (Text)

data Blob = Blob { _blobInfo     :: Base Blob
                 , _blobContents :: B.ByteString }

makeClassy ''Blob

instance Show Blob where
  show x = case x^.blobInfo.gitId of
    Pending _ -> "Blob"
    Stored y  -> "Blob#" ++ show y

instance Updatable Blob where
  getId x        = x^.blobInfo.gitId
  objectRepo x   = x^.blobInfo.gitRepo
  objectPtr x    = x^.blobInfo.gitObj
  update         = writeBlob
  lookupFunction = lookupBlob

newBlobBase :: Blob -> Base Blob
newBlobBase b =
  newBase (b^.blobInfo.gitRepo) (Pending doWriteBlob) Nothing

-- | Create a new blob in the 'Repository', with 'ByteString' as its contents.
--
--   Note that since empty blobs cannot exist in Git, no means is provided for
--   creating one; if the give string is 'empty', it is an error.
createBlob :: B.ByteString -> Repository -> Blob
createBlob text repo
  | text == B.empty = error "Cannot create an empty blob"
  | otherwise =
    Blob { _blobInfo     = newBase repo (Pending doWriteBlob) Nothing
         , _blobContents = text }

lookupBlob :: Oid -> Repository -> IO (Maybe Blob)
lookupBlob oid repo =
  lookupObject' oid repo c'git_blob_lookup c'git_blob_lookup_prefix $
    \coid obj _ ->
      return Blob { _blobInfo     = newBase repo (Stored coid) (Just obj)
                  , _blobContents = B.empty }

getBlobContents :: Blob -> IO (Blob, B.ByteString)
getBlobContents b =
  case b^.blobInfo.gitId of
    Pending _   -> return $ (b, contents)
    Stored hash ->
      if contents /= B.empty
        then return (b, contents)
        else
        case b^.blobInfo.gitObj of
          Just blobPtr ->
            withForeignPtr blobPtr $ \ptr -> do
              size <- c'git_blob_rawsize (castPtr ptr)
              buf  <- c'git_blob_rawcontent (castPtr ptr)
              bstr <- curry unsafePackCStringLen (castPtr buf)
                            (fromIntegral size)
              return (blobContents .~ bstr $ b, bstr)

          Nothing -> do
            b' <- lookupBlob (Oid hash) repo
            case b' of
              Just blobPtr' -> getBlobContents blobPtr'
              Nothing       -> return (b, B.empty)

  where repo     = b^.blobInfo.gitRepo
        contents = b^.blobContents

-- | Write out a blob to its repository.  If it has already been written,
--   nothing will happen.
writeBlob :: Blob -> IO Blob
writeBlob b@(Blob { _blobInfo = Base { _gitId = Stored _ } }) = return b
writeBlob b = do hash <- doWriteBlob b
                 return $ blobInfo.gitId .~ Stored hash $
                          blobContents   .~ B.empty    $ b

doWriteBlob :: Blob -> IO COid
doWriteBlob b = do
  ptr <- mallocForeignPtr
  r   <- withForeignPtr repo (createFromBuffer ptr)
  when (r < 0) $ throwIO BlobCreateFailed
  return (COid ptr)

  where
    repo = fromMaybe (error "Repository invalid")
                     (b^.blobInfo.gitRepo.repoObj)

    createFromBuffer ptr repoPtr =
      unsafeUseAsCStringLen (b^.blobContents) $
        uncurry (\cstr len ->
                  withForeignPtr ptr $ \ptr' ->
                    c'git_blob_create_frombuffer
                      ptr' repoPtr (castPtr cstr) (fromIntegral len))

-- Blob.hs
