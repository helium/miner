-module(miner_discovery_worker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API exports
%% ------------------------------------------------------------------
-export([
    start/1
]).

%% ------------------------------------------------------------------
%% `gen_server' exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-record(state, {
    %% Raw binary packet.
    %%
    %% Although it is a LoRaWAN packet, we're operating at a low level
    %% so we just treat it like a binary blob.
    packet = <<>> :: binary(),
    %% Number of uplinks remaining until we're done with discovery
    %% mode.
    remaining_uplinks = 0 :: non_neg_integer(),
    tx_power = 0 :: number(),
    spreading = "" :: string(),
    region = undefined :: atom()
}).

-define(DEFAULT_TRANSMIT_DELAY_MS, 9000).
-define(DEFAULT_UPLINKS, 10).

%% ------------------------------------------------------------------
%% API implementation
%% ------------------------------------------------------------------
-spec start(binary()) -> {ok, pid()} | ignore | {error, any()}.
start(Packet) ->
    gen_server:start({local, ?MODULE}, ?MODULE, [Packet], []).

%% ------------------------------------------------------------------
%% `gen_server' implementation
%% ------------------------------------------------------------------
init([Packet]) ->
    {ok, Region} = miner_lora:region(),
    TxPower = tx_power(Region),
    Spreading = spreading(Region, byte_size(Packet)),
    timer:send_after(?DEFAULT_TRANSMIT_DELAY_MS, self(), tick),
    {ok, #state{
        region = Region,
        tx_power = TxPower,
        spreading = Spreading,
        packet = Packet,
        remaining_uplinks = ?DEFAULT_UPLINKS
    }}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, #state{remaining_uplinks = 0} = State) ->
    {stop, normal, State};
handle_info(
    tick,
    #state{
        remaining_uplinks = Rem,
        packet = Packet,
        spreading = Spreading,
        tx_power = TxPower
    } = State
) ->
    ChannelSelectorFun = fun (FreqList) ->
        lists:nth(rand:uniform(length(FreqList)), FreqList)
    end,
    ok = miner_lora:send_poc(
        Packet,
        immediate,
        ChannelSelectorFun,
        Spreading,
        TxPower
    ),

    timer:send_after(?DEFAULT_TRANSMIT_DELAY_MS, self(), tick),
    {noreply, State#state{remaining_uplinks = Rem - 1}};
handle_info(_Info, State) ->
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal
%% ------------------------------------------------------------------

%% TODO: taken from miner_onion_server, refactor to common module?
-spec tx_power(Region :: atom()) -> integer().
tx_power('EU868') ->
    14;
tx_power('US915') ->
    27;
tx_power(_) ->
    27.

%% TODO: taken from miner_onion_server, refactor to common module?
-spec spreading(Region :: atom(), Len :: pos_integer()) -> string().
spreading('EU868', L) when L < 65 ->
    "SF12BW125";
spreading('EU868', L) when L < 129 ->
    "SF9BW125";
spreading('EU868', L) when L < 238 ->
    "SF8BW125";
spreading(_, L) when L < 25 ->
    "SF10BW125";
spreading(_, L) when L < 67 ->
    "SF9BW125";
spreading(_, L) when L < 139 ->
    "SF8BW125";
spreading(_, _) ->
    "SF7BW125".
