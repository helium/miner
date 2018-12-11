-module(miner_poc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
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
all() ->
    [basic].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
basic(_Config) ->
    % Create chain
    BaseDir = "data/miner_poc_SUITE/basic",
    {PrivKey, PubKey} = libp2p_crypto:generate_keys(),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Opts = [
        {key, {PubKey, SigFun}}
        ,{seed_nodes, []}
        ,{port, 0}
        ,{num_consensus_members, 7}
        ,{base_dir, BaseDir}
    ],
    {ok, _Sup} = blockchain_sup:start_link(Opts),
    ?assert(erlang:is_pid(blockchain_swarm:swarm())),

    % Generate fake blockchains (just the keys)
    RandomKeys = generate_keys(6),
    Address = blockchain_swarm:address(),
    ConsensusMembers = [
        {Address, {PubKey, PrivKey, libp2p_crypto:mk_sig_fun(PrivKey)}}
    ] ++ RandomKeys,

    % Create genesis block
    Balance = 5000,
    GenPaymentTxs = [blockchain_txn_coinbase_v1:new(Addr, Balance)
                     || {Addr, _} <- ConsensusMembers],
    GenConsensusGroupTx = blockchain_txn_gen_consensus_group_v1:new([Addr || {Addr, _} <- ConsensusMembers]),
    Txs = GenPaymentTxs ++ [GenConsensusGroupTx],
    GenesisBlock = blockchain_block:new_genesis_block(Txs),
    ok = blockchain_worker:integrate_genesis_block(GenesisBlock),

    Chain = blockchain_worker:blockchain(),

    ?assertEqual(blockchain_block:hash_block(GenesisBlock), blockchain_block:hash_block(blockchain:head_block(Chain))),
    ?assertEqual(GenesisBlock, blockchain:head_block(Chain)),
    ?assertEqual(blockchain_block:hash_block(GenesisBlock), blockchain:genesis_hash(Chain)),
    ?assertEqual(GenesisBlock, blockchain:genesis_block(Chain)),
    ?assertEqual(1, blockchain_worker:height()),

    % All these point are in a line one after the other (except last)
    LatLongs = [
        {{37.780586, -122.469471}, {PrivKey, PubKey}},
        {{37.780959, -122.467496}, libp2p_crypto:generate_keys()},
        {{37.78101, -122.465372}, libp2p_crypto:generate_keys()},
        {{37.781179, -122.463226}, libp2p_crypto:generate_keys()},
        {{37.781281, -122.461038}, libp2p_crypto:generate_keys()},
        {{37.781349, -122.458892}, libp2p_crypto:generate_keys()},
        {{37.781468, -122.456617}, libp2p_crypto:generate_keys()},
        {{37.781637, -122.4543}, libp2p_crypto:generate_keys()},
        {{37.832976, -122.12726}, libp2p_crypto:generate_keys()} % This should be excluded cause too far
    ],

    % Add a Gateway
    AddGatewayTxs = build_gateways(LatLongs, {PrivKey, PubKey}),
    Block = create_block(ConsensusMembers, AddGatewayTxs),
    ok = blockchain_worker:add_block(Block, self()),

    % Assert the Gateways location
    AssertLocaltionTxns = build_asserts(LatLongs, {PrivKey, PubKey}),
    Block2 = create_block(ConsensusMembers, AssertLocaltionTxns),
    ok = blockchain_worker:add_block(Block2, self()),
    
    ok = miner_ct_utils:wait_until(fun() -> 3 =:= blockchain_worker:height() end),

    % Start poc statem
    {ok, Statem} = miner_poc_statem:start_link(#{delay => 5}),
    _ = erlang:trace(Statem, true, ['receive']),

    ?assertMatch({requesting, _}, sys:get_state(Statem)),

    % Mock submit_txn to actually add the block
    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, submit_txn, fun(_, Txn) ->
        B = create_block(ConsensusMembers, [Txn]),
        ok = blockchain_worker:add_block(B, self())
    end),

    meck:new(miner_onion, [passthrough]),
    meck:expect(miner_onion, dial_framed_stream, fun(_, _, _) ->
        {ok, self()}
    end),

    meck:new(miner_onion_handler, [passthrough]),
    meck:expect(miner_onion_handler, send, fun(Stream, _Onion) ->
        ?assertEqual(self(), Stream)
    end),

    % Add some blocks to pass the delay
    lists:foreach(
        fun(_) ->
            B = create_block(ConsensusMembers, []),
            ok = blockchain_worker:add_block(B, self()),
            timer:sleep(100)
        end,
        lists:seq(1, 4)
    ),
    
    % 3 initial blocks + 4 blocks added + 1 mining block
    ok = miner_ct_utils:wait_until(fun() -> 8 =:= blockchain_worker:height() end),

    ok = send_receipts(LatLongs),

    % Capture all trace messages from statem
    Msgs = loop([]),

    % First few are blocks
    {AddBlockMsgs, Msgs1} = lists:split(4, Msgs),
    lists:foreach(
        fun(Msg) ->
            ?assertMatch({blockchain_event, {add_block, _, true}}, Msg)
        end,
        AddBlockMsgs
    ),

    % Filter extra useless add block
    Msgs2 = lists:filter(
        fun({blockchain_event, _}) -> false;
           (_) -> true
        end,
        Msgs1
    ),

    % Then target
    [TargetMsg|Msgs3] = Msgs2,
    ?assertMatch({target, _, _}, TargetMsg),
 
    % Then challenge
    [ChallengeMsg|Msgs4] = Msgs3,
    ?assertMatch({challenge, _, _}, ChallengeMsg),

    % Receipts and submit
    lists:foreach(
        fun({receipt, _}) -> ok;
           (submit) -> ok;
           (_) -> error     
        end,
        Msgs4
    ),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ?assert(meck:validate(miner_onion)),
    meck:unload(miner_onion),
    ?assert(meck:validate(miner_onion_handler)),
    meck:unload(miner_onion_handler),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

loop(Acc) ->
    receive
        {trace, _, 'receive', {blockchain_event, _}=Msg} ->
            loop([Msg|Acc]);
        {trace, _, 'receive', {target, _, _}=Msg} ->
            loop([Msg|Acc]);
        {trace, _, 'receive', {challenge, _, _}=Msg} ->
            loop([Msg|Acc]);
        {trace, _, 'receive', {'$gen_cast', {receipt, _}=Msg}} ->
            loop([Msg|Acc]);
        {trace, _, 'receive', submit} ->
            loop([submit|Acc]);
        _M ->
            loop(Acc)
    after 2500 ->
        lists:reverse(Acc)
    end.

send_receipts(LatLongs) ->
    lists:foreach(
        fun({_LatLong, {PrivKey, PubKey}}) ->
            Address = libp2p_crypto:pubkey_to_address(PubKey),
            SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            {Mega, Sec, Micro} = os:timestamp(),
            Timestamp = Mega * 1000000 * 1000000 + Sec * 1000000 + Micro,
            Receipt = blockchain_poc_receipt_v1:new(Address, Timestamp, <<>>),
            SignedReceipt = blockchain_poc_receipt_v1:sign(Receipt, SigFun),
            miner_poc_statem:receipt(SignedReceipt)
        end,
        LatLongs
    ).

build_asserts(LatLongs, {PrivKey, PubKey}) ->
    lists:foldl(
        fun({LatLong, {GatewayPrivKey, GatewayPubKey}}, Acc) ->
            Gateway = libp2p_crypto:pubkey_to_address(GatewayPubKey),
            GatewaySigFun = libp2p_crypto:mk_sig_fun(GatewayPrivKey),
            OwnerSigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            Owner = libp2p_crypto:pubkey_to_address(PubKey),
            Index = h3:from_geo(LatLong, 9),    

            AssertLocationRequestTx = blockchain_txn_assert_location_v1:new(Gateway, Owner, Index, 1),
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
            Gateway = libp2p_crypto:pubkey_to_address(GatewayPubKey),
            GatewaySigFun = libp2p_crypto:mk_sig_fun(GatewayPrivKey),
            OwnerSigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            Owner = libp2p_crypto:pubkey_to_address(PubKey),

            AddGatewayTx = blockchain_txn_add_gateway_v1:new(Owner, Gateway),
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
            {PrivKey, PubKey} = libp2p_crypto:generate_keys(),
            SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            [{libp2p_crypto:pubkey_to_address(PubKey), {PubKey, PrivKey, SigFun}}|Acc]
        end
        ,[]
        ,lists:seq(1, N)
    ).

create_block(ConsensusMembers, Txs) ->
    Blockchain = blockchain_worker:blockchain(),
    PrevHash = blockchain:head_hash(Blockchain),
    Height = blockchain_block:height(blockchain:head_block(Blockchain)) + 1,
    Block0 = blockchain_block:new(PrevHash, Height, Txs, <<>>, #{}),
    BinBlock = erlang:term_to_binary(blockchain_block:remove_signature(Block0)),
    Signatures = signatures(ConsensusMembers, BinBlock),
    Block1 = blockchain_block:sign_block(erlang:term_to_binary(Signatures), Block0),
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