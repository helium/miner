-module(miner_poc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-export([
    all/0
]).

-export([
    basic/1,
    startup/1,
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
    [startup, dist].

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
                                                   ?dkg_curve => Curve}),

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
            ct_rpc:call(Miner, blockchain_worker, integrate_genesis_block, [GenesisBlock])
        end,
        Miners
    ),

    ok = ct_rpc:call(M, blockchain_event, add_handler, [Self], RPCTimeout),
    ?assertEqual({0, 0}, rcv_loop(M, 35, {length(Miners), length(Miners)})),

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
                        {_, _, Score} = ct_rpc:call(M, blockchain_ledger_gateway_v1, score, [A, G, Height, Ledger]),
                    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Score])
                end,
                maps:to_list(ActiveGateways)
            )
    end,

    miner_ct_utils:end_per_testcase(TestCase, Config),
    ok.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
basic(_Config) ->
    % Create chain
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

    % Generate fake blockchains (just the keys)
    RandomKeys = generate_keys(6),
    Address = blockchain_swarm:pubkey_bin(),
    ConsensusMembers = [
        {Address, {PubKey, PrivKey, libp2p_crypto:mk_sig_fun(PrivKey)}}
    ] ++ RandomKeys,

    % Create genesis block
    Balance = 5000,
    GenPaymentTxs = [blockchain_txn_coinbase_v1:new(Addr, Balance)
                     || {Addr, _} <- ConsensusMembers],
    GenConsensusGroupTx = blockchain_txn_consensus_group_v1:new([Addr || {Addr, _} <- ConsensusMembers], <<>>, 1, 0),
    Txs = GenPaymentTxs ++ [GenConsensusGroupTx],
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

    % Assert the Gateways location
    AssertLocaltionTxns = build_asserts(LatLongs, {PrivKey, PubKey}),
    ok = add_block(Chain, ConsensusMembers, AssertLocaltionTxns),

    ok = miner_ct_utils:wait_until(fun() -> {ok, 3} =:= blockchain:height(Chain) end),

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

    % Start poc statem @ height 3
    {ok, Statem} = miner_poc_statem:start_link(#{}),
    ?assertMatch({requesting, _}, sys:get_state(Statem)),

    % Add some block to start process
    ok = add_block(Chain, ConsensusMembers, []),

    % 3 previous blocks + 1 block to start process + 1 block with poc req txn
    ok = miner_ct_utils:wait_until(fun() -> {ok, 5} =:= blockchain:height(Chain) end),

    SubmitedTxns0 = get_submited_txn(Statem),
    ?assertEqual(1, erlang:length(SubmitedTxns0)),
    [PocReqTxn] = SubmitedTxns0,
    ?assertEqual(blockchain_txn_poc_request_v1, blockchain_txn:type(PocReqTxn)),
    Gateway = blockchain_txn_poc_request_v1:challenger(PocReqTxn),
    ?assertEqual(blockchain_swarm:pubkey_bin(), Gateway),

    ok = miner_ct_utils:wait_until(fun() ->
        case sys:get_state(Statem) of
            {receiving, _} -> true;
            _Other -> false
        end
    end),

    % Send receipts and add 3 block to pass timeout
    ok = send_receipts(LatLongs),
    timer:sleep(100),
    lists:foreach(
        fun(_) ->
            ok = add_block(Chain, ConsensusMembers, []),
            timer:sleep(100)
        end,
        lists:seq(1, 4)
    ),

    ct:pal("Height: ~p", [blockchain:height(Chain)]),

     % 5 previous blocks + 4 block to pass receiving timeout + 1 block with poc receipts txn
    ok = miner_ct_utils:wait_until(fun() -> {ok, 10} =:= blockchain:height(Chain) end),

    SubmitedTxns1 = get_submited_txn(Statem),
    ?assertEqual(2, erlang:length(SubmitedTxns1)),
    [_, PocReceiptsTxn] = SubmitedTxns1,
    ?assertEqual(blockchain_txn_poc_receipts_v1, blockchain_txn:type(PocReceiptsTxn)),

    ?assert(0 < erlang:length(blockchain_txn_poc_receipts_v1:receipts(PocReceiptsTxn))),
    ?assertEqual(blockchain_swarm:pubkey_bin(), blockchain_txn_poc_receipts_v1:challenger(PocReceiptsTxn)),
    ?assertEqual([], blockchain_txn_poc_receipts_v1:witnesses(PocReceiptsTxn)),
    Hash = blockchain_txn_poc_request_v1:secret_hash(PocReqTxn),
    ?assertEqual(Hash, crypto:hash(sha256, blockchain_txn_poc_receipts_v1:secret(PocReceiptsTxn))),

    ok = miner_ct_utils:wait_until(fun() ->
        case sys:get_state(Statem) of
            {requesting, _} -> true;
            _Other -> false
        end
    end),

    Ledger = blockchain:ledger(Chain),
    {ok, GwInfo} = blockchain_ledger_v1:find_gateway_info(blockchain_swarm:pubkey_bin(), Ledger),
    ?assertEqual(5, blockchain_ledger_gateway_v1:last_poc_challenge(GwInfo)),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ?assert(meck:validate(miner_onion)),
    meck:unload(miner_onion),
    ?assert(meck:validate(miner_onion_handler)),
    meck:unload(miner_onion_handler),
    ok.

startup(_Config) ->
    % Create chain but never integrate to leave blockchain = undefined
    BaseDir = "data/miner_poc_SUITE/startup",
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

    {ok, Statem} = miner_poc_statem:start_link(#{delay => 5}),

    ?assertMatch({requesting, {data, undefined, _, _, _, _, _, _, _, _, _, _, _}}, sys:get_state(Statem)),

    % Send fake notify
    ok = blockchain_worker:notify({add_block, <<"fake block">>, true}),

    ?assertMatch({requesting, {data, undefined, _, _, _, _, _, _, _, _, _, _, _}}, sys:get_state(Statem)),

    % Now add genesis
    % Generate fake blockchains (just the keys)
    RandomKeys = generate_keys(6),
    Address = blockchain_swarm:pubkey_bin(),
    ConsensusMembers = [
        {Address, {PubKey, PrivKey, libp2p_crypto:mk_sig_fun(PrivKey)}}
    ] ++ RandomKeys,

    % Create genesis block
    Balance = 5000,
    GenPaymentTxs = [blockchain_txn_coinbase_v1:new(Addr, Balance)
                     || {Addr, _} <- ConsensusMembers],
    GenConsensusGroupTx = blockchain_txn_consensus_group_v1:new([Addr || {Addr, _} <- ConsensusMembers], <<>>, 1, 0),
    Txs = GenPaymentTxs ++ [GenConsensusGroupTx],
    GenesisBlock = blockchain_block_v1:new_genesis_block(Txs),
    ok = blockchain_worker:integrate_genesis_block(GenesisBlock),

    Chain = blockchain_worker:blockchain(),
    {ok, HeadBlock} = blockchain:head_block(Chain),

    ?assertEqual(blockchain_block:hash_block(GenesisBlock), blockchain_block:hash_block(HeadBlock)),
    ?assertEqual({ok, GenesisBlock}, blockchain:head_block(Chain)),
    ?assertEqual({ok, blockchain_block:hash_block(GenesisBlock)}, blockchain:genesis_hash(Chain)),
    ?assertEqual({ok, GenesisBlock}, blockchain:genesis_block(Chain)),
    ?assertEqual({ok, 1}, blockchain:height(Chain)),

    % Now this should match the chain
    ?assertMatch({requesting, {data, Chain, _, _, _, _, _, _, _, _, _, _, _}}, sys:get_state(Statem)),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

rcv_loop(_Miner, _, {0, 0}=Acc) ->
    Acc;
rcv_loop(_Miner, 0, Acc) ->
    Acc;
rcv_loop(Miner, I, Acc0) ->
    receive
        {blockchain_event, {add_block, Hash, false, _}} ->
            ct:pal("hash ~p", [Hash]),
            Acc1 = case ct_rpc:call(Miner, blockchain_worker, blockchain, []) of
                undefined ->
                    Acc0;
                Chain ->
                    {ok, Block} = ct_rpc:call(Miner, blockchain, get_block, [Hash, Chain]),
                    lists:foldl(
                        fun(Txn, {Reqs, Recs}=A) ->
                            case blockchain_txn:type(Txn) of
                                blockchain_txn_poc_receipts_v1 ->
                                    Path = blockchain_txn_poc_receipts_v1:path(Txn),
                                    case lists:all(fun(PE) ->
                                                      blockchain_poc_path_element_v1:receipt(PE) /= undefined
                                                      andalso length(blockchain_poc_path_element_v1:witnesses(PE)) > 0
                                              end, Path) of
                                        true ->
                                            {Reqs, Recs-1};
                                        false ->
                                            A
                                    end;
                                blockchain_txn_poc_request_v1 ->
                                    {Reqs-1, Recs};
                                _ ->
                                    A
                            end
                        end,
                        Acc0,
                        blockchain_block:transactions(Block)
                    )
            end,
            ct:pal("counter ~p accumulated lengths ~p", [I, Acc1]),
            rcv_loop(Miner, I-1, Acc1);
        {blockchain_event, {add_block, _Hash, true, _}} ->
            rcv_loop(Miner, I, Acc0)
    end.

get_submited_txn(Pid) ->
    History = meck:history(blockchain_worker, Pid),
    Filter =
        fun({_, {blockchain_worker, submit_txn, [Txn]}, _}) ->
            {true, Txn};
        (_) ->
            false
        end,
    lists:filtermap(Filter, History).

add_block(Chain, ConsensusMembers, Txns) ->
    B = create_block(ConsensusMembers, Txns),
    ok = blockchain:add_block(B, Chain).

send_receipts(LatLongs) ->
    lists:foreach(
        fun({_LatLong, {PrivKey, PubKey}}) ->
            Address = libp2p_crypto:pubkey_to_bin(PubKey),
            SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            {Mega, Sec, Micro} = os:timestamp(),
            Timestamp = Mega * 1000000 * 1000000 + Sec * 1000000 + Micro,
            Receipt = blockchain_poc_receipt_v1:new(Address, Timestamp, 0, <<>>, radio),
            SignedReceipt = blockchain_poc_receipt_v1:sign(Receipt, SigFun),
            miner_poc_statem:receipt(SignedReceipt)
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

            AssertLocationRequestTx = blockchain_txn_assert_location_v1:new(Gateway, Owner, Index, 1, 0),
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

            AddGatewayTx = blockchain_txn_add_gateway_v1:new(Owner, Gateway, 0, 0),
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
