%%% RELOC KEEP - works with consensus group
-module(miner_txn_mgr_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").

-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").
-include_lib("helium_proto/include/blockchain_txn_handler_pb.hrl").

-include("miner_ct_macros.hrl").

-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0
        ]).

-export([
         txn_in_sequence_nonce_test/1,
         txn_out_of_sequence_nonce_test/1,
         txn_invalid_nonce_test/1,
         txn_dependent_test/1,
         txn_from_future_via_protocol_v1_test/1,
         txn_from_future_via_protocol_v2_test/1,
         txn_from_future_via_protocol_v3_test/1,
         txn_queue_protocol_v3_test/1,
         txn_queue_protocol_v2_test/1,
         txn_queue_protocol_v1_test/1

        ]).

all() -> [
          txn_in_sequence_nonce_test,
          txn_out_of_sequence_nonce_test,
          txn_invalid_nonce_test,
          txn_dependent_test,

          %% XXX v1 test is inconsistent. TODO Check if it can be fixed.
          {testcase, txn_from_future_via_protocol_v1_test, [{repeat_until_ok, 5}]},
          txn_from_future_via_protocol_v2_test,
          txn_from_future_via_protocol_v3_test,
          txn_queue_protocol_v3_test,
          txn_queue_protocol_v2_test,
          txn_queue_protocol_v1_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(?MODULE, _TestCase, Config0),
    try
    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, h3:from_geo({37.780586, -122.469470}, 13), 0)
                 || Addr <- Addresses],

    NumConsensusMembers = ?config(num_consensus_members, Config),
    BlockTime =
        case _TestCase of
            txn_dependent_test -> 5000;
            txn_queue_protocol_v2_test -> 5000;
            txn_queue_protocol_v1_test -> 5000;
            _ -> ?config(block_time, Config)
        end,

    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, #{?block_time => BlockTime,
                                                   %% rule out rewards
                                                   ?election_interval => infinity,
                                                   ?num_consensus_members => NumConsensusMembers,
                                                   ?batch_size => BatchSize,
                                                   ?dkg_curve => Curve}),

    {ok, DKGCompletionNodes} = miner_ct_utils:initial_dkg(Miners, InitialVars ++ InitialPaymentTransactions ++ AddGwTxns,
                                             Addresses, NumConsensusMembers, Curve),
    ct:pal("Nodes which completed the DKG: ~p", [DKGCompletionNodes]),
    %% Get both consensus and non consensus miners
    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),
    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(DKGCompletionNodes), Miners -- DKGCompletionNodes),
    ct:pal("genesis load results: ~p", [_GenesisLoadResults]),

    %% confirm we have a height of 1
    ok = miner_ct_utils:wait_for_gte(height, Miners, 2),

    [   {consensus_miners, ConsensusMiners},
        {non_consensus_miners, NonConsensusMiners}
        | Config]
    catch
        What:Why ->
            end_per_testcase(_TestCase, Config),
            erlang:What(Why)
    end.

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).


txn_in_sequence_nonce_test(Config) ->
    %% send two standalone payments, with correctly sequenced nonce values
    %% both txns are sent in quick succession
    %% these should clear through the txn mgr right away without probs
    %% and txn mgr cache will clear
    Miner = hd(?config(non_consensus_miners, Config)),
    AddrList = ?config(tagged_miner_addresses, Config),

    ConMiners = ?config(consensus_miners, Config),
    IgnoredTxns = [],
    Addr = miner_ct_utils:node2addr(Miner, AddrList),

    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),

    PayerAddr = Addr,
    Payee = hd(miner_ct_utils:shuffle(ConMiners)),
    PayeeAddr = miner_ct_utils:node2addr(Payee, AddrList),
    {ok, Pubkey, SigFun, ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    StartNonce = miner_ct_utils:get_nonce(Miner, Addr),

    {ok, Pubkey, SigFun, ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    %% the first txn
    Txn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+1]),
    SignedTxn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    %% the second txn
    Txn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+2]),
    SignedTxn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),
    %% send the txns
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn1]),
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn2]),

    %% both txns should have been accepted by the CG and removed from the txn mgr cache
    %% txn mgr cache should be empty
    Result = miner_ct_utils:wait_until(
                                        fun()->
                                            case get_cached_txns_with_exclusions(Miner, IgnoredTxns) of
                                                #{} -> true;
                                                _ -> false
                                            end
                                        end, 60, 2000),
    ok = handle_get_cached_txn_result(Result, Miner, IgnoredTxns, Chain),

    %% check the miners nonce values to be sure the txns have actually been absorbed and not just lost
    ExpectedNonce = StartNonce +2,
    true = nonce_updated_for_miner(Addr, ExpectedNonce, ConMiners),

    ok.

