%%%-------------------------------------------------------------------
%% @doc miner_targeter
%% @end
%%%-------------------------------------------------------------------
-module(miner_targeter).

-export([select/3
         ,prob/3
         %% ,find_target/4
        ]).

-spec select(binary(), nonempty_list(), nonempty_list()) -> libp2p_crypto:address().
select(Entropy, Population, Weights) ->
    %% TODO this is silly....
    <<A:85/integer-unsigned-little, B:85/integer-unsigned-little, C:86/integer-unsigned-little>> = crypto:hash(sha256, Entropy),
    S = rand:seed_s(exrop, {A, B, C}),
    {R, _} = rand:uniform_s(S),
    Rnd =  R * lists:sum(Weights),
    select(Population, Weights, Rnd, 0).

-spec select(nonempty_list(), nonempty_list(), float(), non_neg_integer()) -> libp2p_crypto:address().
select(Population, [W1 | _T], Rnd, Index) when (Rnd - W1) < 0 ->
    lists:nth(Index + 1, Population);
select(Population, [W1 | T], Rnd, Index) ->
    select(Population, T, Rnd - W1, Index + 1).

-spec prob(float(), pos_integer(), float()) -> float().
prob(Score, LenScores, SumScores) ->
    (1.0 - Score) / (LenScores - SumScores).

%% -spec find_target(blockchain_block:hash(), binary(), libp2p_crypto:address(), blockchain:blockchain()) -> libp2p_crypto:address().
%% find_target(Hash, Entropy, RequestingNode, Chain) ->
%%     {ok, Block} = blockchain:get_block(Hash, Chain),
%%     ActiveGateways = blockchain_ledger:active_gateways(blockchain_worker:ledger()),
%%     AllMinerScores = [miner:score(Addr, Block, Chain) || Addr <- TargetSearchNodes],
%%     LenMinerScores = length(AllMinerScores),
%%     SumMinerScores = lists:sum(AllMinerScores),
%%     Probs = [prob(Score, LenMinerScores, SumMinerScores) || Score <- AllMinerScores],
%%     select(Entropy, TargetSearchNodes, Probs).
