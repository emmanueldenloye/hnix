{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}

{-# OPTIONS_GHC -Wno-name-shadowing #-}

module Nix.Type.Infer (
  Constraint(..),
  TypeError(..),
  InferError(..),
  Subst(..),
  inferTop
) where

import           Control.Applicative
import           Control.Arrow
import           Control.Monad.Catch
import           Control.Monad.Except
import           Control.Monad.Fail
import           Control.Monad.Logic
import           Control.Monad.Reader
import           Control.Monad.Ref
import           Control.Monad.ST
import           Control.Monad.State
import           Data.Fix
import           Data.Foldable
import qualified Data.HashMap.Lazy as M
import           Data.List (delete, find, nub, intersect, (\\))
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe (fromJust)
import           Data.STRef
import qualified Data.Set as Set
import           Data.Text (Text)
import           Nix.Atoms
import           Nix.Convert
import           Nix.Eval (MonadEval(..))
import qualified Nix.Eval as Eval
import           Nix.Expr.Types
import           Nix.Expr.Types.Annotated
import           Nix.String
import           Nix.Scope
import           Nix.Thunk
import qualified Nix.Type.Assumption as As
import           Nix.Type.Env
import qualified Nix.Type.Env as Env
import           Nix.Type.Type
import           Nix.Utils

-------------------------------------------------------------------------------
-- Classes
-------------------------------------------------------------------------------

-- | Inference monad
newtype Infer s a = Infer
    { getInfer ::
        ReaderT (Set.Set TVar, Scopes (Infer s) (JThunk s))
            (StateT InferState (ExceptT InferError (ST s))) a
    }
    deriving (Functor, Applicative, Alternative, Monad, MonadPlus, MonadFix,
              MonadReader (Set.Set TVar, Scopes (Infer s) (JThunk s)), MonadFail,
              MonadState InferState, MonadError InferError)

-- | Inference state
newtype InferState = InferState { count :: Int }

-- | Initial inference state
initInfer :: InferState
initInfer = InferState { count = 0 }

data Constraint
    = EqConst Type Type
    | ExpInstConst Type Scheme
    | ImpInstConst Type (Set.Set TVar) Type
    deriving (Show, Eq, Ord)

newtype Subst = Subst (Map TVar Type)
  deriving (Eq, Ord, Show, Semigroup, Monoid)

class Substitutable a where
  apply :: Subst -> a -> a

instance Substitutable TVar where
  apply (Subst s) a = tv
    where t = TVar a
          (TVar tv) = Map.findWithDefault t a s

instance Substitutable Type where
  apply _ (TCon a)           = TCon a
  apply s (TSet b a)         = TSet b (M.map (apply s) a)
  apply s (TList a)          = TList (map (apply s) a)
  apply (Subst s) t@(TVar a) = Map.findWithDefault t a s
  apply s (t1 :~> t2)        = apply s t1 :~> apply s t2
  apply s (TMany ts)         = TMany (map (apply s) ts)

instance Substitutable Scheme where
  apply (Subst s) (Forall as t) = Forall as $ apply s' t
    where s' = Subst $ foldr Map.delete s as

instance Substitutable Constraint where
   apply s (EqConst t1 t2)         = EqConst (apply s t1) (apply s t2)
   apply s (ExpInstConst t sc)     = ExpInstConst (apply s t) (apply s sc)
   apply s (ImpInstConst t1 ms t2) = ImpInstConst (apply s t1) (apply s ms) (apply s t2)

instance Substitutable a => Substitutable [a] where
  apply = map . apply

instance (Ord a, Substitutable a) => Substitutable (Set.Set a) where
  apply = Set.map . apply


class FreeTypeVars a where
  ftv :: a -> Set.Set TVar

instance FreeTypeVars Type where
  ftv TCon{}      = Set.empty
  ftv (TVar a)    = Set.singleton a
  ftv (TSet _ a)  = Set.unions (map ftv (M.elems a))
  ftv (TList a)   = Set.unions (map ftv a)
  ftv (t1 :~> t2) = ftv t1 `Set.union` ftv t2
  ftv (TMany ts)  = Set.unions (map ftv ts)

instance FreeTypeVars TVar where
  ftv = Set.singleton

instance FreeTypeVars Scheme where
  ftv (Forall as t) = ftv t `Set.difference` Set.fromList as

instance FreeTypeVars a => FreeTypeVars [a] where
  ftv   = foldr (Set.union . ftv) Set.empty

instance (Ord a, FreeTypeVars a) => FreeTypeVars (Set.Set a) where
  ftv   = foldr (Set.union . ftv) Set.empty


class ActiveTypeVars a where
  atv :: a -> Set.Set TVar

instance ActiveTypeVars Constraint where
  atv (EqConst t1 t2)         = ftv t1 `Set.union` ftv t2
  atv (ImpInstConst t1 ms t2) = ftv t1 `Set.union` (ftv ms `Set.intersection` ftv t2)
  atv (ExpInstConst t s)      = ftv t `Set.union` ftv s

instance ActiveTypeVars a => ActiveTypeVars [a] where
  atv = foldr (Set.union . atv) Set.empty

data TypeError
  = UnificationFail Type Type
  | InfiniteType TVar Type
  | UnboundVariables [Text]
  | Ambigious [Constraint]
  | UnificationMismatch [Type] [Type]
  deriving (Eq, Show)

data InferError
  = TypeInferenceErrors [TypeError]
  | TypeInferenceAborted
  | forall s. Exception s => EvaluationError s

typeError :: MonadError InferError m => TypeError -> m ()
typeError err = throwError $ TypeInferenceErrors [err]

deriving instance Show InferError
instance Exception InferError

instance Semigroup InferError where
    x <> _ = x

instance Monoid InferError where
    mempty  = TypeInferenceAborted
    mappend = (<>)

-------------------------------------------------------------------------------
-- Inference
-------------------------------------------------------------------------------

-- | Run the inference monad
runInfer' :: Infer s a -> ST s (Either InferError a)
runInfer' = runExceptT
          . (`evalStateT` initInfer)
          . (`runReaderT` (Set.empty, emptyScopes))
          . getInfer

runInfer :: (forall s. Infer s a) -> Either InferError a
runInfer m = runST (runInfer' m)

inferType :: Env -> NExpr -> Infer s [(Subst, Type)]
inferType env ex = do
  Judgment as cs t <- infer ex
  let unbounds = Set.fromList (As.keys as) `Set.difference`
                 Set.fromList (Env.keys env)
  unless (Set.null unbounds) $
      typeError $ UnboundVariables (nub (Set.toList unbounds))
  let cs' = [ ExpInstConst t s
            | (x, ss) <- Env.toList env
            , s <- ss
            , t <- As.lookup x as]
  inferState <- get
  let eres = (`evalState` inferState) $ runSolver $ do
          subst <- solve (cs ++ cs')
          return (subst, subst `apply` t)
  case eres of
      Left errs -> throwError $ TypeInferenceErrors errs
      Right xs  -> pure xs

-- | Solve for the toplevel type of an expression in a given environment
inferExpr :: Env -> NExpr -> Either InferError [Scheme]
inferExpr env ex = case runInfer (inferType env ex) of
  Left err -> Left err
  Right xs -> Right $ map (\(subst, ty) -> closeOver (subst `apply` ty)) xs

-- | Canonicalize and return the polymorphic toplevel type.
closeOver :: Type -> Scheme
closeOver = normalize . generalize Set.empty

extendMSet :: TVar -> Infer s a -> Infer s a
extendMSet x = Infer . local (first (Set.insert x)) . getInfer

letters :: [String]
letters = [1..] >>= flip replicateM ['a'..'z']

fresh :: MonadState InferState m => m Type
fresh = do
    s <- get
    put s{count = count s + 1}
    return $ TVar $ TV (letters !! count s)

instantiate :: MonadState InferState m => Scheme -> m Type
instantiate (Forall as t) = do
    as' <- mapM (const fresh) as
    let s = Subst $ Map.fromList $ zip as as'
    return $ apply s t

generalize :: Set.Set TVar -> Type -> Scheme
generalize free t  = Forall as t
    where as = Set.toList $ ftv t `Set.difference` free

unops :: Type -> NUnaryOp -> [Constraint]
unops u1 = \case
    NNot -> [ EqConst u1 (typeFun [typeBool, typeBool]) ]
    NNeg -> [ EqConst u1 (TMany [ typeFun [typeInt,   typeInt]
                               , typeFun [typeFloat, typeFloat] ]) ]

binops :: Type -> NBinaryOp -> [Constraint]
binops u1 = \case
    NApp    -> []                -- this is handled separately

    -- Equality tells you nothing about the types, because any two types are
    -- allowed.
    NEq     -> []
    NNEq    -> []

    NGt     -> inequality
    NGte    -> inequality
    NLt     -> inequality
    NLte    -> inequality

    NAnd    -> [ EqConst u1 (typeFun [typeBool, typeBool, typeBool]) ]
    NOr     -> [ EqConst u1 (typeFun [typeBool, typeBool, typeBool]) ]
    NImpl   -> [ EqConst u1 (typeFun [typeBool, typeBool, typeBool]) ]

    NConcat -> [ EqConst u1 (TMany [ typeFun [typeList,   typeList,   typeList]
                                  , typeFun [typeList,   typeNull,   typeList]
                                  , typeFun [typeNull,   typeList,   typeList]
                                  ]) ]

    NUpdate -> [ EqConst u1 (TMany [ typeFun [typeSet,    typeSet,    typeSet]
                                  , typeFun [typeSet,    typeNull,   typeSet]
                                  , typeFun [typeNull,   typeSet,    typeSet]
                                  ]) ]

    NPlus   -> [ EqConst u1 (TMany [ typeFun [typeInt,    typeInt,    typeInt]
                                  , typeFun [typeFloat,  typeFloat,  typeFloat]
                                  , typeFun [typeInt,    typeFloat,  typeFloat]
                                  , typeFun [typeFloat,  typeInt,    typeFloat]
                                  , typeFun [typeString, typeString, typeString]
                                  , typeFun [typePath,   typePath,   typePath]
                                  , typeFun [typeString, typeString, typePath]
                                  ]) ]
    NMinus  -> arithmetic
    NMult   -> arithmetic
    NDiv    -> arithmetic
  where
    inequality =
        [ EqConst u1 (TMany [ typeFun [typeInt,    typeInt,    typeBool]
                            , typeFun [typeFloat,  typeFloat,  typeBool]
                            , typeFun [typeInt,    typeFloat,  typeBool]
                            , typeFun [typeFloat,  typeInt,    typeBool]
                            ]) ]

    arithmetic =
        [ EqConst u1 (TMany [ typeFun [typeInt,    typeInt,    typeInt]
                            , typeFun [typeFloat,  typeFloat,  typeFloat]
                            , typeFun [typeInt,    typeFloat,  typeFloat]
                            , typeFun [typeFloat,  typeInt,    typeFloat]
                            ]) ]

liftInfer :: ST s a -> Infer s a
liftInfer = Infer . lift . lift . lift

instance MonadRef (Infer s) where
    type Ref (Infer s) = STRef s
    newRef x            = liftInfer $ newSTRef x
    readRef x           = liftInfer $ readSTRef x
    writeRef x y        = liftInfer $ writeSTRef x y

instance MonadAtomicRef (Infer s) where
    atomicModifyRef x f = liftInfer $ do
        res <- snd . f <$> readSTRef x
        _ <- modifySTRef x (fst . f)
        return res

newtype JThunk s = JThunk (Thunk (Infer s) (Judgment s))

instance MonadThrow (Infer s) where
    throwM = throwError . EvaluationError

instance MonadCatch (Infer s) where
    catch m h = catchError m $ \case
        EvaluationError e ->
            maybe (error $ "Exception was not an exception: " ++ show e) h
                  (fromException (toException e))
        err -> error $ "Unexpected error: " ++ show err

instance MonadThunk (Judgment s) (JThunk s) (Infer s) where
    thunk = fmap JThunk . buildThunk

    force (JThunk t) f = catch (forceThunk t f) $ \(_ :: ThunkLoop) ->
        -- If we have a thunk loop, we just don't know the type.
        f =<< Judgment As.empty [] <$> fresh

    value = JThunk . valueRef

instance MonadEval (Judgment s) (Infer s) where
    freeVariable var = do
        tv <- fresh
        return $ Judgment (As.singleton var tv) [] tv

    -- If we fail to look up an attribute, we just don't know the type.
    attrMissing _ _ = Judgment As.empty [] <$> fresh

    evaledSym _ = pure

    evalCurPos =
        return $ Judgment As.empty [] $ TSet False $ M.fromList
            [ ("file", typePath)
            , ("line", typeInt)
            , ("col",  typeInt) ]

    evalConstant c  = return $ Judgment As.empty [] (go c)
      where
        go = \case
          NInt _   -> typeInt
          NFloat _ -> typeFloat
          NBool _  -> typeBool
          NNull    -> typeNull

    evalString      = const $ return $ Judgment As.empty [] typeString
    evalLiteralPath = const $ return $ Judgment As.empty [] typePath
    evalEnvPath     = const $ return $ Judgment As.empty [] typePath

    evalUnary op (Judgment as1 cs1 t1) = do
        tv <- fresh
        return $ Judgment as1 (cs1 ++ unops (t1 :~> tv) op) tv

    evalBinary op (Judgment as1 cs1 t1) e2 = do
        Judgment as2 cs2 t2 <- e2
        tv <- fresh
        return $ Judgment
            (as1 `As.merge` as2)
            (cs1 ++ cs2 ++ binops (t1 :~> t2 :~> tv) op)
            tv

    evalWith = Eval.evalWithAttrSet

    evalIf (Judgment as1 cs1 t1) t f = do
        Judgment as2 cs2 t2 <- t
        Judgment as3 cs3 t3 <- f
        return $ Judgment
            (as1 `As.merge` as2 `As.merge` as3)
            (cs1 ++ cs2 ++ cs3 ++ [EqConst t1 typeBool, EqConst t2 t3])
            t2

    evalAssert (Judgment as1 cs1 t1) body = do
        Judgment as2 cs2 t2 <- body
        return $ Judgment
            (as1 `As.merge` as2)
            (cs1 ++ cs2 ++ [EqConst t1 typeBool])
            t2

    evalApp (Judgment as1 cs1 t1) e2 = do
        Judgment as2 cs2 t2 <- e2
        tv <- fresh
        return $ Judgment
            (as1 `As.merge` as2)
            (cs1 ++ cs2 ++ [EqConst t1 (t2 :~> tv)])
            tv

    evalAbs (Param x) k = do
        tv@(TVar a) <- fresh
        ((), Judgment as cs t) <-
            extendMSet a (k (pure (Judgment (As.singleton x tv) [] tv))
                            (\_ b -> ((),) <$> b))
        return $ Judgment
            (as `As.remove` x)
            (cs ++ [EqConst t' tv | t' <- As.lookup x as])
            (tv :~> t)

    evalAbs (ParamSet ps variadic _mname) k = do
        js <- fmap concat $ forM ps $ \(name, _) -> do
                tv <- fresh
                pure [(name, tv)]

        let (env, tys) = (\f -> foldl' f (As.empty, M.empty) js)
                $ \(as1, t1) (k, t) ->
                    (as1 `As.merge` As.singleton k t, M.insert k t t1)
            arg   = pure $ Judgment env [] (TSet True tys)
            call  = k arg $ \args b -> (args,) <$> b
            names = map fst js

        (args, Judgment as cs t) <-
            foldr (\(_, TVar a) -> extendMSet a) call js

        ty <- TSet variadic <$> traverse (inferredType <$>) args

        return $ Judgment
            (foldl' As.remove as names)
            (cs ++ [ EqConst t' (tys M.! x)
                   | x  <- names
                   , t' <- As.lookup x as])
            (ty :~> t)

    evalError = throwError . EvaluationError

data Judgment s = Judgment
    { assumptions     :: As.Assumption
    , typeConstraints :: [Constraint]
    , inferredType    :: Type
    }
    deriving Show

instance FromValue NixString (Infer s) (Judgment s) where
    fromValueMay _ = return Nothing
    fromValue _ = error "Unused"

instance FromValue (AttrSet (JThunk s), AttrSet SourcePos) (Infer s) (Judgment s) where
    fromValueMay (Judgment _ _ (TSet _ xs)) = do
        let sing _ = Judgment As.empty []
        pure $ Just (M.mapWithKey (\k v -> value (sing k v)) xs, M.empty)
    fromValueMay _ = pure Nothing
    fromValue = fromValueMay >=> \case
        Just v  -> pure v
        Nothing -> pure (M.empty, M.empty)

instance ToValue (AttrSet (JThunk s), AttrSet SourcePos) (Infer s) (Judgment s) where
    toValue (xs, _) = Judgment
        <$> foldrM go As.empty xs
        <*> (concat <$> traverse (`force` (pure . typeConstraints)) xs)
        <*> (TSet True <$> traverse (`force` (pure . inferredType)) xs)
      where
        go x rest = force x $ \x' -> pure $ As.merge (assumptions x') rest

instance ToValue [JThunk s] (Infer s) (Judgment s) where
    toValue xs = Judgment
        <$> foldrM go As.empty xs
        <*> (concat <$> traverse (`force` (pure . typeConstraints)) xs)
        <*> (TList <$> traverse (`force` (pure . inferredType)) xs)
      where
        go x rest = force x $ \x' -> pure $ As.merge (assumptions x') rest

instance ToValue Bool (Infer s) (Judgment s) where
    toValue _ = pure $ Judgment As.empty [] typeBool

infer :: NExpr -> Infer s (Judgment s)
infer = cata Eval.eval

inferTop :: Env -> [(Text, NExpr)] -> Either InferError Env
inferTop env [] = Right env
inferTop env ((name, ex):xs) = case inferExpr env ex of
  Left err -> Left err
  Right ty -> inferTop (extend env (name, ty)) xs

normalize :: Scheme -> Scheme
normalize (Forall _ body) = Forall (map snd ord) (normtype body)
  where
    ord = zip (nub $ fv body) (map TV letters)

    fv (TVar a)    = [a]
    fv (a :~> b)   = fv a ++ fv b
    fv (TCon _)    = []
    fv (TSet _ a)  = concatMap fv (M.elems a)
    fv (TList a)   = concatMap fv a
    fv (TMany ts)  = concatMap fv ts

    normtype (a :~> b)  = normtype a :~> normtype b
    normtype (TCon a)   = TCon a
    normtype (TSet b a) = TSet b (M.map normtype a)
    normtype (TList a)  = TList (map normtype a)
    normtype (TMany ts) = TMany (map normtype ts)
    normtype (TVar a)   =
      case Prelude.lookup a ord of
        Just x -> TVar x
        Nothing -> error "type variable not in signature"

-------------------------------------------------------------------------------
-- Constraint Solver
-------------------------------------------------------------------------------

newtype Solver m a = Solver (LogicT (StateT [TypeError] m) a)
    deriving (Functor, Applicative, Alternative, Monad, MonadPlus,
              MonadLogic, MonadState [TypeError])

instance MonadTrans Solver where
    lift = Solver . lift . lift

instance Monad m => MonadError TypeError (Solver m) where
    throwError err = Solver $ lift (modify (err:)) >> mzero
    catchError _ _ = error "This is never used"

runSolver :: Monad m => Solver m a -> m (Either [TypeError] [a])
runSolver (Solver s) = do
    res <- runStateT (observeAllT s) []
    pure $ case res of
        (x:xs, _) -> Right (x:xs)
        (_, es)   -> Left (nub es)

-- | The empty substitution
emptySubst :: Subst
emptySubst = mempty

-- | Compose substitutions
compose :: Subst -> Subst -> Subst
Subst s1 `compose` Subst s2 =
    Subst $ Map.map (apply (Subst s1)) s2 `Map.union` s1

unifyMany :: Monad m => [Type] -> [Type] -> Solver m Subst
unifyMany [] [] = return emptySubst
unifyMany (t1 : ts1) (t2 : ts2) =
  do su1 <- unifies t1 t2
     su2 <- unifyMany (apply su1 ts1) (apply su1 ts2)
     return (su2 `compose` su1)
unifyMany t1 t2 = throwError $ UnificationMismatch t1 t2

allSameType :: [Type] -> Bool
allSameType [] = True
allSameType [_] = True
allSameType (x:y:ys) = x == y && allSameType (y:ys)

unifies :: Monad m => Type -> Type -> Solver m Subst
unifies t1 t2 | t1 == t2 = return emptySubst
unifies (TVar v) t = v `bind` t
unifies t (TVar v) = v `bind` t
unifies (TList xs) (TList ys)
    | allSameType xs && allSameType ys = case (xs, ys) of
          (x:_, y:_) -> unifies x y
          _ -> return emptySubst
    | length xs == length ys = unifyMany xs ys
-- We assume that lists of different lengths containing various types cannot
-- be unified.
unifies t1@(TList _) t2@(TList _) = throwError $ UnificationFail t1 t2
unifies (TSet True _) (TSet True _) = return emptySubst
unifies (TSet False b) (TSet True s)
    | M.keys b `intersect` M.keys s == M.keys s = return emptySubst
unifies (TSet True s) (TSet False b)
    | M.keys b `intersect` M.keys s == M.keys b = return emptySubst
unifies (TSet False s) (TSet False b)
    | null (M.keys b \\ M.keys s) = return emptySubst
unifies (t1 :~> t2) (t3 :~> t4) = unifyMany [t1, t2] [t3, t4]
unifies (TMany t1s) t2 = considering t1s >>- unifies ?? t2
unifies t1 (TMany t2s) = considering t2s >>- unifies t1
unifies t1 t2 = throwError $ UnificationFail t1 t2

bind :: Monad m => TVar -> Type -> Solver m Subst
bind a t | t == TVar a     = return emptySubst
         | occursCheck a t = throwError $ InfiniteType a t
         | otherwise       = return (Subst $ Map.singleton a t)

occursCheck ::  FreeTypeVars a => TVar -> a -> Bool
occursCheck a t = a `Set.member` ftv t

nextSolvable :: [Constraint] -> (Constraint, [Constraint])
nextSolvable xs = fromJust (find solvable (chooseOne xs))
  where
    chooseOne xs = [(x, ys) | x <- xs, let ys = delete x xs]

    solvable (EqConst{}, _)      = True
    solvable (ExpInstConst{}, _) = True
    solvable (ImpInstConst _t1 ms t2, cs) =
        Set.null ((ftv t2 `Set.difference` ms) `Set.intersection` atv cs)

considering :: [a] -> Solver m a
considering xs = Solver $ LogicT $ \c n -> foldr c n xs

solve :: MonadState InferState m => [Constraint] -> Solver m Subst
solve [] = return emptySubst
solve cs = solve' (nextSolvable cs)
  where
    solve' (EqConst t1 t2, cs) =
      unifies t1 t2 >>- \su1 ->
      solve (apply su1 cs) >>- \su2 ->
          return (su2 `compose` su1)

    solve' (ImpInstConst t1 ms t2, cs) =
      solve (ExpInstConst t1 (generalize ms t2) : cs)

    solve' (ExpInstConst t s, cs) = do
      s' <- lift $ instantiate s
      solve (EqConst t s' : cs)

instance Scoped (JThunk s) (Infer s) where
  currentScopes = currentScopesReader
  clearScopes = clearScopesReader @(Infer s) @(JThunk s)
  pushScopes = pushScopesReader
  lookupVar = lookupVarReader
