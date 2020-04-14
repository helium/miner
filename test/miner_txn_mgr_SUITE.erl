-module(miner_txn_mgr_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
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
         txn_dependent_test/1

        ]).

%% common test callbacks

all() -> [
          txn_in_sequence_nonce_test,
          txn_out_of_sequence_nonce_test,
          txn_invalid_nonce_test,
          txn_dependent_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(?MODULE, _TestCase, Config0),

    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, h3:from_geo({37.780586, -122.469470}, 13), 0)
                 || Addr <- Addresses],

    NumConsensusMembers = ?config(num_consensus_members, Config),
    BlockTime = ?config(block_time, Config),
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, #{?block_time => BlockTime,
                                                   %% rule out rewards
                                                   ?election_interval => infinity,
                                                   ?num_consensus_members => NumConsensusMembers,
                                                   ?batch_size => BatchSize,
                                                   ?dkg_curve => Curve}),

    DKGResults = miner_ct_utils:inital_dkg(Miners, InitialVars ++ InitialPaymentTransactions ++ AddGwTxns,
                                             Addresses, NumConsensusMembers, Curve),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),

    %% Get both consensus and non consensus miners
    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),
    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(ConsensusMiners), NonConsensusMiners),

    %% confirm we have a height of 1
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, 1),

    [   {consensus_miners, ConsensusMiners},
        {non_consensus_miners, NonConsensusMiners}
        | Config].


end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).


txn_in_sequence_nonce_test(Config) ->
    %% send two standalone payments, with correctly sequenced nonce values
    %% both txns are sent in quick succession
    %% these should clear through the txn mgr right away without probs
    Miner = hd(?config(non_consensus_miners, Config)),
    ConMiners = ?config(consensus_miners, Config),
    IgnoredTxns = [blockchain_txn_poc_receipts_v1],
    Addr = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),

    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Miner, blockchain, ledger, [Chain]),
    {ok, Fee} = ct_rpc:call(Miner, blockchain_ledger_v1, transaction_fee, [Ledger]),

    PayerAddr = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),
    Payee = hd(miner_ct_utils:shuffle(ConMiners)),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    StartNonce = miner_ct_utils:get_nonce(Miner, Addr),
    {ok, StartHeight} = ct_rpc:call(Miner, blockchain, height, [Chain]),

    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    %% the first txn
    Txn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, StartNonce+1]),
    SignedTxn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    %% the second txn
    Txn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, StartNonce+2]),
    SignedTxn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),
    %% send the txns
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn1]),
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn2]),

    %% both txns should have been accepted by the CG and removed from the txn mgr cache
    %% txn mgr cache should be empty
    Result = miner_ct_utils:wait_until(
                                        fun()->
                                            case get_cached_txns_with_exclusions(Miner, IgnoredTxns) of
                                                [] -> true;
                                                _ -> false
                                            end
                                        end, 20, 5000),
    ok = handle_get_cached_txn_result(Result, Miner, IgnoredTxns),

    %% check the miners nonce values to be sure the txns have actually been absorbed and not just lost
    miner_ct_utils:wait_for_gte(height, [Miner], StartHeight + 10),
    ExpectedNonce = StartNonce +2,
    ExpectedNonce = miner_ct_utils:get_nonce(Miner, Addr),

    ok.



