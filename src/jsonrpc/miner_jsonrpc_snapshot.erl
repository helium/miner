-module(miner_jsonrpc_snapshot).

-include("miner_jsonrpc.hrl").
-behavior(miner_jsonrpc_handler).

-export([handle_rpc/2]).

%%
%% jsonrpc_handler
%%

%% TODO: add an optional start block height parameter

handle_rpc(<<"snapshot_list">>, []) ->
    Chain = blockchain_worker:blockchain(),
    case blockchain:find_last_snapshots(Chain, 5) of
        undefined ->
            ?jsonrpc_error(no_snapshots_found);
        Snapshots ->
            [
                #{
                    height => Height,
                    hash => ?BIN_TO_B64(Hash),
                    hash_hex => blockchain_utils:bin_to_hex(Hash),
                    have_snapshot => have_snapshot(Hash, Chain)
                }
             || {Height, _, Hash} <- Snapshots
            ]
    end;
handle_rpc(<<"snapshot_info">>, [#{<<"path">> := Path}]) ->
    case file:read_file(Path) of
        {error, Error} ->
            ?jsonrpc_error({error, Error});
        {ok, Snap} ->
            blockchain_ledger_snapshot_v1:deserialize(Snap),
            #{
                height => blockchain_ledger_snapshot_v1:height(Snap),
                hash => ?BIN_TO_B64(blockchain_ledger_snapshot_v1:hash(Snap))
            }
    end;
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).

%%
%% Internal
%%
have_snapshot(Hash, Chain) ->
    case blockchain:get_snapshot(Hash, Chain) of
        {ok, _Snap} -> true;
        _ -> false
    end.
