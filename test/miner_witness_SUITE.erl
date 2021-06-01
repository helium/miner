-module(miner_witness_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-export([
    all/0
]).

-export([
    init_per_testcase/2,
    end_per_testcase/2,
    refresh_test/1
]).

-define(SFLOCS, [631210968910285823, 631210968909003263, 631210968912894463, 631210968907949567]).
-define(NYLOCS, [631243922668565503, 631243922671147007, 631243922895615999, 631243922665907711]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [refresh_test].

init_per_testcase(TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(miner_witness_suite, TestCase, Config0),
    Config.

end_per_testcase(TestCase, Config) ->
    miner_ct_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
refresh_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(refresh_test, Config, maps:put(?poc_version, 8, CommonPOCVars)).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
run_dist_with_params(TestCase, Config, VarMap) ->
    {ok, Keys} = setup_dist_test(TestCase, Config, VarMap),
    %% Execute the test
    ok = exec_dist_test(TestCase, Config, VarMap, Keys),
    %% show the final receipt counter
    Miners = ?config(miners, Config),
    FinalReceiptMap = challenger_receipts_map(find_receipts(Miners)),
    ct:pal("FinalReceiptCounter: ~p", [receipt_counter(FinalReceiptMap)]),
    %% The test endeth here
    ok.

exec_dist_test(_, Config, VarMap,     #{secret := Priv, public := _Pub}) ->
    Miners = ?config(miners, Config),
    %% Print scores before we begin the test
    InitialScores = gateway_scores(Config),
    ct:pal("InitialScores: ~p", [InitialScores]),
    %% check that every miner has issued a challenge
    ?assert(check_all_miners_can_challenge(Miners)),
    case maps:get(?poc_version, VarMap, 1) of
        V when V > 3 ->
            miner_ct_utils:wait_until(
              fun() ->
                      ok = miner_witness_monitor:save_witnesses(),
                      miner_witness_monitor:check_witness_monotonic(30)
              end,
              20, 2500),
            Vars = #{?witness_refresh_interval => 10,
                     ?witness_refresh_rand_n => 100},
            Txn = blockchain_txn_vars_v1:new(Vars, 2, #{version_predicate => 2,
                                                        unsets => [garbage_value]}),
            Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
            Txn1 = blockchain_txn_vars_v1:proof(Txn, Proof),
            %% wait for it to take effect
            _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn1])
                 || Miner <- Miners],
            miner_ct_utils:wait_until(
              fun() ->
                      ok = miner_witness_monitor:save_witnesses(),
                      miner_witness_monitor:check_witness_refresh()
              end,
              20, 2500),
            FinalScores = gateway_scores(Config),
            ct:pal("FinalScores: ~p", [FinalScores]),
            ok;
        _ ->
            %% By this point, we have ensured that every miner
            %% has a valid request atleast once, we just check
            %% that we have N (length(Miners)) receipts.
            ?assert(check_atleast_k_receipts(Miners, length(Miners))),
            ok
    end,
    ok.

setup_dist_test(TestCase, Config, VarMap) ->
    Miners = ?config(miners, Config),
    MinersAndPorts = ?config(ports, Config),
    RadioPorts = [ P || {_Miner, {_TP, P}} <- MinersAndPorts ],

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    {_, Locations} = lists:unzip(initialize_chain(Miners, TestCase, Config, VarMap, Keys)),
    _GenesisBlock = get_genesis_block(Miners, Config),
    miner_fake_radio_backplane:start_link(maps:get(?poc_version, VarMap), 45000, lists:zip(RadioPorts, Locations)),

    %% MinerCount = length(Locations),

    %% miner_fake_radio_backplane:start_link(TestCase, 45000, lists:zip(lists:seq(46001, 46000 + MinerCount), Locations)),

    %% Doesn't matter which miner we want to monitor, since we only care about what's in the ledger
    miner_witness_monitor:start_link(hd(Miners)),
    timer:sleep(5000),
    %% Get non consensus miners
    NonConsensusMiners = miner_ct_utils:non_consensus_miners(Miners),
    %% Get consensus miners
    ConsensusMiners = miner_ct_utils:in_consensus_miners(Miners),
    %% ensure that blockchain is undefined for non_consensus miners
    false = miner_ct_utils:blockchain_worker_check(NonConsensusMiners),
    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(ConsensusMiners), NonConsensusMiners),
    %% wait till height 15
    ok = miner_ct_utils:wait_for_gte(height, Miners, 15, all, 30),
    {ok, Keys}.

