%%%-------------------------------------------------------------------
%% @doc
%% == Miner PoC Path ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_poc_path).

-export([
    build/2
    ,shortest/3
    ,length/3
    ,build_graph/2
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type graph() :: #{any() => [{number(), any()}]}.

-export_type([graph/0]).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec build(binary(), map()) -> list().
build(Target, Gateways) ->
    Graph = ?MODULE:build_graph(Target, Gateways),
    GraphList = maps:fold(
        fun(Addr, _, Acc) ->
            G = maps:get(Addr, Gateways),
            Score = blockchain_ledger_gateway:score(G),
            [{Score, G}|Acc]
        end
        ,Graph
    ),
    [Start, End|_] = lists:sort(fun({A, _}, {B, _}) -> A >= B end, GraphList),
    {_, Path} = ?MODULE:shortest(Graph, Start, End),
    Path.

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

-spec build_graph(binary(), map(), graph()) -> graph().
build_graph([], _Gateways, Graph) ->
    Graph;
build_graph([Address|Addresses], Gateways, Graph) ->
    Neighbors = neighbors(Address, Gateways),
    Graph1 = lists:foldl(
        fun({_W, A}, Map) ->
            case maps:is_key(A, Map) of
                true -> Map;
                false ->
                    Neighbors = neighbors(Address, Gateways),
                    maps:put(A, Neighbors, Map)
            end
        end
        ,Graph
        ,Neighbors
    ),
    case maps:size(Graph1) > 100 of
        false ->
            Graph2 = build_graph(Addresses, Gateways, Graph1),
            build_graph(Neighbors, Gateways, Graph2);
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
    NewRoutes = [{Cost + NewCost, [NewNode | Path]} || {NewCost, NewNode} <- maps:get(Node, Graph), not maps:get(NewNode, Seen, false)],
    path(Graph, lists:sort(NewRoutes ++ Routes), End, Seen#{Node => true}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
neighbors(Address, Gateways) ->
    % TODO: It should format with appropriate resolution
    TargetGw = maps:get(Address, Gateways),
    Index = blockchain_ledger_gateway:location(TargetGw),
    KRing = h3:k_ring(Index, 1),
    GwInRing = maps:to_list(maps:filter(
        fun(A, G) ->
            I = blockchain_ledger_gateway:location(G),
            lists:member(I, KRing)
                andalso Address =/= A
        end
        ,Gateways
    )),
    [{edge_weight(TargetGw, G), A} || {A, G} <- GwInRing].

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
edge_weight(Gw1, Gw2) ->
    1 - abs(blockchain_ledger_gateway:score(Gw1) -  blockchain_ledger_gateway:score(Gw2)).

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
        {{37.832976, -122.12726}, 0.12} % This should be excluded cause too far
    ],
    Gateways = lists:foldl(
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
    [{LL, _}|_] = LatLongs,
    Target = crypto:hash(sha256, erlang:term_to_binary(LL)),
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


-endif.