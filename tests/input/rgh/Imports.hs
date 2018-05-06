{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS -Wall #-}

module Imports (cleanImports) where

import Control.Exception (SomeException)
import Control.Monad (void)
import Control.Monad.RWS (MonadWriter(tell))
import Control.Monad.Trans (liftIO, MonadIO)
import Data.Char (toLower)
import Data.Function (on)
import Data.Generics (everywhere, mkT)
import Data.List (find, groupBy, intercalate, nub, sortBy)
import Data.Maybe (catMaybes)
import Data.Monoid ((<>))
import Data.Set as Set (empty, member, Set, singleton, union, unions)
import Debug.Trace (trace)
import GHC (extensionsForHSEParser, GHCOpts(..), ghcProcessArgs)
import qualified Language.Haskell.Exts.Annotated as A (ann, Decl(DerivDecl), ImportDecl(ImportDecl, importAs, importModule, importQualified, importSpecs), ImportSpec(..), ImportSpecList(..), InstHead(..), InstRule(..), Module(..), ModuleHead(ModuleHead), ModuleName(ModuleName), Name, QName(Qual, UnQual), SrcLoc(SrcLoc), Type(..))
import Language.Haskell.Exts.SrcLoc (SrcSpanInfo)
import LoadModule (loadModule)
import ModuleInfo (ModuleInfo(..))
import ModuleKey (moduleFullPath)
import SrcLoc (endOfImports, keep, keepAll, scanModule, skip, srcLoc, startOfImports)
import System.Exit (ExitCode(ExitSuccess, ExitFailure))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode, showCommandForUser)
import Utils (prettyPrint', replaceFile, simplify)

-- | Run ghc with -ddump-minimal-imports and capture the resulting .imports file.
cleanImports :: MonadIO m => FilePath -> GHCOpts -> [ModuleInfo SrcSpanInfo] -> m ()
cleanImports _ _ [] = trace ("cleanImports - no modules") (pure ())
cleanImports scratch opts info =
    dump >> mapM_ (\x -> do newText <- doModule scratch opts x
                            let path = moduleFullPath (_moduleKey x)
                            liftIO $ case newText of
                                       Nothing -> putStrLn (path <> " - imports already clean")
                                       Just s | _moduleText x /= s ->
                                                        do putStrLn (path ++ " imports changed")
                                                           -- let (path', ext) = splitExtension path in
                                                           -- writeFile {-path' ++ "-new" ++ ext-} s
                                                           void $ replaceFile path s
                                       Just _ -> pure ()) info
    where
      dump = do
        let args' = ["--make", "-c", "-ddump-minimal-imports", "-outputdir", scratch] ++
                    ghcProcessArgs (opts {extensions = extensions opts ++ extensionsForHSEParser}) ++
                    map _modulePath info
        (code, _out, err) <- liftIO $ readProcessWithExitCode (hc opts) args' ""
        case code of
          ExitSuccess -> return ()
          ExitFailure _ -> error ("cleanImports: dump failed\n " ++ showCommandForUser (hc opts) args' ++ " ->\n" ++ err)

-- | Parse the import list generated by GHC, parse the original source
-- file, and if all goes well insert the new imports into the old
-- source file.  We also need to modify the imports of any names
-- that are types that appear in standalone instance derivations so
-- their members are imported too.
doModule :: MonadIO m => FilePath -> GHCOpts -> ModuleInfo SrcSpanInfo -> m (Maybe String)
doModule scratch opts info@(ModuleInfo {_module = A.Module _ mh _ oldImports _}) =
    do let name = maybe "Main" (\ (A.ModuleHead _ (A.ModuleName _ s) _ _) -> s) mh
       let importsPath = scratch </> name ++ ".imports"

       -- The .imports file will appear in the real current directory,
       -- ignore the source dir path.  This may change in future
       -- versions of GHC, see http://ghc.haskell.org/trac/ghc/ticket/7957
       -- markForDelete importsPath
       liftIO (loadModule opts importsPath) >>=
              either (\(e :: SomeException) -> error $ "Could not load generated imports: " ++ show e)
                     (\(ModuleInfo {_module = newImports}) ->
                          pure (updateSource True info newImports extraImports))
    where
      extraImports = filter isHiddenImport oldImports
      isHiddenImport (A.ImportDecl {A.importSpecs = Just (A.ImportSpecList _ True _)}) = True
      isHiddenImport _ = False
doModule _ _ _ = error "Unsupported module type"

-- | If all the parsing went well and the new imports differ from the
-- old, update the source file with the new imports.
updateSource :: Bool -> ModuleInfo SrcSpanInfo -> A.Module SrcSpanInfo -> [A.ImportDecl SrcSpanInfo] -> Maybe String
updateSource removeEmptyImports info@(ModuleInfo {_module = A.Module _ _ _ oldImports _, _moduleKey = _key}) (A.Module _ _ _ newImports _) extraImports =
    replaceImports (fixNewImports removeEmptyImports info oldImports (newImports ++ extraImports)) info
updateSource _ _ _ _ = error "updateSource"

-- | Compare the old and new import sets and if they differ clip out
-- the imports from the sourceText and insert the new ones.
replaceImports :: [A.ImportDecl SrcSpanInfo] -> ModuleInfo SrcSpanInfo -> Maybe String
replaceImports newImports (ModuleInfo {_module = A.Module _l _mh _ps is _ds})
    | map simplify is == map simplify newImports =
        Nothing
replaceImports newImports info@(ModuleInfo {_module = m@(A.Module _l _mh _ps (_ : _) _ds)}) =
    Just $ scanModule (do -- keep (endOfHeader m)
                          maybe (pure ()) keep (startOfImports m)
                          tell (intercalate "\n" (map prettyPrint' newImports))
                          -- skip (startOfDecls m)
                          skip (endOfImports m)
                          keepAll)
                      info
replaceImports _ _ = error "replaceImports"

-- | Final touch-ups - sort and merge similar imports.
fixNewImports :: Bool         -- ^ If true, imports that turn into empty lists will be removed
              -> ModuleInfo l
              -> [A.ImportDecl SrcSpanInfo]
              -> [A.ImportDecl SrcSpanInfo]
              -> [A.ImportDecl SrcSpanInfo]
fixNewImports remove m oldImports imports =
    filter importPred $ Prelude.map expandSDTypes $ Prelude.map mergeDecls $ groupBy (\ a b -> importMergable a b == EQ) $ sortBy importMergable imports
    where
      -- mergeDecls :: [ImportDecl] -> ImportDecl
      mergeDecls [] = error "mergeDecls"
      mergeDecls xs@(x : _) = x {A.importSpecs = mergeSpecLists (catMaybes (Prelude.map A.importSpecs xs))}
          where
            -- Merge a list of specs for the same module
            mergeSpecLists :: [A.ImportSpecList SrcSpanInfo] -> Maybe (A.ImportSpecList SrcSpanInfo)
            mergeSpecLists (A.ImportSpecList loc flag specs : ys) =
                Just (A.ImportSpecList loc flag (mergeSpecs (sortBy compareSpecs (nub (concat (specs : Prelude.map (\ (A.ImportSpecList _ _ specs') -> specs') ys))))))
            mergeSpecLists [] = error "mergeSpecLists"
      expandSDTypes :: A.ImportDecl SrcSpanInfo -> A.ImportDecl SrcSpanInfo
      expandSDTypes i@(A.ImportDecl {A.importSpecs = Just (A.ImportSpecList l f specs)}) =
          i {A.importSpecs = Just (A.ImportSpecList l f (Prelude.map (expandSpec i) specs))}
      expandSDTypes i = i
      expandSpec i s =
          if not (A.importQualified i) && member (Nothing, simplify n) sdTypes ||
             maybe False (\ mn -> (member (Just (simplify mn), simplify n) sdTypes)) (A.importAs i) ||
             member (Just (simplify (A.importModule i)), simplify n) sdTypes
          then s'
          else s
          where
            n = case s of
                  (A.IVar _ x) -> x
                  (A.IAbs _ _ x) -> x
                  (A.IThingAll _ x) -> x
                  (A.IThingWith _ x _) -> x
            s' = case s of
                  (A.IVar l x) -> A.IThingAll l x
                  (A.IAbs l _ x) -> A.IThingAll l x
                  (A.IThingWith l x _) -> A.IThingAll l x
                  (A.IThingAll _ _) -> s

      -- Eliminate imports that became empty
      -- importPred :: ImportDecl -> Bool
      importPred (A.ImportDecl _ mn _ _ _ _ _ (Just (A.ImportSpecList _ _ []))) =
          not remove || maybe False (isEmptyImport . A.importSpecs) (find ((== (simplify mn)) . simplify . A.importModule) oldImports)
          where
            isEmptyImport (Just (A.ImportSpecList _ _ [])) = True
            isEmptyImport _ = False
      importPred _ = True

      sdTypes :: Set (Maybe (A.ModuleName ()), A.Name ())
      sdTypes = standaloneDerivingTypes m

-- | Compare the two import declarations ignoring the things that are
-- actually being imported.  Equality here indicates that the two
-- imports could be merged.
importMergable :: A.ImportDecl SrcSpanInfo -> A.ImportDecl SrcSpanInfo -> Ordering
importMergable a b =
    case (compare `on` noSpecs) a' b' of
      EQ -> EQ
      specOrdering ->
          case (compare `on` (A.importModule . simplify)) a' b' of
            EQ -> specOrdering
            moduleNameOrdering -> moduleNameOrdering
    where
      a' = simplify a
      b' = simplify b
      -- Return a version of an ImportDecl with an empty spec list and no
      -- source locations.  This will distinguish "import Foo as F" from
      -- "import Foo", but will let us group imports that can be merged.
      -- Don't merge hiding imports with regular imports.
      A.SrcLoc _path _ _ = srcLoc (A.ann a)
      noSpecs :: A.ImportDecl l -> A.ImportDecl l
      noSpecs x = x { A.importSpecs = case A.importSpecs x of
                                        Just (A.ImportSpecList l True _) -> Just (A.ImportSpecList l True []) -- hiding
                                        Just (A.ImportSpecList _ False _) -> Nothing
                                        Nothing -> Nothing }

-- Merge elements of a sorted spec list as possible
-- unimplemented, should merge Foo and Foo(..) into Foo(..), and the like
mergeSpecs :: [A.ImportSpec SrcSpanInfo] -> [A.ImportSpec SrcSpanInfo]
mergeSpecs [] = []
mergeSpecs [x] = [x]
{-
-- We need to do this using the simplified syntax
mergeSpecs (x : y : zs) =
    case (name x' == name y', x, y) of
      (True, S.IThingAll _ _, _) -> mergeSpecs (x : zs)
      (True, _, S.IThingAll _ _) -> mergeSpecs (y : zs)
      (True, S.IThingWith _ n xs, S.IThingWith _ ys) -> mergeSpecs (S.IThingWith n (nub (xs ++ ys)))
      (True, S.IThingWith _ _, _) -> mergeSpecs (x' : zs)
      (True, _, S.IThingWith _ _) -> mergeSpecs (y' : zs)
      _ -> x : mergeSpecs (y : zs)
    where
      x' = sImportSpec x
      y' = sImportSpec y
      name (S.IVar n) = n
      name (S.IAbs n) = n
      name (S.IThingAll n) = n
      name (S.IThingWith n _) = n
-}
mergeSpecs xs = xs

-- Compare function used to sort the symbols within an import.
compareSpecs :: A.ImportSpec SrcSpanInfo -> A.ImportSpec SrcSpanInfo -> Ordering
-- compareSpecs a b = (compare `on` sImportSpec) a b
compareSpecs a b =
    case (compare `on` (everywhere (mkT (map toLower)))) a' b' of
      EQ -> compare b' a' -- upper case first
      x -> x
    where
      a' = prettyPrint' a
      b' = prettyPrint' b

standaloneDerivingTypes :: ModuleInfo l -> Set (Maybe (A.ModuleName ()), A.Name ())
standaloneDerivingTypes (ModuleInfo {_module = A.XmlPage _ _ _ _ _ _ _}) = error "standaloneDerivingTypes A.XmlPage"
standaloneDerivingTypes (ModuleInfo {_module = A.XmlHybrid _ _ _ _ _ _ _ _ _}) = error "standaloneDerivingTypes A.XmlHybrid"
standaloneDerivingTypes (ModuleInfo {_module = A.Module _ _ _ _ decls}) =
    unions (Prelude.map derivDeclTypes decls)

-- | Collect the declared types of a standalone deriving declaration.
class DerivDeclTypes a where
    derivDeclTypes :: a -> Set (Maybe (A.ModuleName ()), A.Name ())

instance DerivDeclTypes (A.Decl l) where
    derivDeclTypes (A.DerivDecl _ _ _ x) = derivDeclTypes x
    derivDeclTypes _ = empty

instance DerivDeclTypes (A.InstRule l) where
    derivDeclTypes (A.IRule _ _ _ x)  = derivDeclTypes x
    derivDeclTypes (A.IParen _ x) = derivDeclTypes x

instance DerivDeclTypes (A.InstHead l) where
    derivDeclTypes (A.IHCon _ _) = empty
    derivDeclTypes (A.IHParen _ x) = derivDeclTypes x
    derivDeclTypes (A.IHInfix _ x _op) = derivDeclTypes x
    derivDeclTypes (A.IHApp _ x y) = union (derivDeclTypes x) (derivDeclTypes y)

instance DerivDeclTypes (A.Type l) where
    derivDeclTypes (A.TyForall _ _ _ x) = derivDeclTypes x -- qualified type
    derivDeclTypes (A.TyFun _ x y) = union (derivDeclTypes x) (derivDeclTypes y) -- function type
    derivDeclTypes (A.TyTuple _ _ xs) = unions (Prelude.map derivDeclTypes xs) -- tuple type, possibly boxed
    derivDeclTypes (A.TyList _ x) =  derivDeclTypes x -- list syntax, e.g. [a], as opposed to [] a
    derivDeclTypes (A.TyApp _ x y) = union (derivDeclTypes x) (derivDeclTypes y) -- application of a type constructor
    derivDeclTypes (A.TyVar _ _) = empty -- type variable
    derivDeclTypes (A.TyCon _ (A.Qual _ m n)) = singleton (Just (simplify m), simplify n) -- named type or type constructor
       -- Unqualified names refer to imports without "qualified" or "as" values.
    derivDeclTypes (A.TyCon _ (A.UnQual _ n)) = singleton (Nothing, simplify n)
    derivDeclTypes (A.TyCon _ _) = empty
    derivDeclTypes (A.TyParen _ x) = derivDeclTypes x -- type surrounded by parentheses
    derivDeclTypes (A.TyInfix _ x _op y) = union (derivDeclTypes x) (derivDeclTypes y) -- infix type constructor
    derivDeclTypes (A.TyKind _ x _) = derivDeclTypes x -- type with explicit kind signature
    derivDeclTypes (A.TyParArray _ x) = derivDeclTypes x
    derivDeclTypes (A.TyPromoted _ _) = empty
    derivDeclTypes (A.TyEquals _ _ _) = empty -- a ~ b, not clear how this related to standalone deriving
    derivDeclTypes (A.TySplice _ _) = empty
    derivDeclTypes (A.TyBang _ _ x) = derivDeclTypes x
    derivDeclTypes (A.TyWildCard _ _) = empty