txn_out_of_sequence_nonce_test(Config) ->
    %% send two standalone payments, but out of order so that the first submitted has an out of sequence nonce
    %% this will result in validations determining undecided and the txn stays in txn mgr cache
    %% this txn will only clear out after the second txn is submitted
    Miner = hd(?config(non_consensus_miners, Config)),
    ConMiners = ?config(consensus_miners, Config),
    AddrList = ?config(tagged_miner_addresses, Config),

    IgnoredTxns = [],
    Addr = miner_ct_utils:node2addr(Miner, AddrList),

    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),

    PayerAddr = Addr,
    Payee = hd(miner_ct_utils:shuffle(ConMiners)),
    PayeeAddr = miner_ct_utils:node2addr(Payee, AddrList),
    {ok, Pubkey, SigFun, ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    StartNonce = miner_ct_utils:get_nonce(Miner, Addr),
    {ok, Pubkey, SigFun, ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    %% the first txn
    Txn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+1]),
    SignedTxn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    %% the second txn
    Txn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+2]),
    SignedTxn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),

    %% send txn 2 first
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn2]),

    %% confirm the txn remains in the txn mgr cache
    %% it should be the only txn
    Result1 = miner_ct_utils:wait_until(
        fun() ->
            case get_cached_txns_with_exclusions(Miner, IgnoredTxns) of
                #{} -> true;
                FilteredTxns ->
                    %% we expect the payment txn to remain as its nonce is too far ahead
                    case FilteredTxns of
                        #{SignedTxn2 := _TxnData} -> true;
                        _ -> false
                    end
            end
        end, 60, 2000),
    ok = handle_get_cached_txn_result(Result1, Miner, IgnoredTxns, Chain),

    %% now submit the other txn which will have the missing nonce
    %% this should result in both this and the previous txn being accepted by the CG
    %% and cleared out of the txn mgr
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn1]),

    %% both txn should now have been accepted by the CG and removed from the txn mgr cache
    %% txn mgr cache should be empty
    Result2 = miner_ct_utils:wait_until(
                                        fun()->
                                            case get_cached_txns_with_exclusions(Miner, IgnoredTxns) of
                                                #{} -> true;
                                                _ -> false
                                            end
                                        end, 60, 2000),
    ok = handle_get_cached_txn_result(Result2, Miner, IgnoredTxns, Chain),

    %% check the miners nonce values to be sure the txns have actually been absorbed and not just lost
    ExpectedNonce = StartNonce +2,
    true = nonce_updated_for_miner(Addr, ExpectedNonce, ConMiners),

    ok.

txn_invalid_nonce_test(Config) ->
    %% send two standalone payments, the second with a duplicate/invalid nonce
    %% the first txn will be successful, the second should be declared invalid
    %% both will be removed from the txn mgr cache,
    %% the first because it is absorbed, the second because it is invalid
    Miner = hd(?config(non_consensus_miners, Config)),
    ConMiners = ?config(consensus_miners, Config),
    AddrList = ?config(tagged_miner_addresses, Config),

    IgnoredTxns = [],
    Addr = miner_ct_utils:node2addr(Miner, AddrList),

    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),

    PayerAddr = Addr,
    Payee = hd(miner_ct_utils:shuffle(ConMiners)),
    PayeeAddr = miner_ct_utils:node2addr(Payee, AddrList),
    {ok, Pubkey, SigFun, ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    StartNonce = miner_ct_utils:get_nonce(Miner, Addr),
    {ok, Pubkey, SigFun, ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    %% the first txn
    Txn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+1]),
    SignedTxn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    %% the second txn - with the same nonce as the first
    Txn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+1]),
    SignedTxn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),
    %% send txn1
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn1]),

    %% wait until the first txn has been accepted by the CG and removed from the txn mgr cache
    %% txn mgr cache should be empty
    Result1 = miner_ct_utils:wait_until(
                                        fun()->
                                            case get_cached_txns_with_exclusions(Miner, IgnoredTxns) of
                                                #{} -> true;
                                                _ -> false
                                            end
                                        end, 60, 2000),
    ok = handle_get_cached_txn_result(Result1, Miner, IgnoredTxns, Chain),

    %% now send the second txn ( with the dup nonce )
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn2]),

    %% give the second txn a bit of time to be processed by the txn mgr and for it to be declared invalid
    %% and removed from the txn mgr cache
    Result2 = miner_ct_utils:wait_until(
                                        fun()->
                                            case get_cached_txns_with_exclusions(Miner, IgnoredTxns) of
                                                #{} -> true;
                                                _ -> false
                                            end
                                        end, 60, 2000),
    ok = handle_get_cached_txn_result(Result2, Miner, IgnoredTxns, Chain),

    %% check the miners nonce values to be sure the txns have actually been absorbed and not just lost
    ExpectedNonce = StartNonce +1,
    true = nonce_updated_for_miner(Addr, ExpectedNonce, ConMiners),

    ok.

