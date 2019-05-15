module Parse(someFunc) where
import Data.Char
import Data.List
import Data.Maybe
import Data.Monoid
import qualified Data.Foldable as F
import qualified Data.Map as M
import Control.Monad
import Control.Monad.Writer
import Control.Monad.State
import Control.Arrow

data Token = EndLine | Ident String | Number Int 
    | Literal String | LiteralOne Char | Symbol String 
    | Comma | ParenOpen | ParenClose | Error String String deriving (Eq, Show)
tokenize :: String -> [Token]
tokenize [] = []
tokenize all = (\(x, xs)-> maybe xs (:xs) x) $ tokenize <$> getToken all where
    getToken :: String -> (Maybe Token, String)
    getToken [] = (Nothing, [])
    getToken (x:xs)
        | isDigit x = make (Number . read) isDigit
        | isIdentHead x = make Ident isIdentBody
        | isOperator x = make Symbol isOperator
        | isBracket x = (Just $ toSymbol [x], xs)
        | x == '"' = make' Literal ('"' /=)
        | x == '#' = first (const Nothing) $ span ('\n' /=) xs
        | x == '\'' = make' toChar ('\'' /=)
        | isSpace x = (Nothing, xs)
        | otherwise = (Just $ Error [x] "wrong", xs)
        where
            -- (token constructor, tail condition) -> (token, rest string)
            make f g = first (Just . f . (x:)) $ span g xs
            make' f g = fmap (drop 1) $ first h $ span g xs
                where h all = Just $ case all of [] -> Error all "no"; _ -> f all
            -- Char -> Bool
            [isIdentSymbol, isOperator, isBracket] = map (flip elem) ["_'" , "+-*/\\<>|?=@^$:~`.", "(){}[],"]
            [isIdentHead, isIdentBody] = map any [[isLetter, ('_' ==)], [isLetter, isDigit, isIdentSymbol]]
                where any = F.foldr ((<*>) . (<$>) (||)) $ const False
            -- String -> Token
            toChar all = case all of [x] -> LiteralOne x; [] -> Error all "too short"; (x:xs) -> Error all "too long"
            toSymbol all = case all of "(" -> ParenOpen; ")" -> ParenClose; "," -> Comma; _ -> Symbol all

data Expr = IdentExpr String | FuncExpr Token [Expr] | StringExpr String | NumberExpr Int | Rewrite Rule Expr Expr deriving (Show, Eq)
parseExpr:: State [Token] (Maybe Expr)
parseExpr = state $ \ts-> parseExpr ts [] [] where--4
    -- (input tokens, operation stack, expression queue) -> (expression, rest token)
    parseExpr:: [Token] -> [(Token, Int)] -> [Expr] -> (Maybe Expr, [Token])
    parseExpr [] s q = (Just $ head $ makeExpr s q, [])
    parseExpr all@(x:xs) s q = case x of
        Error t m   -> (Nothing, all)
        Number n    -> maybeEnd $ parseExpr xs s (NumberExpr n:q)
        Ident i     -> maybeEnd $ if xs /= [] && head xs == ParenOpen
            then parseExpr xs ((x, 1):s) q
            else parseExpr xs s (IdentExpr i:q)
        ParenOpen   -> maybeEnd $ parseExpr xs ((x, 2):s) q -- 2 args for end condition
        ParenClose  -> maybeEnd $ parseExpr xs rest $ makeExpr opes q where
            (opes, _:rest) = span ((/= ParenOpen) . fst) s
        Comma       -> maybeEnd $ parseExpr xs rest $ makeExpr opes q where
            isIdent x    = case x of Ident _ -> True; _ -> False
            incrementArg = apply (isIdent . fst) (fmap (1+))
            (opes, rest) = incrementArg <$> span ((/= ParenOpen) . fst) s
        Symbol ope  -> case getOpe ope of 
            Just _      -> parseExpr xs ((x, 2):rest) $ makeExpr opes q where
                (opes, rest) = span (precederEq ope . fst) s
            Nothing     -> result 
        where
            result = (Just $ head $ makeExpr s q, all)
            maybeEnd a = if sum (map ((-1+) . snd) s) + 1 == length q then result else a
    -- ((operator or function token, argument number), input) -> output
    makeExpr:: [(Token, Int)] -> [Expr] -> [Expr]
    makeExpr [] q = q
    makeExpr ((t, n):os) q = makeExpr os $ FuncExpr t args:rest
        where (args, rest) = (reverse $ take n q, drop n q)
    -- apply 'f' to a element that satisfy 'cond' for the first time
    apply cond f all = case b of [] -> all; (x:xs) -> a ++ f x:xs
        where (a, b) = span (not <$> cond) all
    -- String -> (preceed, left associative)
    getOpe = flip M.lookup $ M.fromList 
        [("+", (0, True)), ("-", (0, True)), ("*", (1, True)), ("/", (1, True)), ("^", (2, False))]
    precederEq:: String -> Token -> Bool
    precederEq s ParenOpen = False
    precederEq s (Ident _) = True
    precederEq s (Symbol t) = precederEq' $ map getOpe' [s, t] where
        precederEq' [(aPre, aLeft), (bPre, bLeft)] = bLeft && ((aLeft && aPre <= bPre) || aPre < bPre)
        getOpe' = fromMaybe (0, True) . getOpe

