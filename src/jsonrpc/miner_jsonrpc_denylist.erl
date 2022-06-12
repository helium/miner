-module(miner_jsonrpc_denylist).

-include("miner_jsonrpc.hrl").
-behavior(miner_jsonrpc_handler).

-export([handle_rpc/2]).

handle_rpc(<<"denylist_status">>, []) ->
    try miner_poc_denylist:get_version() of 
        {ok, Version} -> #{ loaded => true, version => Version }
    catch _:_ ->
        #{ loaded => false }
    end;
handle_rpc(<<"denylist_status">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});

handle_rpc(<<"denylist_check">>, #{ <<"address">> := Address}) ->
    try miner_poc_denylist:check(?B58_TO_BIN(Address)) of
        Denied -> #{ denied => Denied }
    catch _:Reason ->
        ?jsonrpc_error({invalid_params, Reason})
    end;
handle_rpc(<<"denylist_check">>, Params) ->
    ?jsonrpc_error({invalid_params, Params}).