txn_dependent_test(Config) ->
    %% send a bunch of out of order dependent txns
    %% they should all end up being accepted in the *same* block
    %% but only after the txn with the lowest sequenced nonce is submitted
    %% as until that happens none will pass validations
    %% confirm the 3 txns remain in the txn mgr cache until the missing txn is submitted
    %% after which we confirm the txn mgr cache empties due to the txns being accepted
    %% confirm we dont have any strays in the txn mgr cache at the end of it
    Miners = ?config(miners, Config),
    Miner = hd(?config(non_consensus_miners, Config)),
    ConMiners = ?config(consensus_miners, Config),
    AddrList = ?config(tagged_miner_addresses, Config),

    Addr = miner_ct_utils:node2addr(Miner, AddrList),

    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),

    ct:pal("miner in use ~p", [Miner]),

    PayerAddr = Addr,
    Payee = hd(miner_ct_utils:shuffle(ConMiners)),
    PayeeAddr = miner_ct_utils:node2addr(Payee, AddrList),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),
    IgnoredTxns = [blockchain_txn_poc_request_v1],
    StartNonce = miner_ct_utils:get_nonce(Miner, Addr),

    %% prep the txns, 1 - 4
    Txn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+1]),
    SignedTxn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    Txn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+2]),
    SignedTxn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),
    Txn3 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+3]),
    SignedTxn3 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn3, SigFun]),
    Txn4 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+4]),
    SignedTxn4 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn4, SigFun]),

    %% get the start height
    {ok, Height} = ct_rpc:call(Miner, blockchain, height, [Chain]),

    %% send txns with nonces 2, 3 and 4, all out of sequence
    %% we won't send txn with nonce 1 yet
    %% this means the 3 submitted txns cannot be accepted and will remain in the txn mgr cache
    %% until txn with nonce 1 gets submitted
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn2]),
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn4]),
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn3]),

    %% Wait a few blocks, confirm txns remain in the cache
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 3),

    %% confirm all txns are still be in txn mgr cache
    true = miner_ct_utils:wait_until(
                                        fun()->
                                            maps:size(get_cached_txns_with_exclusions(Miner, IgnoredTxns)) == 3
                                        end, 60, 100),

    %% now submit the remaining txn which will have the missing nonce
    %% this should result in both this and the previous txns being accepted by the CG
    %% and cleared out of the txn mgr cache
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn1]),

    %% Wait one more block
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 4),

    %% confirm all txns are are gone from the cache within the span of a single block
    %% ie they are not carrying across blocks
    true = miner_ct_utils:wait_until(
                                        fun()->
                                            maps:size(get_cached_txns_with_exclusions(Miner, IgnoredTxns)) == 0
                                        end, 60, 100),

    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 5),

    ExpectedNonce = StartNonce +4,
    true = nonce_updated_for_miner(Addr, ExpectedNonce, ConMiners),

    ok.

txn_queue_protocol_v3_test(Config) ->
    %% send a bunch of txns via the grpc submit API
    %% wait for them to appear in the sidecar buffer
    %% validate each txns position in the buffer
    %% then force one txn to be dequeued from the buffer
    %% and revalidate the queue positions of the remaining
    %% txns

    IgnoredTxns = [],
    Miners = ?config(miners, Config),
    ConMiners = ?config(consensus_miners, Config),
    AddrList = ?config(tagged_miner_addresses, Config),

    %% run the common elements of the test
    %% which are shared across all 3 queue
    %% tests ( one for each of the txn protocols )
    Config1 = txn_queue_common_test(Config),
    %% the common test appends a shared dataset
    %% to the config
    %% take what we need from it to complete
    %% the rest of this test
    CommonDataMap = ?config(common_data, Config1),
    #{
        txn1 := SignedTxn1,
        txn2 := SignedTxn2,
        txn3 := SignedTxn3,
        txn4 := SignedTxn4,
        txn1_key := Txn1Key,
        txn2_key := Txn2Key,
        txn3_key := Txn3Key,
        txn4_key := Txn4Key,
        txn1_submit_height := Txn1SubmitHeight,
        txn2_submit_height := Txn2SubmitHeight,
        txn3_submit_height := Txn3SubmitHeight,
        txn4_submit_height := Txn4SubmitHeight,
        con_miner_1 := ConMiner1,
        miner := Miner,
        last_height :=  Height
    } = CommonDataMap,
    ConMiner1Addr = miner_ct_utils:node2addr(ConMiner1, AddrList),

    %% query the txn mgr txn status API
    %% this should give us back the same data as the above
    %% sidecar query
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 3),
    {ok, Txn1Key, _, Txn1SubmitHeight, [{ConMiner1Addr, _, 1, 4}]} =
        txn_mgr_query_txn(Txn1Key, Miner),
    {ok, Txn2Key, _, Txn2SubmitHeight, [{ConMiner1Addr, _, 2, 4}]} =
        txn_mgr_query_txn(Txn2Key, Miner),
    {ok, Txn3Key, _, Txn3SubmitHeight, [{ConMiner1Addr, _, 3, 4}]} =
        txn_mgr_query_txn(Txn3Key, Miner),
    {ok, Txn4Key, _, Txn4SubmitHeight, [{ConMiner1Addr, _, 4, 4}]} =
        txn_mgr_query_txn(Txn4Key, Miner),

    %% force one txn in the sidecar buffer to be processed
    %% and then get the queue pos of the remaining txns
    %% force the random_n function to return txn1
    %% when this is processed txns 2 - 4 will all then
    %% move up the buffer
    [
        ok =
            ct_rpc:call(
                Node,
                meck,
                expect,
                [hbbft_utils, random_n, fun(_, _) -> [blockchain_txn:serialize(SignedTxn1)] end],
                300
            )
    ||
        Node <- ConMiners
    ],
    %% wait for a block to allow txn1 to be dequeued
    %% and then force random_n to return an empty list again
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 4),
    [
        ok =
            ct_rpc:call(
                Node,
                meck,
                expect,
                [hbbft_utils, random_n, fun(_, _) -> [] end],
                300
            )
    ||
        Node <- ConMiners
    ],

    %% await at least 5 blocks
    %% this gives time for the txn's updated queue data
    %% to be propagated back to txn mgr cache
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 10),

    %% requery the cg member's sidecar and confirm new buffer queue data
    {{ok, 1, 3}, _}  = ct_rpc:call(ConMiner1, miner_hbbft_sidecar, handle_txn, [update, SignedTxn2]),
    {{ok, 2, 3}, _}  = ct_rpc:call(ConMiner1, miner_hbbft_sidecar, handle_txn, [update, SignedTxn3]),
    {{ok, 3, 3}, _}  = ct_rpc:call(ConMiner1, miner_hbbft_sidecar, handle_txn, [update, SignedTxn4]),
    {{error, not_found}, _IgnoreHeight}  = ct_rpc:call(ConMiner1, miner_hbbft_sidecar, handle_txn, [update, SignedTxn1]),

    %% requery the txn list via txn mgr api
    {ok, Txn2Key, _, Txn2SubmitHeight, [{ConMiner1Addr, _, 1, 3}]} =
        txn_mgr_query_txn(Txn2Key, Miner),
    {ok, Txn3Key, _, Txn3SubmitHeight, [{ConMiner1Addr, _, 2, 3}]} =
        txn_mgr_query_txn(Txn3Key, Miner),
   {ok, Txn4Key, _, Txn4SubmitHeight, [{ConMiner1Addr, _, 3, 3}]} =
        txn_mgr_query_txn(Txn4Key, Miner),

    %% confirm txn mgr only contains 3 txns in its cache
    true = miner_ct_utils:wait_until(
                                        fun()->
                                            maps:size(get_cached_txns_with_exclusions(Miner, IgnoredTxns)) == 3
                                        end, 60, 100),

    ok.

