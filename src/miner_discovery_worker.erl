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
    %% Raw binary packets.
    %%
    %% Although these are LoRaWAN packet, we're operating at a low
    %% level so we just treat them like a binary blobs.
    packets = [] :: [binary()],
    tx_power = 0 :: number(),
    region = undefined :: atom()
}).

-define(DEFAULT_TRANSMIT_DELAY_MS, 5000).

%% ------------------------------------------------------------------
%% API implementation
%% ------------------------------------------------------------------
-spec start([binary()]) -> {ok, pid()} | ignore | {error, any()}.
start(Packets) ->
    gen_server:start({local, ?MODULE}, ?MODULE, [Packets], []).

%% ------------------------------------------------------------------
%% `gen_server' implementation
%% ------------------------------------------------------------------
init([Packets]) ->
    lager:info("starting discovery mode with ~p packets every ~p ms", [
        length(Packets),
        ?DEFAULT_TRANSMIT_DELAY_MS
    ]),
    {ok, Region} = miner_lora:region(),
    TxPower = tx_power(Region),
    timer:send_after(?DEFAULT_TRANSMIT_DELAY_MS, self(), tick),
    {ok, #state{
        packets = Packets,
        tx_power = TxPower,
        region = Region
    }}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, #state{packets = []} = State) ->
    {stop, normal, State};
handle_info(
    tick,
    #state{
        packets = [Packet | Packets],
        tx_power = TxPower,
        region = Region
    } = State
) ->
    ChannelSelectorFun = fun (FreqList) ->
        lists:nth(rand:uniform(length(FreqList)), FreqList)
    end,
    Spreading = spreading(Region, byte_size(Packet)),
    case miner_lora:send_poc(
        Packet,
        immediate,
        ChannelSelectorFun,
        Spreading,
        TxPower
    ) of
        ok ->
            ok;
        {warning, _} ->
            %% Most warnings should be ok.
            ok;
        {error, timeout} ->
            %% This transmission timed out, but others may work. Keep going.
            lager:warning("transmission timed out.")
    end,
    timer:send_after(?DEFAULT_TRANSMIT_DELAY_MS, self(), tick),
    {noreply, State#state{packets = Packets}};
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
