{-# LANGUAGE GeneralizedNewtypeDeriving, TemplateHaskell #-}
module Editor.CodeEdit.VarAccess
  ( VarAccess, run
  -- OTransaction wrappers:
  , WidgetT
  , otransaction, transaction, atEnv
  , getP, assignCursor, assignCursorPrefix
  -- 
  , AccessedVars, markVariablesAsUsed, usedVariables
  , withName, NameSource(..)
  , getDefName
  ) where

import Control.Applicative (Applicative, liftA2)
import Control.Monad (liftM)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.RWS (RWST, runRWST)
import Data.Map (Map)
import Data.Store.Guid (Guid)
import Data.Store.Transaction (Transaction)
import Editor.Anchors (ViewTag)
import Editor.ITransaction (ITransaction)
import Editor.OTransaction (OTransaction)
import Graphics.UI.Bottle.Widget (Widget)
import qualified Control.Lens as Lens
import qualified Control.Lens.TH as LensTH
import qualified Control.Monad.Trans.RWS as RWS
import qualified Data.Map as Map
import qualified Data.Store.Guid as Guid
import qualified Editor.Anchors as Anchors
import qualified Editor.OTransaction as OT
import qualified Graphics.UI.Bottle.Widget as Widget

type WidgetT m = Widget (ITransaction ViewTag m)

type AccessedVars = [Guid]

data NameGenState = NameGenState
  { ngUnusedNames :: [String]
  , ngUsedNames :: Map Guid String
  }

newtype VarAccess m a = VarAccess
  { _varAccess :: RWST NameGenState AccessedVars () (OTransaction ViewTag m) a }
  deriving (Functor, Applicative, Monad)
LensTH.makeLenses ''VarAccess

atEnv :: Monad m => (OT.Env -> OT.Env) -> VarAccess m a -> VarAccess m a
atEnv = Lens.over varAccess . RWS.mapRWST . OT.atEnv

run :: Monad m => VarAccess m a -> OTransaction ViewTag m a
run (VarAccess action) =
  liftM f $ runRWST action initialNameGenState ()
  where
    f (x, _, _) = x

otransaction :: Monad m => OTransaction ViewTag m a -> VarAccess m a
otransaction = VarAccess . lift

transaction :: Monad m => Transaction ViewTag m a -> VarAccess m a
transaction = otransaction . OT.transaction

getP :: Monad m => Anchors.MkProperty ViewTag m a -> VarAccess m a
getP = transaction . Anchors.getP

assignCursor :: Monad m => Widget.Id -> Widget.Id -> VarAccess m a -> VarAccess m a
assignCursor x y = atEnv $ OT.envAssignCursor x y

assignCursorPrefix :: Monad m => Widget.Id -> Widget.Id -> VarAccess m a -> VarAccess m a
assignCursorPrefix x y = atEnv $ OT.envAssignCursorPrefix x y

-- Used vars:

usedVariables
  :: Monad m
  => VarAccess m a -> VarAccess m (a, [Guid])
usedVariables = Lens.over varAccess RWS.listen

markVariablesAsUsed :: Monad m => AccessedVars -> VarAccess m ()
markVariablesAsUsed = VarAccess . RWS.tell

-- Auto-generating names

initialNameGenState :: NameGenState
initialNameGenState =
  NameGenState names Map.empty
  where
    alphabet = map (:[]) ['a'..'z']
    names = alphabet ++ liftA2 (++) names alphabet

withNewName :: Monad m => Guid -> (String -> VarAccess m a) -> VarAccess m a
withNewName guid useNewName = do
  nameGen <- VarAccess RWS.ask
  let
    (name : nextNames) = ngUnusedNames nameGen
    newNameGen = nameGen
      { ngUnusedNames = nextNames
      , ngUsedNames = Map.insert guid name $ ngUsedNames nameGen
      }
  VarAccess . RWS.local (const newNameGen) . Lens.view varAccess $ useNewName name

data NameSource = AutoGeneratedName | StoredName

withName :: Monad m => Guid -> ((NameSource, String) -> VarAccess m a) -> VarAccess m a
withName guid useNewName = do
  storedName <- transaction . Anchors.getP $ Anchors.assocNameRef guid
  -- TODO: maybe use Maybe?
  if null storedName
    then do
      existingName <- VarAccess $ RWS.asks (Map.lookup guid . ngUsedNames)
      let useGenName = useNewName . (,) AutoGeneratedName
      case existingName of
        Nothing -> withNewName guid useGenName
        Just name -> useGenName name
    else useNewName (StoredName, storedName)

getDefName :: Monad m => Guid -> VarAccess m (NameSource, String)
getDefName guid = do
  storedName <- transaction . Anchors.getP $ Anchors.assocNameRef guid
  return $
    if null storedName
    then (AutoGeneratedName, (("anon_"++) . take 6 . Guid.asHex) guid)
    else (StoredName, storedName)