gen_locations(_TestCase, Addresses, VarMap) ->
    LocationJitter = case maps:get(?poc_version, VarMap, 1) of
                         V when V > 3 ->
                             90;
                         _ ->
                             1000000
                     end,

    Locs = lists:foldl(
             fun(I, Acc) ->
                     [h3:from_geo({37.780586, -122.469470 + I/LocationJitter}, 13)|Acc]
             end,
             [],
             lists:seq(1, length(Addresses))
            ),
    {Locs, Locs}.

initialize_chain(Miners, TestCase, Config, VarMap, Keys) ->
    Addresses = ?config(addresses, Config),
    N = ?config(num_consensus_members, Config),
    Curve = ?config(dkg_curve, Config),
    InitialVars = miner_ct_utils:make_vars(Keys, VarMap),
    InitialPaymentTransactions = [blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    {ActualLocations, ClaimedLocations} = gen_locations(TestCase, Addresses, VarMap),
    AddressesWithLocations = lists:zip(Addresses, ActualLocations),
    AddressesWithClaimedLocations = lists:zip(Addresses, ClaimedLocations),
    InitialGenGatewayTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0) || {Addr, Loc} <- AddressesWithLocations],
    InitialTransactions = InitialVars ++ InitialPaymentTransactions ++ InitialGenGatewayTxns,

    {ok, DKGCompletedNodes} = miner_ct_utils:initial_dkg(Miners, InitialTransactions, Addresses, N, Curve),

    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(DKGCompletedNodes), Miners -- DKGCompletedNodes),

    AddressesWithClaimedLocations.

get_genesis_block(Miners, Config) ->
    RPCTimeout = ?config(rpc_timeout, Config),
    ct:pal("RPCTimeout: ~p", [RPCTimeout]),
    %% obtain the genesis block
    GenesisBlock = get_genesis_block_(Miners, RPCTimeout),
    ?assertNotEqual(undefined, GenesisBlock),
    GenesisBlock.

get_genesis_block_([Miner|Miners], RPCTimeout) ->
    case ct_rpc:call(Miner, blockchain_worker, blockchain, [], RPCTimeout) of
        {badrpc, Reason} ->
            ct:fail(Reason),
            get_genesis_block_(Miners ++ [Miner], RPCTimeout);
        undefined ->
            get_genesis_block_(Miners ++ [Miner], RPCTimeout);
        Chain ->
            {ok, GBlock} = rpc:call(Miner, blockchain, genesis_block, [Chain], RPCTimeout),
            GBlock
    end.

find_requests(Miners) ->
    [M | _] = Miners,
    Chain = ct_rpc:call(M, blockchain_worker, blockchain, []),
    Blocks = ct_rpc:call(M, blockchain, blocks, [Chain]),
    lists:flatten(lists:foldl(fun({_Hash, Block}, Acc) ->
                                      Txns = blockchain_block:transactions(Block),
                                      Requests = lists:filter(fun(T) ->
                                                                      blockchain_txn:type(T) == blockchain_txn_poc_request_v1
                                                              end,
                                                              Txns),
                                      [Requests | Acc]
                              end,
                              [],
                              maps:to_list(Blocks))).

find_receipts(Miners) ->
    [M | _] = Miners,
    Chain = ct_rpc:call(M, blockchain_worker, blockchain, []),
    Blocks = ct_rpc:call(M, blockchain, blocks, [Chain]),
    lists:flatten(lists:foldl(fun({_Hash, Block}, Acc) ->
                                      Txns = blockchain_block:transactions(Block),
                                      Height = blockchain_block:height(Block),
                                      Receipts = lists:filter(fun(T) ->
                                                                      blockchain_txn:type(T) == blockchain_txn_poc_receipts_v1
                                                              end,
                                                              Txns),
                                      TaggedReceipts = lists:map(fun(R) ->
                                                                         {Height, R}
                                                                 end,
                                                                 Receipts),
                                      TaggedReceipts ++ Acc
                              end,
                              [],
                              maps:to_list(Blocks))).

challenger_receipts_map(Receipts) ->
    lists:foldl(fun({_Height, Receipt}=R, Acc) ->
                        {ok, Challenger} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(blockchain_txn_poc_receipts_v1:challenger(Receipt))),
                        case maps:get(Challenger, Acc, undefined) of
                            undefined ->
                                maps:put(Challenger, [R], Acc);
                            List ->
                                maps:put(Challenger, lists:keysort(1, [R | List]), Acc)
                        end
                end,
                #{},
                Receipts).