txn_out_of_sequence_nonce_test(Config) ->
    %% send two standalone payments, but out of order so that the first submitted has an out of sequence nonce
    %% this will result in validations determining undecided and the txn stays in txn mgr
    %% until the prior txn is absorbed
    %% thereafter both will
    Miner = hd(?config(non_consensus_miners, Config)),
    ConMiners = ?config(consensus_miners, Config),
    IgnoredTxns = [blockchain_txn_poc_receipts_v1],
    Addr = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),

    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Miner, blockchain, ledger, [Chain]),
    {ok, Fee} = ct_rpc:call(Miner, blockchain_ledger_v1, transaction_fee, [Ledger]),

    PayerAddr = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),
    Payee = hd(miner_ct_utils:shuffle(ConMiners)),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    StartNonce = miner_ct_utils:get_nonce(Miner, Addr),
    {ok, StartHeight} = ct_rpc:call(Miner, blockchain, height, [Chain]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    %% the first txn
    Txn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, StartNonce+1]),
    SignedTxn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    %% the second txn
    Txn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, StartNonce+2]),
    SignedTxn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),

    %% send txn 2 first
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn2]),

    %% confirm the txn remains in the txn mgr cache
    %% it should be the only txn
    Result1 = miner_ct_utils:wait_until(
        fun() ->
            case get_cached_txns_with_exclusions(Miner, IgnoredTxns) of
                [] -> true;
                FilteredTxns ->
                    %% we expect the payment txn to remain as its nonce is too far ahead
                    case FilteredTxns of
                        [{SignedTxn2, {_Callback, _RecvBlockHeight, _Acceptions, _Rejections, _Dialers}}] -> true;
                        _ -> false
                    end
            end
        end, 20, 5000),
    ok = handle_get_cached_txn_result(Result1, Miner, IgnoredTxns),

    %% now submit the other txn which will have the missing nonce
    %% this should result in both this and the previous txn being accepted by the CG
    %% and cleared out of the txn mgr
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn1]),

    %% both txn should now have been accepted by the CG and removed from the txn mgr cache
    %% txn mgr cache should be empty
    Result2 = miner_ct_utils:wait_until(
                                        fun()->
                                            case get_cached_txns_with_exclusions(Miner, IgnoredTxns) of
                                                [] -> true;
                                                _ -> false
                                            end
                                        end, 20, 5000),
    ok = handle_get_cached_txn_result(Result2, Miner, IgnoredTxns),

    %% check the miners nonce values to be sure the txns have actually been absorbed and not just lost
    miner_ct_utils:wait_for_gte(height, [Miner], StartHeight + 10),
    ExpectedNonce = StartNonce +2,
    ExpectedNonce = miner_ct_utils:get_nonce(Miner, Addr),

    ok.


txn_invalid_nonce_test(Config) ->
    %% send two standalone payments, the second with a duplicate/invalid nonce
    %% the first txn will be successful, the second should be declared invalid
    %% both will be removed from the txn mgr cache,
    %% the first because it is absorbed, the second because it is invalid
    Miner = hd(?config(non_consensus_miners, Config)),
    ConMiners = ?config(consensus_miners, Config),
    IgnoredTxns = [blockchain_txn_poc_receipts_v1],
    Addr = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),

    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Miner, blockchain, ledger, [Chain]),
    {ok, Fee} = ct_rpc:call(Miner, blockchain_ledger_v1, transaction_fee, [Ledger]),

    PayerAddr = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),
    Payee = hd(miner_ct_utils:shuffle(ConMiners)),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    StartNonce = miner_ct_utils:get_nonce(Miner, Addr),
    {ok, StartHeight} = ct_rpc:call(Miner, blockchain, height, [Chain]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    %% the first txn
    Txn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, StartNonce+1]),
    SignedTxn1 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    %% the second txn - with the same nonce as the first
    Txn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, StartNonce+1]),
    SignedTxn2 = ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),
    %% send txn1
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn1]),

    %% wait until the first txn has been accepted by the CG and removed from the txn mgr cache
    %% txn mgr cache should be empty
    Result1 = miner_ct_utils:wait_until(
                                        fun()->
                                            case get_cached_txns_with_exclusions(Miner, IgnoredTxns) of
                                                [] -> true;
                                                _ -> false
                                            end
                                        end, 20, 5000),
    ok = handle_get_cached_txn_result(Result1, Miner, IgnoredTxns),

    %% now send the second txn ( with the dup nonce )
    ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn2]),

    %% give the second txn a bit of time to be processed by the txn mgr and for it to be declared invalid
    %% and removed from the txn mgr cache
    Result2 = miner_ct_utils:wait_until(
                                        fun()->
                                            case get_cached_txns_with_exclusions(Miner, IgnoredTxns) of
                                                [] -> true;
                                                _ -> false
                                            end
                                        end, 20, 5000),
    ok = handle_get_cached_txn_result(Result2, Miner, IgnoredTxns),

    %% check the miners nonce values to be sure the txns have actually been absorbed and not just lost
    miner_ct_utils:wait_for_gte(height, [Miner], StartHeight + 10),
    ExpectedNonce = StartNonce +1,
    ExpectedNonce = miner_ct_utils:get_nonce(Miner, Addr),

    ok.


