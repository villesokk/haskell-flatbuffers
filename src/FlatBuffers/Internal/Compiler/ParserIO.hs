{-# LANGUAGE FlexibleContexts #-}

module FlatBuffers.Internal.Compiler.ParserIO where

import           Control.Applicative                      ( (<|>) )
import           Control.Monad                            ( when )
import           Control.Monad.Except                     ( MonadError, MonadIO, liftIO, throwError )
import           Control.Monad.State                      ( MonadState, execStateT, get, put )

import           Data.Coerce                              ( coerce )
import           Data.Foldable                            ( traverse_ )
import           Data.Map.Strict                          ( Map )
import qualified Data.Map.Strict                          as Map
import qualified Data.Text                                as T

import           FlatBuffers.Internal.Compiler.Parser     ( schema )
import           FlatBuffers.Internal.Compiler.SyntaxTree ( FileTree(..), Include(..), Schema, StringLiteral(..), includes )

import qualified System.Directory                         as Dir
import qualified System.FilePath                          as FP
import           System.FilePath                          ( (</>) )

import           Text.Megaparsec                          ( errorBundlePretty, parse )

newtype ParseOptions = ParseOptions
  { -- | Directories to search for @include@s.
    includeDirectories :: [FilePath]
  }

defaultParseOptions :: ParseOptions
defaultParseOptions = ParseOptions []

parseSchemas ::
     MonadIO m
  => MonadError String m
  => FilePath -- ^ Filepath of the root schema. It must be a path relative to the project root or an absolute path.
  -> ParseOptions
  -> m (FileTree Schema)
parseSchemas rootFilePath parseOpts = do
  fileContent <- liftIO $ readFile rootFilePath
  case parse schema rootFilePath fileContent of
    Left err -> throwError (errorBundlePretty err)
    Right rootSchema -> do
      rootFilePathCanon <- liftIO $ Dir.canonicalizePath rootFilePath
      let includeDirs = includeDirectories parseOpts
      let importedFilePaths = T.unpack . coerce <$> includes rootSchema

      importedSchemas <- flip execStateT Map.empty $
                            traverse_
                              (parseImportedSchema includeDirs rootFilePathCanon)
                              importedFilePaths
      pure FileTree
            { fileTreeFilePath = rootFilePathCanon
            , fileTreeRoot     = rootSchema
            , fileTreeForest   = importedSchemas
            }

parseImportedSchema ::
     MonadState (Map FilePath Schema) m
  => MonadIO m
  => MonadError String m
  => [FilePath]
  -> FilePath
  -> FilePath
  -> m ()
parseImportedSchema includeDirs rootFilePathCanon filePath =
  go (FP.takeDirectory rootFilePathCanon) filePath
  where
    go parentSchemaDir filePath = do
      let dirCandidates = parentSchemaDir : includeDirs

      actualFilePathCanonMaybe <- liftIO $ Dir.findFile dirCandidates filePath >>= traverse Dir.canonicalizePath

      case actualFilePathCanonMaybe of
        Nothing -> throwError $ "File '" <> filePath <> "' not found. Searched in these directories: " <> show dirCandidates
        Just actualFilePathCanon -> do
          importedSchemas <- get
          when (actualFilePathCanon /= rootFilePathCanon && actualFilePathCanon `Map.notMember` importedSchemas) $ do
            fileContent <- liftIO $ readFile actualFilePathCanon
            case parse schema actualFilePathCanon fileContent of
              Left err -> throwError (errorBundlePretty err)
              Right importedSchema -> do
                put (Map.insert actualFilePathCanon importedSchema importedSchemas)
                let importedSchemaDir = FP.takeDirectory actualFilePathCanon
                traverse_ (go importedSchemaDir . T.unpack . coerce) (includes importedSchema)
