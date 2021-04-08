-module(miner_discovery_handler).

-behavior(libp2p_framed_stream).

-include_lib("helium_proto/include/discovery_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
    server/4,
    client/2,
    add_stream_handler/1
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3,
    handle_data/3,
    handle_info/3
]).

-define(VERSION, "discovery/1.0.0").

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

-spec add_stream_handler(pid() | ets:tab()) -> ok.
add_stream_handler(SwarmTID) ->
    libp2p_swarm:add_stream_handler(
        SwarmTID,
        ?VERSION,
        {libp2p_framed_stream, server, [miner_poc_handler, self(), SwarmTID]}
    ).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------

init(client, _Conn, _Args) ->
    lager:info("client started with ~p", [_Args]),
    {ok, #state{}};
init(server, _Conn, _Args) ->
    lager:info("server started with ~p", [_Args]),
    {ok, #state{}}.

handle_data(server, Data, State) ->
    #discovery_start_pb{
        hotspot = PubKeyBin,
        transaction_id = TxnID,
        signature = Sig
    } =  discovery_pb:decode_msg(Data, discovery_start_pb),
    Hostpost = erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
    case
        libp2p_crypto:verify(
            <<Hostpost/binary, ",", TxnID/binary>>,
            base64:decode(Sig),
            libp2p_crypto:bin_to_pubkey(PubKeyBin)
        )
    of
        false ->
            lager:info("failed to verify signature for ~p (txn_id=~p sig=~p)", [
                blockchain_utils:addr2name(PubKeyBin),
                TxnID,
                Sig
            ]);
        true ->
            %% TODO
            ok
    end,
    {noreply, State};
handle_data(_Type, _Data, State) ->
    lager:warning("~p got data ~p", [_Type, _Data]),
    {noreply, State}.

handle_info(client, {send, Data}, State) ->
    {noreply, State, Data};
handle_info(_Type, _Msg, State) ->
    lager:warning("test ~p got info ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
