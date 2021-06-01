-module(miner_jsonrpc_txns).

-include("miner_jsonrpc.hrl").

-behavior(miner_jsonrpc_handler).

-define(MAX_LOOKBACK, 25). %% only search the previous 25 blocks

-export([handle_rpc/2]).

%%
%% jsonrpc_handler
%%

%% TODO: add an optional start block height parameter

handle_rpc(<<"transaction_get">>, #{ <<"hash">> := Hash }) ->
    try
        BinHash = ?B64_TO_BIN(Hash),
        case get_transaction(BinHash) of
            {ok, {Height, Txn}} ->
                Json = blockchain_txn:to_json(Txn, []),
                Json#{block => Height};
            {error, not_found} ->
                ?jsonrpc_error({not_found, "No transaction: ~p", [Hash]})
        end
    catch
        _:_ ->
            ?jsonrpc_error({invalid_params, Hash})
    end;
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).

%%
%% Internal
%%

get_transaction(TxnHash) ->
    Chain = blockchain_worker:blockchain(),
    {ok, HeadBlock} = blockchain:head_block(Chain),
    HeadHeight = blockchain_block:height(HeadBlock),
    case blockchain:fold_chain(fun(B, Acc) -> find_txn(B, TxnHash, HeadHeight, Acc) end,
                               {HeadHeight, undefined},
                               HeadBlock,
                               Chain) of
        {_H, undefined} -> {error, not_found};
        {H, Txn} -> {ok, {H, Txn}}
    end.

find_txn(_Blk, _TxnHash, Start, {CH, undefined}) when Start - CH > ?MAX_LOOKBACK -> return;
find_txn(Blk, TxnHash, _Start, {_CH, undefined}) ->
    NewHeight = blockchain_block:height(Blk),
    Txns = blockchain_block:transactions(Blk),
    case lists:filter(fun(T) -> blockchain_txn:hash(T) == TxnHash end, Txns) of
        [] -> {NewHeight, undefined};
        [Match] -> {NewHeight, Match}
    end;
find_txn(_Blk, _TxnHash, _Start, _Acc) -> return.
