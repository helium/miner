-module(miner_query).

-compile(export_all).


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
