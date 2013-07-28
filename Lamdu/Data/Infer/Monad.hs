module Lamdu.Data.Infer.Monad
  ( Error(..)
  , TriggeredRules(..)
  , Infer, run
  , liftContext, liftExprRefs, liftError, error
  , ruleTrigger
  -- TODO: Delete these:
  , InferActions(..)
  , executeRelation, rerunRelations
  ) where

import Prelude hiding (error)

import Control.Lens.Operators
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.Reader (ReaderT(..))
import Control.Monad.Trans.State (StateT(..))
import Control.Monad.Trans.Writer (WriterT(..))
import Data.Foldable (traverse_)
import Data.Map (Map)
import Data.Monoid (Monoid(..))
import Data.Store.Guid (Guid)
import Lamdu.Data.Expression.Utils () -- Expr.Body Show instance
import Lamdu.Data.Infer.Internal
import Lamdu.Data.Infer.Rule.Internal
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.Reader as Reader
import qualified Control.Monad.Trans.Writer as Writer
import qualified Data.IntMap as IntMap
import qualified Lamdu.Data.Expression as Expr
import qualified Lamdu.Data.Infer.ExprRefs as ExprRefs

data Error def
  = VarEscapesScope Guid
  | VarNotInScope
  | InfiniteExpression (RefD def)
  | CompositeTag (RefD def)
  | GetMissingField
  | GetFieldRequiresRecord
  | Mismatch (Expr.Body def (RefD def)) (Expr.Body def (RefD def))
  deriving (Show)

newtype InferActions def = InferActions
  { iaExecuteRelation :: Relation def -> RefD def -> Infer def ()
  }

newtype TriggeredRules def = TriggeredRules
  { triggeredRules :: RuleIdMap (Map (RefD def, Trigger) Bool)
  }
instance Monoid (TriggeredRules def) where
  mempty = TriggeredRules IntMap.empty
  mappend (TriggeredRules x) (TriggeredRules y) =
    TriggeredRules $ IntMap.unionWith mappend x y

type Infer def =
  ReaderT (InferActions def)
  (WriterT (TriggeredRules def)
   (StateT (Context def)
    (Either (Error def))))

ruleTrigger :: RuleId -> RefD def -> Trigger -> Bool -> Infer def ()
ruleTrigger ruleId ref trigger res =
  lift . Writer.tell . TriggeredRules $
  IntMap.empty & Lens.at ruleId .~
  Just (mempty & Lens.at (ref, trigger) .~ Just res)

liftContext ::
  StateT (Context def) (Either (Error def)) a ->
  Infer def a
liftContext = lift . lift

liftExprRefs ::
  StateT (ExprRefsD def) (Either (Error def)) a ->
  Infer def a
liftExprRefs = liftContext . Lens.zoom ctxExprRefs

liftError :: Either (Error def) a -> Infer def a
liftError = lift . lift . lift

error :: Error def -> Infer def a
error = liftError . Left

run ::
  InferActions def -> Infer def a ->
  WriterT (TriggeredRules def) (StateT (Context def) (Either (Error def))) a
run = flip runReaderT

executeRelation :: Relation def -> RefD def -> Infer def ()
executeRelation relation ref = do
  act <- Reader.asks iaExecuteRelation
  act relation ref

rerunRelations :: Eq def => RefD def -> Infer def ()
rerunRelations ref = do
  relations <- liftContext . Lens.zoom ctxExprRefs $ ExprRefs.read ref <&> (^. rdRelations)
  traverse_ (`executeRelation` ref) relations