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

-define(SERVER, ?MODULE).
-define(POC_PROTOCOL, "miner_poc/1.0.0").
-define(CHALLENGE_TIMEOUT, 3).

-record(data, {
    last_submit = 0 :: non_neg_integer()
    ,address :: libp2p_crypto:address()
    ,challengees :: [libp2p_crypto:address()]
    ,challenge_timeout = ?CHALLENGE_TIMEOUT :: non_neg_integer()
    ,receipts = [] :: [binary()]
}).

-record(path, {
    target
    ,target_address
    ,path
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
    ok = libp2p_swarm:add_stream_handler(
        blockchain_swarm:swarm()
        ,?POC_PROTOCOL
        ,{libp2p_framed_stream, server, [miner_poc_handler, ?SERVER]}
    ),
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


challenging(info, {challenge, Target, Gateways}, Data) ->
    TargetGw = maps:get(Target, Gateways),
    Path0 = #path{target=TargetGw, target_address=Target, path=[]},
    _Path1 = path_selection(TargetGw, Gateways, [], 0, Path0),

    Challengees = [Target],
    {next_state, receiving, Data#data{challengees=Challengees}};
challenging(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

path_selection(TargetGw, Gateways, Path, 3, #path{path=[]}=P) ->
    path_selection(TargetGw, Gateways, [], 0, P#path{path=Path});
path_selection(_TargetGw, _Gateways, _Path, 3, #path{target_address=Target, path=FullPath}) ->
    {A, B} = lists:split(3, FullPath),
    A ++ [Target] ++ B;
path_selection(TargetGw, Gateways, Path, Size, #path{path=FullPath}=P) ->
    S = case Size rem 2 of 0 -> high; _ -> low end,
    TargetIndex = blockchain_ledger:gateway_location(TargetGw),
    KRing = h3:k_ring(TargetIndex, 1),
    % TODO: do something if not enough gateways
    GwInRing = maps:filter(
        fun(Address, Gateway) ->
            Index = blockchain_ledger:gateway_location(Gateway),
            Score = blockchain_ledger:gateway_score(Gateway),
            lists:member(Index, KRing)
                andalso not lists:member(Address, Path)
                andalso not lists:member(Address, FullPath)
                andalso case S of high -> Score >= 1.0; low -> Score =< 1.0 end
        end
        ,Gateways
    ),
    SelectedAddress = lists:first(maps:keys(GwInRing)),
    SelectedGw = maps:get(SelectedAddress, GwInRing),
    path_selection(SelectedGw, Gateways, [SelectedAddress|Path], Size+1, P).



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
submiting(info, submit, Data) ->
    {keep_state, requesting, Data};
submiting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

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
-spec target(binary(), blockchain_block:block()) -> {libp2p_crypto:address(), map()}.
target(Hash, _Block) ->
    ActiveGateways = active_gateways(),
    Probs = create_probs(ActiveGateways),
    Entropy = entropy(Hash, Probs),
    Target = select_target(Probs, maps:keys(ActiveGateways), Entropy, 1),
    {Target, ActiveGateways}.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec create_probs(map()) -> [float()].
create_probs(Gateways) ->
    GwScores = [blockchain_ledger:gateway_score(G) || G <- maps:values(Gateways)],
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
    <<A:85/integer-unsigned-little, B:85/integer-unsigned-little
      ,C:86/integer-unsigned-little, _>> = crypto:hash(sha256, Entropy),
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
            andalso blockchain_ledger:gateway_location(Gateway) =/= undefined
        end
        ,ActiveGateways
    ).
