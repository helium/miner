-module(poc_target).

-export([select/3
        ,prob/3
        ,find_target/4
        ]).

-spec prob(float(), pos_integer(), float()) -> float().
prob(Score, LenScores, SumScores) ->
    (1.0 - Score) / (LenScores - SumScores).

-spec find_target(blockchain:hash_ref(), binary(), blockchain_crypto:address(), blockchain:chain()) -> blockchain_crypto:address().
find_target(Hash, Entropy, RequestingNode, Chain) ->
    case blockchain_worker:get_block(Hash) of
        {ok, Block} ->
            ActiveGateways = blockchain_ledger:active_gateways(blockchain_worker:ledger()),
            TargetSearchGateways = [Y || Y <- maps:keys(ActiveGateways)], %% check if location /= undefined?
        {error, Reason} ->
            %%
    end,
    %AllNodes = blockchain:all_nodes(Chain),
    %TargetSearchNodes = [Node#node.address || Node <- AllNodes, Node#node.position /= undefined, Node#node.added_at =< block:height(Block), Node#node.address /= RequestingNode],
    AllMinerScores = [blockchain:quality(Addr, Block, Chain) || Addr <- TargetSearchNodes],
    LenMinerScores = length(AllMinerScores),
    SumMinerScores = lists:sum(AllMinerScores),
    Probs = [prob(Score, LenMinerScores, SumMinerScores) || Score <- AllMinerScores],
    select(Entropy, TargetSearchNodes, Probs).

-spec select(binary(), nonempty_list(), nonempty_list()) -> blockchain_crypto:address().
select(Entropy, Population, Weights) ->
    %% TODO this is silly but it makes EQC happy....
    <<A:85/integer-unsigned-little, B:85/integer-unsigned-little, C:86/integer-unsigned-little>> = crypto:hash(sha256, Entropy),
    S = rand:seed_s(exrop, {A, B, C}),
    {R, _} = rand:uniform_s(S),
    Rnd =  R * lists:sum(Weights)
    select(Population, Weights, Rnd, 0).

-spec select(nonempty_list(), nonempty_list(), float(), non_neg_integer()) -> blockchain_crypto:address().
select(Population, [W1 | _T], Rnd, Index) when (Rnd - W1) < 0 ->
    lists:nth(Index + 1, Population);
select(Population, [W1 | T], Rnd, Index) ->
    select(Population, T, Rnd - W1, Index + 1).
