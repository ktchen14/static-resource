-- Copyright (c) 2020 VMware, Inc.
-- SPDX-License-Identifier: MIT

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ViewPatterns #-}

import Prelude hiding (writeFile)

import qualified Data.ByteString.Char8 as SB
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Text (Text, pack, unpack)
import Data.Text.Encoding (decodeUtf8)
import Data.Text.IO (writeFile)

import Data.List (intercalate, sortOn)
import Data.Maybe (fromMaybe)

import qualified Data.Vector as V
import Data.Hashable (Hashable)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.HashSet (HashSet)
import qualified Data.HashSet as HS

import Control.Monad (join, liftM2, void)

import System.Directory (createDirectoryIfMissing, withCurrentDirectory)
import System.Environment (getArgs, getProgName)
import System.Exit (die)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (hPutStrLn, stderr)

import Data.Aeson (FromJSON, ToJSON, (.:), (.:?), (.=))
import qualified Data.Aeson as J
import Data.Aeson.Types (Parser, typeMismatch)
import qualified Data.Aeson.Encode.Pretty as P

import qualified Data.ByteString.Base16 as Base16
import qualified Crypto.Hash.SHA1 as SHA1

-- Return a parser failure if the JSON object has keys that don't appear in ks
failOnErroneousKeys :: (Eq a, Hashable a, Show a)
                    => [a] -> HashMap a b -> Parser (HashMap a b)
failOnErroneousKeys ks object
  | null erroneous = return object
  | otherwise = fail $ "Unrecognized " ++ keysWord ++ ": " ++ hint
  where
    keysWord = "key" ++ if length erroneous == 1 then "" else "s"
    hint = intercalate ", " $ map show $ erroneous
    erroneous = HS.toList $ keySet `HS.difference` HS.fromList ks
    keySet = HS.fromMap $ fmap (\_ -> ()) object

-- A StaticItem is an item in the source section of the resource configuration
data StaticItem = PublicItem Text
                | SecretItem { secret :: Text, public :: Maybe Text }
                  deriving (Eq, Show)

instance FromJSON StaticItem where
  parseJSON (J.String s) = pure $ PublicItem s
  parseJSON (J.Object o) = do
    failOnErroneousKeys ["secret", "public"] o
    secret <- o .: "secret"
    public <- o .:? "public"
    return SecretItem { .. }
  parseJSON x = typeMismatch "a String or Object" x

instance ToJSON StaticItem where
  toJSON (SecretItem { secret = _, public = Nothing }) =
    J.object ["secret" .= ("[redacted]" :: Text)]
  toJSON (SecretItem { secret = _, public = Just p }) =
    J.object ["secret" .= ("[redacted]" :: Text), "public" .= p]
  toJSON (PublicItem x) = J.toJSON x

-- The actual text for the StaticItem
secretText :: StaticItem -> Text
secretText (PublicItem x) = x
secretText (SecretItem { secret = x }) = x

-- The text that should appear in the metadata output (default: "[redacted]")
publicText :: StaticItem -> Text
publicText (PublicItem x) = x
publicText (SecretItem { public = x }) = fromMaybe "[redacted]" x

-- A version reference corresponding to a { "ref": ... } JSON object and
-- implemented as a SHA1 hash rendered as base16 text
newtype Version = Version Text deriving (Eq, Show)

class ToVersion a where
  toVersion :: a -> Version

instance ToVersion ByteString where
  toVersion = Version . decodeUtf8 . Base16.encode . SHA1.hash

instance ToVersion String where
  toVersion = toVersion . SB.pack

instance FromJSON Version where
  parseJSON (J.Object o) = o .: "ref" >>= return . Version
  parseJSON x = typeMismatch "Version" x

instance ToJSON Version where
  toJSON (Version x) = J.object ["ref" .= x]

-- The source section of the resource configuration
type Source = HashMap Text StaticItem

instance (Show k, Ord k, Show v) => ToVersion (HashMap k v) where
  toVersion = toVersion . show . stable

-- A stable representation of a Source produced by transforming a Source from a
-- HashMap with an undefined key order to a list of pairs sorted by key. If both
-- a and b are HashMaps and a == b then:
--   all $ zipWith (==) (stable a) (stable b) == True
stable :: Ord a => HashMap a b -> [(a, b)]
stable = sortOn fst . HM.toList

-- Map both the keys and values of a HashMap
mapH :: (Eq b, Hashable b) => (a -> b) -> (c -> d) -> HashMap a c -> HashMap b d
mapH k v = HM.fromList . map (\(a, b) -> (k a, v b)) . HM.toList

data Root = Root { source :: Source, version :: Maybe Version }

instance ToVersion Root where
  toVersion = toVersion . source

instance FromJSON Root where
  parseJSON (J.Object o) = do
    source <- o .: "source"
    version <- o .:? "version"
    return Root { .. }
  parseJSON x = typeMismatch "root object" x

-- Return a list of metadata objects intended to be emitted in the output stream
-- of the resource
toMetadata :: Root -> [HashMap Text Text]
toMetadata = map each . stable . source
  where each (k, v) = HM.fromList [("name", k), ("value", publicText v)]

-- Validate that a version generated from the Root's source is identical to the
-- Root's version
validateVersionInRoot :: Root -> Either String Root
validateVersionInRoot root@(Root { source = s, version = (Just t) })
  | toVersion s == t = Right root
  | otherwise = Left $ show t ++ " is inaccessible from " ++ hint
  where hint = "source definition:\n" ++ (LB.unpack $ P.encodePretty s)
validateVersionInRoot x = Right x

checkScript root _ = return [toVersion root]

inScript root [] = die "No destination directory given in argument list"
inScript root (head -> target) = do
  either (hPutStrLn stderr) (void . return) $ validateVersionInRoot root
  createDirectoryIfMissing True target
  withCurrentDirectory target $ HM.traverseWithKey handleItem sourceData
  return $ J.object ["version" .= toVersion root, metadataOutput]
  where
    sourceData = HM.fromList $ map usefulItem $ HM.toList $ source root
    usefulItem (k, v) = (unpack k, secretText v)
    handleItem k v = do
      createDirectoryIfMissing True $ takeDirectory k
      writeFile k v
    metadataOutput = "metadata" .= toMetadata root

outScript root _ = return $ J.object ["version" .= toVersion root]

main = getProgName >>= script where
  root = either die return =<< fmap J.eitherDecode LB.getContents
  args = getArgs

  invoke :: ToJSON a => (Root -> [String] -> IO a) -> IO ()
  invoke x = LB.putStrLn =<< fmap J.encode (join $ liftM2 x root args)

  script "check" = invoke checkScript
  script "in" = invoke inScript
  script "out" = invoke outScript
  script n = die $ "Erroneous invocation with program name: " ++ n