txn_queue_protocol_v2_test(Config) ->
    %% using v2 of the txn protocol
    %% send a bunch of txns via the grpc submit API
    %% wait for them to appear in the sidecar buffer
    %% validate each txns position in the buffer
    %% as we are running on a v3 node, sidecar queue data
    %% will still be available
    %% however the txn mgr will only receive v2 data
    %% meaning it will not receive any queue position data
    %% and those values will default to zero

    Miners = ?config(miners, Config),
    AddrList = ?config(tagged_miner_addresses, Config),

    %% remove the v3 protocol handler,
    %% force the test to run on v2 protocol
    lists:foreach(
                fun(M) ->
                    Swarm = ct_rpc:call(M, blockchain_swarm, tid, [], 2000),
                    ct_rpc:call(
                        M,
                        libp2p_swarm,
                        remove_stream_handler,
                        [Swarm, ?TX_PROTOCOL_V3]
                    )
                end,
                Miners
    ),

    %% run the common elements of the test
    %% which are shared across all 3 queue
    %% tests ( one for each of the txn protocols )
    Config1 = txn_queue_common_test(Config),
    %% the common test appends a shared dataset
    %% to the config
    %% take what we need from it to complete
    %% the rest of this test
    CommonDataMap = ?config(common_data, Config1),
    #{
        txn1_key := Txn1Key,
        txn2_key := Txn2Key,
        txn3_key := Txn3Key,
        txn4_key := Txn4Key,
        txn1_submit_height := Txn1SubmitHeight,
        txn2_submit_height := Txn2SubmitHeight,
        txn3_submit_height := Txn3SubmitHeight,
        txn4_submit_height := Txn4SubmitHeight,
        con_miner_1 := ConMiner1,
        miner := Miner,
        last_height :=  Height
    } = CommonDataMap,
    ConMiner1Addr = miner_ct_utils:node2addr(ConMiner1, AddrList),

    %% query the txn mgr txn status API
    %% queue data will not be available and will default to zero
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 3),
    {ok, Txn1Key, _, Txn1SubmitHeight, [{ConMiner1Addr, _, 0, 0}]} =
        txn_mgr_query_txn(Txn1Key, Miner),
    {ok, Txn2Key, _, Txn2SubmitHeight, [{ConMiner1Addr, _, 0, 0}]} =
        txn_mgr_query_txn(Txn2Key, Miner),
    {ok, Txn3Key, _, Txn3SubmitHeight, [{ConMiner1Addr, _, 0, 0}]} =
        txn_mgr_query_txn(Txn3Key, Miner),
    {ok, Txn4Key, _, Txn4SubmitHeight, [{ConMiner1Addr, _, 0, 0}]} =
        txn_mgr_query_txn(Txn4Key, Miner),

    ok.

