-define(ASYNC_DELAY, 100).
-define(ASYNC_RETRIES, 40).
-define(JOIN_REQ,2#000).
-define(APPEUI, <<0,0,0,2,0,0,0,1>>).
-define(DEVEUI, <<0,0,0,0,0,0,0,1>>).
-define(APPKEY, <<16#2B, 16#7E, 16#15, 16#16, 16#28, 16#AE, 16#D2, 16#A6, 16#AB, 16#F7, 16#15, 16#88, 16#09, 16#CF, 16#4F, 16#3C>>).

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
