-module(miner_collect).

-behaviour(gen_server).

%% API
-export([
         start_link/0,
         stop/0
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("blockchain/include/blockchain_vars.hrl").

-define(SERVER, ?MODULE).

-record(state,
        {
         heights :: #{}
        }).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

stop() ->
    gen_server:call(?SERVER, stop).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    %% timeout for async startup
    {ok, Height} = blockchain:height(blockchain_worker:blockchain()),
    ok = blockchain_event:add_handler(self()),
    {ok, #state{heights = update_heights(#{}, Height)}}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

handle_info({blockchain_event, {add_block, _, _, Ledger}},
            #state{heights = Heights} = State) ->
    Curr = blockchain_ledger_v1:current_height(Ledger),
    {noreply, State#state{heights = update_heights(Heights, Curr)}};
handle_info(_Info, State) ->
    lager:warning("unexpected message ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

update_heights(Init, Curr) ->
    %% filter for active gateways, make sure that everything is just
    %% reporting once

    Book = libp2p_swarm:peerbook(blockchain_swarm:swarm()),
    Peers = [{Address, libp2p_peerbook:get(Book, Address)}
             || Address <- libp2p_peerbook:keys(Book)],
    Triples = [{Address,
                begin
                    Ht = libp2p_peer:signed_metadata_get(Peer, <<"height">>, 0),
                    Ht - (Ht rem 40)
                end,
                libp2p_peer:signed_metadata_get(Peer, <<"ledger_fingerprint">>, undefined)}
               || {Address, {ok, Peer}} <- Peers],
    Filtered =
        [{element(2, erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(X))), H, Y}
         || {X, H, Y} <- Triples, Y /= undefined],
    New =
        lists:foldl(
          fun({_Name, Height, _Fingerprint}, Acc) when Height < Curr - 200 ->
                  maps:remove(Height, Acc);
             ({Name, Height, Fingerprint}, Acc) ->
                  HeightMap = maps:get(Height, Acc, #{}),
                  FPs = maps:get(Fingerprint, HeightMap, []),
                  Acc#{Height => HeightMap#{Fingerprint => lists:usort([Name | FPs])}}
          end,
          Init,
          Filtered),
    %% summarize
    Summary =
        maps:fold(
          fun(Height, FPs, Acc) ->
                  L = maps:to_list(FPs),
                  L1 = [{FP, length(FPL)} || {FP, FPL} <- L],
                  [{Height, L1} | Acc]
          end,
          [],
          New),
    S = lists:sublist(lists:reverse(lists:sort(Summary)), 4),
    [begin
         Rep = lists:sum([R || {_, R} <- FPCounts]),
         FPCounts1 = [{FP, trunc((Ct/Rep) * 100), Ct}|| {FP, Ct} <- FPCounts],
         lager:info("height ~p reporting ~p fps ~p", [Ht, Rep, lists:keysort(3, FPCounts1)])
     end
     || {Ht, FPCounts} <- S],
    New.
