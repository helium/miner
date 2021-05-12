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
        {libp2p_framed_stream, server, [?MODULE, self(), SwarmTID]}
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
    lager:info("got ~p ~p", [Data, State]),
    #discovery_start_pb{
        hotspot = HotspotPubkeyBin,
        packets = Packets,
        signature = Sig
    } = discovery_pb:decode_msg(Data, discovery_start_pb),
    Hotspot = erlang:list_to_binary(libp2p_crypto:bin_to_b58(HotspotPubkeyBin)),
    case verify_signature(Hotspot, HotspotPubkeyBin, Sig) of
        false ->
            lager:info("failed to verify signature for ~p (sig=~p)", [
                blockchain_utils:addr2name(HotspotPubkeyBin),
                Sig
            ]);
        true ->
            case miner_lora:location_ok() of
                true ->
                    miner_discovery_worker:start(Packets);
                false ->
                    lager:warning("can not start discovery mode until location is ok"),
                    ok
            end,
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

-spec verify_signature(
    Hotspot :: binary(),
    HotspotPubkeyBin :: libp2p_crypto:pubkey_bin(),
    Sig :: binary()
) -> boolean().
verify_signature(Hotspot, HotspotPubkeyBin, Sig) ->
    case get_hotspot_owner(HotspotPubkeyBin) of
        {error, _Reason} ->
            lager:info("failed to find owner for hotspot ~p: ~p", [
                {Hotspot, HotspotPubkeyBin},
                _Reason
            ]),
            false;
        {ok, OwnerPubKeyBin} ->
            libp2p_crypto:verify(
                <<Hotspot/binary>>,
                base64:decode(Sig),
                libp2p_crypto:bin_to_pubkey(OwnerPubKeyBin)
            )
    end.

-spec get_hotspot_owner(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, libp2p_crypto:pubkey_bin()} | {error, any()}.
get_hotspot_owner(PubKeyBin) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    blockchain_ledger_v1:find_gateway_owner(PubKeyBin, Ledger).
