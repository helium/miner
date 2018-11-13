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
    start_link/1
    ,receipt/1
]).

%% ------------------------------------------------------------------
%% gen_statem Function Exports
%% ------------------------------------------------------------------
-export([
    init/1
    ,code_change/3
    ,callback_mode/0
    ,terminate/2
]).

%% ------------------------------------------------------------------
%% gen_statem callbacks Exports
%% ------------------------------------------------------------------
-export([
    requesting/3
    ,mining/3
    ,targeting/3
    ,challenging/3
    ,receiving/3
    ,submiting/3
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).
-define(CHALLENGE_TIMEOUT, 3).

-record(data, {
    last_submit = 0 :: non_neg_integer()
    ,address :: libp2p_crypto:address()
    ,challengees :: [libp2p_crypto:address()]
    ,challenge_timeout = ?CHALLENGE_TIMEOUT :: non_neg_integer()
    ,receipts = [] :: [binary()]
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

receipt(Data) ->
    gen_statem:cast(?SERVER, {receipt, Data}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    ok = blockchain_event:add_handler(self()),
    ok = miner_poc:add_stream_handler(blockchain_swarm:swarm()),
    ok = miner_onion:add_stream_handler(blockchain_swarm:swarm()),
    Address = blockchain_swarm:address(),
    {ok, requesting, #data{address=Address}}.

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
requesting(info, {blockchain_event, {add_block, _Hash}}, #data{last_submit=LastSubmit
                                                               ,address=Address}=Data) ->
    CurrHeight = blockchain_worker:height(),
    case (CurrHeight - LastSubmit) > 30 of
        false ->
            {keep_state, Data};
        true ->
            Tx = blockchain_txn_poc_request:new(Address),
            {ok, _, SigFun} = blockchain_swarm:keys(),
            SignedTx = blockchain_txn_poc_request:sign(Tx, SigFun),
            ok = blockchain_worker:submit_txn(blockchain_txn_poc_request, SignedTx),
            {next_state, mining, Data}
    end;
requesting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
mining(info, {blockchain_event, {add_block, Hash}}, #data{address=Address}=Data) ->
    case blockchain_worker:get_block(Hash) of
        {ok, Block} ->
            Txns = blockchain_block:poc_request_transactions(Block),
            Filter = fun(Txn) -> Address =:= blockchain_txn_poc_request:gateway_address(Txn) end,
            case lists:filter(Filter, Txns) of
                [_POCReq] ->
                    CurrHeight = blockchain_worker:height(),
                    self() ! {target, Hash, Block},
                    {next_state, targeting, Data#data{last_submit=CurrHeight}};
                _ ->
                    % TODO: maybe we should restart
                    {keep_state, Data}
            end;
        {error, _Reason} ->
            % TODO: maybe we should restart
            lager:error("failed to get block ~p : ~p", [Hash, _Reason]),
            {keep_state, Data}
    end;
mining(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
targeting(info, {target, Hash, Block}, Data) ->
    {Target, Gateways} = target(Hash, Block),
    self() ! {challenge, Target, Gateways},
    {next_state, challenging, Data#data{challengees=[]}};
targeting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
challenging(info, {challenge, Target, Gateways}, #data{address=Address}=Data) ->
    Path = miner_poc_path:build(Target, Gateways),
    % TODO: Maybe make this smaller?
    Payload = erlang:term_to_binary(#{
        challenger => Address
    }),
    OnionList = [{Payload, libp2p_crypto:address_to_pubkey(A)} || A <- Path],
    Onion = miner_onion_server:construct_onion(OnionList),
    [Start|_] = Path,
    P2P = libp2p_crypto:address_to_p2p(Start),
    {ok, Stream} = miner_onion:dial_framed_stream(blockchain_swarm:swarm(), P2P, []),
    _ = miner_onion_handler:send(Stream, Onion),
    {next_state, receiving, Data#data{challengees=Path}};
challenging(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
receiving(info, {blockchain_event, {add_block, _Hash}}, #data{challenge_timeout=0}=Data) ->
    self() ! submit,
    {next_state, submiting, Data#data{challenge_timeout= ?CHALLENGE_TIMEOUT}};
receiving(info, {blockchain_event, {add_block, _Hash}}, #data{challenge_timeout=T}=Data) ->
    {keep_state, Data#data{challenge_timeout=T-1}};
receiving(cast, {receipt, Receipt}, #data{receipts=Receipts0
                                          ,challengees=Challengees}=Data) ->
    Address = blockchain_poc_receipt:address(Receipt),
    % TODO: Also check onion IV
    case blockchain_poc_receipt:is_valid(Receipt)
         andalso lists:member(Address, Challengees)
    of
        false ->
            lager:warning("ignoring receipt ~p", [Receipt]),
            {keep_state, Data};
        true ->
            Receipts1 = [Receipt|Receipts0],
            case erlang:length(Receipts1) =:= erlang:length(Challengees) of
                false ->
                    {keep_state, Data#data{receipts=Receipts1}};
                true ->
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
submiting(info, submit, #data{address=Address, receipts=Receipts}=Data) ->
    Txn0 = blockchain_txn_poc_receipts:new(Receipts, Address),
    {ok, _, SigFun} = blockchain_swarm:keys(),
    Txn1 = blockchain_poc_receipt:sign(Txn0, SigFun),
    ok = blockchain_worker:submit_txn(blockchain_poc_receipt, Txn1),
    {keep_state, requesting, Data};
submiting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec target(binary(), blockchain_block:block()) -> {libp2p_crypto:address(), map()}.
target(Hash, _Block) ->
    ActiveGateways = active_gateways(),
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
    lager:debug("ignoring event [~p] ~p", [_EventType, _EventContent]),
    {keep_state, Data}.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec create_probs(map()) -> [float()].
create_probs(Gateways) ->
    GwScores = [blockchain_ledger_gateway:score(G) || G <- maps:values(Gateways)],
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
-spec active_gateways() -> map().
active_gateways() ->
    ActiveGateways = blockchain_ledger:active_gateways(blockchain_worker:ledger()),
    maps:filter(
        fun(Address, Gateway) ->
            % TODO: Maybe do some find of score check here
            Address =/= blockchain_swarm:address()
            andalso blockchain_ledger_gateway:location(Gateway) =/= undefined
        end
        ,ActiveGateways
    ).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

target_test() ->
    meck:new(blockchain_ledger, [passthrough]),
    meck:new(blockchain_worker, [passthrough]),
    meck:new(blockchain_swarm, [passthrough]),
    
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
            G0 = blockchain_ledger_gateway:new(Owner, Index),
            G1 = blockchain_ledger_gateway:score(Score, G0),
            maps:put(Address, G1, Acc)

        end,
        maps:new(),
        LatLongs
    ),

    meck:expect(blockchain_ledger, active_gateways, fun(_) -> ActiveGateways end),
    meck:expect(blockchain_worker, ledger, fun() -> ok end),
    meck:expect(blockchain_swarm, address, fun() -> <<"unknown">> end),

    Block = blockchain_block:new(<<>>, 2, [], <<>>, #{}),
    Hash = blockchain_block:hash_block(Block),
    {Target, Gateways} = target(Hash, undefined),

    [{LL, S}|_] = LatLongs,
    ?assertEqual(crypto:hash(sha256, erlang:term_to_binary(LL)), Target),
    ?assertEqual(ActiveGateways, Gateways),

    ?assert(meck:validate(blockchain_ledger)),
    ?assert(meck:validate(blockchain_worker)),
    ?assert(meck:validate(blockchain_swarm)),
    meck:unload(blockchain_ledger),
    meck:unload(blockchain_worker),
    meck:unload(blockchain_swarm).

-endif.