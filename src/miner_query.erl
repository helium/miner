%% Use this module to run some basic query against the chain
%% For example:
%%
%% - Lookup last 500 blocks for payment_v2 transactions:
%% lookup_txns_by_type(500, blockchain_txn_payment_v2).
%%
%% - Lookup last 500 blocks for particular txn hash:
%% lookup_txns_by_type(500, <<some_txn_hash>>).

-module(miner_query).

-export([poc_analyze/2,
         txns/2, txns/3,
         blocks/2,
         lookup_txns_by_hash/2,
         lookup_txns_by_type/2]).

poc_analyze(_Start, _End) ->
    ok.

txns(Type, Start, End) when is_atom(Type) ->
    txns([Type], Start, End);
txns(Types, Start, End) ->
    Txns = txns(Start, End),
    lists:filter(fun(T) -> lists:member(blockchain_txn:type(T), Types) end, Txns).

txns(Start, End) ->
    Blocks = blocks(Start, End),
    lists:flatten(lists:map(fun blockchain_block:transactions/1, Blocks)).

blocks(Start, End) ->
    Chain = blockchain_worker:blockchain(),
    [begin
         {ok, B} = blockchain:get_block(N, Chain),
         B
     end
     || N <- lists:seq(Start, End)].

lookup_txns_by_type(LastXBlocks, TxnType) ->
    C = blockchain_worker:blockchain(),
    {ok, Current} = blockchain:height(C),
    Range = lists:seq(Current - LastXBlocks, Current),
    Blocks = [{I, element(2, blockchain:get_block(I, C))} || I <- Range],
    Txns = lists:map(fun({I, B}) -> Ts = blockchain_block:transactions(B), {I, Ts}  end, Blocks),
    X = lists:map(fun({I, Ts}) -> {I, lists:filter(fun(T) ->
                                                           blockchain_txn:type(T) == TxnType
                                                   end, Ts)}  end, Txns),
    lists:filter(fun({_I, List}) -> length(List) /= 0  end, X).

lookup_txns_by_hash(LastXBlocks, TxnHash) ->
    C = blockchain_worker:blockchain(),
    {ok, Current} = blockchain:height(C),
    Range = lists:seq(Current - LastXBlocks, Current),
    Blocks = [{I, element(2, blockchain:get_block(I, C))} || I <- Range],
    Txns = lists:map(fun({I, B}) -> Ts = blockchain_block:transactions(B), {I, Ts}  end, Blocks),
    X = lists:map(fun({I, Ts}) -> {I, lists:filter(fun(T) -> blockchain_txn:hash(T) == TxnHash
                                                   end, Ts)}  end, Txns),
    lists:filter(fun({_I, List}) -> length(List) /= 0  end, X).