txn_queue_protocol_v1_test(Config) ->
    %% using v1 of the txn protocol
    %% send a bunch of txns via the grpc submit API
    %% wait for them to appear in the sidecar buffer
    %% validate each txns position in the buffer
    %% as we are running on a v3 node, sidecar queue data
    %% will still be available
    %% however the txn mgr will only receive v1 data
    %% meaning it will not receive any queue position data
    %% and those values will default to zero

    Miners = ?config(miners, Config),
    AddrList = ?config(tagged_miner_addresses, Config),

    %% remove the v3 and v2 protocol handlers,
    %% force the test to run on v1 protocol
    lists:foreach(
                fun(M) ->
                    Swarm = ct_rpc:call(M, blockchain_swarm, tid, [], 2000),
                    ct_rpc:call(
                        M,
                        libp2p_swarm,
                        remove_stream_handler,
                        [Swarm, ?TX_PROTOCOL_V3]
                    ),
                    ct_rpc:call(
                        M,
                        libp2p_swarm,
                        remove_stream_handler,
                        [Swarm, ?TX_PROTOCOL_V2]
                    )
                end,
                Miners
    ),
    %% run the common elements of the test
    %% which are shared across all 3 queue
    %% tests ( one for each of the txn protocols )
    Config1 = txn_queue_common_test(Config),
    %% the common test appends a shared dataset
    %% to the config
    %% take what we need from it to complete
    %% the rest of this test
    CommonDataMap = ?config(common_data, Config1),
    #{
        txn1_key := Txn1Key,
        txn2_key := Txn2Key,
        txn3_key := Txn3Key,
        txn4_key := Txn4Key,
        txn1_submit_height := Txn1SubmitHeight,
        txn2_submit_height := Txn2SubmitHeight,
        txn3_submit_height := Txn3SubmitHeight,
        txn4_submit_height := Txn4SubmitHeight,
        con_miner_1 := ConMiner1,
        miner := Miner,
        last_height :=  Height
    } = CommonDataMap,
    ConMiner1Addr = miner_ct_utils:node2addr(ConMiner1, AddrList),

    %% query the txn mgr txn status API
    %% queue data will not be available and will default to zero
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 3),
    {ok, Txn1Key, _, Txn1SubmitHeight, [{ConMiner1Addr, _, 0, 0}]} =
        txn_mgr_query_txn(Txn1Key, Miner),
    {ok, Txn2Key, _, Txn2SubmitHeight, [{ConMiner1Addr, _, 0, 0}]} =
        txn_mgr_query_txn(Txn2Key, Miner),
    {ok, Txn3Key, _, Txn3SubmitHeight, [{ConMiner1Addr, _, 0, 0}]} =
        txn_mgr_query_txn(Txn3Key, Miner),
    {ok, Txn4Key, _, Txn4SubmitHeight, [{ConMiner1Addr, _, 0, 0}]} =
        txn_mgr_query_txn(Txn4Key, Miner),

    ok.

txn_queue_common_test(Config) ->
    %% this sets up and runs the elements of the
    %% txn queue tests which are common
    %% across all 3 protocol versions
    %% any data required by the parent
    %% will be added to the config

    Miners = ?config(miners, Config),
    NonConMiners = ?config(non_consensus_miners, Config),
    Miner = hd(NonConMiners),
    ConMiners = ?config(consensus_miners, Config),
    ConMiner1 = hd(ConMiners),
    AddrList = ?config(tagged_miner_addresses, Config),

    Addr = miner_ct_utils:node2addr(Miner, AddrList),
    ConMiner1Addr = miner_ct_utils:node2addr(ConMiner1, AddrList),

    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    ct:pal("consensus miners ~p", [ConMiners]),
    ct:pal("non consensus miners ~p", [NonConMiners]),
    ct:pal("miner in use ~p", [Miner]),
    ct:pal("consensus miner in use ~p", [ConMiner1]),
    ct:pal("consensus miner bin in use ~p", [ConMiner1Addr]),

    PayerAddr = Addr,
    Payee = hd(miner_ct_utils:shuffle(ConMiners)),
    PayeeAddr = miner_ct_utils:node2addr(Payee, AddrList),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),
    IgnoredTxns = [],

    %% meck out the sidecar random_n function
    %% make it return an empty list
    %% simulate an empty buffer
    %% this should result in the submitted txns
    %% remaining in the sidecar buffer
    meck:new(hbbft_utils, [passthrough]),
    [
            ok =
            ct_rpc:call(
                Node,
                meck,
                expect,
                [hbbft_utils, random_n, fun(_, _) -> [] end],
                3000
            )
    ||
        Node <- ConMiners
    ],

    %% meck out the signatory_rand_members function
    %% force it to always return a deterministic list of acceptors
    %% which in this case will be a single consensus member
    %% this will result in the txn mgr pushing its cached txns
    %% to this single CG member
    %% and thus we can ensure we only need to check the sidecar
    %% buffer on a single and known CG member

    %% also meck out is_valid for payment txns
    %% this test is not concerned with validity issues
    meck:new(blockchain_txn_mgr, [passthrough]),
    meck:new(blockchain_txn_payment_v1, [passthrough]),
    meck:new(blockchain_txn, [passthrough]),
    [
        begin
            ok =
            ct_rpc:call(
                Node,
                meck,
                expect,
                [blockchain_txn_mgr, signatory_rand_members, fun(_, _, _, _, _) -> {ok, [ConMiner1Addr]} end],
                3000
            ),
            ok =
            ct_rpc:call(
                Node,
                meck,
                expect,
                [blockchain_txn_payment_v1, is_valid, fun(_, _) -> ok end],
                3000
            ),
            ok =
            ct_rpc:call(
                Node,
                meck,
                expect,
                [blockchain_txn, absorb, fun(_, _) -> ok end],
                3000
            )
        end
    ||
        Node <- Miners
    ],

    %% get the start height, after all prep
    {ok, Height} = ct_rpc:call(Miner, blockchain, height, [Chain]),

    %% prep the txns, 1 - 4
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 2),
    StartNonce = miner_ct_utils:get_nonce(Miner, Addr),
    ct:pal("start nonce: ~p", [StartNonce]),
    Txn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+1]),
    SignedTxn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    Txn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+2]),
    SignedTxn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),
    Txn3 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+3]),
    SignedTxn3 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn3, SigFun]),
    Txn4 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, StartNonce+4]),
    SignedTxn4 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn4, SigFun]),


    %% submit the txns via the txn mgr api
    %% same API as used by the grpc txn submit
    %% submit each txn at 1 block intervals
    %% helps to ensure they get submitted in order to sidecar
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 3),
    {ok, Txn1Key, Txn1SubmitHeight} = ct_rpc:call(Miner, blockchain_txn_mgr, grpc_submit, [SignedTxn1]),
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 4),
    {ok, Txn2Key, Txn2SubmitHeight} = ct_rpc:call(Miner, blockchain_txn_mgr, grpc_submit, [SignedTxn2]),
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 5),
    {ok, Txn3Key, Txn3SubmitHeight} = ct_rpc:call(Miner, blockchain_txn_mgr, grpc_submit, [SignedTxn3]),
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 6),
    {ok, Txn4Key, Txn4SubmitHeight} = ct_rpc:call(Miner, blockchain_txn_mgr, grpc_submit, [SignedTxn4]),
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 7),

    %% we dont want the txns being submitted multiple times to the same CG member
    %% so force no new members to be returned as available dialers
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 8),
    [
            ok =
            ct_rpc:call(
                Node,
                meck,
                expect,
                [blockchain_txn_mgr, signatory_rand_members, fun(_, _, _, _, _) -> {ok, []} end],
                3000
            )
    ||
        Node <- Miners
    ],

    %% confirm all txns are in txn mgr cache
    true = miner_ct_utils:wait_until(
        fun()->
            maps:size(get_cached_txns_with_exclusions(Miner, IgnoredTxns)) == 4
        end, 60, 500),

    %% query the cg member's sidecar and confirm buffer queue data
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, Height + 10),
    {{ok, 1, 4}, _}  = ct_rpc:call(ConMiner1, miner_hbbft_sidecar, handle_txn, [update, SignedTxn1]),
    {{ok, 2, 4}, _}  = ct_rpc:call(ConMiner1, miner_hbbft_sidecar, handle_txn, [update, SignedTxn2]),
    {{ok, 3, 4}, _}  = ct_rpc:call(ConMiner1, miner_hbbft_sidecar, handle_txn, [update, SignedTxn3]),
    {{ok, 4, 4}, _}  = ct_rpc:call(ConMiner1, miner_hbbft_sidecar, handle_txn, [update, SignedTxn4]),

    [
        {common_data, #{
            txn1 => SignedTxn1,
            txn2 => SignedTxn2,
            txn3 => SignedTxn3,
            txn4 => SignedTxn4,
            txn1_key => Txn1Key,
            txn2_key => Txn2Key,
            txn3_key => Txn3Key,
            txn4_key => Txn4Key,
            txn1_submit_height => Txn1SubmitHeight,
            txn2_submit_height => Txn2SubmitHeight,
            txn3_submit_height => Txn3SubmitHeight,
            txn4_submit_height => Txn4SubmitHeight,
            con_miner_1 => ConMiner1,
            miner => Miner,
            last_height =>  Height + 10
        }} | Config].