request_counter(TotalRequests) ->
    lists:foldl(fun(Req, Acc) ->
                        {ok, Challenger} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(blockchain_txn_poc_request_v1:challenger(Req))),
                        case maps:get(Challenger, Acc, undefined) of
                            undefined ->
                                maps:put(Challenger, 1, Acc);
                            N when N > 0 ->
                                maps:put(Challenger, N + 1, Acc);
                            _ ->
                                maps:put(Challenger, 1, Acc)
                        end
                end,
                #{},
                TotalRequests).


check_all_miners_can_challenge(Miners) ->
    N = length(Miners),
    RequestCounter = request_counter(find_requests(Miners)),
    ct:pal("RequestCounter: ~p~n", [RequestCounter]),

    case N == maps:size(RequestCounter) of
        false ->
            ct:pal("Not every miner has issued a challenge...waiting..."),
            %% wait 50 more blocks?
            NewHeight = miner_ct_utils:height(hd(Miners)),
            ok = miner_ct_utils:wait_for_gte(height, Miners, NewHeight + 10, all, 30),
            check_all_miners_can_challenge(Miners);
        true ->
            ct:pal("Got a challenge from each miner atleast once!"),
            true
    end.

check_atleast_k_receipts(Miners, K) ->
    ReceiptMap = challenger_receipts_map(find_receipts(Miners)),
    TotalReceipts = lists:foldl(fun(ReceiptList, Acc) ->
                                        length(ReceiptList) + Acc
                                end,
                                0,
                                maps:values(ReceiptMap)),
    ct:pal("TotalReceipts: ~p", [TotalReceipts]),
    CurHeight = miner_ct_utils:height(hd(Miners)),
    case TotalReceipts >= K of
        false ->
            %% wait more
            ct:pal("Don't have receipts from each miner yet..."),
            ct:pal("ReceiptCounter: ~p", [receipt_counter(ReceiptMap)]),
            case CurHeight + 5 of
                N when N > 50 ->
                    false;
                N ->
                    ok = miner_witness_monitor:save_witnesses(),
                    ok = miner_ct_utils:wait_for_gte(height, Miners, N, all, 30),
                    check_atleast_k_receipts(Miners, K)
            end;
        true ->
            ok = miner_witness_monitor:save_witnesses(CurHeight),
            true
    end.

receipt_counter(ReceiptMap) ->
    lists:foldl(fun({Name, ReceiptList}, Acc) ->
                        Counts = lists:map(fun({Height, ReceiptTxn}) ->
                                                   {Height, length(blockchain_txn_poc_receipts_v1:path(ReceiptTxn))}
                                           end,
                                           ReceiptList),
                        maps:put(Name, Counts, Acc)
                end,
                #{},
                maps:to_list(ReceiptMap)).

gateway_scores(Config) ->
    [Miner | _] = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Miner, blockchain, ledger, [Chain]),
    lists:foldl(fun(Address, Acc) ->
                        {ok, S} = ct_rpc:call(Miner, blockchain_ledger_v1, gateway_score, [Address, Ledger]),
                        {ok, Name} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(Address)),
                        maps:put(Name, S, Acc)
                end,
                #{},
                Addresses).

common_poc_vars(Config) ->
    N = ?config(num_consensus_members, Config),
    _BlockTime = ?config(block_time, Config),
    Interval = ?config(election_interval, Config),
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),
    %% Don't put the poc version here
    %% Add it to the map in the tests above
    #{?block_time => 1000, %BlockTime,
      ?election_interval => Interval,
      ?num_consensus_members => N,
      ?batch_size => BatchSize,
      ?dkg_curve => Curve,
      ?poc_challenge_interval => 15,
      ?poc_v4_exclusion_cells => 10,
      ?poc_v4_parent_res => 11,
      ?poc_v4_prob_bad_rssi => 0.01,
      ?poc_v4_prob_good_rssi => 1.0,
      ?poc_v4_prob_no_rssi => 0.5,
      ?poc_v4_target_challenge_age => 300,
      ?poc_v4_target_exclusion_cells => 6000,
      ?poc_v4_target_score_curve => 5,
      ?poc_target_hex_parent_res => 5,

      ?poc_good_bucket_low => -132,
      ?poc_good_bucket_high => -80,
      ?poc_v5_target_prob_randomness_wt => 1.0,
      ?poc_v4_target_prob_edge_wt => 0.0,
      ?poc_v4_target_prob_score_wt => 0.0,
      ?poc_v4_prob_rssi_wt => 0.0,
      ?poc_v4_prob_time_wt => 0.0,
      ?poc_v4_randomness_wt => 0.5,
      ?poc_v4_prob_count_wt => 0.0,
      ?poc_centrality_wt => 0.5,
      ?poc_max_hop_cells => 2000

      %% ?witness_refresh_interval => 10,
      %% ?witness_refresh_rand_n => 100
     }.
