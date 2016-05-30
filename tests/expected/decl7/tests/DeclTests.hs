-- | Test the following cases for import moving
-- (1) Import of a symbol moves out of a module
-- (2) Import of a symbol that moves between two other modules
-- (3a) Import of a symbol that moves into a module, but is
--      still used by its old module
-- (3b) Import of a symbol that moves into a module, but is
--      no longer used by its old module

module DeclTests where

import Control.Monad (when)
import Data.List hiding (find)
import Data.Monoid ((<>))
import Decls (applyMoveSpec, moveDeclsByName, moveInstDecls, MoveSpec(MoveSpec), runSimpleMoveUnsafe)
import qualified Language.Haskell.Exts.Annotated.Syntax as A
import Language.Haskell.Exts.Annotated.Simplify (sName, sQName)
import qualified Language.Haskell.Exts.Syntax as S
import ModuleKey (ModuleKey(_moduleName), moduleName)
import System.Exit (ExitCode(ExitSuccess))
import System.Process (readProcessWithExitCode)
import Symbols (foldDeclared)
import Test.HUnit
import Types
import Utils (gFind, gitResetSubdir)

declTests :: Test
declTests = TestList [decl1, decl2, decl3, decl4, decl5, decl6, simple1]

-- Test moving a declaration to a module that currently imports it
decl1 :: Test
decl1 = TestCase $ testMoveSpec "tests/expected/decl1" "tests/input/atp-haskell" moveSpec1

-- Move tryfindM from Lib to Tableaux.  Tableaux already imports
-- tryfindM, so that import should be removed.  The question is, now
-- that tryfindM has moved out of Lib, can we or must we import
-- tryfindM it from Tableaux?  The answer is no, because of this loop:
--
--     Tableaux -> Quantified -> Prop -> Lib -> Tableaux.
--
-- The fact that Tableaux already imports Lib forces us to omit any
-- import of Tableaux from Lib.

moveSpec1 :: MoveSpec
moveSpec1 = MoveSpec f
    where
      f key (A.TypeSig _ [A.Ident _ s] _)
          | s == "tryfindM" {-|| s == "failing"-} =
              key {_moduleName = S.ModuleName "Data.Logic.ATP.Tableaux"}
      f key (A.FunBind _ ms)
          | any (`elem` [S.Ident "tryfindM" {-, S.Ident "failing"-}])
                (map (\match -> case match of
                                  A.Match _ name _ _ _ -> sName name
                                  A.InfixMatch _ _ name _ _ _ -> sName name) ms) =
              key {_moduleName = S.ModuleName "Data.Logic.ATP.Tableaux"}
      f key __ = key
{-
moveSpec1 k d | Set.member (S.Ident "tryfindM") (foldDeclared Set.insert mempty d) =
                  trace ("Expected TypeSig or FunBind: " ++ show d)
                        (k {_modulePath = "Data/Logic/ATP/Tableaux.hs",
                            _moduleName = S.ModuleName "Data.Logic.ATP.Tableaux"})
moveSpec1 k d@(A.FunBind _ _) = {-trace ("FunBind: " ++ show (foldDeclared (:) mempty d))-} k
moveSpec1 k (A.ClassDecl _ _mcxt _dh _fd _mcds) = k
moveSpec1 k (A.DataDecl _ _dn _mcxt _dh _qcs _md) = k
moveSpec1 k (A.PatBind _ _p _rhs _mbs) = k
moveSpec1 k (A.TypeDecl _ _dh _typ) = k
moveSpec1 k (A.TypeSig _ _name _typ) = k
moveSpec1 k (A.InstDecl _ _mo _ir _mids) = k
moveSpec1 k (A.InfixDecl _ _assoc _mi _ops) = k
moveSpec1 k (A.DerivDecl {}) = k
moveSpec1 k d = error $ "Unexpected decl: " ++ take 120 (show d) ++ ".."
-}

