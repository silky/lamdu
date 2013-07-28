{-# LANGUAGE PatternGuards, RecordWildCards #-}
module Lamdu.Data.Infer.Unify
  ( unify, forceLam
  ) where

import Control.Applicative ((<$>))
import Control.Lens.Operators
import Control.Monad (when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Decycle (DecycleT, runDecycleT, visit)
import Control.Monad.Trans.State (state)
import Control.Monad.Trans.Writer (WriterT(..))
import Data.Foldable (sequenceA_, traverse_)
import Data.Map (Map)
import Data.Map.Utils (lookupOrSelf)
import Data.Maybe (fromMaybe)
import Data.Maybe.Utils (unsafeUnjust)
import Data.Monoid (Monoid(..))
import Data.Monoid.Applicative (ApplicativeMonoid(..))
import Data.Set (Set)
import Data.Store.Guid (Guid)
import Data.Traversable (sequenceA)
import Lamdu.Data.Infer.Internal
import Lamdu.Data.Infer.Monad (Infer, Error(..))
import System.Random (Random, random)
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.Writer as Writer
import qualified Data.IntMap as IntMap
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Lamdu.Data.Expression as Expr
import qualified Lamdu.Data.Expression.Lens as ExprLens
import qualified Lamdu.Data.Expression.Utils as ExprUtil
import qualified Lamdu.Data.Infer.ExprRefs as ExprRefs
import qualified Lamdu.Data.Infer.Monad as InferM
import qualified Lamdu.Data.Infer.Trigger as Trigger

newRandom :: Random r => Infer def r
newRandom = InferM.liftContext . Lens.zoom ctxRandomGen $ state random

forceLam :: Eq def => Expr.Kind -> Scope def -> RefD def -> Infer def (Guid, RefD def, RefD def)
forceLam k lamScope destRef = do
  newGuid <- newRandom
  newParamTypeRef <- InferM.liftExprRefs . fresh lamScope $ ExprLens.bodyHole # ()
  let lamResultScope = lamScope & scopeMap %~ Map.insert newGuid newParamTypeRef
  newResultTypeRef <- InferM.liftExprRefs . fresh lamResultScope $ ExprLens.bodyHole # ()
  newLamRef <-
    InferM.liftExprRefs . fresh lamScope . Expr.BodyLam $
    Expr.Lam k newGuid newParamTypeRef newResultTypeRef
  -- left is renamed into right (keep existing names of destRef):
  rep <- unify newLamRef destRef
  body <- InferM.liftExprRefs $ (^. rdBody) <$> ExprRefs.readRep rep
  return . unsafeUnjust "We just unified Lam into rep" $
    body ^? ExprLens.bodyKindedLam k

-- If we don't assert that the scopes have same refs we could be pure
intersectScopes :: Scope def -> Scope def -> Infer def (Scope def)
intersectScopes (Scope aScope) (Scope bScope) =
  Scope <$> sequenceA (Map.intersectionWith verifyEquiv aScope bScope)
  where
    -- Expensive assertion
    verifyEquiv aref bref = do
      equiv <- InferM.liftExprRefs $ ExprRefs.equiv aref bref
      if equiv
        then return aref
        else error "Scope unification of differing refs"

newtype HoleConstraints = HoleConstraints
  { hcUnusableInHoleScope :: Set Guid
  }

-- You must apply this recursively
checkHoleConstraints :: HoleConstraints -> Expr.Body def (RefD def) -> Either (Error def) ()
checkHoleConstraints (HoleConstraints unusableSet) body
  | Just paramGuid <- body ^? ExprLens.bodyParameterRef
  , paramGuid `Set.member` unusableSet
  = Left $ VarEscapesScope paramGuid
  -- Expensive assertion
  | Lens.anyOf (Expr._BodyLam . Expr.lamParamId) (`Set.member` unusableSet) body =
    error "checkHoleConstraints: Shadowing detected"
  | otherwise = return ()

type U def = DecycleT (RefD def) (Infer def)

uInfer :: Infer def a -> U def a
uInfer = lift

type WU def = WriterT (ApplicativeMonoid (U def) ()) (U def)
wuInfer :: Infer def a -> WU def a
wuInfer = lift . uInfer
wuRun :: WU def a -> U def (a, U def ())
wuRun = fmap (Lens._2 %~ runApplicativeMonoid) . runWriterT
wuLater :: U def () -> WU def ()
wuLater = Writer.tell . ApplicativeMonoid

mergeScopeBodies ::
  Eq def =>
  Map Guid Guid ->
  Scope def -> Expr.Body def (RefD def) ->
  Scope def -> Expr.Body def (RefD def) ->
  WU def (Scope def, Expr.Body def (RefD def))
mergeScopeBodies renames xScope xBody yScope yBody = do
  intersectedScope <- wuInfer $ intersectScopes xScope yScope
  let
    unifyWithHole activeRenames holeScope otherScope nonHoleBody
      | Set.null unusableScopeSet && Map.null renames =
        return (intersectedScope, nonHoleBody)
      | otherwise =
        applyHoleConstraints activeRenames (HoleConstraints unusableScopeSet)
        nonHoleBody intersectedScope
        <&> flip (,) nonHoleBody
      where
        unusableScopeSet = makeUnusableScopeSet holeScope otherScope
  case (xBody, yBody) of
    (_, Expr.BodyLeaf Expr.Hole) -> unifyWithHole renames   yScope xScope xBody
    (Expr.BodyLeaf Expr.Hole, _) -> unifyWithHole Map.empty xScope yScope yBody
    _ -> do
      wuLater . (fromMaybe . lift . InferM.error) (Mismatch xBody yBody) $
        sequenceA_ <$> ExprUtil.matchBody matchLamResult matchOther (==) xBody yBody
      -- We must return the yBody and not xBody here. Ref-wise, both
      -- are fine. But name-wise, the names are going to be taken from
      -- y, not x.
      return (intersectedScope, yBody)
  where
    makeUnusableScopeSet holeScope otherScope =
      Map.keysSet $ Map.difference
      (otherScope ^. scopeMap)
      (holeScope ^. scopeMap)
    matchLamResult xGuid yGuid xRef yRef =
      (yGuid, unifyRecurse (renames & Lens.at xGuid .~ Just yGuid) xRef yRef)
    matchOther xRef yRef = unifyRecurse renames xRef yRef

renameAppliedPiResult :: Map Guid Guid -> AppliedPiResult def -> AppliedPiResult def
renameAppliedPiResult renames (AppliedPiResult piGuid argVal destRef copiedNames) =
  AppliedPiResult
  (lookupOrSelf renames piGuid) argVal destRef
  (Map.mapKeys (lookupOrSelf renames) copiedNames)

renameRelation :: Map Guid Guid -> Relation def -> Relation def
renameRelation renames (RelationAppliedPiResult apr) =
  RelationAppliedPiResult $ renameAppliedPiResult renames apr

renameTrigger :: Map Guid Guid -> Trigger -> Trigger
renameTrigger _renames x = x

renameRefData :: Map Guid Guid -> RefData def -> RefData def
renameRefData renames RefData {..}
  -- Expensive assertion
  | Lens.anyOf (Expr._BodyLam . Expr.lamParamId) (`Map.member` renames) _rdBody =
    error "Shadowing encountered, what to do?"
  | otherwise =
    RefData
    { _rdScope         = _rdScope & scopeMap %~ Map.mapKeys (lookupOrSelf renames)
    , _rdRenameHistory = _rdRenameHistory & _RenameHistory %~ Map.union renames
    , _rdRelations     = _rdRelations <&> renameRelation renames
    , _rdIsCircumsized = _rdIsCircumsized
    , _rdTriggers      = _rdTriggers <&> Set.map (renameTrigger renames)
    , _rdBody          = _rdBody & ExprLens.bodyParameterRef %~ lookupOrSelf renames
    }

mergeRefData ::
  Eq def =>
  Map Guid Guid -> RefData def -> RefData def ->
  WU def (Bool, RefData def)
mergeRefData renames
  (RefData aScope aMRenameHistory aRelations aIsCircumsized aTriggers aBody)
  (RefData bScope bMRenameHistory bRelations bIsCircumsized bTriggers bBody) =
  mkRefData
  <$> mergeScopeBodies renames aScope aBody bScope bBody
  where
    bodyIsUpdated =
      Lens.has ExprLens.bodyHole aBody /=
      Lens.has ExprLens.bodyHole bBody
    mergedRelations = aRelations ++ bRelations
    mkRefData (intersectedScope, mergedBody) =
      ( bodyIsUpdated
      , RefData
        { _rdScope = intersectedScope
        , _rdRenameHistory = mappend aMRenameHistory bMRenameHistory
        , _rdRelations = mergedRelations
        , _rdIsCircumsized = mappend aIsCircumsized bIsCircumsized
        , _rdTriggers = IntMap.unionWith mappend aTriggers bTriggers
        , _rdBody = mergedBody
        }
      )

renameMergeRefData ::
  Eq def =>
  RefD def -> Map Guid Guid -> RefData def -> RefData def ->
  WU def (Bool, RefData def)
renameMergeRefData rep renames a b =
  mergeRefData renames (renameRefData renames a) b
  >>= Lens._2 %%~ wuInfer . Trigger.updateRefData rep

applyHoleConstraints ::
  Eq def =>
  Map Guid Guid ->
  HoleConstraints ->
  Expr.Body def (RefD def) -> Scope def ->
  WU def (Scope def)
applyHoleConstraints renames holeConstraints body oldScope = do
  wuInfer . InferM.liftError $ checkHoleConstraints holeConstraints body
  wuLater $ traverse_ (holeConstraintsRecurse renames holeConstraints) body
  let unusableMap = Map.fromSet (const ()) $ hcUnusableInHoleScope holeConstraints
  return $ oldScope & scopeMap %~ (`Map.difference` unusableMap)

decycleDefend :: RefD def -> (RefD def -> U def (RefD def)) -> U def (RefD def)
decycleDefend ref action = do
  nodeRep <- lift . InferM.liftExprRefs $ ExprRefs.find "holeConstraintsRecurse:rawNode" ref
  mResult <- visit nodeRep (action nodeRep)
  case mResult of
    Nothing -> lift . InferM.error $ InfiniteExpression nodeRep
    Just result -> return result

holeConstraintsRecurse ::
  Eq def => Map Guid Guid -> HoleConstraints -> RefD def -> U def (RefD def)
holeConstraintsRecurse renames holeConstraints rawNode =
  decycleDefend rawNode $ \nodeRep -> do
    oldNodeData <- lift . InferM.liftExprRefs $ ExprRefs.readRep nodeRep
    lift . InferM.liftExprRefs . ExprRefs.writeRep nodeRep $
      error "Reading node during write..."
    let midRefData = renameRefData renames oldNodeData
    (newRefData, later) <-
      wuRun $
      midRefData
      & rdScope %%~
        applyHoleConstraints renames holeConstraints
        (midRefData ^. rdBody)
    uInfer . InferM.liftExprRefs $ ExprRefs.writeRep nodeRep newRefData
    later
    return nodeRep

unifyRecurse ::
  Eq def => Map Guid Guid -> RefD def -> RefD def -> U def (RefD def)
unifyRecurse renames rawNode other =
  decycleDefend rawNode $ \nodeRep -> do
    (rep, unifyResult) <- lift . InferM.liftExprRefs $ ExprRefs.unifyRefs nodeRep other
    case unifyResult of
      ExprRefs.UnifyRefsAlreadyUnified -> return ()
      ExprRefs.UnifyRefsUnified xData yData -> do
        ((bodyIsUpdated, mergedRefData), later) <-
          wuRun $ renameMergeRefData rep renames xData yData
        -- First let's write the mergedRefData so we're not in danger zone
        -- of reading missing data:
        lift . InferM.liftExprRefs $ ExprRefs.write rep mergedRefData
        -- Now lets do the deferred recursive unifications:
        later
        -- TODO: Remove this when replaced Relations with Rules
        -- Now we can safely re-run the relations
        when bodyIsUpdated . lift $ InferM.rerunRelations rep
    return rep

unify :: Eq def => RefD def -> RefD def -> Infer def (RefD def)
unify x y = runDecycleT $ unifyRecurse mempty x y