module Supercompile (supercompileProgram, supercompileProgramSelective) where

-- FIXME: I need to document the basis on which I push down unlifted heap bindings
-- TODO:
--  * Why does the supercompiler not match as much as it should? (e.g. Interpreter, UInterpreter)
--  * Does the matcher match the types of variables bound in the heap?

import Supercompile.Utilities
import qualified Supercompile.Core.Syntax as S
import qualified Supercompile.Core.FreeVars as S
import qualified Supercompile.Evaluator.Syntax as S
import qualified Supercompile.Drive.Process1 as S ()
import qualified Supercompile.Drive.Process2 as S ()
import qualified Supercompile.Drive.Process3 as S

import BasicTypes (InlinePragma(..), InlineSpec(..), isActiveIn)
import CoreSyn
import CoreFVs    (exprFreeVars)
import CoreUtils  (exprType, bindNonRec)
import CoreUnfold (exprIsConApp_maybe)
import Coercion   (Coercion, isCoVar, isCoVarType, mkCoVarCo, mkAxInstCo)
import DataCon    (DataCon, dataConWorkId, dataConAllTyVars, dataConRepArgTys, dataConTyCon, dataConName)
import VarSet
import VarEnv
import Name       (localiseName, mkSystemName)
import OccName    (mkVarOcc)
import Var        (Var, isTyVar, varUnique, varName, setVarName)
import Id
import MkId       (mkPrimOpId)
import FastString (mkFastString, fsLit)
import PrelNames  (undefinedName)
import PrimOp     (primOpSig)
import Type       (mkTyVarTy, mkForAllTy, mkFunTys, isUnLiftedType)
import TysPrim    (alphaTyVar, argAlphaTyVar)
import TyCon      (newTyConCo_maybe)

import Control.Monad
import qualified Data.Map as M