txn_from_future_via_protocol_v3_test(Cfg) ->

    txn_from_future_test(
        fun() -> ok end,
        fun(A, TxnHash) ->
            %% In V2 mode, with temporal data available, we expect for the
            %% rejection from the future to be identified as such, and
            %% deferred:
            ?assertMatch([_|_], fetch_deferred_rejections(A, TxnHash))
        end,
        fun(A, TxnHash) ->
            %% Finally, we expect the deferred transaction to have been
            %% dequeued:
            ?assertMatch([], fetch_deferred_rejections(A, TxnHash))
        end,
        fun(A_SubmissionResult) ->
            %% Expecting ok, not error,
            %% BECAUSE the reason for B's rejection of T was that
            %% T is already in B's chain,
            %% so A is expected to have fired its T submission callback
            %% during the sync with B,
            %% after being unlocked, and
            %% upon receiving a block containing T.
            %% See calls to purge_block_txns_from_cache/1 within blockchain_txn_mgr.
            ?assertMatch(ok, A_SubmissionResult)
        end,
        Cfg
    ).

txn_from_future_via_protocol_v2_test(Cfg) ->

    Miners = ?config(consensus_miners, Cfg),
    DoInit =
        fun() ->
            %% Remove V3 handler, force it to use v2
            lists:foreach(
                fun(M) ->
                    Swarm = ct_rpc:call(M, blockchain_swarm, tid, [], 2000),
                    ct_rpc:call(
                        M,
                        libp2p_swarm,
                        remove_stream_handler,
                        [Swarm, ?TX_PROTOCOL_V3]
                    )
                end,
                Miners
            )
        end,

    txn_from_future_test(
        DoInit,
        fun(A, TxnHash) ->
            %% In V2 mode, with temporal data available, we expect for the
            %% rejection from the future to be identified as such, and
            %% deferred:
            ?assertMatch([_|_], fetch_deferred_rejections(A, TxnHash))
        end,
        fun(A, TxnHash) ->
            %% Finally, we expect the deferred transaction to have been
            %% dequeued:
            ?assertMatch([], fetch_deferred_rejections(A, TxnHash))
        end,
        fun(A_SubmissionResult) ->
            %% Expecting ok, not error,
            %% BECAUSE the reason for B's rejection of T was that
            %% T is already in B's chain,
            %% so A is expected to have fired its T submission callback
            %% during the sync with B,
            %% after being unlocked, and
            %% upon receiving a block containing T.
            %% See calls to purge_block_txns_from_cache/1 within blockchain_txn_mgr.
            ?assertMatch(ok, A_SubmissionResult)
        end,
        Cfg
    ).

