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
         lookup_txns_by_type/2,
         lookup_txns_by_onionhash/2
]).

poc_analyze(_Start, _End) ->
    ok.

txns(Type, Start, End) when is_atom(Type) ->
    txns([Type], Start, End);
txns(Types, Start, End) ->
    Chain = blockchain_worker:blockchain(),
    fold_blocks(fun(B, Acc) ->
                        Txns = blockchain_block:transactions(B),
                        Txns1 =
                            lists:filter(fun(T) ->
                                                 lists:member(blockchain_txn:type(T), Types)
                                         end, Txns),
                        lists:append(Txns1, Acc)
                end,
                Start, End, Chain,
                []).

txns(Start, End) ->
    Chain = blockchain_worker:blockchain(),
    fold_blocks(fun(B, Acc) ->
                        Txns = blockchain_block:transactions(B),
                        lists:append(Txns, Acc)
                end,
                Start, End, Chain,
                []).

blocks(Start, End) ->
    Chain = blockchain_worker:blockchain(),
    [begin
         {ok, B} = blockchain:get_block(N, Chain),
         B
     end
     || N <- lists:seq(Start, End)].

fold_blocks(_Fun, End, End, _Chain, Acc) ->
    Acc;
fold_blocks(Fun, Start, End, Chain, Acc) ->
    {ok, B} = blockchain:get_block(Start, Chain),
    fold_blocks(Fun, Start + 1, End, Chain, Fun(B, Acc)).

%% slightly different collection semantics, tags by height
lookup_txns_by_type(LastXBlocks, TxnType) ->
    C = blockchain_worker:blockchain(),
    {ok, Current} = blockchain:height(C),
    lists:reverse(
      fold_blocks(
        fun(B, Acc) ->
                I = blockchain_block:height(B),
                case lists:filter(fun(T) ->
                                          blockchain_txn:type(T) == TxnType
                                  end, blockchain_block:transactions(B)) of
                    [] -> Acc;
                    R -> [{I, R} | Acc]
                end
        end,
        Current - LastXBlocks, Current, C,
        [])).

lookup_txns_by_hash(LastXBlocks, TxnHash) ->
    C = blockchain_worker:blockchain(),
    {ok, Current} = blockchain:height(C),
    lists:reverse(
      fold_blocks(
        fun(B, Acc) ->
                I = blockchain_block:height(B),
                case lists:filter(fun(T) ->
                                          blockchain_txn:hash(T) == TxnHash
                                  end, blockchain_block:transactions(B)) of
                    [] -> Acc;
                    R -> [{I, R} | Acc]
                end
        end,
        Current - LastXBlocks, Current, C,
        [])).

lookup_txns_by_onionhash(LastXBlocks, OnionHash) ->
    C = blockchain_worker:blockchain(),
    {ok, Current} = blockchain:height(C),
    lists:reverse(
      fold_blocks(
        fun(B, Acc) ->
                I = blockchain_block:height(B),
                case lists:filter(fun(T) ->
                        case blockchain_txn:type(T) == 'blockchain_txn_poc_receipts_v2' of
                            true ->
                                blockchain_txn_poc_receipts_v2:onion_key_hash(T) == OnionHash;
                            _ ->
                                false
                        end
                    end, blockchain_block:transactions(B)) of
                    [] -> Acc;
                    R -> [{I, R} | Acc]
                end
        end,
        Current - LastXBlocks, Current, C,
        [])).
