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
-define(BLOCK_DELAY, 30).
-define(MINING_TIMEOUT, 5).
-define(CHALLENGE_RETRY, 3).
-define(CHALLENGE_TIMEOUT, 3).
-define(RECEIPTS_TIMEOUT, 10).

-record(data, {
    blockchain :: blockchain:blockchain() | undefined,
    address :: libp2p_crypto:pubkey_bin(),
    secret :: binary() | undefined,
    onion_keys :: keys() | undefined,
    challengees = [] :: [libp2p_crypto:pubkey_bin()],
    receipts = [] :: blockchain_poc_receipt_v1:poc_receipts(),
    witnesses = [] :: blockchain_poc_receipt_v1:poc_witnesses(),
    challenge_timeout = ?CHALLENGE_TIMEOUT :: non_neg_integer(),
    mining_timeout = ?MINING_TIMEOUT :: non_neg_integer(),
    delay = ?BLOCK_DELAY :: non_neg_integer(),
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
    Delay = maps:get(delay, Args, ?BLOCK_DELAY),
    Blockchain = blockchain_worker:blockchain(),
    lager:info("init with ~p", [Args]),
    {ok, requesting, #data{blockchain=Blockchain, address=Address, delay=Delay}}.

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
            {keep_state,  Data#data{blockchain=Chain}}
    end;
requesting(info, {blockchain_event, {add_block, BlockHash, false}}, #data{address=Address}=Data) ->
    case allow_request(BlockHash, Data) of
        false ->
            lager:info("request not allowed yet (~p)", [BlockHash]),
            {keep_state, Data};
        true ->
            lager:info("request allowed @ ~p", [BlockHash]),
            {Txn, Keys, Secret} = create_request(Address),
            ok = blockchain_worker:submit_txn(Txn),
            lager:info("submitted poc request ~p", [Txn]),
            {next_state, mining, Data#data{secret=Secret, onion_keys=Keys}}
    end;
requesting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
mining(info, {blockchain_event, {add_block, BlockHash, _}}, #data{secret=Secret,
                                                                  mining_timeout=MiningTimeout}=Data0) ->
    lager:info("got block ~p checking content", [BlockHash]),
    case find_request(BlockHash, Data0) of
        ok ->
            self() ! {target, <<Secret/binary, BlockHash/binary>>},
            lager:info("request was mined @ ~p", [BlockHash]),
            Data1 = Data0#data{mining_timeout=?MINING_TIMEOUT},
            {next_state, targeting, Data1};
        {error, _Reason} ->
             lager:info("request not found in block ~p : ~p", [BlockHash, _Reason]),
             case MiningTimeout > 0 of
                true ->
                    {keep_state, Data0#data{mining_timeout=MiningTimeout-1}};
                false ->
                    lager:error("did not see PoC request in last ~p block, retrying", [?MINING_TIMEOUT]),
                    {next_state, requesting, Data0#data{mining_timeout=?MINING_TIMEOUT}}
            end
    end;
mining(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
targeting(info, _, #data{retry=0}=Data) ->
    lager:error("targeting/challenging failed ~p times back to requesting", [?CHALLENGE_RETRY]),
    {next_state, requesting, Data#data{retry=?CHALLENGE_RETRY}};
targeting(info, {target, Entropy}, #data{blockchain=Blockchain}=Data) ->
    Ledger = blockchain:ledger(Blockchain),
    {Target, Gateways} = blockchain_poc_path:target(Entropy, Ledger),
    lager:info("target found ~p, challenging, hash: ~p", [Target, Entropy]),
    self() ! {challenge, Entropy, Target, Gateways},
    {next_state, challenging, Data#data{challengees=[]}};
targeting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
challenging(info, {challenge, Entropy, Target, Gateways}, #data{retry=Retry,
                                                                onion_keys= #{secret := PvtOnionKey, public := OnionCompactKey}
                                                               }=Data) ->
    case blockchain_poc_path:build(Target, Gateways) of
        {error, Reason} ->
            lager:error("could not build path for ~p: ~p", [Target, Reason]),
            lager:info("selecting new target"),
            self() ! {target, Entropy},
            {next_state, targeting, Data#data{retry=Retry-1}};
        {ok, Path} ->
            lager:info("path created ~p", [Path]),
            N = erlang:length(Path),
            OnionList = lists:zip(blockchain_txn_poc_receipts_v1:create_secret_hash(Entropy, N), Path),
            Onion = miner_onion_server:construct_onion({libp2p_crypto:mk_ecdh_fun(PvtOnionKey), OnionCompactKey}, OnionList),
            lager:info("onion of length ~p created ~p", [byte_size(Onion), Onion]),
            [Start|_] = Path,
            P2P = libp2p_crypto:pubkey_bin_to_p2p(Start),
            case send_onion(P2P, Onion, 3) of
                ok ->
                    {next_state, receiving, Data#data{challengees=Path}};
                {error, Reason} ->
                    lager:error("failed to dial 1st hotspot (~p): ~p", [P2P, Reason]),
                    lager:info("selecting new target"),
                    self() ! {target, Entropy},
                    {next_state, targeting, Data#data{retry=Retry-1}}
            end
    end;
challenging(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
receiving(info, {blockchain_event, {add_block, _Hash, _}}, #data{challenge_timeout=0}=Data) ->
    lager:warning("timing out, submitting receipts @ ~p", [_Hash]),
    self() ! submit,
    {next_state, submitting, Data#data{challenge_timeout=?CHALLENGE_TIMEOUT}};
receiving(info, {blockchain_event, {add_block, _Hash, _}}, #data{challenge_timeout=T}=Data) ->
    lager:info("got block ~p decreasing timeout", [_Hash]),
    {keep_state, Data#data{challenge_timeout=T-1}};
receiving(cast, {witness, Witness}, #data{witnesses=Witnesses}=Data) ->
     lager:info("got witness ~p", [Witness]),
    {keep_state, Data#data{witnesses=[Witness|Witnesses]}};
receiving(cast, {receipt, Receipt}, #data{receipts=Receipts0
                                          ,challengees=Challengees}=Data) ->
    lager:info("got receipt ~p", [Receipt]),
    Address = blockchain_poc_receipt_v1:address(Receipt),
    % TODO: Also check onion layer secret
    case blockchain_poc_receipt_v1:is_valid(Receipt)
         andalso lists:member(Address, Challengees)
    of
        false ->
            lager:warning("ignoring receipt ~p", [Receipt]),
            {keep_state, Data};
        true ->
            Receipts1 = [Receipt|Receipts0],
            {keep_state, Data#data{receipts=Receipts1}}
    end;
receiving(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
submitting(info, submit, #data{address=Address, receipts=Receipts, witnesses=Witnesses, secret=Secret}=Data) ->
    Txn0 = blockchain_txn_poc_receipts_v1:new(Receipts, Witnesses, Address, Secret, 0),
    {ok, _, SigFun} = blockchain_swarm:keys(),
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
waiting(info, {blockchain_event, {add_block, _BlockHash, _}}, #data{receipts_timeout=0}=Data) ->
    lager:warning("I have been waiting for ~p blocks abandoning last request", [?RECEIPTS_TIMEOUT]),
    {next_state, requesting,  Data#data{receipts_timeout=?RECEIPTS_TIMEOUT}};
waiting(info, {blockchain_event, {add_block, BlockHash, _}}, #data{receipts_timeout=Timeout}=Data) ->
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
-spec allow_request(binary(), data()) -> boolean().
allow_request(BlockHash, #data{blockchain=Blockchain,
                               address=Address,
                               delay=Delay}) ->
    Ledger = blockchain:ledger(Blockchain),
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
                    case blockchain_ledger_gateway_v1:last_poc_challenge(GwInfo) of
                        undefined ->
                            lager:info("got block ~p @ height ~p (never challenged before)", [BlockHash, Height]),
                            true;
                        LastChallenge ->
                            lager:info("got block ~p @ height ~p (~p)", [BlockHash, Height, LastChallenge]),
                            (Height - LastChallenge) > Delay
                    end
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec create_request(libp2p_crypto:pubkey_bin()) -> {blockchain_txn_poc_request_v1:txn_poc_request(),
                                                     keys(),
                                                     binary()}.
create_request(Address) ->
    Keys = libp2p_crypto:generate_keys(ecc_compact),
    Secret = libp2p_crypto:keys_to_bin(Keys),
    #{public := OnionCompactKey} = Keys,
    Tx = blockchain_txn_poc_request_v1:new(
        Address,
        crypto:hash(sha256, Secret),
        crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(OnionCompactKey))
    ),
    {ok, _, SigFun} = blockchain_swarm:keys(),
    {blockchain_txn:sign(Tx, SigFun), Keys, Secret}.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec find_request(binary(), data()) -> ok | {error, any()}.
find_request(BlockHash, #data{blockchain=Blockchain,
                              address=Address,
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
                    blockchain_txn:type(Txn) =:= blockchain_txn_poc_request_v1  andalso
                    blockchain_txn_poc_request_v1:gateway(Txn) =:= Address andalso
                    blockchain_txn:hash(Txn) =:= crypto:hash(sha256, Secret) andalso
                    blockchain_txn_poc_request_v1:onion(Txn) =:= crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(OnionCompactKey))
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
                               address=Address,
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
                    blockchain_txn_poc_receipts_v1:challenger(Txn) =:= Address andalso
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
            _ = miner_onion_handler:send(Stream, Onion),
            lager:info("onion sent"),
            ok;
        {error, Reason} ->
            lager:error("failed to dial 1st hotspot (~p): ~p", [P2P, Reason]),
            timer:sleep(timer:seconds(5)),
            send_onion(P2P, Onion, Retry-1)
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

target_test() ->
    meck:new(blockchain_ledger_v1, [passthrough]),
    meck:new(blockchain_worker, [passthrough]),
    meck:new(blockchain_swarm, [passthrough]),
    meck:new(blockchain, [passthrough]),
    LatLongs = [
        {{37.782061, -122.446167}, 0.1},
        {{37.782604, -122.447857}, 0.99},
        {{37.782074, -122.448528}, 0.99},
        {{37.782002, -122.44826}, 0.99},
        {{37.78207, -122.44613}, 0.99},
        {{37.781909, -122.445411}, 0.99},
        {{37.783371, -122.447879}, 0.99},
        {{37.780827, -122.44716}, 0.99}
    ],
    ActiveGateways = lists:foldl(
        fun({LatLong, Score}, Acc) ->
            Owner = <<"test">>,
            Address = crypto:hash(sha256, erlang:term_to_binary(LatLong)),
            Index = h3:from_geo(LatLong, 9),
            G0 = blockchain_ledger_gateway_v1:new(Owner, Index),
            G1 = blockchain_ledger_gateway_v1:score(Score, G0),
            maps:put(Address, G1, Acc)

        end,
        maps:new(),
        LatLongs
    ),

    meck:expect(blockchain_ledger_v1, active_gateways, fun(_) -> ActiveGateways end),
    meck:expect(blockchain_worker, blockchain, fun() -> blockchain end),
    meck:expect(blockchain_swarm, pubkey_bin, fun() -> <<"unknown">> end),
    meck:expect(blockchain, ledger, fun(_) -> ledger end),

    Block = blockchain_block_v1:new(#{prev_hash => <<>>,
                                      height => 2,
                                      transactions => [],
                                      signatures => [],
                                      hbbft_round => 0,
                                      time => 0}),
    Hash = blockchain_block:hash_block(Block),
    {Target, Gateways} = blockchain_poc_path:target(Hash, undefined),

    [{LL, _}|_] = LatLongs,
    ?assertEqual(crypto:hash(sha256, erlang:term_to_binary(LL)), Target),
    ?assertEqual(ActiveGateways, Gateways),

    ?assert(meck:validate(blockchain_ledger_v1)),
    ?assert(meck:validate(blockchain_worker)),
    ?assert(meck:validate(blockchain_swarm)),
    ?assert(meck:validate(blockchain)),
    meck:unload(blockchain_ledger_v1),
    meck:unload(blockchain_worker),
    meck:unload(blockchain_swarm),
    meck:unload(blockchain).

-endif.
