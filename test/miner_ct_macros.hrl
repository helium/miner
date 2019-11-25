-define(ASYNC_DELAY, 100).
-define(ASYNC_RETRIES, 40).

-define(assertAsync(Expr, BoolExpr, ExprRetry, ExprDelay),
    Res = miner_ct_utils:wait_until(fun() -> (Expr),(BoolExpr) end, ExprRetry, ExprDelay),
    ct:pal("Async Res: ~p for expr: ~p", [Res, ??BoolExpr]),
    case Res of
        false -> 
            erlang:error({assert,
                    [{module, ?MODULE},
                      {line, ?LINE},
                      {expression, (??BoolExpr)},
                      {expected, true},
                      {value ,Res}
                    ]
            });
        _ -> 
            Res
    end).

