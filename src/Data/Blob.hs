{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- | Semantic-specific functionality for blob handling.
module Data.Blob
( Blobs(..)
, NoLanguageForBlob (..)
, decodeBlobs
, moduleForBlob
, noLanguageForBlob
, BlobPair
, maybeBlobPair
, decodeBlobPairs
, languageForBlobPair
, languageTagForBlobPair
, pathForBlobPair
, pathKeyForBlobPair
, module Analysis.Blob
) where


import           Analysis.Blob
import           Control.Effect.Error
import           Control.Exception
import           Data.Aeson
import           Data.Bifunctor
import qualified Data.ByteString.Lazy as BL
import           Data.Edit
import           Data.JSON.Fields
import           Data.Maybe.Exts
import           Data.Module
import           Data.List  (stripPrefix)
import           GHC.Generics (Generic)
import           Source.Language as Language
import qualified System.Path     as Path


newtype Blobs a = Blobs { blobs :: [a] }
  deriving (Generic, FromJSON)

decodeBlobs :: BL.ByteString -> Either String [Blob]
decodeBlobs = fmap blobs <$> eitherDecode

-- | An exception indicating that we’ve tried to diff or parse a blob of unknown language.
newtype NoLanguageForBlob = NoLanguageForBlob Path.AbsRelFile
  deriving (Eq, Exception, Ord, Show)

noLanguageForBlob :: Has (Error SomeException) sig m => Path.AbsRelFile -> m a
noLanguageForBlob blobPath = throwError (SomeException (NoLanguageForBlob blobPath))

-- | Construct a 'Module' for a 'Blob' and @term@, relative to some root 'FilePath'.
moduleForBlob :: Maybe FilePath -- ^ The root directory relative to which the module will be resolved, if any. TODO: typed paths
              -> Blob             -- ^ The 'Blob' containing the module.
              -> term             -- ^ The @term@ representing the body of the module.
              -> Module term    -- ^ A 'Module' named appropriate for the 'Blob', holding the @term@, and constructed relative to the root 'FilePath', if any.
moduleForBlob rootDir b = Module info
  -- JZ:TODO: Fix to strings before merging
  where root = maybe (Path.takeDirectory $ blobPath b) Path.absRel rootDir
        info = ModuleInfo (dropRelative root (blobPath b)) (languageToText (blobLanguage b)) mempty

dropRelative :: Path.AbsRelDir -> Path.AbsRelFile -> Path.AbsRelFile
dropRelative a' b' = case as `stripPrefix` bs of
     Just rs | ra == rb -> Path.toAbsRel $ (foldl (Path.</>) Path.currentDir rs) Path.</> bf
     _ -> b'
  where (ra, as, _) = Path.splitPath $ Path.normalise a'
        (rb, bs, _) = Path.splitPath $ Path.normalise $ Path.takeDirectory b'
        bf = Path.takeFileName b'

-- | Represents a blobs suitable for diffing which can be either a blob to
-- delete, a blob to insert, or a pair of blobs to diff.
type BlobPair = Edit Blob Blob

instance FromJSON BlobPair where
  parseJSON = withObject "BlobPair" $ \o ->
    fromMaybes <$> (o .:? "before") <*> (o .:? "after")
    >>= maybeM (Prelude.fail "Expected object with 'before' and/or 'after' keys only")

maybeBlobPair :: MonadFail m => Maybe Blob -> Maybe Blob -> m BlobPair
maybeBlobPair a b = maybeM (fail "expected file pair with content on at least one side") (fromMaybes a b)

languageForBlobPair :: BlobPair -> Language
languageForBlobPair = mergeEdit combine . bimap blobLanguage blobLanguage where
  combine a b
    | a == Unknown || b == Unknown = Unknown
    | otherwise                    = b

pathForBlobPair :: BlobPair -> Path.AbsRelFile
pathForBlobPair = blobPath . mergeEdit (const id)

languageTagForBlobPair :: BlobPair -> [(String, String)]
languageTagForBlobPair pair = showLanguage (languageForBlobPair pair)
  where showLanguage = pure . (,) "language" . show

-- JZ:TODO: I need to ask about what does this do.
pathKeyForBlobPair :: BlobPair -> FilePath
pathKeyForBlobPair = mergeEdit combine . bimap blobFpath blobFpath where
   combine before after | before == after = after
                        | otherwise       = before <> " -> " <> after
   blobFpath = Path.toString . blobPath

instance ToJSONFields Blob where
  toJSONFields p = [ "path" .=  blobFilePath p, "language" .= blobLanguage p]

decodeBlobPairs :: BL.ByteString -> Either String [BlobPair]
decodeBlobPairs = fmap blobs <$> eitherDecode
