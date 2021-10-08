%%%-------------------------------------------------------------------
%% @doc
%% == Miner POC Stream Handler ==
%% used to relay a receipt or witness report received by a validator
%% onto the actual challenger
%% @end
%%%-------------------------------------------------------------------
-module(miner_poc_report_handler).

-behavior(libp2p_framed_stream).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
    server/4,
    client/2,
    decode/1
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

-record(state, {
    peer :: undefined | libp2p_crypto:pubkey_bin(),
    peer_addr :: undefined | string()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

send(Pid, Data) ->
    Pid ! {send, Data}.

decode(Data) ->
    try blockchain_poc_response_v1:decode(Data) of
        Res -> Res
    catch
        _:_ ->
            lager:error("got unknown data ~p", [Data]),
            {error, failed_to_decode_report}
    end.
%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------
init(client, _Conn, _Args) ->
    {ok, #state{}};
init(server, Conn, _Args) ->
    {_, PeerAddr} = libp2p_connection:addr_info(Conn),
    {ok, #state{peer = identify(Conn), peer_addr = PeerAddr}}.

handle_data(client, Data, State) ->
    lager:info("client got data: ~p", [Data]),
    %% client should not receive data
    {stop, normal, State};
handle_data(server, Payload, #state{peer = SelfPeer} = State) ->
    {OnionKeyHash, Data} = binary_to_term(Payload),
    lager:info("server got data, OnionKeyHash: ~p, Report: ~p", [OnionKeyHash, Data]),
    P2PAddr = libp2p_crypto:pubkey_bin_to_p2p(SelfPeer),
    try ?MODULE:decode(Data) of
        {witness, _} = Report ->
            ok = miner_poc_mgr:report(Report, OnionKeyHash, SelfPeer, P2PAddr);
        {receipt, _} = Report ->
            ok = miner_poc_mgr:report(Report, OnionKeyHash, SelfPeer, P2PAddr)
    catch
        _:_ ->
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

identify(Conn) ->
    case libp2p_connection:session(Conn) of
        {ok, Session} ->
            libp2p_session:identify(Session, self(), ?MODULE),
            receive
                {handle_identify, ?MODULE, {ok, Identify}} ->
                    libp2p_identify:pubkey_bin(Identify)
            after 10000 -> erlang:error(failed_identify_timeout)
            end;
        {error, closed} ->
            erlang:error(dead_session)
    end.
