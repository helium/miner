%%%-------------------------------------------------------------------
%% @doc
%% == Router Handler ==
%% @end
%%%-------------------------------------------------------------------
-module(router_handler).

-behavior(libp2p_framed_stream).

-include_lib("helium_proto/src/pb/blockchain_state_channel_v1_pb.hrl").

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

-record(state, {}).

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
init(server, _Conn, _Args) ->
    lager:info("init server with ~p", [_Args]),
    {ok, #state{}};
init(client, _Conn, _Args) ->
    lager:info("init client with ~p", [_Args]),
    {ok, #state{}}.

handle_data(_Type, Bin, State) ->
    case decode(Bin) of
        {ok, #blockchain_state_channel_response_v1_pb{accepted=false}} ->
            ok;
        {ok, #blockchain_state_channel_response_v1_pb{accepted=true, downlink=Downlink}} ->
            case Downlink of
                undefined ->
                    ok;
                #helium_packet_pb{}=Packet ->
                    %% ok, try to send this out
                    spawn(fun() -> miner_lora:send(Packet) end),
                    ok
            end;
        {error, _Reason} ->
            lager:warning("got error decoding blockchain_state_channel_message ~p", [_Reason])
    end,
    {noreply, State}.

handle_info(_Type, {send, Data}, State) ->
    lager:debug("~p sending data ~p", [_Type, Data]),
    {noreply, State, Data};
handle_info(_Type, _Msg, State) ->
    lager:warning("~p got info ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec decode(binary()) -> {ok, #blockchain_state_channel_response_v1_pb{}} | {error, any()}.
decode(Bin) ->
    case blockchain_state_channel_v1_pb:decode_msg(Bin, blockchain_state_channel_message_v1_pb) of
        #blockchain_state_channel_message_v1_pb{msg={response, Resp}} ->
            {ok, Resp};
        {error, _Reason}=Error ->
            Error;
        Msg ->
            {error, {unknown_msg, Msg}}
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
