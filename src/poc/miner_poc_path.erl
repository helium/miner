%%%-------------------------------------------------------------------
%% @doc
%% == Miner PoC Path ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_poc_path).

-export([
    build/2,
    shortest/3,
    length/3,
    build_graph/2
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(RESOLUTION, 9).
-define(RING_SIZE, 2).
% KRing of 1
%     Scale 3.57
%     Max distance 1.028 miles @ resolution 8
%     Max distance 0.38 miles @ resolution 9

% KRing of 2
%     Scale 5.42
%     Max distance 1.564 miles @ resolution 8
%     Max distance 0.59 miles @ resolution 9  <----

-type graph() :: #{any() => [{number(), any()}]}.

-export_type([graph/0]).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec build(binary(), map()) -> {ok, list()} | {error, any()}.
build(Target, Gateways) ->
    Graph = ?MODULE:build_graph(Target, Gateways),
    GraphList = maps:fold(
        fun(Addr, _, Acc) ->
            G = maps:get(Addr, Gateways),
            Score = blockchain_ledger_gateway_v1:score(G),
            [{Score, Addr}|Acc]
        end,
        [],
        Graph
    ),
    case erlang:length(GraphList) > 2 of
        false ->
            {error, not_enough_gateways};
        true ->
            [{_, Start}, {_, End}|_] = lists:sort(fun({ScoreA, AddrA}, {ScoreB, AddrB}) ->
                                                          ScoreA * ?MODULE:length(Graph, Target, AddrA) >
                                                          ScoreB * ?MODULE:length(Graph, Target, AddrB)
                                                  end, GraphList),
            {_, Path1} = ?MODULE:shortest(Graph, Start, Target),
            {_, [Target|Path2]} = ?MODULE:shortest(Graph, Target, End),
            %% NOTE: It is possible the path contains dupes, these are also considered valid
            {ok, Path1 ++ Path2}
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec shortest(graph(), any(), any()) -> {number(), list()}.
shortest(Graph, Start, End) ->
    path(Graph, [{0, [Start]}], End, #{}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec length(graph(), any(), any()) -> integer().
length(Graph, Start, End) ->
    {_Cost, Path} = shortest(Graph, Start, End),
    erlang:length(Path).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec build_graph(binary(), map()) -> graph().
build_graph(Address, Gateways) ->
    build_graph([Address], Gateways, maps:new()).

-spec build_graph([binary()], map(), graph()) -> graph().
build_graph([], _Gateways, Graph) ->
    Graph;
build_graph([Address0|Addresses], Gateways, Graph0) ->
    Neighbors0 = neighbors(Address0, Gateways),
    Graph1 = lists:foldl(
        fun({_W, Address1}, Acc) ->
            case maps:is_key(Address1, Acc) of
                true -> Acc;
                false ->
                    Neighbors1 = neighbors(Address1, Gateways),
                    Graph1 = maps:put(Address1, Neighbors1, Acc),
                    build_graph([A || {_, A} <- Neighbors1], Gateways, Graph1)
            end
        end,
        maps:put(Address0, Neighbors0, Graph0),
        Neighbors0
    ),
    case maps:size(Graph1) > 100 of
        false ->
            build_graph(Addresses, Gateways, Graph1);
        true ->
            Graph1
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec path(graph(), list(), any(), map()) -> {number(), list()}.
path(_Graph, [], _End, _Seen) ->
    % nowhere to go
    {0, []};
path(_Graph, [{Cost, [End | _] = Path} | _], End, _Seen) ->
    % base case
    {Cost, lists:reverse(Path)};
path(Graph, [{Cost, [Node | _] = Path} | Routes], End, Seen) ->
    NewRoutes = [{Cost + NewCost, [NewNode | Path]} || {NewCost, NewNode} <- maps:get(Node, Graph, [{0, []}]), not maps:get(NewNode, Seen, false)],
    path(Graph, lists:sort(NewRoutes ++ Routes), End, Seen#{Node => true}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
neighbors(Address, Gateways) ->
    TargetGw = maps:get(Address, Gateways),
    Index = blockchain_ledger_gateway_v1:location(TargetGw),
    KRing = case h3:get_resolution(Index) of
        Res when Res < ?RESOLUTION ->
            [];
        ?RESOLUTION ->
            h3:k_ring(Index, ?RING_SIZE);
        Res when Res > ?RESOLUTION ->
            Parent = h3:parent(Index, ?RESOLUTION),
            h3:k_ring(Parent, ?RING_SIZE)
    end,
    GwInRing = maps:to_list(maps:filter(
        fun(A, G) ->
            I = blockchain_ledger_gateway_v1:location(G),
            I1 = case h3:get_resolution(I) of
                R when R =< ?RESOLUTION -> I;
                R when R > ?RESOLUTION -> h3:parent(I, ?RESOLUTION)
            end,
            lists:member(I1, KRing)
                andalso Address =/= A
        end,
        Gateways
    )),
    [{edge_weight(TargetGw, G), A} || {A, G} <- GwInRing].

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
edge_weight(Gw1, Gw2) ->
    1 - abs(blockchain_ledger_gateway_v1:score(Gw1) -  blockchain_ledger_gateway_v1:score(Gw2)).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

neighbors_test() ->
    LatLongs = [
        {{37.782061, -122.446167}, 0.1}, % This should be excluded cause target
        {{37.782604, -122.447857}, 0.99},
        {{37.782074, -122.448528}, 0.99},
        {{37.782002, -122.44826}, 0.99},
        {{37.78207, -122.44613}, 0.99},
        {{37.781909, -122.445411}, 0.99},
        {{37.783371, -122.447879}, 0.99},
        {{37.780827, -122.44716}, 0.99},
        {{38.897675, -77.036530}, 0.12} % This should be excluded cause too far
    ],
    {Target, Gateways} = build_gateways(LatLongs),
    Neighbors = neighbors(Target, Gateways),

    ?assertEqual(erlang:length(maps:keys(Gateways)) - 2, erlang:length(Neighbors)),
    {LL1, _} =  lists:last(LatLongs),
    TooFar = crypto:hash(sha256, erlang:term_to_binary(LL1)),
    lists:foreach(
        fun({_, Address}) ->
            ?assert(Address =/= Target),
            ?assert(Address =/= TooFar)
        end,
        Neighbors
    ),
    ok.

build_graph_test() ->
    LatLongs = [
        {{37.782061, -122.446167}, 0.1},
        {{37.782604, -122.447857}, 0.99},
        {{37.782074, -122.448528}, 0.99},
        {{37.782002, -122.44826}, 0.99},
        {{37.78207, -122.44613}, 0.99},
        {{37.781909, -122.445411}, 0.99},
        {{37.783371, -122.447879}, 0.99},
        {{37.780827, -122.44716}, 0.99},
        {{38.897675, -77.036530}, 0.12} % This should be excluded cause too far
    ],
    {Target, Gateways} = build_gateways(LatLongs),

    Graph = build_graph(Target, Gateways),
    ?assertEqual(8, maps:size(Graph)),

    {LL1, _} = lists:last(LatLongs),
    TooFar = crypto:hash(sha256, erlang:term_to_binary(LL1)),
    ?assertNot(lists:member(TooFar, maps:keys(Graph))),
    ok.


build_graph_in_line_test() ->
    % All these point are in a line one after the other (except last)
    LatLongs = [
        {{37.780586, -122.469471}, 0.1},
        {{37.780959, -122.467496}, 0.99},
        {{37.78101, -122.465372}, 0.98},
        {{37.781179, -122.463226}, 0.97},
        {{37.781281, -122.461038}, 0.96},
        {{37.781349, -122.458892}, 0.95},
        {{37.781468, -122.456617}, 0.94},
        {{37.781637, -122.4543}, 0.93},
        {{38.897675, -77.036530}, 0.12} % This should be excluded cause too far
    ],
    {Target, Gateways} = build_gateways(LatLongs),

    Graph = build_graph(Target, Gateways),
    ?assertEqual(8, maps:size(Graph)),

    {LL1, _} = lists:last(LatLongs),
    TooFar = crypto:hash(sha256, erlang:term_to_binary(LL1)),
    ?assertNot(lists:member(TooFar, maps:keys(Graph))),

    Addresses = lists:droplast([crypto:hash(sha256, erlang:term_to_binary(X)) || {X, _} <- LatLongs]),
    Size = erlang:length(Addresses),

    lists:foldl(
        fun(Address, Acc) when Acc =:= 1 ->
            Next = lists:nth(Acc + 1, Addresses),
            GraphPart = maps:get(Address, Graph, []),
            ?assert(lists:member(Next, [A || {_, A} <- GraphPart])),
            Acc + 1;
        (Address, Acc) when Size =:= Acc ->
            Prev = lists:nth(Acc - 1, Addresses),
            GraphPart = maps:get(Address, Graph, []),
            ?assert(lists:member(Prev, [A || {_, A} <- GraphPart])),
            0;
        (Address, Acc) ->
            % Each hotspot should at least see the next / prev one
            Next = lists:nth(Acc + 1, Addresses),
            Prev = lists:nth(Acc - 1, Addresses),
            GraphPart = maps:get(Address, Graph, []),
            ?assert(lists:member(Next, [A || {_, A} <- GraphPart])),
            ?assert(lists:member(Prev, [A || {_, A} <- GraphPart])),
            Acc + 1
        end,
        1,
        Addresses
    ),
    ok.

build_test() ->
    % All these point are in a line one after the other (except last)
    LatLongs = [
        {{37.780959, -122.467496}, 0.65},
        {{37.78101, -122.465372}, 0.75},
        {{37.780586, -122.469471}, 0.99},
        {{37.781179, -122.463226}, 0.75},
        {{37.781281, -122.461038}, 0.1},
        {{37.781349, -122.458892}, 0.75},
        {{37.781468, -122.456617}, 0.75},
        {{37.781637, -122.4543}, 0.95},
        {{38.897675, -77.036530}, 0.12} % This should be excluded cause too far
    ],
    {Target, Gateways} = build_gateways(LatLongs),

    {ok, Path} = build(Target, Gateways),

    ?assertNotEqual(Target, hd(Path)),
    ?assert(lists:member(Target, Path)),
    ?assertNotEqual(Target, lists:last(Path)),
    ok.

build_with_zero_score_test() ->
    % All these point are in a line one after the other (except last)
    LatLongs = [
        {{37.780586, -122.469471}, 0.0},
        {{37.780959, -122.467496}, 0.0},
        {{37.78101, -122.465372}, 0.0},
        {{37.781179, -122.463226}, 0.0},
        {{37.781281, -122.461038}, 0.0},
        {{37.781349, -122.458892}, 0.0},
        {{37.781468, -122.456617}, 0.0},
        {{37.781637, -122.4543}, 0.0},
        {{38.897675, -77.036530}, 0.0} % This should be excluded cause too far
    ],
    {Target, Gateways} = build_gateways(LatLongs),
    {ok, Path} = build(Target, Gateways),
    ?assert(lists:member(Target, Path)),
    ok.

build_gateways(LatLongs) ->
    Gateways = lists:foldl(
        fun({LatLong, Score}, Acc) ->
            Owner = <<"test">>,
            Address = crypto:hash(sha256, erlang:term_to_binary(LatLong)),
            Res = rand:uniform(7) + 8,
            Index = h3:from_geo(LatLong, Res),
            G0 = blockchain_ledger_gateway_v1:new(Owner, Index),
            G1 = blockchain_ledger_gateway_v1:score(Score, G0),
            maps:put(Address, G1, Acc)

        end,
        maps:new(),
        LatLongs
    ),
    [{LL, _}|_] = LatLongs,
    Target = crypto:hash(sha256, erlang:term_to_binary(LL)),
    {Target, Gateways}.

-endif.
