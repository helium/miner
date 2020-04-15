-module(miner_payment_txn_SUITE).

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
         single_payment_test/1,
         self_payment_test/1,
         bad_payment_test/1,
         dependent_payment_test/1
        ]).

%% common test callbacks

all() -> [
          single_payment_test,
          self_payment_test,
          bad_payment_test,
          dependent_payment_test
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
    %% VarCommitInterval = ?config(var_commit_interval, Config),

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, #{?block_time => BlockTime,
                                                   %% rule out rewards
                                                   ?election_interval => infinity,
                                                   ?num_consensus_members => NumConsensusMembers,
                                                   ?batch_size => BatchSize,
                                                   ?dkg_curve => Curve,
                                                   ?allow_zero_amount => false}),

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

single_payment_test(Config) ->
    Miners = ?config(miners, Config),
    ConsensusMiners = ?config(consensus_miners, Config),
    [Payer, Payee | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    %% FIXME: really need to be setting the balances elsewhere
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),

    Chain = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Payer, blockchain, ledger, [Chain]),

    {ok, Fee} = ct_rpc:call(Payer, blockchain_ledger_v1, transaction_fee, [Ledger]),
    ct:pal("Fee: ~p", [Fee]),

    %% send some helium tokens from payer to payee
    Txn = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, 1]),

    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),

    SignedTxn = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn, SigFun]),

    ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [SignedTxn]),

    %% wait until all the nodes agree the payment has happened
    %% NOTE: Fee is zero
    ok = miner_ct_utils:confirm_balance_both_sides(Miners, PayerAddr, PayeeAddr, 4000 + Fee, 6000),

    PayerBalance = miner_ct_utils:get_balance(Payer, PayerAddr),
    PayeeBalance = miner_ct_utils:get_balance(Payee, PayeeAddr),

    4000 = PayerBalance + Fee,
    6000 = PayeeBalance,

    %% put the transaction into and then suspend one of the consensus group members
    Txn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, 2]),

    SignedTxn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),

    %ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [SignedTxn2]),

    Candidate = hd(ConsensusMiners),

    Group = ct_rpc:call(Candidate, gen_server, call, [miner, consensus_group, infinity]),
    false = Group == undefined,
    ok = libp2p_group_relcast:handle_command(Group, SignedTxn2),
    ct_rpc:call(Candidate, sys, suspend, [Group]),

    {ok, CurrentHeight2} = ct_rpc:call(Payer, blockchain, height, [Chain]),

    %% XXX: wait till the blockchain grows by 1 block
    miner_ct_utils:wait_for_gte(height, Miners -- [Candidate], CurrentHeight2 + 1),

    %% the transaction should not have cleared
    PayerBalance2 = miner_ct_utils:get_balance(Payer, PayerAddr),
    PayeeBalance2 = miner_ct_utils:get_balance(Payee, PayeeAddr),

    ?assertEqual(4000, PayerBalance2 + Fee),
    ?assertEqual(6000, PayeeBalance2),

    ct_rpc:call(Candidate, sys, resume, [Group]),

    %% check balances again - transaction should have cleared
    %% NOTE: Fee is zero
    %% NOTE to self: The old balances of 4000 and 6000 also work here as these are the starting values
    %%               the assertAsyc will pick these up initialy and assert true
    %%               If we pass in the new expected balances from after the txns clear, these too work
    %%               as the assertAsync will retry N times until it gets returns for these balances
    %%               ( assuming of course the txns do clear )
    ok = miner_ct_utils:confirm_balance_both_sides(Miners, PayerAddr, PayeeAddr, 3000 + Fee, 7000),

    ct:comment("FinalPayerBalance: ~p, FinalPayeeBalance: ~p", [PayerBalance, PayeeBalance]),
    ok.

self_payment_test(Config) ->
    Miners = ?config(miners, Config),
    [Payer, Payee | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = PayerAddr,

    %% check initial balances
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),

    Chain = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Payer, blockchain, ledger, [Chain]),

    {ok, Fee} = ct_rpc:call(Payer, blockchain_ledger_v1, transaction_fee, [Ledger]),

    %% send some helium tokens from payer to payee
    Txn = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, 1]),

    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),

    SignedTxn = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn, SigFun]),

    ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [SignedTxn]),

    %% XXX: presumably the transaction wouldn't have made it to the blockchain yet
    %% get the current height here
    Chain2 = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    {ok, CurrentHeight} = ct_rpc:call(Payer, blockchain, height, [Chain2]),

    %% XXX: wait till the blockchain grows by 2 blocks
    %% assuming that the transaction makes it within 2 blocks
    miner_ct_utils:wait_for_gte(height, Miners, CurrentHeight + 2),


    PayerBalance = miner_ct_utils:get_balance(Payer, PayerAddr),
    PayeeBalance = miner_ct_utils:get_balance(Payee, PayeeAddr),

    %% No change in balances since the payment should have failed, fee=0 anyway
    5000 = PayerBalance + Fee,
    5000 = PayeeBalance,

    ct:comment("FinalPayerBalance: ~p, FinalPayeeBalance: ~p", [PayerBalance, PayeeBalance]),
    ok.