txn_dependent_test(Config) ->
    %% send a bunch of dependent txns
    %% give them time to be accepted by the CG group and
    %% confirm we dont have any strays in the txn mgr cache at the end of it
    Miner = hd(?config(non_consensus_miners, Config)),
    ConMiners = ?config(consensus_miners, Config),
    Count = 50,
    Addr = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),

    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Miner, blockchain, ledger, [Chain]),
    {ok, Fee} = ct_rpc:call(Miner, blockchain_ledger_v1, transaction_fee, [Ledger]),

    PayerAddr = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),
    Payee = hd(miner_ct_utils:shuffle(ConMiners)),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    IgnoredTxns = [blockchain_txn_poc_receipts_v1],
    StartNonce = miner_ct_utils:get_nonce(Miner, Addr),
    {ok, StartHeight} = ct_rpc:call(Miner, blockchain, height, [Chain]),

    %% send a bunch of dependant txns and ensure they are processed by the txn mgr
    %% and dont hang around it its cache
    UnsignedTxns = [ ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1, Fee, Nonce]) || Nonce <- lists:seq(1, Count) ],
    SignedTxns = [ ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn, SigFun]) || Txn <- UnsignedTxns],
    [ ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn]) || SignedTxn <- miner_ct_utils:shuffle(SignedTxns) ],
    IgnoredTxns = [blockchain_txn_poc_receipts_v1],
    Result1 = miner_ct_utils:wait_until(
                                        fun()->
                                            case get_cached_txns_with_exclusions(Miner, IgnoredTxns) of
                                                [] -> true;
                                                _ -> false
                                            end
                                        end, 60, 5000),
    ok = handle_get_cached_txn_result(Result1, Miner, IgnoredTxns),
    %% check the miners nonce values to be sure the txns have actually been absorbed and not just lost
    miner_ct_utils:wait_for_gte(height, [Miner], StartHeight + 10),
    ExpectedNonce = StartNonce +50,
    ExpectedNonce = miner_ct_utils:get_nonce(Miner, Addr),

    ok.


%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------
handle_get_cached_txn_result(Result, Miner, IgnoredTxns)->
    case Result of
        true ->
            ok;
        false ->
          TxnList = get_cached_txns_with_exclusions(Miner, IgnoredTxns),
          ct:pal("~p", [format_txn_list(TxnList)]),
          ct:fail("unexpected txns in txn_mgr cache for miner ~p",[Miner])
    end.


get_cached_txns_with_exclusions(Miner, Exclusions)->
    case ct_rpc:call(Miner, blockchain_txn_mgr, txn_list, []) of
        [] -> [];
        Txns ->
            lists:filter(
                fun({Txn, {_Callback, _RecvBlockHeight, _Acceptions, _Rejections, _Dialers}})->
                    not lists:member(blockchain_txn:type(Txn), Exclusions) end, Txns)
    end.

format_txn_list(TxnList) ->
    lists:map(fun({Txn, {_Callback, RecvBlockHeight, Acceptions, Rejections, _Dialers}}) ->
                      TxnMod = blockchain_txn:type(Txn),
                      TxnHash = blockchain_txn:hash(Txn),
                      [
                       {txn_type, atom_to_list(TxnMod)},
                       {txn_hash, io_lib:format("~p", [libp2p_crypto:bin_to_b58(TxnHash)])},
                       {acceptions, length(Acceptions)},
                       {rejections, length(Rejections)},
                       {accepted_block_height, RecvBlockHeight},
                       {active_dialers, length(_Dialers)}
                      ]
              end, TxnList).