-- Test moving a declaration to a non-existant module
-- Test updating import of decl that moved from A to B in module C
decl2 :: Test
decl2 = TestCase $ do
          let input = "tests/input/decl-mover"
          testMoveSpec' "tests/expected/decl2" input
            (runSimpleMoveUnsafe input (moveDeclsByName "withCurrentDirectory" "IO" "Tmp"))

-- Test moving a declaration to a module that does *not* currently
-- import it.  Now we don't know whether it leaves behind uses for
-- which we need to import it (which might be called "moving down") or
-- if we are moving it to the place where it is used (which could be
-- called "moving up".)
decl3 :: Test
decl3 = TestCase $ do
          let input = "tests/input/decl-mover"
          testMoveSpec' "tests/expected/decl3" input
            (runSimpleMoveUnsafe input (moveDeclsByName "lines'" "SrcLoc" "Tmp") >>
             runSimpleMoveUnsafe input (moveDeclsByName "lines'" "Tmp" "Utils"))

decl4 :: Test
decl4 = TestCase $ do
          let input = "tests/input/decl-mover"
          testMoveSpec' "tests/expected/decl4" input (runSimpleMoveUnsafe input spec)
    where
      spec = foldl1' (<>) [moveDeclsByName "withTempDirectory" "IO" "Utils",
                           moveDeclsByName "ignoringIOErrors" "IO" "Utils",
                           moveDeclsByName "FoldDeclared" "Symbols" "Tmp",
                           moveInstDecls instpred]
      instpred key name _types
          | (gFind (sQName name) :: [S.Name]) == [S.Ident "FoldDeclared"] =
              key {_moduleName = S.ModuleName "Tmp"}
      instpred key _ _ = key

decl5 :: Test
decl5 = TestCase $ testMoveSpec "tests/expected/decl5" "tests/input/decl-mover" spec
    where
      spec = foldl1' (<>) [moveDeclsByName "ModuleKey" "Types" "ModuleKey",
                           moveDeclsByName "fullPathOfModuleKey" "Types" "ModuleKey",
                           moveDeclsByName "moduleKey" "Types" "ModuleKey"]

decl6 :: Test
decl6 = TestCase $ testMoveSpec "tests/expected/decl6" "tests/input/decl-mover" spec
    where
      spec = foldl1' (<>) [moveDeclsByName "MoveSpec" "Decls" "MoveSpec",
                           moveDeclsByName "moveDeclsByName" "Decls" "MoveSpec",
                           moveDeclsByName "appendMoveSpecs" "Decls" "MoveSpec",
                           moveDeclsByName "identityMoveSpec" "Decls" "MoveSpec"]

simple1 :: Test
simple1 =
    TestCase $
      testMoveSpec' "tests/expected/simple1" "tests/input/simple" $
        runSimpleMoveUnsafe "tests/input/simple" (moveDeclsByName "listPairs" "A" "B")

testMoveSpec :: FilePath -> FilePath -> MoveSpec -> IO ()
testMoveSpec expected actual moveSpec =
    testMoveSpec' expected actual $ runSimpleMoveUnsafe actual moveSpec

testMoveSpec' :: FilePath -> FilePath -> IO () -> IO ()
testMoveSpec' expected actual action = do
  gitResetSubdir actual
  action
  (code, diff, _) <- readProcessWithExitCode "diff" ["-ruN", expected, actual] ""
  when (code == ExitSuccess) (gitResetSubdir actual)
  assertString diff

testSpec :: MoveSpec -> ModuleInfo -> IO ModuleInfo
testSpec moveSpec m@(ModuleInfo {_moduleKey = k, _module = A.Module _ _ _ _ ds}) = do
  putStrLn ("---- module " ++ show (moduleName k) ++ " ----")
  mapM_ (\d -> let k' = applyMoveSpec moveSpec k d in
               putStrLn (show (foldDeclared (:) [] d) ++ ": " ++ if k /= k' then show k ++ " " ++  " -> " ++ show k' else "unchanged")) ds
  return m
testSpec _ _ = error "Unexpected module"