-module(miner_jsonrpc_handler).

-callback handle_rpc(Method :: binary(), Params :: term()) -> jsx:json_term().

-export([handle/2, handle_event/3]).
-export([
    jsonrpc_b58_to_bin/2,
    jsonrpc_b64_to_bin/2,
    jsonrpc_get_param/2,
    jsonrpc_get_param/3,
    jsonrpc_error/1,
    to_key/1,
    to_value/1,
    jsonrpc_maybe/1
]).

-include("miner_jsonrpc.hrl").

-include_lib("elli/include/elli.hrl").

-behaviour(elli_handler).

handle(Req, _Args) ->
    %% Delegate to our handler function
    handle(Req#req.method, elli_request:path(Req), Req).

handle('POST', _, Req) ->
    Json = elli_request:body(Req),
    {reply, Reply} =
        jsonrpc2:handle(Json, fun handle_rpc/2, fun decode_helper/1, fun encode_helper/1),
    {ok, [], Reply};
handle(_, _, _Req) ->
    {404, [], <<"Not Found">>}.

handle_rpc(Method, Params) ->
    lager:debug("Dispatching method ~p with params: ~p", [Method, Params]),
    handle_rpc_(Method, Params).

handle_rpc_(<<"block_", _/binary>> = Method, Params) ->
    miner_jsonrpc_blocks:handle_rpc(Method, Params);
handle_rpc_(<<"transaction_", _/binary>> = Method, Params) ->
    miner_jsonrpc_txns:handle_rpc(Method, Params);
handle_rpc_(<<"account_", _/binary>> = Method, Params) ->
    miner_jsonrpc_accounts:handle_rpc(Method, Params);
handle_rpc_(<<"info_", _/binary>> = Method, Params) ->
    miner_jsonrpc_info:handle_rpc(Method, Params);
handle_rpc_(<<"denylist_", _/binary>> = Method, Params) ->
    miner_jsonrpc_denylist:handle_rpc(Method, Params);
handle_rpc_(<<"dkg_", _/binary>> = Method, Params) ->
    miner_jsonrpc_dkg:handle_rpc(Method, Params);
handle_rpc_(<<"hbbft_", _/binary>> = Method, Params) ->
    miner_jsonrpc_hbbft:handle_rpc(Method, Params);
handle_rpc_(<<"txn_", _/binary>> = Method, Params) ->
    miner_jsonrpc_txn:handle_rpc(Method, Params);
handle_rpc_(<<"ledger_", _/binary>> = Method, Params) ->
    miner_jsonrpc_ledger:handle_rpc(Method, Params);
handle_rpc_(<<"snapshot_", _/binary>> = Method, Params) ->
    miner_jsonrpc_snapshot:handle_rpc(Method, Params);
handle_rpc_(<<"sc_", _/binary>> = Method, Params) ->
    miner_jsonrpc_sc:handle_rpc(Method, Params);
handle_rpc_(<<"peer_", _/binary>> = Method, Params) ->
    miner_jsonrpc_peer:handle_rpc(Method, Params);
handle_rpc_(_, _) ->
    ?jsonrpc_error(method_not_found).

%% @doc Handle request events, like request completed, exception
%% thrown, client timeout, etc. Must return `ok'.
handle_event(request_throw, [Req, Exception, Stack], _Config) ->
    lager:error("exception: ~p~nstack: ~p~nrequest: ~p~n", [
        Exception,
        Stack,
        elli_request:to_proplist(Req)
    ]),
    ok;
handle_event(request_exit, [Req, Exit, Stack], _Config) ->
    lager:error("exit: ~p~nstack: ~p~nrequest: ~p~n", [
        Exit,
        Stack,
        elli_request:to_proplist(Req)
    ]),
    ok;
handle_event(request_error, [Req, Error, Stack], _Config) ->
    lager:error("error: ~p~nstack: ~p~nrequest: ~p~n", [
        Error,
        Stack,
        elli_request:to_proplist(Req)
    ]),
    ok;
handle_event(_, _, _) ->
    ok.

jsonrpc_get_param(Key, PropList) ->
    case proplists:get_value(Key, PropList, false) of
        false -> ?jsonrpc_error(invalid_params);
        V -> V
    end.

jsonrpc_get_param(Key, PropList, Default) ->
    proplists:get_value(Key, PropList, Default).

jsonrpc_b58_to_bin(Key, PropList) ->
    B58 = jsonrpc_get_param(Key, PropList),
    try
        ?B58_TO_BIN(B58)
    catch
        _:_ -> ?jsonrpc_error(invalid_params)
    end.

jsonrpc_b64_to_bin(Key, PropList) ->
    B64 = jsonrpc_get_param(Key, PropList),
    try
        ?B64_TO_BIN(B64)
    catch
        _:_ -> ?jsonrpc_error(invalid_params)
    end.

%%
%% Errors
%%
-define(throw_error(C, L), throw({jsonrpc2, C, iolist_to_binary((L))})).
-define(throw_error(C, F, A),
    throw({jsonrpc2, C, iolist_to_binary(io_lib:format((F), (A)))})
).

-define(ERR_NOT_FOUND, -100).
-define(ERR_INVALID_PASSWORD, -110).
-define(ERR_ERROR, -150).

-spec jsonrpc_error(term()) -> no_return().
jsonrpc_error(method_not_found = E) ->
    throw(E);
jsonrpc_error(invalid_params = E) ->
    throw(E);
jsonrpc_error({invalid_params, _} = E) ->
    throw(E);
jsonrpc_error({not_found, F, A}) ->
    ?throw_error(?ERR_NOT_FOUND, F, A);
jsonrpc_error({not_found, M}) ->
    ?throw_error(?ERR_NOT_FOUND, M);
jsonrpc_error(invalid_password) ->
    ?throw_error(?ERR_INVALID_PASSWORD, "Invalid password");
jsonrpc_error({error, F, A}) ->
    ?throw_error(?ERR_ERROR, F, A);
jsonrpc_error({error, E}) ->
    jsonrpc_error({error, "~p", E}).

%%
%% Internal
%%

decode_helper(Bin) ->
    jsx:decode(Bin, [{return_maps, true}]).

encode_helper(Json) ->
    jsx:encode(Json).

to_key(X) when is_atom(X) -> atom_to_binary(X, utf8);
to_key(X) when is_list(X) -> iolist_to_binary(X);
to_key(X) when is_binary(X) -> X.

%% don't want these atoms stringified
to_value(true) -> true;
to_value(false) -> false;
to_value(undefined) -> null;
%% lightly format floats, but pass through integers as-is
to_value(X) when is_float(X) -> float_to_binary(blockchain_utils:normalize_float(X), [{decimals, 3}, compact]);
to_value(X) when is_integer(X) -> X;
%% make sure we have valid representations of other types which may show up in values
to_value(X) when is_list(X) -> iolist_to_binary(X);
to_value(X) when is_atom(X) -> atom_to_binary(X, utf8);
to_value(X) when is_binary(X) -> X;
to_value(X) when is_map(X) -> ensure_binary_map(X);
to_value(X) -> iolist_to_binary(io_lib:format("~p", [X])).

ensure_binary_map(M) ->
    maps:fold(fun(K, V, Acc) ->
        BinK = to_key(K),
        BinV = to_value(V),
        Acc#{BinK => BinV}
              end, #{}, M).

jsonrpc_maybe(undefined) -> <<"undefined">>;
jsonrpc_maybe(X) -> X.
