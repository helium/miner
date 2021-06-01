-module(miner_jsonrpc_txn).

-include("miner_jsonrpc.hrl").
-behavior(miner_jsonrpc_handler).

%% jsonrpc_handler
-export([handle_rpc/2]).

%%
%% jsonrpc_handler
%%

handle_rpc(<<"txn_queue">>, []) ->
    case (catch blockchain_txn_mgr:txn_list()) of
        {'EXIT', _} -> #{ error => <<"timeout">> };
        [] -> [];
        Txns ->
            maps:fold(fun(T, D, Acc) ->
                              Type = blockchain_txn:type(T),
                              Hash = blockchain_txn:hash(T),
                              Accepts = proplists:get_value(acceptions, D, []),
                              Rejects = proplists:get_value(rejections, D, []),
                              AcceptHeight = proplists:get_value(recv_block_height, D, undefined),
                              [ #{ type => Type,
                                   hash => ?BIN_TO_B64(Hash),
                                   accepts => length(Accepts),
                                   rejections => length(Rejects),
                                   accepted_height => AcceptHeight } | Acc ]
                      end, [], Txns)
    end;
handle_rpc(<<"txn_add_gateway">>, #{ <<"owner">> := OwnerB58 } = Params) ->
    try
        Payer = case maps:get(payer, Params, undefined) of
                    undefined -> undefined;
                    PayerB58 -> ?B58_TO_BIN(PayerB58)
                end,
        {ok, Bin} = blockchain:add_gateway_txn(?B58_TO_BIN(OwnerB58), Payer),
        B64 = base64:encode(Bin),
        #{ <<"result">> => B64 }
    catch
        T:E:St ->
            lager:error("Couldn't do add gateway via JSONRPC because: ~p ~p: ~p",
                        [T, E, St]),
            Error = io_lib:format("~p", [E]),
            #{ <<"error">> => Error }
    end;
handle_rpc(<<"txn_assert_location">>, #{ <<"owner">> := OwnerB58 } = Params) ->
    try
        Payer = case maps:get(payer, Params, undefined) of
                    undefined -> undefined;
                    PayerB58 -> ?B58_TO_BIN(PayerB58)
                end,
        H3String = case parse_location(Params) of
                       {error, _} = Err -> throw(Err);
                       {ok, S} -> S
                   end,
        Nonce = maps:get(nonce, Params, 1),
        {ok, Bin} = blockchain:assert_loc_txn(H3String, ?B58_TO_BIN(OwnerB58),
                                              Payer, Nonce),
        B64 = base64:encode(Bin),
        #{ <<"result">> => B64 }
    catch
        T:E:St ->
            lager:error("Couldn't complete assert location JSONRPC because ~p ~p: ~p",
                        [T, E, St]),
            Error = io_lib:format("~p", [E]),
            #{ <<"error">> => Error }
    end;
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).

parse_location(#{ <<"h3">> := H3 }) ->
    try
        %% h3 literally expects a string, not a binary string, so...
        H3Str = binary_to_list(H3),
        h3:from_string(H3Str),
        {ok, H3Str}
    catch
        _:_ ->
            {error, {invalid_location, H3}}
    end;
parse_location(#{ <<"lat">> := LatIn,
                  <<"lon">> := LonIn }) ->
    try
        Lat = binary_to_float(LatIn),
        Lon = binary_to_float(LonIn),
        h3:to_string(h3:from_geo({Lat, Lon}, 12))
    catch
        _:_ ->
            {error, {invalid_location, {LatIn, LonIn}}}
    end;
parse_location(_Other) -> {error, no_valid_location_found}.