bad_payment_test(Config) ->
    Miners = ?config(miners, Config),
    [Payer, Payee | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),

    Chain = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Payer, blockchain, ledger, [Chain]),

    {ok, Fee} = ct_rpc:call(Payer, blockchain_ledger_v1, transaction_fee, [Ledger]),

    %% Create a zero amount payment txn
    Amount = 0,
    Txn = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, Amount, Fee, 1]),

    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),

    SignedTxn = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn, SigFun]),

    {error, invalid_transaction} = ct_rpc:call(Payer, blockchain_txn, is_valid, [SignedTxn, Chain]),

    %% Create a negative amount payment txn
    Amount2 = -100,
    Txn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, Amount2, Fee, 1]),

    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),

    SignedTxn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),

    {error, invalid_transaction} = ct_rpc:call(Payer, blockchain_txn, is_valid, [SignedTxn2, Chain]),

    ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [SignedTxn2]),

    %% XXX: presumably the transaction wouldn't have made it to the blockchain yet
    %% get the current height here
    Chain2 = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    {ok, CurrentHeight} = ct_rpc:call(Payer, blockchain, height, [Chain2]),

    %% XXX: wait till the blockchain grows by 2 blocks
    %% assuming that the transaction makes it within 2 blocks
    miner_ct_utils:wait_for_gte(height, Miners, CurrentHeight + 2),


    PayerBalance = miner_ct_utils:get_balance(Payer, PayerAddr),
    PayeeBalance = miner_ct_utils:get_balance(Payee, PayeeAddr),

    %% No change in balances since the payment should have failed, fee=0 anyway
    5000 = PayerBalance + Fee,
    5000 = PayeeBalance,

    ct:comment("FinalPayerBalance: ~p, FinalPayeeBalance: ~p", [PayerBalance, PayeeBalance]),
    ok.

dependent_payment_test(Config) ->
    Miners = ?config(miners, Config),
    Count = 50,
    Chain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(hd(Miners), blockchain, ledger, [Chain]),
    {ok, Fee} = ct_rpc:call(hd(Miners), blockchain_ledger_v1, transaction_fee, [Ledger]),

    lists:foreach(fun(Miner) ->
                        PayerAddr = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),
                        Payee = hd(miner_ct_utils:shuffle(Miners -- [Miner])),
                        PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),
                        {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),
                        UnsignedTxns = [ ct_rpc:call(Miner, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1, Fee, Nonce]) || Nonce <- lists:seq(1, Count) ],
                        SignedTxns = [ ct_rpc:call(Miner, blockchain_txn_payment_v1, sign, [Txn, SigFun]) || Txn <- UnsignedTxns],
                        put(a_txn, {Miner, lists:last(SignedTxns)}),
                        [ ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [SignedTxn]) || SignedTxn <- miner_ct_utils:shuffle(SignedTxns) ]
                end, Miners),


    {AMiner, ATxn} = get(a_txn),
    ct:pal("txn_mgr txn_status ~p ", [ct_rpc:call(AMiner, blockchain_txn_mgr, txn_status, [blockchain_txn:hash(ATxn)])]),

    Result = miner_ct_utils:wait_until(fun() ->
                                             HaveNoncesIncremented = lists:map(fun(Miner) ->
                                                               Addr = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),
                                                               Nonce = miner_ct_utils:get_nonce(Miner, Addr),
                                                               case Nonce == Count of
                                                                   true ->
                                                                       true;
                                                                   false ->
                                                                       TxnList = ct_rpc:call(Miner, blockchain_txn_mgr, txn_list, []),
                                                                       C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                                                       H = ct_rpc:call(Miner, blockchain, height, [C]),
                                                                       ct:pal("nonce for ~p is ~p, ~p transactions in queue at height ~p", [Miner, Nonce, length(TxnList), H]),
                                                                       false
                                                               end
                                                       end, Miners),
                                             [true] == lists:usort(HaveNoncesIncremented)
                                     end, 60, 5000),
    case Result of
        true ->
            ok;
        false ->
            lists:foreach(fun(Miner) ->
                                  TxnList = ct_rpc:call(Miner, blockchain_txn_mgr, txn_list, []),
                                  ct:pal("~p", [format_txn_list(TxnList)])
                          end, Miners),
            ct:fail("boom")
    end,
    ok.


%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------

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
