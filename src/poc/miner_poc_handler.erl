%%%-------------------------------------------------------------------
%% @doc
%% == Miner POC Stream Handler ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_poc_handler).

-behavior(libp2p_framed_stream).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
    server/4,
    client/2
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3,
    handle_data/3,
    handle_info/3,
    send/2
]).

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

send(Pid, Data) ->
    Pid ! {send, Data}.

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------
init(client, _Conn, _Args) ->
    erlang:process_flag(trap_exit, true),
    lager:info("started ~p client", [?MODULE]),
    {ok, #state{}};
init(server, _Conn, _Args) ->
    erlang:process_flag(trap_exit, true),
    lager:info("started ~p server", [?MODULE]),
    {ok, #state{}}.

handle_data(client, Data, State) ->
    lager:info("client got data: ~p", [Data]),
    %% client should not receive data
    {stop, normal, State};
handle_data(server, Data, State) ->
    try blockchain_poc_response_v1:decode(Data) of
        {witness, Witness} ->
            ok = miner_poc_statem:witness(Witness);
        {receipt, Receipt} ->
            ok = miner_poc_statem:receipt(Receipt)
    catch _:_ ->
        lager:error("got unknown data ~p", [Data])
    end,
    %% we only expect one receipt/witness from the peer at a time
    {stop, normal, State}.

handle_info(client, {send, Data}, State) ->
    lager:info("client sending data: ~p", [Data]),
    %% send one and done
    {stop, normal, State, Data};
handle_info(_Type, _Msg, State) ->
    lager:info("rcvd unknown type: ~p unknown msg: ~p", [_Type, _Msg]),
    %% unexpected input, just close
    {stop, normal, State}.
