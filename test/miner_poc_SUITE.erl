-module(miner_poc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-export([
    all/0
]).

-export([
    basic/1,
    dist/1
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
all() ->
    [basic, dist].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
dist(Config0) ->
    RPCTimeout = timer:seconds(2),
    miner_fake_radio_backplane:start_link(45000, lists:seq(46001, 46008)),

    TestCase = poc_dist,
    Config = miner_ct_utils:init_per_testcase(TestCase, [{}, Config0]),
    Miners = proplists:get_value(miners, Config),
    Addresses = proplists:get_value(addresses, Config),

    N = proplists:get_value(num_consensus_members, Config),
    BlockTime = proplists:get_value(block_time, Config),
    Interval = proplists:get_value(election_interval, Config),
    BatchSize = proplists:get_value(batch_size, Config),
    Curve = proplists:get_value(dkg_curve, Config),
    %% VarCommitInterval = proplists:get_value(var_commit_interval, Config),

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, #{?block_time => BlockTime,
                                                   ?election_interval => Interval,
                                                   ?num_consensus_members => N,
                                                   ?batch_size => BatchSize,
                                                   ?dkg_curve => Curve,
                                                   ?poc_challenge_interval => 20}),

    InitialPaymentTransactions = [blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    Locations = lists:foldl(
        fun(I, Acc) ->
            [h3:from_geo({37.780586, -122.469470 + I/1000000}, 13)|Acc]
        end,
        [],
        lists:seq(1, length(Addresses))
    ),
    IntitialGatewayTransactions = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0) || {Addr, Loc} <- lists:zip(Addresses, Locations)],
    InitialTransactions = InitialVars ++ InitialPaymentTransactions ++ IntitialGatewayTransactions,

    DKGResults = miner_ct_utils:pmap(
        fun(Miner) ->
            ct_rpc:call(Miner, miner_consensus_mgr, initial_dkg, [InitialTransactions, Addresses, N, Curve])
        end,
        Miners
    ),
    ct:pal("results ~p", [DKGResults]),
    ?assert(lists:all(fun(Res) -> Res == ok end, DKGResults)),


    Self = self(),
    [M|_] = Miners,

    %% wait until one node has a working chain
    ok = miner_ct_utils:wait_until(
        fun() ->
            lists:any(
                fun(Miner) ->
                    case ct_rpc:call(Miner, blockchain_worker, blockchain, [], RPCTimeout) of
                        {badrpc, Reason} ->
                            ct:fail(Reason),
                            false;
                        undefined ->
                            false;
                        Chain ->
                            Ledger = ct_rpc:call(Miner, blockchain, ledger, [Chain], RPCTimeout),
                            ActiveGteways = ct_rpc:call(Miner, blockchain_ledger_v1, active_gateways, [Ledger], RPCTimeout),
                            maps:size(ActiveGteways) == erlang:length(Addresses)
                    end
                end,
                Miners
            )
        end,
        10,
        timer:seconds(6)
    ),

    %% obtain the genesis block
    GenesisBlock = lists:foldl(
        fun(Miner, undefined) ->
            case ct_rpc:call(Miner, blockchain_worker, blockchain, [], RPCTimeout) of
                {badrpc, Reason} ->
                    ct:fail(Reason),
                    false;
                undefined ->
                    false;
                Chain ->
                    {ok, GBlock} = rpc:call(Miner, blockchain, genesis_block, [Chain]),
                    GBlock
            end;
        (_, Acc) ->
                Acc
        end,
        undefined,
        Miners
    ),

    ?assertNotEqual(undefined, GenesisBlock),

    %% load the genesis block on all the nodes
    lists:foreach(
        fun(Miner) ->
                case ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [], 5000) of
                    true ->
                        ok;
                    false ->
                        ct_rpc:call(Miner, blockchain_worker,
                                    integrate_genesis_block, [GenesisBlock], 5000)
                end
        end,
        Miners
    ),

    ok = ct_rpc:call(M, blockchain_event, add_handler, [Self], RPCTimeout),
    
    ReqsRecipts = lists:foldl(
        fun(A, Acc) ->
            maps:put(A, {0, 0}, Acc)
        end,
        #{},
        Addresses
    ),
    ?assert(rcv_loop(M, 100, ReqsRecipts)),

    %% wait until one node has a working chain

    case ct_rpc:call(M, blockchain_worker, blockchain, [], RPCTimeout) of
        {badrpc, Reason} -> ct:fail(Reason);
        undefined -> ok;
        Chain ->
            Ledger = ct_rpc:call(M, blockchain, ledger, [Chain], RPCTimeout),
            {ok, Height} = ct_rpc:call(M, blockchain_ledger_v1, current_height, [Ledger]),
            ActiveGateways = ct_rpc:call(M, blockchain_ledger_v1, active_gateways, [Ledger], RPCTimeout),
            lists:foreach(
                fun({A, G}) ->
                        {_, _, Score} = ct_rpc:call(M, blockchain_ledger_gateway_v2, score, [A, G, Height, Ledger]),
                    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Score])
                end,
                maps:to_list(ActiveGateways)
            )
    end,

    miner_ct_utils:end_per_testcase(TestCase, Config),
    ok.

