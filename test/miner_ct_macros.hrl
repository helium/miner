-define(ASYNC_DELAY, 100).
-define(ASYNC_RETRIES, 40).

-define(assertAsync(Expr, BoolExpr, ExprRetry, ExprDelay),
    Res = miner_ct_utils:wait_until(fun() -> (Expr),(BoolExpr) end, ExprRetry, ExprDelay),
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

%% version of the above but without a final bool expression and no error assert upon failure
%% the caller determines success criteria, doesnt require the wait_until to return true
-define(noAssertAsync(Expr, ExprRetry, ExprDelay),
    Res = miner_ct_utils:wait_until(fun() -> (Expr) end, ExprRetry, ExprDelay),
    case Res of
        false ->
            false;
        _ ->
            Res
    end).