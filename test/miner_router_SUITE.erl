-module(miner_router_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("helium_proto/src/pb/helium_longfi_pb.hrl").

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
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, undefined, 0) || Addr <- Addresses],

    N = proplists:get_value(num_consensus_members, Config),
    BlockTime = proplists:get_value(block_time, Config),
    Interval = proplists:get_value(election_interval, Config),
    BatchSize = proplists:get_value(batch_size, Config),
    Curve = proplists:get_value(dkg_curve, Config),
    %% VarCommitInterval = proplists:get_value(var_commit_interval, Config),

    #{secret := Priv, public := Pub} =
        libp2p_crypto:generate_keys(ecc_compact),

    Vars = #{block_time => BlockTime,
             election_interval => Interval,
             election_restart_interval => 10,
             num_consensus_members => N,
             batch_size => BatchSize,
             vars_commit_delay => 2,
             block_version => v1,
             dkg_curve => Curve,
             predicate_callback_mod => miner,
             predicate_callback_fun => test_version,
             proposal_threshold => 0.85,
             monthly_reward => 0,
             securities_percent => 0,
             dc_percent => 0,
             poc_challengees_percent => 0,
             poc_challengers_percent => 0,
             poc_witnesses_percent => 0,
             consensus_percent => 0,
             election_selection_pct => 60,
             election_replacement_factor => 4,
             election_replacement_slope => 20,
             min_score => 0.2,
             h3_ring_size => 2,
             h3_path_res => 8,
             alpha_decay => 0.007,
             beta_decay => 0.0005,
             max_staleness => 100000
            },

    BinPub = libp2p_crypto:pubkey_to_bin(Pub),
    KeyProof = blockchain_txn_vars_v1:create_proof(Priv, Vars),

    ct:pal("master key ~p~n priv ~p~n vars ~p~n keyproof ~p~n artifact ~p",
           [BinPub, Priv, Vars, KeyProof,
            term_to_binary(Vars, [{compressed, 9}])]),

    InitialVars = [ blockchain_txn_vars_v1:new(Vars, <<>>, 1, #{master_key => BinPub,
                                                                key_proof => KeyProof}) ],

    DKGResults = miner_ct_utils:pmap(
                   fun(Miner) ->
                           ct_rpc:call(Miner, miner_consensus_mgr, initial_dkg,
                                       [InitialVars ++ InitialPaymentTransactions ++ InitialDCTransactions ++ AddGwTxns, Addresses,
                                        N, Curve])
                   end, Miners),
    ?assertEqual([ok], lists:usort(DKGResults)),

    NonConsensusMiners = lists:filtermap(fun(Miner) ->
                                                 false == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                         end, Miners),

    %% ensure that blockchain is undefined for non_consensus miners
    true = lists:all(fun(Res) ->
                             Res == undefined
                     end,
                     lists:foldl(fun(Miner, Acc) ->
                                         R = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                         [R | Acc]
                                 end, [], NonConsensusMiners)),

    %% get the genesis block from the first Consensus Miner
    ConsensusMiner = hd(lists:filtermap(fun(Miner) ->
                                                true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                        end, Miners)),
    Chain = ct_rpc:call(ConsensusMiner, blockchain_worker, blockchain, []),
    {ok, GenesisBlock} = ct_rpc:call(ConsensusMiner, blockchain, genesis_block, [Chain]),

    ct:pal("non consensus nodes ~p", [NonConsensusMiners]),

    _GenesisLoadResults = miner_ct_utils:pmap(fun(M) ->
                                                      ct_rpc:call(M, blockchain_worker, integrate_genesis_block, [GenesisBlock])
                                              end, NonConsensusMiners),

    ok = miner_ct_utils:wait_until(fun() ->
                                           lists:all(fun(M) ->
                                                             C = ct_rpc:call(M, blockchain_worker, blockchain, []),
                                                             {ok, 1} == ct_rpc:call(M, blockchain, height, [C])
                                                     end, Miners)
                                   end),

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
    Txn = ct_rpc:call(Owner, blockchain_txn_oui_v1, new, [OwnerPubKeyBin, [RouterP2P], 1, 0]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Owner, blockchain_swarm, keys, []),
    SignedTxn = ct_rpc:call(Owner, blockchain_txn_oui_v1, sign, [Txn, SigFun]),
    ok = ct_rpc:call(Owner, blockchain_worker, submit_txn, [SignedTxn]),

     ok = miner_ct_utils:wait_until(
        fun() ->
            Chain = ct_rpc:call(Owner, blockchain_worker, blockchain, []),
            Ledger = blockchain:ledger(Chain),
            case ct_rpc:call(Owner, blockchain_ledger_v1, find_routing, [1, Ledger]) of
                {ok, _} -> true;
                _ -> false
            end
        end,
        60,
        timer:seconds(1)
    ),

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
            ?assertEqual(Packet, Got),
            ?assertEqual(Resp, helium_longfi_pb:decode_msg(Got, helium_LongFiResp_pb)),
            ok;
        _Other ->
            ct:pal("wrong data ~p", [_Other]),
            ct:fail(wrong_data)
    after 2000 ->
        ct:fail(timeout)
    end,
    ok.