topUnique :: Unique
anfUniqSupply' :: UniqSupply
(topUnique, anfUniqSupply') = takeUniqFromSupply anfUniqSupply


-- | Descriptions of terms: used for building readable names for ANF-introduced variables
data Description = Opaque String | ArgumentOf Description

descriptionString :: Description -> String
descriptionString = go (0 :: Int)
  where
    go n (Opaque s)     = s ++ (if n > 0 then show n else "")
    go n (ArgumentOf d) = go (n + 1) d

desc :: S.Term -> Description
desc = desc' . unI

desc' :: S.TermF Identity -> Description
desc' (S.Var x)            = Opaque (S.varString x)
desc' (S.Value _)          = Opaque "value"
desc' (S.TyApp e1 _)       = argOf (desc e1)
desc' (S.CoApp e1 _)       = argOf (desc e1)
desc' (S.App e1 _)         = argOf (desc e1)
desc' (S.PrimOp pop as es) = foldr (\() d -> argOf d) (Opaque (show pop)) (map (const ()) as ++ map (const ()) es)
desc' (S.Case _ _ _ _)     = Opaque "case"
desc' (S.Cast _ _)         = Opaque "cast"
desc' (S.Let _ _ e)        = desc e
desc' (S.LetRec _ e)       = desc e

argOf :: Description -> Description
argOf = ArgumentOf


newtype ParseM a = ParseM { unParseM :: UniqSupply -> (UniqSupply, [(Var, S.Term)], a) }

instance Functor ParseM where
    fmap = liftM

instance Monad ParseM where
    return x = ParseM $ \s -> (s, [], x)
    mx >>= fxmy = ParseM $ \s -> case unParseM mx s of (s, floats1, x) -> case unParseM (fxmy x) s of (s, floats2, y) -> (s, floats1 ++ floats2, y)

instance MonadUnique ParseM where
    getUniqueSupplyM = ParseM $ \us -> case splitUniqSupply us of (us1, us2) -> (us1, [], us2)

runParseM' :: ParseM a -> ([(Var, S.Term)], a)
runParseM' act = (floats, x)
  where (_s, floats, x) = unParseM act anfUniqSupply'

runParseM :: ParseM S.Term -> S.Term
runParseM = uncurry (S.bindManyMixedLiftedness S.termFreeVars) . runParseM'

freshFloatId :: String -> S.Term -> ParseM (Maybe (Var, S.Term), Var)
freshFloatId _ (I (S.Var x)) = return (Nothing, x)
freshFloatId n e             = fmap (\x -> (Just (x, e), x)) $ mkSysLocalM (mkFastString n) (S.termType e)

freshFloatCoVar :: String -> S.Term -> ParseM (Maybe (Var, S.Term), Coercion)
freshFloatCoVar _ (I (S.Value (S.Coercion co))) = return (Nothing, co)
freshFloatCoVar n e                             = fmap (\x -> (Just (x, e), mkCoVarCo x)) $ mkSysLocalM (mkFastString n) (S.termType e)

floatIt :: [(Var, S.Term)] -> ParseM ()
floatIt floats = ParseM $ \s -> (s, floats, ())

nameIt :: Description -> S.Term -> ParseM Var
nameIt d e = freshFloatId ("a" ++ descriptionString d) e >>= \(mb_float, x) -> floatIt (maybeToList mb_float) >> return x

nameCo :: Description -> S.Term -> ParseM Coercion
nameCo d e = freshFloatCoVar ("c" ++ descriptionString d) e >>= \(mb_float, co) -> floatIt (maybeToList mb_float) >> return co

bindFloats :: ParseM S.Term -> ParseM S.Term
bindFloats = bindFloatsWith . fmap ((,) [])

bindFloatsWith :: ParseM ([(Var, S.Term)], S.Term) -> ParseM S.Term
bindFloatsWith act = ParseM $ \s -> case unParseM act s of (s, floats, (xes, e)) -> (s, [], S.bindManyMixedLiftedness S.termFreeVars (xes ++ floats) e)

bindUnliftedFloats :: ParseM S.Term -> ParseM S.Term
bindUnliftedFloats act = ParseM $ \s -> case unParseM act s of (s, floats, e) -> if any (isUnLiftedType . idType . fst) floats
                                                                                 then (s, [], S.bindManyMixedLiftedness S.termFreeVars floats e)
                                                                                 else (s, floats, e)

appE :: S.Term -> S.Term -> ParseM S.Term
appE e1 e2
  | isCoVarType (S.termType e2) = fmap (e1 `S.coApp`) $ nameCo (argOf (desc e1)) e2
  | otherwise                   = fmap (e1 `S.app`)   $ nameIt (argOf (desc e1)) e2



conAppToTerm :: DataCon -> [CoreExpr] -> ParseM S.Term
conAppToTerm dc es
  | Just co_axiom <- newTyConCo_maybe (dataConTyCon dc)
  , let [co_val_e] = co_val_es -- NB: newtypes may not have existential arguments
  = fmap (`S.cast` mkAxInstCo co_axiom tys') $ coreExprToTerm co_val_e
  | otherwise
  = do -- Convert all arguments to supercompiler syntax and divide into type/coercion/value
       co_val_es' <- mapM coreExprToTerm co_val_es
       let (co_es', val_es') = span (isCoVarType . S.termType) co_val_es'
 
       -- Put each argument into a form suitable for an explicit value
       -- NB: if any argument is non-trivial then the resulting binding will not be a simple value
       -- (some let-bindings will surround it) and inlining will be impeded.
       (d, cos') <- mapAccumLM (\d co_e' -> fmap ((,) (argOf d)) $ nameCo (argOf d) co_e')
                               (Opaque (S.nameString (dataConName dc))) co_es'
       (_, xs') <- mapAccumLM (\d val_e' -> fmap ((,) (argOf d)) $ nameIt (argOf d) val_e')
                              d val_es'
       return $ S.value (S.Data dc tys' cos' xs')
  where
    (tys', co_val_es) = takeWhileJust fromType_maybe es

    fromType_maybe (Type ty) = Just ty
    fromType_maybe _         = Nothing

coreExprToTerm :: CoreExpr -> ParseM S.Term
coreExprToTerm = term
  where
    -- PrimOp and (partially applied) Data are dealt with later on by generating appropriate unfoldings
    -- We use exprIsConApp_maybe here to ensure we desugar explicit constructor use into something that looks cheap
    term e | Just (dc, univ_tys, es) <- exprIsConApp_maybe (const NoUnfolding) e
           = conAppToTerm dc (map Type univ_tys ++ es)
    term (Var x)                   = return $ S.var x
    term (Lit l)                   = return $ S.value (S.Literal l)
    term (App e_fun (Type ty_arg)) = fmap (flip S.tyApp ty_arg) (term e_fun)
    term (App e_fun e_arg)         = join $ liftM2 appE (term e_fun) (maybeUnLiftedTerm (exprType e_arg) e_arg)
    term (Lam x e) | isTyVar x     = fmap (S.value . S.TyLambda x) (bindFloats (term e))
                   | otherwise     = fmap (S.value . S.Lambda x) (bindFloats (term e))
    term (Let (NonRec x e1) e2)    = liftM2 (S.let_ x) (maybeUnLiftedTerm (idType x) e1) (bindFloats (term e2))
    term (Let (Rec xes) e)         = bindFloatsWith (liftM2 (,) (mapM (secondM term) xes) (term e))
    term (Case e x ty alts)        = liftM2 (\e alts -> S.case_ e x ty alts) (term e) (mapM alt alts)
    term (Cast e co)               = fmap (flip S.cast co) (term e)
    term (Note _ e)                = term e -- FIXME: record notes
    term (Type ty)                 = pprPanic "termToCoreExpr" (ppr ty)
    term (Coercion co)             = return $ S.value (S.Coercion co)
    
    -- We can float unlifted bindings out of an unlifted argument/let
    -- because they were certain to be evaluated anyway. Otherwise we have
    -- to residualise all the floats if any of them were unlifted.
    maybeUnLiftedTerm ty e
      | isUnLiftedType ty = term e
      | otherwise         = bindUnliftedFloats (term e)

    alt (DEFAULT,    [], e) = fmap ((,) S.DefaultAlt)            $ bindFloats (term e)
    alt (LitAlt l,   [], e) = fmap ((,) (S.LiteralAlt l))        $ bindFloats (term e)
    alt (DataAlt dc, xs, e) = fmap ((,) (S.DataAlt dc as qs zs)) $ bindFloats (term e)
      where (as, ys) = span isTyVar xs
            (qs, zs) = span isCoVar ys
    alt it                  = pprPanic "termToCoreExpr" (ppr it)

termToCoreExpr :: S.Term -> CoreExpr
termToCoreExpr = term
  where
    term e = case unI e of
        S.Var x             -> Var x
        S.Value v           -> value v
        S.TyApp e ty        -> term e `App` Type ty
        S.CoApp e co        -> term e `App` Coercion co
        S.App e x           -> term e `App` Var x
        S.PrimOp pop tys es -> Var (mkPrimOpId pop) `mkTyApps` tys `mkApps` map term es
        S.Case e x ty alts  -> Case (term e) x ty (map alt alts)
        S.Let x e1 e2       -> bindNonRec x (term e1) (term e2)
        S.LetRec xes e      -> Let (Rec (map (second term) xes)) (term e)
        S.Cast e co         -> Cast (term e) co
    
    value (S.Indirect x)         = Var x
    value (S.Literal l)          = Lit l
    value (S.Coercion co)        = Coercion co
    value (S.TyLambda a e)       = Lam a (term e)
    value (S.Lambda x e)         = Lam x (term e)
    value (S.Data dc tys cos xs) = ((Var (dataConWorkId dc) `mkTyApps` tys) `mkCoApps` cos) `mkVarApps` xs
    
    alt (S.DataAlt dc as qs ys, e) = (DataAlt dc, as ++ qs ++ ys, term e)
    alt (S.LiteralAlt l,        e) = (LitAlt l,   [],             term e)
    alt (S.DefaultAlt,          e) = (DEFAULT,    [],             term e)

-- Split input bindings into two lists:
--  1) CoreBinds binding variables with at least one binder marked by the predicate,
--     and any CoreBinds that those CoreBinds transitively refer to
--  2) The remaining CoreBinds. These may refer to those CoreBinds but are not referred
--     to *by* them
--
-- As a bonus, it returns the free variables of the bindings in the second list.
--
-- NB: assumes no-shadowing at the top level. I don't want to have to rename stuff to
-- commute CoreBinds...
partitionBinds :: (Id -> Bool) -> [CoreBind] -> ([CoreBind], [CoreBind], S.FreeVars)
partitionBinds should_sc initial_binds = go initial_inside [(b, unionVarSets (map S.idFreeVars (bindersOf b) ++ map exprFreeVars (rhssOfBind b))) | b <- initial_undecided]
  where
    (initial_inside, initial_undecided) = partition (any should_sc . bindersOf) initial_binds
    
    go :: [CoreBind] -> [(CoreBind, S.FreeVars)] -> ([CoreBind], [CoreBind], S.FreeVars)
    go inside undecided
        | null inside' = (inside, map fst undecided, unionVarSets (map snd undecided))
        | otherwise    = first3 (inside ++) $ go (map fst inside') undecided'
      where
        -- Move anything inside that refers to a binding that was moved inside last round
        (inside', undecided') = partition (\(_, fvs) -> inside_bs `intersectsVarSet` fvs) undecided
        inside_bs = mkVarSet [x | b <- inside, x <- bindersOf b]

coreBindsToCoreTerm :: (Id -> Bool) -> [CoreBind] -> (CoreExpr, Var -> [CoreBind])
coreBindsToCoreTerm should_sc binds
  = (mkLets internal_sc_binds (mkChurchVarTup sc_internal_xs),
     \y -> [NonRec x (mkChurchTupleSelector sc_internal_xs internal_x (Var y)) | (x, internal_x) <- sc_xs_internal_xs] ++ dont_sc_binds)
  where
    -- We put all the sc_binds into a local let, and use Church-encoded tuples to bind back to the top level the names of
    -- any of those sc_binds that are either exported *or* in the free variables of something from dont_sc_binds.
    -- Making that list as small as possible allows the supercompiler to determine that more things are used linearly.
    --
    -- We used to use a standard "big tuple" to do the binding-back, but this breaks down if we need to include
    -- some variables of unlifted type (of kind #) or a dictionary (of kind Constraint) since the type arguments of
    -- the (,..,) tycon must be of kind *.
    (sc_binds, dont_sc_binds, dont_sc_binds_fvs) = partitionBinds should_sc binds
    
    -- This is a sweet hack. Most of the top-level binders will be External names. It is a Bad Idea to locally-bind
    -- an External name, because several Externals with the same name but different uniques will generate clashing
    -- C labels at code-generation time (the unique is not included in the label).
    --
    -- To work around this, we deexternalise the variables at the *local binding sites* we are about to create.
    -- Note that we leave the *use sites* totally intact: we rely on the fact that a) variables are compared only by
    -- unique and b) the internality of these names will be carried down on the next simplifier run, so this works.
    -- The ice is thin, though!
    sc_xs = bindersOfBinds sc_binds
    internal_sc_binds = [case bind of NonRec x e -> NonRec (localiseVar x) e
                                      Rec xes    -> Rec (map (first localiseVar) xes)
                        | bind <- sc_binds]
    sc_xs_internal_xs = filter (\(x, _) -> isExportedId x || x `elemVarSet` dont_sc_binds_fvs) (sc_xs `zip` bindersOfBinds internal_sc_binds)
    sc_internal_xs = map snd sc_xs_internal_xs
    localiseVar x = setIdNotExported (x `setVarName` localiseName (varName x))
     -- If we don't mark these Ids as not exported then we get lots of residual top-level bindings of the form x = y

mkChurchVarTup :: [Id] -> CoreExpr
mkChurchVarTup []             = Var (mkVanillaGlobal undefinedName (mkForAllTy alphaTyVar (mkTyVarTy alphaTyVar)))
mkChurchVarTup xs@(first_x:_) = Lam argAlphaTyVar $ Lam k $ Var k `mkVarApps` xs
  where iss = mkInScopeSet (mkVarSet xs)
        -- Gin up a name for the continuation argument from spit, glue, and an exhaustive set of shadowed names
        --
        -- FIXME: We have to lie and use argAlphaTyVar here because we want to instantiate it with types of
        -- kind * and of kind Constraint.
        --
        -- The lie is that instantiation with types of kind # would be very bad!! Luckily this never happens
        -- since the top level can never bind an unlifted value.
        k = uniqAway iss $ mkLocalId (mkSystemName (varUnique first_x) (mkVarOcc "k"))
                                     (map idType xs `mkFunTys` mkTyVarTy argAlphaTyVar)

mkChurchTupleSelector :: [Var] -> Var -> CoreExpr -> CoreExpr
mkChurchTupleSelector xs want_x tup_e = tup_e `App` Type (idType want_x) `App` mkLams xs (Var want_x)

termUnfoldings :: S.Term -> [(Var, S.Term)]
termUnfoldings e = go (S.termFreeVars e) emptyVarSet []
  where
    go new_fvs all_fvs all_xes
      | isEmptyVarSet added_fvs = all_xes
      | otherwise               = go (unionVarSets (map (S.termFreeVars . snd) added_xes)) (all_fvs `unionVarSet` added_fvs) (added_xes ++ all_xes)
      where added_fvs = new_fvs `minusVarSet` all_fvs
            added_xes = [ (x, e)
                        | x <- varSetElems added_fvs
                        , Just e <- [varUnfolding x]]

    varUnfolding x
      | Just pop <- isPrimOpId_maybe x     = Just $ primOpUnfolding pop
      | Just dc <- isDataConWorkId_maybe x = Just $ dataUnfolding dc
      | not (shouldExposeUnfolding x)      = Nothing
      | otherwise                          = case realIdUnfolding x of
        NoUnfolding                   -> Nothing
        OtherCon _                    -> Nothing
        DFunUnfolding _ dc es         -> Just $ runParseM $ conAppToTerm dc es
        CoreUnfolding { uf_tmpl = e } -> Just $ runParseM $ coreExprToTerm e
         -- NB: it's OK if the unfolding is a non-value, as the evaluator won't inline LetBound non-values
    
    -- We don't want to expose an unfolding if it would not be inlineable in the initial phase.
    -- This gives normal RULES more of a chance to fire.
    shouldExposeUnfolding x = case inl_inline inl_prag of
        Inline          -> True
        Inlinable       -> True
        NoInline        -> isActiveIn 2 (inl_act inl_prag)
        EmptyInlineSpec -> True
      where inl_prag = idInlinePragma x
    
    primOpUnfolding pop = S.tyLambdas as $ S.lambdas xs $ S.primOp pop (map mkTyVarTy as) (map S.var xs)
      where (as, arg_tys, _res_ty, _arity, _strictness) = primOpSig pop
            xs = zipWith (mkSysLocal (fsLit "x")) bv_uniques arg_tys
    
    dataUnfolding dc
      | Just co_axiom <- newTyConCo_maybe (dataConTyCon dc)
      , let [x] = xs
      = S.tyLambdas as $ S.lambdas [x] $ S.var x `S.cast` mkAxInstCo co_axiom (map mkTyVarTy as)
      | otherwise
      = S.tyLambdas as $ S.lambdas xs $ S.value (S.Data dc (map mkTyVarTy as) (map mkCoVarCo qs) ys)
      where as = dataConAllTyVars dc
            arg_tys = dataConRepArgTys dc
            xs = zipWith (mkSysLocal (fsLit "x")) bv_uniques arg_tys
            (qs, ys) = span isCoVar xs

    -- It doesn't matter if we reuse Uniques here because by construction they can't shadow other uses of the anfUniqSupply'
    bv_uniques = uniqsFromSupply anfUniqSupply'

supercompile :: CoreExpr -> IO CoreExpr
supercompile e = -- liftM (termToCoreExpr . snd) $
                 return $ termToCoreExpr $
                 S.supercompile (M.fromList unfs) e'
  where unfs = termUnfoldings e'
        e' = runParseM (coreExprToTerm e)

supercompileProgram :: [CoreBind] -> IO [CoreBind]
supercompileProgram = supercompileProgramSelective (const True)

supercompileProgramSelective :: (Id -> Bool) -> [CoreBind] -> IO [CoreBind]
supercompileProgramSelective should_sc binds = liftM (\e' -> NonRec x e' : rebuild x) (supercompile e)
  where x = mkSysLocal (fsLit "sc") topUnique (exprType e)
        (e, rebuild) = coreBindsToCoreTerm should_sc binds