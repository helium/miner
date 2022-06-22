-module(miner_jsonrpc_denylist).

-include("miner_jsonrpc.hrl").
-behavior(miner_jsonrpc_handler).

-export([handle_rpc/2]).

handle_rpc(<<"denylist_status">>, []) ->
    try miner_poc_denylist:get_version() of 
        {ok, Version} when Version =/= 0 -> #{ loaded => true, version => Version };
        {ok, _} -> #{ loaded => false }
    catch _:_ ->
        #{ loaded => false }
    end;
handle_rpc(<<"denylist_status">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});

handle_rpc(<<"denylist_check">>, #{ <<"address">> := Address}) ->
    %% miner_poc_denylist:check/1 will return false if no list loaded
    %% so first check if a denylist is loaded using get_version/0
    DenylistLoaded = try miner_poc_denylist:get_version() of 
        {ok, Version} when Version =/= 0 -> true;
        _ -> false
    catch _:_ -> false
    end,
    case DenylistLoaded of
        true -> 
            try miner_poc_denylist:check(?B58_TO_BIN(Address)) of
                Denied -> #{ denied => Denied }
            catch _:Reason ->
                ?jsonrpc_error({invalid_params, Reason})
            end;
        false -> ?jsonrpc_error({internal_error, denylist_not_loaded})
    end;
handle_rpc(<<"denylist_check">>, Params) ->
    ?jsonrpc_error({invalid_params, Params}).
