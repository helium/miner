-module(miner_packet_routing_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include("lora.hrl").

-export([
    all/0
]).

-export([
         init_per_testcase/2,
         end_per_testcase/2,
         basic_test/1
        ]).

-define(SFLOCS, [631210968910285823, 631210968909003263, 631210968912894463, 631210968907949567]).
-define(NYLOCS, [631243922668565503, 631243922671147007, 631243922895615999, 631243922665907711]).

all() ->
    [basic_test].

init_per_testcase(TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(?MODULE, TestCase, Config0),
    Addresses = ?config(addresses, Config),
    N = ?config(num_consensus_members, Config),
    Curve = ?config(dkg_curve, Config),
    MinersAndPorts = ?config(ports, Config),
    Miners = ?config(miners, Config),
    Keys = libp2p_crypto:generate_keys(ecc_compact),
    InitialVars = miner_ct_utils:make_vars(Keys, #{}),
    InitialPaymentTransactions = [blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    Locations = ?SFLOCS ++ ?NYLOCS,
    AddressesWithLocations = lists:zip(Addresses, Locations),
    InitialGenGatewayTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0) || {Addr, Loc} <- AddressesWithLocations],
    InitialTransactions = InitialVars ++ InitialPaymentTransactions ++ InitialGenGatewayTxns,
    DKGResults = miner_ct_utils:pmap(
        fun(Miner) ->
            ct_rpc:call(Miner, miner_consensus_mgr, initial_dkg, [InitialTransactions, Addresses, N, Curve])
        end,
        Miners
    ),
    ct:pal("results ~p", [DKGResults]),
    ?assert(lists:all(fun(Res) -> Res == ok end, DKGResults)),
    RadioPorts = [ P || {_Miner, {_TP, P}} <- MinersAndPorts ],
    miner_fake_radio_backplane:start_link(8, 45000, lists:zip(RadioPorts, Locations)),

    GenesisBlock = get_genesis_block(Miners, Config),
    timer:sleep(5000),
    true = load_genesis_block(GenesisBlock, Miners, Config),
    miner_fake_radio_backplane ! go,
    Config.

end_per_testcase(TestCase, Config) ->
    gen_server:stop(miner_fake_radio_backplane),
    miner_ct_utils:end_per_testcase(TestCase, Config).

basic_test(Config) ->
    Miners = ?config(miners, Config),
    ok = miner_ct_utils:wait_for_gte(height, Miners, 5),
    miner_fake_radio_backplane:transmit(<<?JOIN_REQUEST:3, 0:5, 1337:64/integer-unsigned-little, 1234:64/integer-unsigned-little, 1111:16/integer-unsigned-big, 0:32/integer-unsigned-big>>, 911.200, 631210968910285823),
    ok = miner_ct_utils:wait_for_gte(height, Miners, 10),
    ok.


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


load_genesis_block(GenesisBlock, Miners, Config) ->
    RPCTimeout = ?config(rpc_timeout, Config),
    %% load the genesis block on all the nodes
    lists:foreach(
        fun(Miner) ->
                case ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [], RPCTimeout) of
                    true ->
                        ok;
                    false ->
                        Res = ct_rpc:call(Miner, blockchain_worker,
                                          integrate_genesis_block, [GenesisBlock], RPCTimeout),
                        ct:pal("loading genesis ~p block on ~p ~p", [GenesisBlock, Miner, Res])
                end
        end,
        Miners
    ),

    timer:sleep(5000),

    ok == miner_ct_utils:wait_for_gte(height, Miners, 1).

