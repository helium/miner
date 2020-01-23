%%%-------------------------------------------------------------------
%% @doc
%% == Simple Http Stream ==
%% This is only intended for Cargo use, more complicated packet exchange will be implemented later
%% @end
%%%-------------------------------------------------------------------
-module(simple_http_stream_test).

-behavior(libp2p_framed_stream).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
         server/4,
         client/2,
         version/0
        ]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
         init/3,
         handle_data/3,
         handle_info/3
        ]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(state, {
                endpoint :: pid() | undefined
               }).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

-spec version() -> string().
version() ->
    "simple_http/1.0.0".

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------

init(server, _Conn, [_, Endpoint]=_Args) ->
    lager:info("server started with ~p", [_Args]),
    {ok, #state{endpoint=Endpoint}};
init(client, _Conn, [Data]=_Args) ->
    lager:info("client started with ~p", [_Args]),
    {ok, #state{}, Data};
init(_Type, _Conn, _Args) ->
    lager:error("~p started with ~p", [_Type, _Args]),
    {ok, #state{}}.

handle_data(server, _Bin, #state{endpoint=undefined}=State) ->
    lager:warning("server ignoring data ~p (cause no endpoint)", [_Bin]),
    {noreply, State};
handle_data(server, Data, #state{endpoint=Endpoint}=State) ->
    lager:info("got data ~p", [Data]),
    Endpoint ! {simple_http_stream_test, Data},
    {noreply, State};
handle_data(_Type, _Bin, State) ->
    lager:warning("~p got data ~p", [_Type, _Bin]),
    {noreply, State}.

handle_info(_Type, _Msg, State) ->
    lager:warning("~p got info ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