pand:: State [Token] (Maybe (a->b)) -> State [Token] (Maybe a) -> State [Token] (Maybe b)
pand f a = f >>= maybe (return Nothing) (\f'-> fmap f' <$> a)

expect:: State [Token] (Maybe a) -> State [Token] (Maybe b) -> State [Token] (Maybe a)
expect f a = f >>= maybe (return Nothing) (\f'-> maybe Nothing (const $ Just f') <$> a)

parseSequence:: State [Token] (Maybe a)-> State [Token] (Maybe [a])
parseSequence p = p >>= \case
    Just x' -> parseSequence p >>= \case
        Just s' -> return $ Just (x':s')
        Nothing -> return Nothing
    Nothing -> return $ Just []
    
parseToken:: Token -> State [Token] (Maybe Token) 
parseToken x = state $ \case
    [] -> (Nothing, [])
    all@(t:ts) -> if t == x then (Just x, ts) else (Nothing, all)
parseSymbol x = parseToken (Symbol x)
parseIdent = state $ \case
    [] -> (Nothing, [])
    all@(t:ts) -> case t of Ident i-> (Just i, ts); _-> (Nothing, all)

parseSeparated:: State [Token] (Maybe s) -> State [Token] (Maybe a) -> State [Token] (Maybe [a]) 
parseSeparated s p = p >>= \case
    Just x' -> s >>= \case
        Just _ -> parseSeparated s p >>= \case
            Just r' -> return $ Just (x':r')
            Nothing -> return Nothing
        Nothing -> return $ Just [x']
    Nothing -> return $ Just []
parseCommaSeparated = parseSeparated $ parseToken Comma

data VarDecSet = VarDecSet [String] Expr deriving (Show)
parseVarDecSet:: State [Token] (Maybe VarDecSet)
parseVarDecSet = return (Just VarDecSet) `pand` parseCommaSeparated parseIdent `expect` parseSymbol ":" `pand` parseExpr

data Statement = StepStm Expr | ImplStm Expr | AssumeStm Expr [Statement] | BlockStm String Expr [Statement] deriving (Show)
parseStatement:: State [Token] (Maybe Statement)
parseStatement = parseIdent >>= \case
    Just "step" -> return (Just StepStm) `pand` parseExpr
    Just "impl" -> return (Just ImplStm) `pand` parseExpr
    Just "assume" -> return (Just AssumeStm) `pand` parseExpr `pand` parseBlock
    _ -> return Nothing 
    where parseBlock = return (Just id) `expect` parseSymbol "{" `pand` parseSequence parseStatement `expect` parseSymbol "}"

type VarDec = [(String, Expr)]
parseVarDecs:: State [Token] (Maybe VarDec)
parseVarDecs = fmap conv (parseCommaSeparated parseVarDecSet) where
    toTuple (VarDecSet ns t) = (ns, repeat t)
    conv = Just . concatMap (uncurry zip) . maybe [] (map toTuple)
parseParenVarDecs = return (Just id) `expect` parseToken ParenOpen `pand` parseVarDecs `expect` parseToken ParenClose

data Decla = Axiom VarDec Expr | Theorem VarDec Expr [Statement] 
    | Define String VarDec Expr | Predicate String String Expr VarDec Expr deriving (Show)
parseDecla:: Maybe String -> State [Token] (Maybe Decla)
parseDecla (Just "axiom") = return (Just Axiom)
    `pand` parseParenVarDecs 
    `expect` parseSymbol "{" `pand` parseExpr `expect` parseSymbol "}"
parseDecla (Just "theorem") = return (Just Theorem) 
    `pand` parseParenVarDecs 
    `expect` parseSymbol "{" 
    `pand` parseExpr 
    `expect` parseToken (Ident "proof") `expect` parseSymbol ":" `pand` parseSequence parseStatement
    `expect` parseSymbol "}"
parseDecla (Just "define") = return (Just Define)
    `pand` parseIdent
    `pand` parseParenVarDecs 
    `expect` parseSymbol "{" `pand` parseExpr `expect` parseSymbol "}"
parseDecla (Just "predicate") = return (Just Predicate)
    `pand` parseIdent
    `expect` parseSymbol "[" `pand` parseIdent `expect` parseSymbol ":" `pand` parseExpr `expect` parseSymbol "]"
    `pand` parseParenVarDecs
    `expect` parseSymbol "{" `pand` parseExpr `expect` parseSymbol "}"
parseDecla _ = return Nothing

parseProgram:: State [Token] (Maybe [Decla])
parseProgram = parseSequence $ parseIdent >>= parseDecla

type Rule = (Expr, Expr)
makeRules:: [Expr] -> ([Rule], [Rule])
makeRules (x:xs) = if isStep then (r:ms, mi) else (ms, r:mi) where 
    (isStep, r) = makeRule x
    (ms, mi) = makeRules xs
    -- expression -> (is step rule, rule)
    makeRule:: Expr -> (Bool, Rule)
    makeRule (FuncExpr (Symbol kind) [a, b]) = case kind of
        ">>=" -> (True, (a, b))
        "->" -> (False, (a, b))

type Simplicity = [Token]
makeSimplicity:: Simplicity -> [Rule] -> Simplicity
makeSimplicity m [] = m
makeSimplicity m ((a, b):rs) = makeSimplicity (addSimplicity m a b) rs where
    addSimplicity:: Simplicity -> Expr -> Expr -> Simplicity
    addSimplicity m (FuncExpr a _) (FuncExpr b _) = addSimplicity' m a b where
        addSimplicity' m a b = case (elemIndex a m, elemIndex b m) of
            (Just a', Just b') -> if a' > b' then error "error" else m
            (Just a', Nothing) -> insertAt b a' m
            (Nothing, Just b') -> insertAt a (b'+1) m
            (Nothing, Nothing) -> b:a:m
    addSimplicity m _ _ = m
    insertAt:: a -> Int -> [a] -> [a]
    insertAt xs 0 as = xs:as
    insertAt xs i (a:as) = a : insertAt xs (i - 1) as

unify:: Expr -> Expr -> (Bool, M.Map String Expr)
unify p t = (runState $ unifym p t) M.empty where
    unifym:: Expr -> Expr -> State (M.Map String Expr) Bool 
    unifym (IdentExpr var) t = state $ \m-> maybe (True, M.insert var t m) (\x-> (x==t, m)) $ M.lookup var m
    unifym (NumberExpr n) (NumberExpr n') = return $ n == n'
    unifym (NumberExpr _) _ = return False
    unifym (FuncExpr f ax) (FuncExpr f' ax') = (and $ unifym' ax ax') (f == f') where
        and f r = if r then f else return False
        unifym' (e:ex) (e':ex') = unifym e e' >>= and (unifym' ex ex')
    unifym (FuncExpr _ _) _ = return False

assign:: M.Map String Expr -> Expr -> Expr
assign m e@(IdentExpr var) = fromMaybe e $ M.lookup var m
assign m (FuncExpr f args) = FuncExpr f $ map (assign m) args
assign m e = e

equals:: (Expr, Expr) -> Bool
equals (Rewrite _ n _, t) = equals (n, t)
equals (t, Rewrite _ n _) = equals (t, n)
equals (a, b) = a == b

applyDiff:: Derivater -> (Expr, Expr) -> Maybe Expr
applyDiff d pair@(FuncExpr f as, FuncExpr g bs) = if f == g 
    then case num of
        0 -> Nothing
        1 -> maybe Nothing makeExpr $ applyDiff d x where
            (xs', x:xs) = splitAt idx args
            makeExpr t = Just $ FuncExpr f ((map fst xs') ++ t:(map fst xs))
        _ -> d pair
    else d pair where 
        args = zip as bs
        es = fmap equals $ args
        (idx, num) = encount True es
        -- (element, list) -> (index of the first encountered element, number of encounters)
        encount:: Eq a => a -> [a] -> (Int, Int)
        encount = encount' (-1, 0) where
            encount' p _ [] = p
            encount' (i, n) e (x:xs) = encount' (if n > 0 then i else i + 1, if e == x then n + 1 else n) e xs

type Derivater = (Expr, Expr) -> Maybe Expr
derviate:: Rule -> Derivater
derviate (a, b) (ea, eb) = if isMatch && isMatch' then Just $ assign map eb else Nothing where 
    (isMatch, map) = unify a ea
    (isMatch', _) = unify b eb

derviateDiff:: Rule -> Derivater
derviateDiff d = applyDiff $ derviate d

simplify:: [Rule] -> Expr -> Expr
simplify m e@(FuncExpr h args) = apply' e m where
    e' = FuncExpr h $ map (simplify m) args
    apply' e [] = e
    apply' e (r:rs) = apply' (apply e r) rs
    apply:: Rule -> Expr -> Maybe Expr
    apply (a, b) e = if isMatch then Just $ assign map b else Nothing where (isMatch, map) = unify a e
--addDecra (Axiom vars expr) = 

getTokenTest line = show token ++ ":" ++ rest where (token, rest) = getToken line
tokenizeTest line = intercalate "," $ map show $ tokenize line
parserTest x = show . runState x . tokenize

test x = forever $ getLine >>= (putStrLn . x)
someFunc = test $ parserTest $ parseVarDecs
