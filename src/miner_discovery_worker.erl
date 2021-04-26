-module(miner_discovery_worker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API exports
%% ------------------------------------------------------------------
-export([
    begin_discovery_mode/1
]).

%% ------------------------------------------------------------------
%% `gen_server' exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

%% ------------------------------------------------------------------
%% API implementation
%% ------------------------------------------------------------------
-spec begin_discovery_mode(Packet :: binary()) -> ok.
begin_discovery_mode(Packet) ->
    gen_server:call(?MODULE, {begin_discovery_mode, Packet}).

%% ------------------------------------------------------------------
%% Internal
%% ------------------------------------------------------------------
-record(state, {
    %% Raw binary packet.
    %%
    %% Although it is a LoRaWAN packet, we're operating at a low level
    %% so we just treat it like a binary blob.
    packet = <<>> :: binary(),
    %% Delay between each uplink.
    tansmit_period = 9999 :: pos_integer(),
    %% Number of uplinks remaining until we're done with discovery
    %% mode.
    remaining_uplinks = 0 :: pos_integer()
}).

-spec send_discovery_uplink(State :: #state{}) -> #state{}.
send_discovery_uplink(State0) when State0#state.remaining_uplinks > 0 ->
    %% Reviewer: I cargo-culted this from other parts of this code
    %%           base. I don't know if it's needed or if the call to
    %%           `miner_lora:region/0' below is enough.
    case miner_lora:location_ok() of
        false ->
            #state{};
        true ->
            ChannelSelectorFun = fun (FreqList) ->
                lists:nth(rand:uniform(length(FreqList)), FreqList)
            end,
            %% Reviewer: is this ok? Will this crash be handled?
            {ok, Region} = miner_lora:region(),
            TxPower = tx_power(Region),
            Spreading = spreading(Region, byte_size(State0#state.packet)),
            ok = miner_lora:send_poc(
                State0#state.packet,
                immediate,
                ChannelSelectorFun,
                Spreading,
                TxPower
            ),
            State0#state{remaining_uplinks = State0#state.remaining_uplinks - 1}
    end;
send_discovery_uplink(State0) ->
    State0.

%% TODO: taken from miner_onion_server, refactor to common module
-spec tx_power(Region :: atom()) -> integer().
tx_power('EU868') ->
    14;
tx_power('US915') ->
    27;
tx_power(_) ->
    27.

%% TODO: taken from miner_onion_server, refactor to common module
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

%% ------------------------------------------------------------------
%% `gen_server' implementation
%% ------------------------------------------------------------------
init({}) ->
    {ok, #state{}}.

handle_call({begin_discovery_mode, Packet}, _From, State) ->
    %% Reviewer: should this be handle_cast instead?
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.
