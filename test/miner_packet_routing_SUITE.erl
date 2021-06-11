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
    try
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

    {ok, DKGCompletedNodes} = miner_ct_utils:initial_dkg(Miners, InitialTransactions, Addresses, N, Curve),

    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(DKGCompletedNodes), Miners -- DKGCompletedNodes),

    RadioPorts = [ P || {_Miner, {_TP, P}} <- MinersAndPorts ],
    miner_fake_radio_backplane:start_link(8, 45000, lists:zip(RadioPorts, Locations)),

    miner_fake_radio_backplane ! go,
    Config
    catch
        What:Why ->
            end_per_testcase(TestCase, Config),
            erlang:What(Why)
    end.

end_per_testcase(TestCase, Config) ->
    catch gen_server:stop(miner_fake_radio_backplane),
    miner_ct_utils:end_per_testcase(TestCase, Config).

basic_test(Config) ->
    Miners = ?config(miners, Config),
    ok = miner_ct_utils:wait_for_gte(height, Miners, 5),
    miner_fake_radio_backplane:transmit(<<?JOIN_REQUEST:3, 0:5, 1337:64/integer-unsigned-big, 1234:64/integer-unsigned-big, 1111:16/integer-unsigned-big, 0:32/integer-unsigned-big>>, 911.200, 631210968910285823),
    ok = miner_ct_utils:wait_for_gte(height, Miners, 10),
    ok.

