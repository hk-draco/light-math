module Type where
import Data.Char
import Data.List
import Data.Maybe
import Data.Monoid
import qualified Data.Map as M
import Control.Monad.Writer
import Control.Monad.State
import Control.Arrow
import Control.Applicative
import Parse
import Engine

type TypeMap = M.Map String Expr
data TypedExpr = TypedExpr Expr TypeMap

evalType:: TypeMap -> Expr -> Writer [Message] (Maybe Expr)
evalType tmap NumberExpr{} = return $ Just $ makeIdentExpr "N"
evalType tmap StringExpr{} = return $ Just $ makeIdentExpr "Char"
evalType tmap (IdentExpr ph@(_, h)) = maybe (writer (Nothing, [Message ph "Not defined"])) (return . Just) (M.lookup h tmap)
evalType tmap (FuncExpr (PureExprHead ph@(p, h)) as) = f $ \case
    FuncExpr (PureExprHead (_, "->")) [arg, ret] ->
        checkArgs as (getArgs arg) >>= \x-> return (if x then Just ret else Nothing)
    _ -> writer (Nothing, [Message ph "Not function"]) 
    where
    getArgs (FuncExpr (PureExprHead (_, "tuple")) xs) = xs
    getArgs x = [x]
    checkArgs:: [Expr] -> [Expr] -> Writer [Message] Bool
    checkArgs [] [] = return True
    checkArgs [] _ = writer (False, [Message ph "Too few arguments"])
    checkArgs _ [] = writer (False, [Message ph "Too many arguments"])
    checkArgs (a:as) (t:ts) = checkType >>= \x-> let (a, msgs) = runWriter (checkArgs as ts) in writer (a||x, msgs) where
        checkType:: Writer [Message] Bool
        checkType = evalType tmap a >>= maybe (return False) (\x-> if equals t x 
            then return True 
            else writer (False, [Message (showCodeExpr a) ("Couldn't match expected type '" ++ showExpr x ++ "' with actual type '" ++ showExpr t ++ "'")]))
    ftype = M.lookup h tmap
    f:: (Expr -> Writer [Message] (Maybe Expr)) -> Writer [Message] (Maybe Expr)
    f g = maybe (writer (Nothing, [Message ph "Not defined"])) g ftype

isIdentOf:: String -> Expr -> Bool
isIdentOf t (IdentExpr (_, s)) = t == s
isIdentOf _ _ = False

isTypeType:: Expr -> Bool
isTypeType = isIdentOf "Type"

