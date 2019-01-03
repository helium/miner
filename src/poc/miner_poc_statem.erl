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
    receipt/1
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
    submiting/3
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).
-define(CHALLENGE_TIMEOUT, 3).
-define(BLOCK_DELAY, 30).

-record(data, {
    blockchain :: blockchain:blockchain(),
    last_submit = 0 :: non_neg_integer(),
    address :: libp2p_crypto:address(),
    secret :: binary() | undefined,
    challengees = [] :: [libp2p_crypto:address()],
    challenge_timeout = ?CHALLENGE_TIMEOUT :: non_neg_integer(),
    receipts = [] :: blockchain_poc_receipt_v1:poc_receipts(),
    delay = ?BLOCK_DELAY :: non_neg_integer()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_statem:start_link({local, ?SERVER}, ?SERVER, Args, []).

receipt(Data) ->
    gen_statem:cast(?SERVER, {receipt, Data}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    ok = blockchain_event:add_handler(self()),
    ok = miner_poc:add_stream_handler(blockchain_swarm:swarm()),
    ok = miner_onion:add_stream_handler(blockchain_swarm:swarm()),
    Address = blockchain_swarm:address(),
    Delay = maps:get(delay, Args, ?BLOCK_DELAY),
    Blockchain = blockchain_worker:blockchain(),
    case maps:get(onion_server, Args, undefined) of
        {ok, {RadioHost, RadioPort}} ->
            PrivKey = maps:get(priv_key, Args),
            miner_onion_server:start_link(RadioHost, RadioPort, Address, PrivKey, self()),
            lager:info("started miner_onion_server");
        undefined ->
            lager:info("onion_server not started")
    end,
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
requesting(info, {blockchain_event, {add_block, _Hash, _}}, #data{blockchain=Blockchain,
                                                                  last_submit=LastSubmit,
                                                                  address=Address,
                                                                  delay=Delay}=Data) ->
    {ok, CurrHeight} = blockchain:height(Blockchain),
    lager:debug("got block ~p @ height ~p (~p)", [_Hash, CurrHeight, LastSubmit]),
    case (CurrHeight - LastSubmit) > Delay of
        false ->
            {keep_state, Data};
        true ->
            Secret = crypto:strong_rand_bytes(8),
            Tx = blockchain_txn_poc_request_v1:new(Address, crypto:hash(sha256, Secret)),
            {ok, _, SigFun} = blockchain_swarm:keys(),
            SignedTx = blockchain_txn_poc_request_v1:sign(Tx, SigFun),
            ok = blockchain_worker:submit_txn(blockchain_txn_poc_request_v1, SignedTx),
            lager:info("submited poc request ~p", [Tx]),
            {next_state, mining, Data#data{secret=Secret}}
    end;
requesting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
mining(info, {blockchain_event, {add_block, Hash, _}}, #data{blockchain=Blockchain, address=Address}=Data) ->
    lager:debug("got block ~p checking content", [Hash]),
    case blockchain:get_block(Hash, Blockchain) of
        {ok, Block} ->
            Txns = blockchain_block:poc_request_transactions(Block),
            Filter = fun(Txn) -> Address =:= blockchain_txn_poc_request_v1:gateway_address(Txn) end,
            case lists:filter(Filter, Txns) of
                [_POCReq] ->
                    {ok, CurrHeight} = blockchain:height(Blockchain),
                    self() ! {target, Hash},
                    lager:info("request was mined @ ~p, targeting now", [CurrHeight]),
                    {next_state, targeting, Data#data{last_submit=CurrHeight}};
                _ ->
                    lager:debug("request not found in block ~p", [Hash]),
                    {keep_state, Data}
            end;
        {error, _Reason} ->
            lager:error("failed to get block ~p : ~p", [Hash, _Reason]),
            {keep_state, Data}
    end;
mining(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
targeting(info, {target, Hash}, #data{blockchain=Blockchain}=Data) ->
    {Target, Gateways} = target(Hash, Blockchain),
    lager:info("target found ~p, challenging", [Target]),
    self() ! {challenge, Hash, Target, Gateways},
    {next_state, challenging, Data#data{challengees=[]}};
targeting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
challenging(info, {challenge, Hash, Target, Gateways}, #data{address=Address}=Data) ->
    case miner_poc_path:build(Target, Gateways) of
        {error, Reason} ->
            lager:error("could not build path for ~p: ~p", [Target, Reason]),
            lager:info("selecting new target"),
            self() ! {target, Hash},
            {next_state, targeting, Data};
        {ok, Path} ->
            lager:info("path created ~p", [Path]),
            Payload = erlang:term_to_binary(#{
                challenger => Address
            }),
            OnionList = [{Payload, A} || A <- Path],
            Onion = miner_onion_server:construct_onion(OnionList),
            lager:info("onion created ~p", [Onion]),
            [Start|_] = Path,
            P2P = libp2p_crypto:address_to_p2p(Start),
            case miner_onion:dial_framed_stream(blockchain_swarm:swarm(), P2P, []) of
                {ok, Stream} ->
                    _ = miner_onion_handler:send(Stream, Onion),
                    lager:info("onion sent"),
                    {next_state, receiving, Data#data{challengees=Path}};
                {error, Reason} ->
                    lager:error("failed to dial 1st hotspot (~p): ~p", [P2P, Reason]),
                    lager:info("selecting new target"),
                    self() ! {target, Hash},
                    {next_state, targeting, Data}
            end
    end;
challenging(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
receiving(info, {blockchain_event, {add_block, _Hash, _}}, #data{challenge_timeout=0}=Data) ->
    lager:warning("timing out, submiting receipts @ ~p", [_Hash]),
    self() ! submit,
    {next_state, submiting, Data#data{challenge_timeout= ?CHALLENGE_TIMEOUT}};
receiving(info, {blockchain_event, {add_block, _Hash, _}}, #data{challenge_timeout=T}=Data) ->
    lager:debug("got block ~p decreasing timeout", [_Hash]),
    {keep_state, Data#data{challenge_timeout=T-1}};
receiving(cast, {receipt, Receipt}, #data{receipts=Receipts0
                                          ,challengees=Challengees}=Data) ->
    lager:info("got receipt ~p", [Receipt]),
    Address = blockchain_poc_receipt_v1:address(Receipt),
    % TODO: Also check onion IV
    case blockchain_poc_receipt_v1:is_valid(Receipt)
         andalso lists:member(Address, Challengees)
    of
        false ->
            lager:warning("ignoring receipt ~p", [Receipt]),
            {keep_state, Data};
        true ->
            Receipts1 = [Receipt|Receipts0],
            case erlang:length(Receipts1) =:= erlang:length(Challengees) of
                false ->
                    lager:debug("waiting for more"),
                    {keep_state, Data#data{receipts=Receipts1}};
                true ->
                    lager:info("got all ~p receipts, submitting", [erlang:length(Receipts1)]),
                    self() ! submit,
                    {next_state, submiting, Data#data{receipts=Receipts1}}
            end
    end;
receiving(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
submiting(info, submit, #data{address=Address, receipts=Receipts, secret=Secret}=Data) ->
    Txn0 = blockchain_txn_poc_receipts_v1:new(Receipts, Address, Secret),
    {ok, _, SigFun} = blockchain_swarm:keys(),
    Txn1 = blockchain_txn_poc_receipts_v1:sign(Txn0, SigFun),
    ok = blockchain_worker:submit_txn(blockchain_txn_poc_receipts_v1, Txn1),
    lager:info("submited blockchain_txn_poc_receipts_v1 ~p", [Txn0]),
    {next_state, requesting, Data};
submiting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec target(binary(), blockchain:blockchain()) -> {libp2p_crypto:address(), map()}.
target(Hash, Blockchain) ->
    ActiveGateways = active_gateways(Blockchain),
    Probs = create_probs(ActiveGateways),
    Entropy = entropy(Hash, Probs),
    Target = select_target(Probs, maps:keys(ActiveGateways), Entropy, 1),
    {Target, ActiveGateways}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

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
-spec create_probs(map()) -> [float()].
create_probs(Gateways) ->
    GwScores = [blockchain_ledger_gateway_v1:score(G) || G <- maps:values(Gateways)],
    LenGwScores = erlang:length(GwScores),
    SumGwScores = lists:sum(GwScores),
    [prob(Score, LenGwScores, SumGwScores) || Score <- GwScores].

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec prob(float(), pos_integer(), float()) -> float().
prob(Score, LenScores, SumScores) ->
    (1.0 - Score) / (LenScores - SumScores).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec entropy(binary(), [float()]) -> float().
entropy(Entropy, Probs) ->
    <<A:85/integer-unsigned-little, B:85/integer-unsigned-little,
      C:86/integer-unsigned-little, _/binary>> = crypto:hash(sha256, Entropy),
    S = rand:seed_s(exrop, {A, B, C}),
    {R, _} = rand:uniform_s(S),
    R * lists:sum(Probs).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
select_target([W1 | _T], Adresses, Rnd, Index) when (Rnd - W1) < 0 ->
    lists:nth(Index, Adresses);
select_target([W1 | T], Adresses, Rnd, Index) ->
    select_target(T, Adresses, Rnd - W1, Index + 1).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec active_gateways(blockchain:blockchain()) -> map().
active_gateways(Blockchain) ->
    Ledger = blockchain:ledger(Blockchain),
    ActiveGateways = blockchain_ledger_v1:active_gateways(Ledger),
    maps:filter(
        fun(Address, Gateway) ->
            % TODO: Maybe do some find of score check here
            Address =/= blockchain_swarm:address()
            andalso blockchain_ledger_gateway_v1:location(Gateway) =/= undefined
        end
        ,ActiveGateways
    ).

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
    meck:expect(blockchain_swarm, address, fun() -> <<"unknown">> end),
    meck:expect(blockchain, ledger, fun(_) -> ledger end),

    Block = blockchain_block:new(<<>>, 2, [], <<>>, #{}),
    Hash = blockchain_block:hash_block(Block),
    {Target, Gateways} = target(Hash, undefined),

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
