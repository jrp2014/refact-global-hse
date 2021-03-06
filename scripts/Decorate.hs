{-# LANGUAGE FlexibleContexts, TemplateHaskell, TupleSections #-}

module Decorate
    ( Params(..)
    , options
    , go
    ) where

import Control.Exception
import Control.Lens (makeLenses, use, view)
import Control.Monad.State
import Control.Monad.Writer
import Data.Default
import Data.Generics
import Data.Set as Set (insert)
import Debug.Trace
import Language.Haskell.Exts
import Language.Haskell.Exts.SrcLoc
import Options.Applicative
import Refactor (GHCOpts, ghcOptsOptions, withCurrentDirectory, loadModule, ModuleInfo(..), ScanM, scanModule, endLoc, srcLoc, useComments, keep)
import System.Console.GetOpt
import System.Environment (getArgs)
import System.Exit (ExitCode(..), exitWith)
import System.FilePath (dropExtension)
import System.IO (hPutStrLn, stderr)
import Test.HUnit (errors, failures, runTestTT, Test(TestList))

data Params
    = Params { _topDir :: FilePath
             , _paths :: [(Maybe FilePath, FilePath)]
             , _ghcOpts :: GHCOpts
             } deriving Show

$(makeLenses ''Params)

options :: Parser Params
options =
    Params <$> t <*> p <*> g
    where
      t :: Parser FilePath
      t = strOption (value "." <> long "cd" <> metavar "DIR" <> help "Set working directory")
      p :: Parser [(Maybe FilePath, FilePath)]
      p = map (Nothing,) <$> some (argument str (metavar "PATH"))
      g :: Parser GHCOpts
      g = ghcOptsOptions

params0 :: Params
params0 = Params {_topDir = ".", _paths = [], _ghcOpts = def}

go params = do
  ms <- withCurrentDirectory (view topDir params) $ mapM (loadModule (view ghcOpts params)) (view paths params)
  mapM_ (\m -> putStrLn (scanModule (f m) m)) ms
    where
      f :: ModuleInfo SrcSpanInfo -> ScanM ()
      f (ModuleInfo {_module = Module _l mh ps is ds}) = do
         mapM_ (decorate "p" . ann) ps
         maybe (pure ()) (decorate "h" . ann) mh
         mapM_ (decorate "i" . ann) is
         mapM_ (decorate "d" . ann) ds
      decorate s x = do
         cs <- useComments
         mapM_ (\(Comment _ sp _) -> tell "[w|" >> keep (srcLoc sp) >> tell "|]" >>
                                     tell "[c|" >> keep (endLoc sp) >> tell "|]")
               (takeWhile (\(Comment _ sp _) -> srcLoc sp < srcLoc x) cs)
         tell "[w|" >> keep (srcLoc x) >> tell "|]"
         tell ("[" ++ s ++ "|")
         cs <- useComments
         mapM_ (\(Comment _ sp _) -> keep (srcLoc sp) >>
                                     tell "[c|" >> keep (endLoc sp) >> tell "|]")
               (takeWhile (\(Comment _ sp _) -> srcLoc sp < endLoc x) cs)
         -- mapM_ (keep . srcLoc) (srcInfoPoints $ ann x)
         keep (endLoc x)
         tell "|]"