extractArgs:: String -> Expr -> [Expr]
extractArgs s e@(FuncExpr (PureExprHead (_, s')) as) = if s == s' then concatMap (extractArgs s) as else [e]
extractArgs s e = [e]

makeFuncType:: [Expr] -> Expr -> Expr
makeFuncType [arg] ret = FuncExpr (makeExprHead "->") [arg, ret]
makeFuncType args ret = FuncExpr (makeExprHead "->") [(FuncExpr $ makeExprHead "tuple") args, ret]

addIdent:: String -> Expr -> TypeMap -> Writer [Message] TypeMap
addIdent i t m = return $ M.insert i t m

conjMaybe:: [Maybe a] -> Maybe [a]
conjMaybe [] = Just []
conjMaybe (x:xs) = (:) <$> x <*> conjMaybe xs

makeTypeMap:: [Decla] -> TypeMap -> Writer [Message] TypeMap
makeTypeMap [] = addIdent "Prop" (makeIdentExpr "Type")
makeTypeMap (x:xs) = (>>= makeTypeMap xs) . (getType x) where
    getType:: Decla -> TypeMap -> Writer [Message] TypeMap
    getType (DataType (p, t) def) = \m-> do
        m' <- addIdent t (makeIdentExpr "Type") m
        addCstr cstrs m'
        where
        thisType = makeIdentExpr t
        cstrs = extractArgs "|" def
        addCstr:: [Expr] -> TypeMap -> Writer [Message] TypeMap
        addCstr [] m = return m
        addCstr (IdentExpr (_, i):xs) m = addIdent i thisType m >>= addCstr xs
        addCstr (FuncExpr (PureExprHead (_, i)) as:xs) m = do
            argsm <- mapM (evalType m) as
            let run x = maybe (return m) x (conjMaybe argsm)
            run $ \args-> do
                let cstrType = makeFuncType args thisType
                m' <- addIdent i cstrType m
                addCstr xs m'
        addCstr e m = error $ show e
    getType (Undef (_, t) e) = addIdent t e
    getType (Define (_, t) args ret def) = addIdent t (makeFuncType (toTypes args) ret) where
    getType _ = return
    toTypes:: VarDec -> [Expr]
    toTypes ((i, t):xs) = t:toTypes xs

makeScope:: TypeMap -> VarDec -> Writer [Message] TypeMap
makeScope gm xs = makeScope' gm xs M.empty where
    makeScope' gm [] lm = return lm
    makeScope' gm ((ps@(p, s), e):xs) lm = evalType gm e
        >>= maybe (return lm) (\x-> if isTypeType x 
                then return $ M.insert s x lm 
                else writer (lm, [Message ps ("Not type")]))
        >>= makeScope' gm xs

makeScopedExpr:: TypeMap -> VarDec -> Expr -> Writer [Message] (Maybe TypedExpr)
makeScopedExpr gs vd e = makeScope gs vd >>= (return . Just . (TypedExpr e))

makeRules:: TypeMap -> [TypedExpr] -> Writer [Message] ([Rule], [Rule])
makeRules tmap [] = return ([], [])
makeRules tmap (x:xs) = do
    result <- makeRule x
    (ms, mi) <- makeRules tmap xs
    return $ case result of 
        Nothing-> (ms, mi)
        Just (isStep, r)-> if isStep then (r:ms, mi) else (ms, r:mi) 
    where
    -- expression -> (is step rule, rule)
    makeRule:: TypedExpr -> Writer [Message] (Maybe (Bool, Rule))
    makeRule (TypedExpr e@(FuncExpr (PureExprHead pk@(p, kind)) [a, b]) ls) = 
        let scope = M.union ls tmap in case kind of
        ">>=" -> do
            at' <- evalType scope a
            bt' <- evalType scope b
            case (at', bt') of 
                (Just at, Just bt)-> if equals a b
                    then return $ Just (True, (a, b)) 
                    else writer (Nothing, [Message pk $ x ++ y]) where
                        x = "Left side type is'" ++ showExpr at ++ "', "
                        y = "but right side type is'" ++ showExpr bt ++ "'"
                _-> return Nothing
        "->" -> do
            et' <- evalType scope e
            case et' of
                Just et-> if isIdentOf "Prop" et 
                    then return $ Just (False, (a, b))
                    else writer (Nothing, [Message pk $ "Couldn't match expected type 'Prop' with actual type '" ++ showExpr et ++ "'"])
                Nothing-> return Nothing
        f -> writer (Nothing, [Message pk "Wrong function"])
    makeRule (TypedExpr e _) = writer (Nothing, [Message (showCodeExpr e) "This is not a function"])

toRuleMap:: [Rule] -> RuleMap
toRuleMap rs = toRuleMap' M.empty $ groupBy equalsHead rs where
    equalsHead (FuncExpr h _, _) (FuncExpr h' _, _) = showHead h == showHead h'
    getHead:: [Rule] -> String
    getHead ((FuncExpr h _, _):_) = showHead h
    toRuleMap':: RuleMap -> [[Rule]] -> RuleMap
    toRuleMap' = foldl (\m r-> M.insert (getHead r) r m)

makeRuleMap:: TypeMap -> [TypedExpr] -> Writer [Message] (RuleMap, RuleMap, Simplicity)
makeRuleMap tmap xs = do
    (a, b) <- makeRules tmap xs
    simp <- makeSimp [] a
    let toAppSimp (a, b) = (appSimp simp a, appSimp simp b)
    let toMap = toRuleMap . map toAppSimp
    return (toMap a, toMap b, simp)

buildProgram:: String -> ((RuleMap, RuleMap, Simplicity), OpeMap, TypeMap, [Message])
buildProgram str = (rmap, omap, tmap, msgs ++ msgs' ++ msgs'') where
    (tmap, msgs') = runWriter $ makeTypeMap declas M.empty
    (rmap, msgs) = runWriter $ makeRuleMap tmap props
    ((declas, omap), rest) = runState parseProgram . tokenize $ str
    (props', msgs'') = runWriter $ mapM toProp declas
    props = extractMaybe props'
    toProp:: Decla -> Writer [Message] (Maybe TypedExpr)
    toProp (Axiom ls p) = makeScopedExpr tmap ls p
    toProp (Theorem ls p _) = makeScopedExpr tmap ls p
    toProp _ = return Nothing