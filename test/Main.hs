{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
{-# OPTIONS_GHC -fno-warn-wrong-do-bind #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}

module Main where

import           Control.Applicative
import           Control.Lens
import           Control.Monad
import           Data.Git
import           Data.Maybe
import           Data.Text as T hiding (map)
import qualified Data.Text.Encoding as E
import           Data.Time.Clock.POSIX
import           Data.Traversable
import           Filesystem (removeTree, isDirectory)
import           Filesystem.Path.CurrentOS
import qualified Prelude
import           Prelude hiding (FilePath, putStr, putStrLn)
import           System.Exit
import           Test.HUnit

default (Text)

main :: IO ()
main = do
  counts' <- runTestTT tests
  case counts' of
    Counts _ _ errors' failures' ->
      if errors' > 0 || failures' > 0
      then exitFailure
      else exitSuccess

catBlob :: Repository -> Text -> IO (Maybe Text)
catBlob repo sha = do
  hash <- stringToOid sha
  for hash $ \hash' -> do
    obj <- lookupObject hash' repo
    case obj of
      Just (BlobObj b) -> do
        (_, contents) <- getBlobContents b
        return (E.decodeUtf8 contents)

      Just _  -> error "Found something else..."
      Nothing -> error "Didn't find anything :("

withRepository :: Text -> (Repository -> Assertion) -> Assertion
withRepository n f = do
  let p = fromText n
  exists <- isDirectory p
  when exists $ removeTree p

  -- we want exceptions to leave the repo behind
  f =<< createRepository p True

  removeTree p

oid :: Updatable a => a -> IO Text
oid = objectId >=> return . oidToText

oidToText :: Oid -> Text
oidToText = T.pack . show

tests :: Test
tests = test [

  "singleBlob" ~:

  withRepository "singleBlob.git" $ \repo -> do
    update_ $ createBlob (E.encodeUtf8 "Hello, world!\n") repo

    x <- catBlob repo "af5626b4a114abcb82d63db7c8082c3c4756e51b"
    (@?=) x (Just "Hello, world!\n")

    x <- catBlob repo "af5626b"
    (@?=) x (Just "Hello, world!\n")

    return ()

  , "singleTree" ~:

  withRepository "singleTree.git" $ \repo -> do
    let hello = createBlob (E.encodeUtf8 "Hello, world!\n") repo
    tr <- updateTree "hello/world.txt" (blobRef hello) (createTree repo)
    x  <- oid tr
    (@?=) x "c0c848a2737a6a8533a18e6bd4d04266225e0271"

    return()

  , "twoTrees" ~:

  withRepository "twoTrees.git" $ \repo -> do
    let hello = createBlob (E.encodeUtf8 "Hello, world!\n") repo
    tr <- updateTree "hello/world.txt" (blobRef hello) (createTree repo)
    x  <- oid tr
    (@?=) x "c0c848a2737a6a8533a18e6bd4d04266225e0271"

    let goodbye = createBlob (E.encodeUtf8 "Goodbye, world!\n") repo
    tr <- updateTree "goodbye/files/world.txt" (blobRef goodbye) tr
    x  <- oid tr
    (@?=) x "98c3f387f63c08e1ea1019121d623366ff04de7a"

    return()

  , "deleteTree" ~:

  withRepository "deleteTree.git" $ \repo -> do
    let hello = createBlob (E.encodeUtf8 "Hello, world!\n") repo
    tr <- updateTree "hello/world.txt" (blobRef hello) (createTree repo)
    x  <- oid tr
    (@?=) x "c0c848a2737a6a8533a18e6bd4d04266225e0271"

    let goodbye = createBlob (E.encodeUtf8 "Goodbye, world!\n") repo
    tr <- updateTree "goodbye/files/world.txt" (blobRef goodbye) tr
    x  <- oid tr
    (@?=) x "98c3f387f63c08e1ea1019121d623366ff04de7a"

    -- Confirm that deleting world.txt also deletes the now-empty subtree
    -- goodbye/files, which also deletes the then-empty subtree goodbye,
    -- returning us back the original tree.
    tr <- removeFromTree "goodbye/files/world.txt" tr
    x  <- oid tr
    (@?=) x "c0c848a2737a6a8533a18e6bd4d04266225e0271"

    return()

  , "createCommit" ~:

  withRepository "createCommit.git" $ \repo -> do
    let hello = createBlob (E.encodeUtf8 "Hello, world!\n") repo
    tr <- updateTree "hello/world.txt" (blobRef hello) (createTree repo)

    let goodbye = createBlob (E.encodeUtf8 "Goodbye, world!\n") repo
    tr <- updateTree "goodbye/files/world.txt" (blobRef goodbye) tr
    x  <- oid tr
    (@?=) x "98c3f387f63c08e1ea1019121d623366ff04de7a"

    -- The Oid has been cleared in tr, so this tests that it gets written as
    -- needed.
    let sig  = Signature {
            _signatureName  = "John Wiegley"
          , _signatureEmail = "johnw@newartisans.com"
          , _signatureWhen  = posixSecondsToUTCTime 1348980883 }

    x <- oid $ commitTree      .~ ObjRef tr
            $ commitAuthor    .~ sig
            $ commitCommitter .~ sig
            $ commitLog       .~ "Sample log message."
            $ createCommit repo
    (@?=) x "44381a5e564d19893d783a5d5c59f9c745155b56"

    return()

  , "createTwoCommits" ~:

  withRepository "createTwoCommits.git" $ \repo -> do
    let hello = createBlob (E.encodeUtf8 "Hello, world!\n") repo
    tr <- updateTree "hello/world.txt" (blobRef hello) (createTree repo)

    let goodbye = createBlob (E.encodeUtf8 "Goodbye, world!\n") repo
    tr <- updateTree "goodbye/files/world.txt" (blobRef goodbye) tr
    x  <- oid tr
    (@?=) x "98c3f387f63c08e1ea1019121d623366ff04de7a"

    -- The Oid has been cleared in tr, so this tests that it gets written as
    -- needed.
    let sig = Signature {
            _signatureName  = "John Wiegley"
          , _signatureEmail = "johnw@newartisans.com"
          , _signatureWhen  = posixSecondsToUTCTime 1348980883 }
        c   = commitTree      .~ ObjRef tr
            $ commitAuthor    .~ sig
            $ commitCommitter .~ sig
            $ commitLog       .~ "Sample log message."
            $ createCommit repo
    x <- oid c
    (@?=) x "44381a5e564d19893d783a5d5c59f9c745155b56"

    let goodbye2 = createBlob (E.encodeUtf8 "Goodbye, world again!\n") repo
    tr <- updateTree "goodbye/files/world.txt" (blobRef goodbye2) tr
    x  <- oid tr
    (@?=) x "f2b42168651a45a4b7ce98464f09c7ec7c06d706"

    let sig = Signature {
            _signatureName  = "John Wiegley"
          , _signatureEmail = "johnw@newartisans.com"
          , _signatureWhen  = posixSecondsToUTCTime 1348981883 }
        c2  = commitTree      .~ ObjRef tr
            $ commitAuthor    .~ sig
            $ commitCommitter .~ sig
            $ commitLog       .~ "Second sample log message."
            $ commitParents   .~ [ObjRef c]
            $ createCommit repo
    x <- oid c2
    (@?=) x "2506e7fcc2dbfe4c083e2bd741871e2e14126603"

    cid <- objectId c2
    writeRef $ createRef "refs/heads/master" (RefTargetId cid) repo
    writeRef $ createRef "HEAD" (RefTargetSymbolic "refs/heads/master") repo

    x <- oidToText <$> lookupId "refs/heads/master" repo
    (@?=) x "2506e7fcc2dbfe4c083e2bd741871e2e14126603"

    return()

  ]

-- Main.hs ends here