txn_from_future_via_protocol_v1_test(Cfg) ->
    Miners = ?config(consensus_miners, Cfg),
    DoInit =
        fun() ->
            %% Remove V3 and V2 handlers so only V1 is available:
            lists:foreach(
                fun(M) ->
                    Swarm = ct_rpc:call(M, blockchain_swarm, tid, [], 2000),
                    ct_rpc:call(
                        M,
                        libp2p_swarm,
                        remove_stream_handler,
                        [Swarm, ?TX_PROTOCOL_V3]
                    ),
                    ct_rpc:call(
                        M,
                        libp2p_swarm,
                        remove_stream_handler,
                        [Swarm, ?TX_PROTOCOL_V2]
                    )
                end,
                Miners
            )
        end,
    AssertDeferredRejections1 =
        fun(LaggingNode, TxnHash) ->
            %% V1 loses temporal data, so a lagging node cannot tell that the
            %% rejection came from the future, so it assumes it came from the
            %% present, thus a deferral never occurs:
            ?assertMatch([], fetch_deferred_rejections(LaggingNode, TxnHash))
        end,
    AssertDeferredRejections2 =
        fun(LaggingNode, TxnHash) ->
            %% We expect deferrals to remain empty:
            ?assertMatch([], fetch_deferred_rejections(LaggingNode, TxnHash))
        end,
    AssertSubmissionCallbackResult =
        fun(LaggingNodeSubmissionResult) ->
            ?assertMatch({error, _}, LaggingNodeSubmissionResult)
        end,
    txn_from_future_test(
        DoInit,
        AssertDeferredRejections1,
        AssertDeferredRejections2,
        AssertSubmissionCallbackResult,
        Cfg
    ).

txn_from_future_test(
    DoInit,
    AssertDeferredRejections1,
    AssertDeferredRejections2,
    AssertSubmissionCallbackResult,
    Cfg
) ->
    %% Premise:
    %%   A node A at height H
    %%   should not count a rejection from a peer B at height H+K,
    %%   until A itself reaches height H+K.
    %% Scenario:
    %%   Given:
    %%     2 nodes: A and B
    %%     1 transaction: T
    %%     A and B begin at the same height
    %%   Test:
    %%     A is locked (approximated netsplit?)
    %%     T is submitted to B
    %%     B accepts and commits T to chain (along with peers other than A)
    %%     A is now behind B (because B added a block while A was locked)
    %%     T is submitted to A
    %%     A accepts T (because it does not have it in its (locked) chain)
    %%     B rejects T (because it sees it as a duplicate)
    %%     A receives B's rejection,
    %%       but considers it to have come from the future
    %%       (since B's height is higher than A's)
    %%     A defers processing B's rejection of T
    %%       until A's height catches up to that of the rejection
    %%     A is unlocked
    %%     A syncs with B
    %%     A processes:
    %%       - cached T
    %%       - deferred rejection of T

    [A, B | _] = Miners = ?config(consensus_miners, Cfg),
    AddrList = ?config(tagged_miner_addresses, Cfg),
    {ok, _Pubkey, A_SigFun, _ECDHFun} = ct_rpc:call(A, blockchain_swarm, keys, []),
    A_Addr = miner_ct_utils:node2addr(A, AddrList),
    B_Addr = miner_ct_utils:node2addr(B, AddrList),
    A_Nonce0 = miner_ct_utils:get_nonce(A, A_Addr),
    AmountStart = 5000,
    AmountDelta = 1000,

    %% A tweakable guess of how many blocks are long-enough to wait on for all
    %% the expected things to take place:
    HeightDelta = 2,

    Txn =
        (fun() ->
            Nonce = A_Nonce0 + 1,
            Txn = blockchain_txn_payment_v1:new(A_Addr, B_Addr, AmountDelta, Nonce),
            blockchain_txn_payment_v1:sign(Txn, A_SigFun)
        end)(),
    TxnHash = blockchain_txn:hash(Txn),

    %% Custom conditions
    ok = DoInit(),

    %% Begin at the same height:
    _ = miner_ct_utils:wait_for_equalized_heights(Miners),

    %% Begin with the same balance:
    ok = miner_ct_utils:confirm_balance(Miners, A_Addr, AmountStart),
    ok = miner_ct_utils:confirm_balance(Miners, B_Addr, AmountStart),

    %% Prevent A from syncing chain with peers:
    A_LockRef = node_lock(A),

    %% Submit T to B, ensuring it has been committed to chain:
    true =
        wait_until(
            fun() ->
                AmountStart == miner_ct_utils:get_balance(B, A_Addr)
                andalso
                AmountStart == miner_ct_utils:get_balance(B, B_Addr)
            end
        ),
    ok = ct_rpc:call(B, blockchain_worker, submit_txn, [Txn]),
    true =
        wait_until(
            fun() ->
                A_Balance = miner_ct_utils:get_balance(B, A_Addr),
                B_Balance = miner_ct_utils:get_balance(B, B_Addr),
                (AmountStart - AmountDelta) == A_Balance
                andalso
                (AmountStart + AmountDelta) == B_Balance
            end
        ),

    %% The most important condition for the whole test case: A falls behind B:
    true =
        wait_until(
            fun() -> miner_ct_utils:height(A) < miner_ct_utils:height(B) end
        ),

    %% Submit dup txn
    HeightAtB = miner_ct_utils:height(B),
    A_SubmissionRef = txn_submit(A, Txn),

    %% If not forced, this queue processing would only be triggered by a new
    %% block creation:
    ok = ct_rpc:call(A, blockchain_txn_mgr, force_process_cached_txns, []),

    %% B advanced, but balance didn't change since last acceptance,
    %% implying dup txn was not accepted:
    ok = miner_ct_utils:wait_for_gte(height, [B], HeightAtB + HeightDelta),
    ?assert(
        (AmountStart - AmountDelta) == miner_ct_utils:get_balance(B, A_Addr)
        andalso
        (AmountStart + AmountDelta) == miner_ct_utils:get_balance(B, B_Addr)
    ),

    %% Since B advanced already, A should have received B's rejection already:
    AssertDeferredRejections1(A, TxnHash),

    %% A did not yet process T
    receive {A_SubmissionRef, _} -> ?assert(false) after 0 -> ok end,

    %% Let A catch-up and advance:
    ok = node_unlock(A, A_LockRef),
    HeightAtAllPeers = miner_ct_utils:wait_for_equalized_heights(Miners),
    ok = miner_ct_utils:wait_for_gte(height, [A], HeightAtAllPeers + HeightDelta),

    %% Assert A processed T
    receive
        {A_SubmissionRef, A_SubmissionResult} ->
            AssertSubmissionCallbackResult(A_SubmissionResult)
    after 0 ->
        ?assert(false)
    end,

    AssertDeferredRejections2(A, TxnHash),

    ok.

