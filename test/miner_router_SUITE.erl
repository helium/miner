-module(miner_router_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("helium_proto/src/pb/helium_longfi_pb.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include("miner_ct_macros.hrl").

-export([
    init_per_testcase/2,
    end_per_testcase/2,
    all/0
]).

-export([
    basic/1
]).


%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() -> [basic].

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(_TestCase, Config0),
    Miners = proplists:get_value(miners, Config),
    Addresses = proplists:get_value(addresses, Config),
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    InitialDCTransactions = [ blockchain_txn_dc_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, h3:from_geo({37.780586, -122.469470}, 13), 0)
                 || Addr <- Addresses],

    NumConsensusMembers = proplists:get_value(num_consensus_members, Config),
    BlockTime = proplists:get_value(block_time, Config),
    Interval = proplists:get_value(election_interval, Config),
    BatchSize = proplists:get_value(batch_size, Config),
    Curve = proplists:get_value(dkg_curve, Config),
    %% VarCommitInterval = proplists:get_value(var_commit_interval, Config),

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, #{?block_time => BlockTime,
                                                   ?election_interval => Interval,
                                                   ?num_consensus_members => NumConsensusMembers,
                                                   ?batch_size => BatchSize,
                                                   ?dkg_curve => Curve}),

    DKGResults = miner_ct_utils:inital_dkg(Miners, InitialVars ++ InitialPaymentTransactions ++ InitialDCTransactions ++ AddGwTxns, 
                                             Addresses, NumConsensusMembers, Curve),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),

    %% Get both consensus and non consensus miners
    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:in_non_consensus_miners(Miners),
    

    %% ensure that blockchain is undefined for non_consensus miners
    false = miner_ct_utils:blockchain_worker_check(NonConsensusMiners),

    %% integrate genesis block    
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(ConsensusMiners), NonConsensusMiners),

    %% confirm height has grown to 1
    ok = miner_ct_utils:wait_until_height_exactly(Miners, 1),

    Config.

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES 
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
basic(Config) ->
    Miners = proplists:get_value(miners, Config),
    [Owner| _Tail] = Miners,
    OwnerPubKeyBin = ct_rpc:call(Owner, blockchain_swarm, pubkey_bin, []),

    application:ensure_all_started(ranch),
    application:set_env(lager, error_logger_flush_queue, false),
    application:ensure_all_started(lager),
    lager:set_loglevel(lager_console_backend, debug),
    lager:set_loglevel({lager_file_backend, "log/console.log"}, debug),

    SwarmOpts = [{libp2p_nat, [{enabled, false}]}],
    {ok, RouterSwarm} = libp2p_swarm:start(router_swarm, SwarmOpts),
    ok = libp2p_swarm:listen(RouterSwarm, "/ip4/0.0.0.0/tcp/0"),
    RouterP2P = erlang:list_to_binary(libp2p_swarm:p2p_address(RouterSwarm)),
    Version = simple_http_stream_test:version(),
    ok = libp2p_swarm:add_stream_handler(
        RouterSwarm,
        Version,
        {libp2p_framed_stream, server, [simple_http_stream_test, self()]}
    ),

    [RouterAddress|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    OwnerSwarm = ct_rpc:call(Owner, blockchain_swarm, swarm, []),
    {ok, _} = ct_rpc:call(Owner, libp2p_swarm, connect, [OwnerSwarm, RouterAddress]),

    ct:pal("MARKER ~p", [{OwnerPubKeyBin, RouterP2P}]),
    Txn = ct_rpc:call(Owner, blockchain_txn_oui_v1, new, [OwnerPubKeyBin, [RouterP2P], 1, 1, 0]),
    {ok, Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Owner, blockchain_swarm, keys, []),
    SignedTxn = ct_rpc:call(Owner, blockchain_txn_oui_v1, sign, [Txn, SigFun]),
    ok = ct_rpc:call(Owner, blockchain_worker, submit_txn, [SignedTxn]),

    Chain = ct_rpc:call(Owner, blockchain_worker, blockchain, []),
    Ledger = blockchain:ledger(Chain),

    ?assertAsync(begin
                        Result = 
                            case ct_rpc:call(Owner, blockchain_ledger_v1, find_routing, [1, Ledger]) of
                                {ok, _} -> true;
                                _ -> false
                            end
                 end,
        Result == true, 60, timer:seconds(1)),
    
    {_, P1, _, P2} =  ct_rpc:call(Owner, application, get_env, [miner, radio_device, undefined]),
    {ok, Sock} = gen_udp:open(P2, [{active, false}, binary, {reuseaddr, true}]),

    Rx = #helium_LongFiRxPacket_pb{
        crc_check=true,
        spreading= 'SF8',
        oui=1,
        device_id=1,
        payload= <<"some data">>
    },
    Resp = #helium_LongFiResp_pb{id=0, kind={rx, Rx}},
    Packet = helium_longfi_pb:encode_msg(Resp, helium_LongFiResp_pb),
    ok = gen_udp:send(Sock, "127.0.0.1", P1, Packet),
    ct:pal("SENT ~p", [{Resp, Packet}]),
    receive 
        {simple_http_stream_test, Got} ->
            {ok, MinerName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(libp2p_crypto:pubkey_to_bin(Pubkey))),
            Resp2 = Resp#helium_LongFiResp_pb{miner_name=binary:replace(erlang:list_to_binary(MinerName), <<"-">>, <<" ">>, [global])},
            ?assertMatch(Resp2, helium_longfi_pb:decode_msg(Got, helium_LongFiResp_pb)),
            ok;
        _Other ->
            ct:pal("wrong data ~p", [_Other]),
            ct:fail(wrong_data)
    after 2000 ->
        ct:fail(timeout)
    end,
    ok.
