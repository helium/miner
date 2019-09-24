%%%-------------------------------------------------------------------
%% @doc
%% == Miner PoC Statem ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_poc_statem).

-behavior(gen_statem).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    receipt/1,
    witness/1
]).

%% ------------------------------------------------------------------
%% gen_statem Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    code_change/3,
    callback_mode/0,
    terminate/2
]).

%% ------------------------------------------------------------------
%% gen_statem callbacks Exports
%% ------------------------------------------------------------------
-export([
    requesting/3,
    mining/3,
    delaying/3,
    targeting/3,
    challenging/3,
    receiving/3,
    submitting/3,
    waiting/3
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).
-define(MINING_TIMEOUT, 5).
-define(MINING_DELAY, 10).
-define(CHALLENGE_RETRY, 3).
-define(RECEIVING_TIMEOUT, 10).
-define(RECEIPTS_TIMEOUT, 10).

-record(data, {
    blockchain :: blockchain:blockchain() | undefined,
    address :: libp2p_crypto:pubkey_bin(),
    secret :: binary() | undefined,
    onion_keys :: keys() | undefined,
    challengees = [] :: [{libp2p_crypto:pubkey_bin(), binary()}],
    packet_hashes = [] :: [{libp2p_crypto:pubkey_bin(), binary()}],
    responses = #{},
    receiving_timeout = ?RECEIVING_TIMEOUT :: non_neg_integer(),
    poc_hash  :: binary() | undefined,
    mining_timeout = ?MINING_TIMEOUT :: non_neg_integer(),
    mining_delay = ?MINING_DELAY :: non_neg_integer(),
    mining_hash :: undefined | binary(),
    mining_ledger :: undefined | blockchain_ledger_v1:ledger(),
    poc_interval :: non_neg_integer() | undefined,
    retry = ?CHALLENGE_RETRY :: non_neg_integer(),
    receipts_timeout = ?RECEIPTS_TIMEOUT :: non_neg_integer()
}).

-type data() :: #data{}.
-type keys() :: #{secret => libp2p_crypto:privkey(), public => libp2p_crypto:pubkey()}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_statem:start_link({local, ?SERVER}, ?SERVER, Args, []).

receipt(Data) ->
    gen_statem:cast(?SERVER, {receipt, Data}).

witness(Data) ->
    gen_statem:cast(?SERVER, {witness, Data}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    ok = blockchain_event:add_handler(self()),
    ok = miner_poc:add_stream_handler(blockchain_swarm:swarm()),
    ok = miner_onion:add_stream_handler(blockchain_swarm:swarm()),
    Address = blockchain_swarm:pubkey_bin(),
    Blockchain = blockchain_worker:blockchain(),
    %% this should really only be overriden for testing
    Delay = maps:get(delay, Args, undefined),
    lager:info("init with ~p", [Args]),
    {ok, requesting, #data{blockchain=Blockchain, address=Address, poc_interval=Delay}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

callback_mode() -> state_functions.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% gen_statem callbacks
%% ------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
requesting(info, Msg, #data{blockchain=undefined}=Data) ->
    case blockchain_worker:blockchain() of
        undefined ->
            lager:warning("dropped ~p cause chain is still undefined", [Msg]),
            {keep_state,  Data};
        Chain ->
            self() ! Msg,
            {keep_state, Data#data{blockchain=Chain}}
    end;
requesting(info, {blockchain_event, {add_block, BlockHash, false, Ledger}}, #data{address=Address}=Data) ->
    case allow_request(BlockHash, Data) of
        false ->
            {keep_state, Data};
        true ->
            {Txn, Keys, Secret} = create_request(Address, BlockHash, Ledger),
            #{public := PubKey} = Keys,
            <<ID:10/binary, _/binary>> = libp2p_crypto:pubkey_to_bin(PubKey),
            lager:md([{poc_id, ID}]),
            lager:info("request allowed @ ~p", [BlockHash]),
            ok = blockchain_worker:submit_txn(Txn),
            lager:info("submitted poc request ~p", [Txn]),
            {next_state, mining, Data#data{secret=Secret, onion_keys=Keys, responses=#{}, poc_hash=BlockHash}}
    end;
requesting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
mining(info, {blockchain_event, {add_block, BlockHash, _, PinnedLedger}}, #data{mining_timeout=MiningTimeout}=Data) ->
    case find_request(BlockHash, Data) of
        ok ->
            RandomDelay = rand:uniform(?MINING_DELAY),
            lager:info("request was mined @ ~p delaying ~p blocks", [BlockHash, RandomDelay]),
            {next_state, delaying, Data#data{mining_timeout=?MINING_TIMEOUT,
                                             mining_hash=BlockHash,
                                             mining_delay=RandomDelay,
                                             mining_ledger=PinnedLedger}};
        {error, _Reason} ->
             case MiningTimeout > 0 of
                true ->
                    {keep_state, Data#data{mining_timeout=MiningTimeout-1}};
                false ->
                    lager:error("did not see PoC request in last ~p block, retrying", [?MINING_TIMEOUT]),
                    {next_state, requesting, Data#data{mining_timeout=?MINING_TIMEOUT}}
            end
    end;
mining(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
delaying(info, {blockchain_event, {add_block, _, _, _}}, #data{mining_delay=Delay}=Data0) when Delay > 0 ->
    {keep_state, Data0#data{mining_delay=Delay-1}};
delaying(info, {blockchain_event, {add_block, _, _, _}}, #data{blockchain=Chain,
                                                               address=Challenger,
                                                               secret=Secret,
                                                               mining_delay=0,
                                                               mining_hash=MiningHash,
                                                               mining_ledger=PinnedLedger}=Data) ->
    lager:info("delay over, moving to targeting"),
    {ok, Block} = blockchain:get_block(MiningHash, Chain),
    Height = blockchain_block:height(Block),
    self() ! {target, <<Secret/binary, MiningHash/binary, Challenger/binary>>, Height, PinnedLedger},
    {next_state, targeting, Data};
delaying(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
targeting(info, {target, _, _, _}, #data{retry=0}=Data) ->
    lager:error("targeting/challenging failed ~p times back to requesting", [?CHALLENGE_RETRY]),
    {next_state, requesting, Data#data{retry=?CHALLENGE_RETRY}};
targeting(info, {target, Entropy, Height, Ledger}, Data) ->
    case blockchain_poc_path:target(Entropy, Ledger, blockchain_swarm:pubkey_bin()) of
        {Target, Gateways} ->
            lager:info("target found ~p, challenging, hash: ~p", [Target, Entropy]),
            self() ! {challenge, Entropy, Target, Gateways, Height, Ledger},
            {next_state, challenging, Data#data{challengees=[]}};
        no_target ->
            lager:warning("no target found, back to requesting"),
            {next_state, requesting, Data#data{retry=?CHALLENGE_RETRY}}
    end;
targeting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
challenging(info, {challenge, Entropy, Target, Gateways, Height, Ledger}, #data{retry=Retry,
                                                                                onion_keys=OnionKey,
                                                                                poc_hash=BlockHash
                                                                               }=Data) ->
    case blockchain_poc_path:build(Entropy, Target, Gateways, Height, Ledger) of
        {error, Reason} ->
            lager:error("could not build path for ~p: ~p", [Target, Reason]),
            lager:info("selecting new target"),
            self() ! {target, Entropy, Height, Ledger},
            {next_state, targeting, Data#data{retry=Retry-1}};
        {ok, Path} ->
            lager:info("path created ~p", [Path]),
            N = erlang:length(Path),
            [<<IV:16/integer-unsigned-little, _/binary>> | LayerData] = blockchain_txn_poc_receipts_v1:create_secret_hash(Entropy, N+1),
            OnionList = lists:zip([ libp2p_crypto:bin_to_pubkey(P) || P <- Path], LayerData),
            {Onion, Layers} = blockchain_poc_packet:build(OnionKey, IV, OnionList, BlockHash, Ledger),
            %% no witness will exist for the first layer hash as it is delivered over p2p
            [_|LayerHashes] = [ crypto:hash(sha256, L) || L <- Layers ],
            lager:info("onion of length ~p created ~p", [byte_size(Onion), Onion]),
            [Start|_] = Path,
            P2P = libp2p_crypto:pubkey_bin_to_p2p(Start),
            case send_onion(P2P, Onion, 3) of
                ok ->
                    {next_state, receiving, Data#data{challengees=lists:zip(Path, LayerData), packet_hashes=lists:zip(Path, LayerHashes)}};
                {error, Reason} ->
                    lager:error("failed to dial 1st hotspot (~p): ~p", [P2P, Reason]),
                    lager:info("selecting new target"),
                    self() ! {target, Entropy, Height, Ledger},
                    {next_state, targeting, Data#data{retry=Retry-1}}
            end
    end;
challenging(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
receiving(info, {blockchain_event, {add_block, _Hash, _, _}}, #data{receiving_timeout=0, responses=Responses}=Data) ->
    case maps:size(Responses) of
        0 ->
            lager:warning("timing out, no receipts @ ~p", [_Hash]),
            %% we got nothing, no reason to submit
            {next_state, requesting, Data#data{retry=?CHALLENGE_RETRY}};
        _ ->
            lager:warning("timing out, submitting receipts @ ~p", [_Hash]),
            self() ! submit,
            {next_state, submitting, Data#data{receiving_timeout=?RECEIVING_TIMEOUT}}
    end;
receiving(info, {blockchain_event, {add_block, _Hash, _, _}}, #data{receiving_timeout=T}=Data) ->
    lager:info("got block ~p decreasing timeout", [_Hash]),
    {keep_state, Data#data{receiving_timeout=T-1}};
receiving(cast, {witness, Witness}, #data{responses=Responses0,
                                          packet_hashes=PacketHashes,
                                          blockchain=Chain}=Data) ->
    lager:info("got witness ~p", [Witness]),
    %% Validate the witness is correct
    Ledger = blockchain:ledger(Chain),
    case validate_witness(Witness, Ledger) of
        false ->
            lager:warning("ignoring invalid witness ~p", [Witness]),
            {keep_state, Data};
        true ->
            PacketHash = blockchain_poc_witness_v1:packet_hash(Witness),
            GatewayWitness = blockchain_poc_witness_v1:gateway(Witness),
            %% check this is a known layer of the packet
            case lists:keyfind(PacketHash, 2, PacketHashes) of
                false ->
                    lager:warning("Saw invalid witness with packet hash ~p", [PacketHash]),
                    {keep_state, Data};
                {GatewayWitness, PacketHash} ->
                    lager:warning("Saw self-witness from ~p", [GatewayWitness]),
                    {keep_state, Data};
                _ ->
                    Witnesses = maps:get(PacketHash, Responses0, []),
                    case erlang:length(Witnesses) >= 5 of
                        true ->
                            {keep_state, Data};
                        false ->
                            Responses1 = maps:put(PacketHash, [Witness|Witnesses], Responses0),
                            {keep_state, Data#data{responses=Responses1}}
                    end
            end
    end;
receiving(cast, {receipt, Receipt}, #data{responses=Responses0, challengees=Challengees}=Data) ->
    lager:info("got receipt ~p", [Receipt]),
    Gateway = blockchain_poc_receipt_v1:gateway(Receipt),
    LayerData = blockchain_poc_receipt_v1:data(Receipt),
    case blockchain_poc_receipt_v1:is_valid(Receipt) of
        false ->
            lager:warning("ignoring invalid receipt ~p", [Receipt]),
            {keep_state, Data};
        true ->
            %% Also check onion layer secret
            case lists:keyfind(Gateway, 1, Challengees) of
                {Gateway, LayerData} ->
                    case maps:get(Gateway, Responses0, undefined) of
                        undefined ->
                            Responses1 = maps:put(Gateway, Receipt, Responses0),
                            {keep_state, Data#data{responses=Responses1}};
                        _ ->
                            lager:warning("Already got this receipt ~p for ~p ignoring", [Receipt, Gateway]),
                            {keep_state, Data}
                    end;
                {Gateway, OtherData} ->
                    lager:warning("Got incorrect layer data ~p from ~p (expected ~p)", [Gateway, OtherData, Data]),
                    {keep_state, Data};
                false ->
                    lager:warning("Got unexpected receipt from ~p", [Gateway]),
                    {keep_state, Data}
            end
    end;
receiving(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
submitting(info, submit, #data{packet_hashes=[]}=Data) ->
    %% Somehow we lost the packet hashes and cannot build the path
    %% to submit the poc_receipt txn. Go back to requesting.
    lager:error("no packet_hashes ~p", [lager:pr(Data, ?MODULE)]),
    {next_state, requesting, Data};
submitting(info, submit, #data{address=Challenger,
                               responses=Responses0,
                               secret=Secret,
                               packet_hashes=LayerHashes,
                               onion_keys= #{public := OnionCompactKey}}=Data) ->
    OnionKeyHash = crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(OnionCompactKey)),
    Path1 = lists:foldl(
        fun({Challengee, LayerHash}, Acc) ->
            Receipt = maps:get(Challengee, Responses0, undefined),
            Witnesses = maps:get(LayerHash, Responses0, []),
            E = blockchain_poc_path_element_v1:new(Challengee, Receipt, Witnesses),
            [E|Acc]
        end,
        [],
        LayerHashes
    ),
    Txn0 = blockchain_txn_poc_receipts_v1:new(Challenger, Secret, OnionKeyHash, lists:reverse(Path1)),
    {ok, _, SigFun, _ECDHFun} = blockchain_swarm:keys(),
    Txn1 = blockchain_txn:sign(Txn0, SigFun),
    ok = blockchain_worker:submit_txn(Txn1),
    lager:info("submitted blockchain_txn_poc_receipts_v1 ~p", [Txn0]),
    {next_state, waiting, Data#data{receipts_timeout=?RECEIPTS_TIMEOUT}};
submitting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
waiting(info, {blockchain_event, {add_block, _BlockHash, _, _}}, #data{receipts_timeout=0}=Data) ->
    lager:warning("I have been waiting for ~p blocks abandoning last request", [?RECEIPTS_TIMEOUT]),
    {next_state, requesting,  Data#data{receipts_timeout=?RECEIPTS_TIMEOUT}};
waiting(info, {blockchain_event, {add_block, BlockHash, _, _}}, #data{receipts_timeout=Timeout}=Data) ->
    case find_receipts(BlockHash, Data) of
        ok ->
            {next_state, requesting,  Data#data{receipts_timeout=?RECEIPTS_TIMEOUT}};
        {error, _Reason} ->
             lager:info("receipts not found in block ~p : ~p", [BlockHash, _Reason]),
            {keep_state,  Data#data{receipts_timeout=Timeout-1}}
    end;
waiting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec validate_witness(blockchain_poc_witness_v1:witness(), blockchain_ledger_v1:ledger()) -> boolean().
validate_witness(Witness, Ledger) ->
    Gateway = blockchain_poc_witness_v1:gateway(Witness),
    %% TODO this should be against the ledger at the time the receipt was mined
    case blockchain_ledger_v1:find_gateway_info(Gateway, Ledger) of
        {error, _Reason} ->
            lager:warning("failed to get witness ~p info ~p", [Gateway, _Reason]),
            false;
        {ok, GwInfo} ->
            case blockchain_ledger_gateway_v2:location(GwInfo) of
                undefined ->
                    lager:warning("ignoring witness ~p location undefined", [Gateway]),
                    false;
                _ ->
                    blockchain_poc_witness_v1:is_valid(Witness)
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec allow_request(binary(), data()) -> boolean().
allow_request(BlockHash, #data{blockchain=Blockchain,
                               address=Address,
                               poc_interval=POCInterval0}) ->
    Ledger = blockchain:ledger(Blockchain),
    POCInterval =
        case POCInterval0 of
            undefined ->
                blockchain_utils:challenge_interval(Ledger);
            _ ->
                POCInterval0
        end,

    case blockchain_ledger_v1:find_gateway_info(Address, Ledger) of
        {error, Error} ->
            lager:warning("failed to get gateway info for ~p : ~p", [Address, Error]),
            false;
        {ok, GwInfo} ->
            case blockchain:get_block(BlockHash, Blockchain) of
                {error, Error} ->
                    lager:warning("failed to get block ~p : ~p", [BlockHash, Error]),
                    false;
                {ok, Block} ->
                    Height = blockchain_block:height(Block),
                    case blockchain_ledger_gateway_v2:last_poc_challenge(GwInfo) of
                        undefined ->
                            lager:info("got block ~p @ height ~p (never challenged before)", [BlockHash, Height]),
                            true;
                        LastChallenge ->
                            lager:info("got block ~p @ height ~p (~p)", [BlockHash, Height, LastChallenge]),
                            (Height - LastChallenge) > POCInterval
                    end
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec create_request(libp2p_crypto:pubkey_bin(), binary(), blockchain_ledger_v1:ledger()) ->
    {blockchain_txn_poc_request_v1:txn_poc_request(), keys(), binary()}.
create_request(Address, BlockHash, Ledger) ->
    Keys = libp2p_crypto:generate_keys(ecc_compact),
    Secret = libp2p_crypto:keys_to_bin(Keys),
    #{public := OnionCompactKey} = Keys,
    Version = blockchain_txn_poc_request_v1:get_version(Ledger),
    Tx = blockchain_txn_poc_request_v1:new(
        Address,
        crypto:hash(sha256, Secret),
        crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(OnionCompactKey)),
        BlockHash,
        Version
    ),
    {ok, _, SigFun, _ECDHFun} = blockchain_swarm:keys(),
    {blockchain_txn:sign(Tx, SigFun), Keys, Secret}.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec find_request(binary(), data()) -> ok | {error, any()}.
find_request(BlockHash, #data{blockchain=Blockchain,
                              address=Challenger,
                              secret=Secret,
                              onion_keys= #{public := OnionCompactKey}}) ->
    lager:info("got block ~p checking content", [BlockHash]),
    case blockchain:get_block(BlockHash, Blockchain) of
        {error, _Reason}=Error ->
            lager:error("failed to get block ~p : ~p", [BlockHash, _Reason]),
            Error;
        {ok, Block} ->
            Txns = blockchain_block:transactions(Block),
            Filter =
                fun(Txn) ->
                    SecretHash = crypto:hash(sha256, Secret),
                    OnionKeyHash = crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(OnionCompactKey)),
                    blockchain_txn:type(Txn) =:= blockchain_txn_poc_request_v1  andalso
                    blockchain_txn_poc_request_v1:challenger(Txn) =:= Challenger andalso
                    blockchain_txn_poc_request_v1:secret_hash(Txn) =:= SecretHash andalso
                    blockchain_txn_poc_request_v1:onion_key_hash(Txn) =:= OnionKeyHash
                end,
            case lists:filter(Filter, Txns) of
                [_POCReq] ->
                    ok;
                _ ->
                    lager:info("request not found in block ~p", [BlockHash]),
                    {error, not_found}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec find_receipts(binary(), data()) -> ok | {error, any()}.
find_receipts(BlockHash, #data{blockchain=Blockchain,
                               address=Challenger,
                               secret=Secret}) ->
    lager:info("got block ~p checking content", [BlockHash]),
    case blockchain:get_block(BlockHash, Blockchain) of
        {error, _Reason}=Error ->
            lager:error("failed to get block ~p : ~p", [BlockHash, _Reason]),
            Error;
        {ok, Block} ->
            Txns = blockchain_block:transactions(Block),
            Filter =
                fun(Txn) ->
                    blockchain_txn:type(Txn) =:= blockchain_txn_poc_receipts_v1 andalso
                    blockchain_txn_poc_receipts_v1:challenger(Txn) =:= Challenger andalso
                    blockchain_txn_poc_receipts_v1:secret(Txn) =:= Secret
                end,
            case lists:filter(Filter, Txns) of
                [_POCReceipts] ->
                    ok;
                _ ->
                    lager:info("request not found in block ~p", [BlockHash]),
                    {error, not_found}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
handle_event(info, {blockchain_event, {add_block, _, _, _}}, Data) ->
    %% suppress the warning here
    {keep_state, Data};
handle_event(_EventType, _EventContent, Data) ->
    lager:warning("ignoring event [~p] ~p", [_EventType, _EventContent]),
    {keep_state, Data}.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
send_onion(_P2P, _Onion, 0) ->
    {error, retries_exceeded};
send_onion(P2P, Onion, Retry) ->
    case miner_onion:dial_framed_stream(blockchain_swarm:swarm(), P2P, []) of
        {ok, Stream} ->
            unlink(Stream),
            _ = miner_onion_handler:send(Stream, Onion),
            lager:info("onion sent"),
            ok;
        {error, Reason} ->
            lager:error("failed to dial 1st hotspot (~p): ~p", [P2P, Reason]),
            timer:sleep(timer:seconds(10)),
            send_onion(P2P, Onion, Retry-1)
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

%% target_test() ->
%%     meck:new(blockchain_ledger_v1, [passthrough]),
%%     meck:new(blockchain_worker, [passthrough]),
%%     meck:new(blockchain_swarm, [passthrough]),
%%     meck:new(blockchain, [passthrough]),
%%     LatLongs = [
%%         {{37.782061, -122.446167}, 1.0, 1.0},
%%         {{37.782604, -122.447857}, 1000.0, 1.0},
%%         {{37.782074, -122.448528}, 1000.0, 1.0},
%%         {{37.782002, -122.44826}, 1000.0, 1.0},
%%         {{37.78207, -122.44613}, 1000.0, 1.0},
%%         {{37.781909, -122.445411}, 1000.0, 1.0},
%%         {{37.783371, -122.447879}, 1000.0, 1.0},
%%         {{37.780827, -122.44716}, 1000.0, 1.0}
%%     ],
%%     ActiveGateways = lists:foldl(
%%         fun({LatLong, Alpha, Beta}, Acc) ->
%%             Owner = <<"test">>,
%%             Address = crypto:hash(sha256, erlang:term_to_binary(LatLong)),
%%             Index = h3:from_geo(LatLong, 12),
%%             G0 = blockchain_ledger_gateway_v2:new(Owner, Index),
%%             G1 = blockchain_ledger_gateway_v2:set_alpha_beta_delta(Alpha, Beta, 1, G0),
%%             maps:put(Address, G1, Acc)

%%         end,
%%         maps:new(),
%%         LatLongs
%%     ),

%%     meck:expect(blockchain_ledger_v1, active_gateways, fun(_) -> ActiveGateways end),
%%     meck:expect(blockchain_ledger_v1, current_height, fun(_) -> {ok, 1} end),
%%     meck:expect(blockchain_ledger_v1, gateway_score, fun(_, _) -> {ok, 0.5} end),
%%     meck:expect(blockchain_worker, blockchain, fun() -> blockchain end),
%%     meck:expect(blockchain_swarm, pubkey_bin, fun() -> <<"unknown">> end),
%%     meck:expect(blockchain, ledger, fun(_) -> ledger end),
%%     meck:expect(blockchain,
%%                 config,
%%                 fun(min_score, _) ->
%%                         {ok, 0.2};
%%                    (h3_exclusion_ring_dist, _) ->
%%                         {ok, 2};
%%                    (h3_max_grid_distance, _) ->
%%                         {ok, 13};
%%                    (h3_neighbor_res, _) ->
%%                         {ok, 12};
%%                    (alpha_decay, _) ->
%%                         {ok, 0.007};
%%                    (beta_decay, _) ->
%%                         {ok, 0.0005};
%%                    (max_staleness, _) ->
%%                         {ok, 100000};
%%                    (correct_min_score, _) ->
%%                         {ok, true}
%%                 end),

%%     Block = blockchain_block_v1:new(#{prev_hash => <<>>,
%%                                       height => 2,
%%                                       transactions => [],
%%                                       signatures => [],
%%                                       hbbft_round => 0,
%%                                       time => 0,
%%                                       election_epoch => 1,
%%                                       epoch_start => 0
%%                                      }),
%%     Hash = blockchain_block:hash_block(Block),
%%     {Target, Gateways} = blockchain_poc_path:target(Hash, undefined, blockchain_swarm:pubkey_bin()),

%%     [{LL, _, _}|_] = LatLongs,
%%     ?assertEqual(crypto:hash(sha256, erlang:term_to_binary(LL)), Target),
%%     ?assertEqual(ActiveGateways, Gateways),

%%     ?assert(meck:validate(blockchain_ledger_v1)),
%%     ?assert(meck:validate(blockchain_worker)),
%%     ?assert(meck:validate(blockchain_swarm)),
%%     ?assert(meck:validate(blockchain)),
%%     meck:unload(blockchain_ledger_v1),
%%     meck:unload(blockchain_worker),
%%     meck:unload(blockchain_swarm),
%%     meck:unload(blockchain).

-endif.