%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------

%% Just a shortcut for elevated defaults:
wait_until(F) ->
    miner_ct_utils:wait_until(
        F,
        60,   % retries
        1000  % inter-retry backoff in milliseconds
    ).

txn_submit(Node, Txn) ->
    SubmissionRef = make_ref(),
    TestPid = self(),
    SubmissionCallback =
        fun (Result) -> TestPid ! {SubmissionRef, Result} end,
    ok = ct_rpc:call(Node, blockchain_txn_mgr, submit, [Txn, SubmissionCallback]),
    SubmissionRef.

fetch_deferred_rejections(Node, TxnHash) ->
    IsMatch = fun({_, _, _, T, _}) -> TxnHash =:= blockchain_txn:hash(T) end,
    Deferred = ct_rpc:call(Node, blockchain_txn_mgr, get_rejections_deferred, []),
    [T || T <- Deferred, IsMatch(T)].

-spec node_lock(atom()) -> reference().
node_lock(Node) ->
    LockRef = make_ref(),
    ok = gen_server:call({blockchain_lock, Node}, {acquire, LockRef}),
    LockRef.

-spec node_unlock(atom(), reference()) -> ok.
node_unlock(Node, LockRef) ->
    {blockchain_lock, Node} ! {LockRef, release},
    ok.

handle_get_cached_txn_result(Result, Miner, IgnoredTxns, Chain)->
    case Result of
        true ->
            ok;
        false ->
          TxnList = get_cached_txns_with_exclusions(Miner, IgnoredTxns),
          {ok, CurHeight} = ct_rpc:call(Miner, blockchain, height, [Chain]),
          ct:pal("~p", [miner_ct_utils:format_txn_mgr_list(TxnList)]),
          ct:fail("unexpected txns in txn_mgr cache for miner ~p. Current height ~p",[Miner, CurHeight])
    end.


get_cached_txns_with_exclusions(Miner, Exclusions)->
    case ct_rpc:call(Miner, blockchain_txn_mgr, txn_list, []) of
        TxnMap when map_size(TxnMap) > 0 ->
            ct:pal("~p txns in txn list", [maps:size(TxnMap)]),
            maps:filter(
                fun(Txn, _TxnData)->
                    not lists:member(blockchain_txn:type(Txn), Exclusions) end, TxnMap);
        _ ->
            ct:pal("empty txn map", []),
            #{}
    end.

nonce_updated_for_miner(Addr, ExpectedNonce, ConMiners)->
    true = miner_ct_utils:wait_until(
        fun() ->
            HaveNoncesIncremented =
                lists:map(fun(M) ->
                            Nonce = miner_ct_utils:get_nonce(M, Addr),
                            Nonce == ExpectedNonce
                          end, ConMiners),
            [true] == lists:usort(HaveNoncesIncremented)
        end, 200, 1000).

txn_mgr_query_txn(TxnKey, Miner) ->
    ct:pal("txn mgr query, key: ~p, miner: ~p",
        [TxnKey, Miner]),
    {ok, pending, TxnMgrData} = ct_rpc:call(Miner, blockchain_txn_mgr, txn_status, [TxnKey]),
    ct:pal("TxnMgrData: ~p", [TxnMgrData]),
    #{  key := RespTxnKey,
        height := RespCurHeight,
        recv_block_height := RespTxnSubmitHeight,
        acceptors := RespAcceptors1 } = TxnMgrData,
    {ok, RespTxnKey, RespCurHeight, RespTxnSubmitHeight, RespAcceptors1}.