basic(_Config) ->
    BaseDir = "data/miner_poc_SUITE/basic",
    {PrivKey, PubKey} = new_random_key(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    ECDHFun = libp2p_crypto:mk_ecdh_fun(PrivKey),
    Opts = [
        {key, {PubKey, SigFun, ECDHFun}},
        {seed_nodes, []},
        {port, 0},
        {num_consensus_members, 7},
        {base_dir, BaseDir}
    ],
    {ok, _Sup} = blockchain_sup:start_link(Opts),
    ?assert(erlang:is_pid(blockchain_swarm:swarm())),

    % Now add genesis
    % Generate fake blockchains (just the keys)
    RandomKeys = generate_keys(6),
    Address = blockchain_swarm:pubkey_bin(),
    ConsensusMembers = [
        {Address, {PubKey, PrivKey, libp2p_crypto:mk_sig_fun(PrivKey)}}
    ] ++ RandomKeys,

    % Create genesis block
    Balance = 5000,
    ConbaseTxns = [blockchain_txn_coinbase_v1:new(Addr, Balance)
                     || {Addr, _} <- ConsensusMembers],
    ConbaseDCTxns = [blockchain_txn_dc_coinbase_v1:new(Addr, Balance)
                     || {Addr, _} <- ConsensusMembers],
    GenConsensusGroupTx = blockchain_txn_consensus_group_v1:new([Addr || {Addr, _} <- ConsensusMembers], <<>>, 1, 0),
    VarsKeys = libp2p_crypto:generate_keys(ecc_compact),
    VarsTx = miner_ct_utils:make_vars(VarsKeys),

    Txs = ConbaseTxns ++ ConbaseDCTxns ++ [GenConsensusGroupTx] ++ VarsTx,
    GenesisBlock = blockchain_block_v1:new_genesis_block(Txs),
    ok = blockchain_worker:integrate_genesis_block(GenesisBlock),

    Chain = blockchain_worker:blockchain(),
    {ok, HeadBlock} = blockchain:head_block(Chain),

    ?assertEqual(blockchain_block:hash_block(GenesisBlock), blockchain_block:hash_block(HeadBlock)),
    ?assertEqual({ok, GenesisBlock}, blockchain:head_block(Chain)),
    ?assertEqual({ok, blockchain_block:hash_block(GenesisBlock)}, blockchain:genesis_hash(Chain)),
    ?assertEqual({ok, GenesisBlock}, blockchain:genesis_block(Chain)),
    ?assertEqual({ok, 1}, blockchain:height(Chain)),

    % All these point are in a line one after the other (except last)
    LatLongs = [
        {{37.780586, -122.469471}, {PrivKey, PubKey}},
        {{37.780959, -122.467496}, new_random_key(ecc_compact)},
        {{37.78101, -122.465372}, new_random_key(ecc_compact)},
        {{37.781179, -122.463226}, new_random_key(ecc_compact)},
        {{37.781281, -122.461038}, new_random_key(ecc_compact)},
        {{37.781349, -122.458892}, new_random_key(ecc_compact)},
        {{37.781468, -122.456617}, new_random_key(ecc_compact)},
        {{37.781637, -122.4543}, new_random_key(ecc_compact)}
    ],

    % Add a Gateway
    AddGatewayTxs = build_gateways(LatLongs, {PrivKey, PubKey}),
    ok = add_block(Chain, ConsensusMembers, AddGatewayTxs),

    ok = miner_ct_utils:wait_until(fun() -> {ok, 2} =:= blockchain:height(Chain) end),

    % Assert the Gateways location
    AssertLocaltionTxns = build_asserts(LatLongs, {PrivKey, PubKey}),
    ok = add_block(Chain, ConsensusMembers, AssertLocaltionTxns),

    ok = miner_ct_utils:wait_until(fun() -> {ok, 3} =:= blockchain:height(Chain) end),
    {ok, Statem} = miner_poc_statem:start_link(#{delay => 5}),

    ?assertEqual(requesting,  erlang:element(1, sys:get_state(Statem))),
    ?assertEqual(Chain, erlang:element(2, erlang:element(2, sys:get_state(Statem)))), % Blockchain is = to Chain

    % Mock submit_txn to actually add the block
    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, submit_txn, fun(Txn) ->
        add_block(Chain, ConsensusMembers, [Txn])
    end),
    meck:new(miner_onion, [passthrough]),
    meck:expect(miner_onion, dial_framed_stream, fun(_, _, _) ->
        {ok, self()}
    end),

    meck:new(miner_onion_handler, [passthrough]),
    meck:expect(miner_onion_handler, send, fun(Stream, _Onion) ->
        ?assertEqual(self(), Stream)
    end),

    meck:new(blockchain_txn_poc_receipts_v1, [passthrough]),
    meck:expect(blockchain_txn_poc_receipts_v1, is_valid, fun(_, _) -> ok end),

    ?assertEqual(10, erlang:element(12, erlang:element(2, sys:get_state(Statem)))),

    % Add some block to start process
    ok = add_block(Chain, ConsensusMembers, []),

    % 3 previous blocks + 1 block to start process + 1 block with poc req txn
    ok = miner_ct_utils:wait_until(fun() -> {ok, 5} =:= blockchain:height(Chain) end),

    % Passing the random delay
    ?assertEqual(delaying, erlang:element(1, sys:get_state(Statem))),
    RandDelay = erlang:element(12, erlang:element(2, sys:get_state(Statem))),
    lists:foreach(
        fun(_) ->
             ok = add_block(Chain, ConsensusMembers, [])
        end,
        lists:seq(1, RandDelay+1)
    ),

    % Moving threw targeting and challenging
    ok = miner_ct_utils:wait_until(fun() ->
        case sys:get_state(Statem) of
            {receiving, _} -> true;
            _Other -> false
        end
    end),

    % Send 7 receipts and add blocks to pass timeout
    ?assertEqual(0, maps:size(erlang:element(8, erlang:element(2, sys:get_state(Statem))))),
    Challengees = erlang:element(6, erlang:element(2, sys:get_state(Statem))),
    ok = send_receipts(LatLongs, Challengees),
    timer:sleep(100),

    ?assertEqual(receiving,  erlang:element(1, sys:get_state(Statem))),
    ?assert(maps:size(erlang:element(8, erlang:element(2, sys:get_state(Statem)))) > 0), % Get reponses

    % Passing receiving_timeout
    lists:foreach(
        fun(_) ->
            ok = add_block(Chain, ConsensusMembers, []),
            timer:sleep(100)
        end,
        lists:seq(1, 10)
    ),

    ?assertEqual(receiving,  erlang:element(1, sys:get_state(Statem))),
    ?assertEqual(0, erlang:element(9, erlang:element(2, sys:get_state(Statem)))), % Get receiving_timeout
    ok = add_block(Chain, ConsensusMembers, []),

    ok = miner_ct_utils:wait_until(fun() ->
        case sys:get_state(Statem) of
            {waiting, _} -> true;
            {submitting, _} -> true;
            {requesting, _} -> true;
            {_Other, _} -> false
        end
    end),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ?assert(meck:validate(miner_onion)),
    meck:unload(miner_onion),
    ?assert(meck:validate(miner_onion_handler)),
    meck:unload(miner_onion_handler),
    ?assert(meck:validate(blockchain_txn_poc_receipts_v1)),
    meck:unload(blockchain_txn_poc_receipts_v1),

    ok = gen_statem:stop(Statem),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

check_map(Map) ->
    lists:all(
        fun({_, {Rq, Rc}}) when Rq > 0 andalso Rc > 0 andalso Rq >= Rc ->
            true;
           ({Address, {Rq, Rc}}) ->
               ct:pal("~p did not get enough req ~p or receipts ~p", [Address, Rq, Rc]),
               false
        end,
        maps:to_list(Map)
    ).

rcv_loop(_Miner, 0, Acc) ->
    check_map(Acc);
rcv_loop(Miner, I, Acc0) ->
    case check_map(Acc0) of
        true ->
            true;
        false ->
            receive
                {blockchain_event, {add_block, Hash, false, _}} ->
                    ct:pal("hash ~p", [Hash]),
                    Acc1 = case ct_rpc:call(Miner, blockchain_worker, blockchain, []) of
                        undefined ->
                            Acc0;
                        Chain ->
                            {ok, Block} = ct_rpc:call(Miner, blockchain, get_block, [Hash, Chain]),
                            lists:foldl(
                                fun(Txn, SubAcc) ->
                                    case blockchain_txn:type(Txn) of
                                        blockchain_txn_poc_receipts_v1 ->
                                            Path = blockchain_txn_poc_receipts_v1:path(Txn),
                                            Challenger = blockchain_txn_poc_receipts_v1:challenger(Txn),
                                            ct:pal("~p got RECEIPTS", [Challenger]),
                                            case lists:all(fun(PE) ->
                                                            blockchain_poc_path_element_v1:receipt(PE) /= undefined
                                                            andalso length(blockchain_poc_path_element_v1:witnesses(PE)) > 0
                                                    end, Path) of
                                                false ->
                                                    SubAcc;
                                                true ->
                                                    
                                                    case maps:get(Challenger, Acc0, undefined) of
                                                        undefined ->
                                                            SubAcc;
                                                        {Reqs, Recs} ->
                                                            maps:update(Challenger, {Reqs, Recs+1}, SubAcc)
                                                    end
                                            end;
                                        blockchain_txn_poc_request_v1 ->
                                            Challenger = blockchain_txn_poc_request_v1:challenger(Txn),
                                            ct:pal("~p got REQ", [Challenger]),
                                            case maps:get(Challenger, Acc0, undefined) of
                                                undefined ->
                                                    SubAcc;
                                                {Reqs, Recs} ->
                                                    maps:update(Challenger, {Reqs+1, Recs}, SubAcc)
                                            end;
                                        _ ->
                                            SubAcc
                                    end
                                end,
                                Acc0,
                                blockchain_block:transactions(Block)
                            )
                    end,
                    rcv_loop(Miner, I-1, Acc1);
                {blockchain_event, {add_block, _Hash, true, _}} ->
                    rcv_loop(Miner, I, Acc0)
            end
    end.

add_block(Chain, ConsensusMembers, Txns) ->
    SortedTxns = lists:sort(fun blockchain_txn:sort/2, Txns),
    B = create_block(ConsensusMembers, SortedTxns),
    ok = blockchain:add_block(B, Chain).

send_receipts(LatLongs, Challengees) ->
    lists:foreach(
        fun({_LatLong, {PrivKey, PubKey}}) ->
            Address = libp2p_crypto:pubkey_to_bin(PubKey),
            SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            {Mega, Sec, Micro} = os:timestamp(),
            Timestamp = Mega * 1000000 * 1000000 + Sec * 1000000 + Micro,
            case lists:keyfind(Address, 1, Challengees) of
                {Address, LayerData} ->
                    Receipt = blockchain_poc_receipt_v1:new(Address, Timestamp, 0, LayerData, radio),
                    SignedReceipt = blockchain_poc_receipt_v1:sign(Receipt, SigFun),
                    miner_poc_statem:receipt(SignedReceipt);
                _ ->
                    ok
            end
        end,
        LatLongs
    ).

build_asserts(LatLongs, {PrivKey, PubKey}) ->
    lists:foldl(
        fun({LatLong, {GatewayPrivKey, GatewayPubKey}}, Acc) ->
            Gateway = libp2p_crypto:pubkey_to_bin(GatewayPubKey),
            GatewaySigFun = libp2p_crypto:mk_sig_fun(GatewayPrivKey),
            OwnerSigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            Owner = libp2p_crypto:pubkey_to_bin(PubKey),
            Index = h3:from_geo(LatLong, 12),
            AssertLocationRequestTx = blockchain_txn_assert_location_v1:new(Gateway, Owner, Index, 1, 1, 0),
            PartialAssertLocationTxn = blockchain_txn_assert_location_v1:sign_request(AssertLocationRequestTx, GatewaySigFun),
            SignedAssertLocationTx = blockchain_txn_assert_location_v1:sign(PartialAssertLocationTxn, OwnerSigFun),
            [SignedAssertLocationTx|Acc]
        end,
        [],
        LatLongs
    ).

build_gateways(LatLongs, {PrivKey, PubKey}) ->
    lists:foldl(
        fun({_LatLong, {GatewayPrivKey, GatewayPubKey}}, Acc) ->
            % Create a Gateway
            Gateway = libp2p_crypto:pubkey_to_bin(GatewayPubKey),
            GatewaySigFun = libp2p_crypto:mk_sig_fun(GatewayPrivKey),
            OwnerSigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            Owner = libp2p_crypto:pubkey_to_bin(PubKey),

            AddGatewayTx = blockchain_txn_add_gateway_v1:new(Owner, Gateway, 1, 0),
            SignedOwnerAddGatewayTx = blockchain_txn_add_gateway_v1:sign(AddGatewayTx, OwnerSigFun),
            SignedGatewayAddGatewayTx = blockchain_txn_add_gateway_v1:sign_request(SignedOwnerAddGatewayTx, GatewaySigFun),
            [SignedGatewayAddGatewayTx|Acc]

        end,
        [],
        LatLongs
    ).

generate_keys(N) ->
    lists:foldl(
        fun(_, Acc) ->
            {PrivKey, PubKey} = new_random_key(ecc_compact),
            SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            [{libp2p_crypto:pubkey_to_bin(PubKey), {PubKey, PrivKey, SigFun}}|Acc]
        end
        ,[]
        ,lists:seq(1, N)
    ).

create_block(ConsensusMembers, Txs) ->
    Blockchain = blockchain_worker:blockchain(),
    {ok, PrevHash} = blockchain:head_hash(Blockchain),
    {ok, HeadBlock} = blockchain:head_block(Blockchain),
    Height = blockchain_block:height(HeadBlock) + 1,
    Block0 = blockchain_block_v1:new(#{prev_hash => PrevHash,
                                       height => Height,
                                       transactions => Txs,
                                       signatures => [],
                                       time => 0,
                                       hbbft_round => 0,
                                       election_epoch => 0,
                                       epoch_start => 0}),
    BinBlock = blockchain_block:serialize(blockchain_block:set_signatures(Block0, [])),
    Signatures = signatures(ConsensusMembers, BinBlock),
    Block1 = blockchain_block:set_signatures(Block0, Signatures),
    Block1.

signatures(ConsensusMembers, BinBlock) ->
    lists:foldl(
        fun({A, {_, _, F}}, Acc) ->
            Sig = F(BinBlock),
            [{A, Sig}|Acc]
        end
        ,[]
        ,ConsensusMembers
    ).

new_random_key(Curve) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(Curve),
    {PrivKey, PubKey}.