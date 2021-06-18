%% @doc This module provides time-on-air regulatory compliance for the
%% EU868 and US915 ISM bands.
%%
%% This module does not interface with hardware or provide any
%% transmission capabilities itself. Instead, the API provides its
%% core functionality through `track_sent/4', `can_send/4', and
%% `time_on_air/6'.
-module(miner_lora_throttle).
-include_lib("blockchain/include/blockchain_vars.hrl").

-export([
    can_send/4,
    dwell_time/3,
    new/2,
    time_on_air/6,
    track_sent/4,
    track_sent/9
]).

-export_type([
    region/0,
    handle/0
]).

-record(sent_packet, {
    sent_at :: number(),
    time_on_air :: number(),
    frequency :: number()
}).

-type region() :: 'AS923' | 'AU915' | 'CN470' | 'CN779' | 'EU433' | 'EU868' | 'IN865' | 'KR920' | 'US915'.
-type region_v2() :: 'as923_1' | 'as923_2' | 'as923_3' | 'au915' | 'cn470' | 'eu433' | 'eu868' | 'in865' | 'kr920' | 'ru864' | 'us915'.

-type regulatory_model() :: {dwell | duty, Limit :: number(), Period :: number()}.

-opaque handle() :: unsupported | {regulatory_model(), list(#sent_packet{})}.

%% Maximum time allowable time on air.
-define(MAX_TIME_ON_AIR_MS, 400).

-spec model(region()) -> unsupported | regulatory_model().
model(Region) ->
    case Region of
        %%                   Limit  Period
        %%                     (%)
        'AS923' -> {'duty',   0.01, 3600000};
        'AU915' -> {'duty',   0.01, 3600000};
        'CN470' -> {'duty',   0.01, 3600000};
        'CN779' -> {'duty',   0.01, 3600000};
        'EU433' -> {'duty',   0.01, 3600000};
        'EU868' -> {'duty',   0.01, 3600000};
        'IN865' -> {'duty',   0.01, 3600000};
        'KR920' -> {'duty',   0.01, 3600000};
        %%                      ms  Period
        'US915' -> {'dwell',   400,   20000};
        %% We can't support regions we are not aware of.
        _ -> unsupported
    end.

-spec model2(region_v2()) -> unsupported | regulatory_model().
model2(Region) ->
    case Region of
        'as923_1' -> {'duty',   0.01, 3600000};
        'as923_2' -> {'duty',   0.01, 3600000};
        'as923_3' -> {'duty',   0.01, 3600000};
        'au915'   -> {'duty',   0.01, 3600000};
        'cn779'   -> {'duty',   0.01, 3600000};
        'eu433'   -> {'duty',   0.01, 3600000};
        'eu868'   -> {'duty',   0.01, 3600000};
        'in865'   -> {'duty',   0.01, 3600000};
        'kr920'   -> {'duty',   0.01, 3600000};
        'us915'   -> {'dwell',   400,   20000};
        _         -> unsupported
    end.

-spec model_from_ledger(Ledger :: blockchain_ledger_v1:ledger()) -> {ok, regulatory_model()} | {error, any()}.
model_from_ledger(Ledger) ->
    case blockchain:config(?regulatory_regions, Ledger) of
        {ok, R} ->
            Regions = [list_to_atom(I) || I <- string:split(binary:bin_to_list(R), ",", all)],
            {ok, model2(Regions)};
        _ ->
            {error, not_found}
    end.

%% Updates Handle with time-on-air information.
%%
%% This function does not send/transmit itself.
-spec track_sent(
    Handle :: handle(),
    SentAt :: number(),
    Frequency :: number(),
    Bandwidth :: number(),
    SpreadingFactor :: integer(),
    CodeRate :: integer(),
    PreambleSymbols :: integer(),
    ExplicitHeader :: boolean(),
    PayloadLen :: integer()
) -> handle().
track_sent(
    unsupported,
    _SentAt,
    _Frequency,
    _Bandwidth,
    _SpreadingFactor,
    _CodeRate,
    _PreambleSymbols,
    _ExplicitHeader,
    _PayloadLen
) ->
    unsupported;
track_sent(
    Handle,
    SentAt,
    Frequency,
    Bandwidth,
    SpreadingFactor,
    CodeRate,
    PreambleSymbols,
    ExplicitHeader,
    PayloadLen
) ->
    TimeOnAir = time_on_air(
        Bandwidth,
        SpreadingFactor,
        CodeRate,
        PreambleSymbols,
        ExplicitHeader,
        PayloadLen
    ),
    track_sent(Handle, SentAt, Frequency, TimeOnAir).

-spec track_sent(handle(), number(), number(), number()) -> handle().
track_sent(unsupported, _SentAt, _Frequency, _TimeOnAir) ->
    unsupported;
track_sent({Region, SentPackets}, SentAt, Frequency, TimeOnAir) ->
    NewSent = #sent_packet{
        frequency = Frequency,
        sent_at = SentAt,
        time_on_air = TimeOnAir
    },
    {Region, trim_sent(Region, [NewSent | SentPackets])}.

-spec trim_sent(regulatory_model(), list(#sent_packet{})) -> list(#sent_packet{}).
trim_sent(Model, SentPackets = [NewSent, LastSent | _])
        when NewSent#sent_packet.sent_at < LastSent#sent_packet.sent_at ->
    trim_sent(Model, lists:sort(fun (A, B) -> A > B end, SentPackets));
trim_sent({_, _, Period}, SentPackets = [H | _]) ->
    CutoffTime = H#sent_packet.sent_at - Period,
    Pred = fun (Sent) -> Sent#sent_packet.sent_at > CutoffTime end,
    lists:takewhile(Pred, SentPackets).

%% @doc Based on previously sent packets, returns a boolean value if
%% it is legal to send on Frequency at time Now.
%%
%%
-spec can_send(
    Handle :: handle(),
    AtTime :: number(),
    Frequency :: integer(),
    TimeOnAir :: number()
) -> boolean().
can_send(unsupported, _AtTime, _Frequency, _TimeOnAir) ->
    false;
can_send(_Handle, _AtTime, _Frequency, TimeOnAir) when TimeOnAir > ?MAX_TIME_ON_AIR_MS ->
    %% TODO: check that all regions have do in fact have the same
    %% maximum time on air.
    false;
can_send({{dwell, Limit, Period}, SentPackets}, AtTime, Frequency, TimeOnAir) ->
    CutoffTime = AtTime - Period + TimeOnAir,
    ProjectedDwellTime = dwell_time(SentPackets, CutoffTime, Frequency) + TimeOnAir,
    ProjectedDwellTime =< Limit;
can_send({{duty, Limit, Period}, SentPackets}, AtTime, _Frequency, TimeOnAir) ->
    CutoffTime = AtTime - Period,
    CurrDwell = dwell_time(SentPackets, CutoffTime, all),
    (CurrDwell + TimeOnAir) / Period < Limit.

%% @doc Computes the total time on air for packets sent on Frequency
%% and no older than CutoffTime.
-spec dwell_time(list(#sent_packet{}), integer(), number() | 'all') -> number().
dwell_time(SentPackets, CutoffTime, Frequency) ->
    dwell_time(SentPackets, CutoffTime, Frequency, 0).

-spec dwell_time(list(#sent_packet{}), integer(), number() | 'all', number()) -> number().
%% Scenario 1: entire packet sent before CutoffTime
dwell_time([P | T], CutoffTime, Frequency, Acc)
        when P#sent_packet.sent_at + P#sent_packet.time_on_air < CutoffTime ->
    dwell_time(T, CutoffTime, Frequency, Acc);
%% Scenario 2: packet sent on non-relevant frequency.
dwell_time([P | T], CutoffTime, Frequency, Acc) when is_number(Frequency), P#sent_packet.frequency /= Frequency ->
    dwell_time(T, CutoffTime, Frequency, Acc);
%% Scenario 3: Packet started before CutoffTime but finished after CutoffTime.
dwell_time([P | T], CutoffTime, Frequency, Acc) when P#sent_packet.sent_at =< CutoffTime ->
    RelevantTimeOnAir = P#sent_packet.time_on_air - (CutoffTime - P#sent_packet.sent_at),
    true = RelevantTimeOnAir >= 0,
    dwell_time(T, CutoffTime, Frequency, Acc + RelevantTimeOnAir);
%% Scenario 4: 100 % of packet transmission after CutoffTime.
dwell_time([P | T], CutoffTime, Frequency, Acc) ->
    dwell_time(T, CutoffTime, Frequency, Acc + P#sent_packet.time_on_air);
dwell_time([], _CutoffTime, _Frequency, Acc) ->
    Acc.

%% @doc Returns total time on air for packet sent with given
%% parameters.
%%
%% See Semtech Appnote AN1200.13, "LoRa Modem Designer's Guide"
-spec time_on_air(
    Bandwidth :: number(),
    SpreadingFactor :: number(),
    CodeRate :: integer(),
    PreambleSymbols :: integer(),
    ExplicitHeader :: boolean(),
    PayloadLen :: integer()
) ->
    Milliseconds :: float().
time_on_air(
    Bandwidth,
    SpreadingFactor,
    CodeRate,
    PreambleSymbols,
    ExplicitHeader,
    PayloadLen
) ->
    SymbolDuration = symbol_duration(Bandwidth, SpreadingFactor),
    PayloadSymbols = payload_symbols(
        SpreadingFactor,
        CodeRate,
        ExplicitHeader,
        PayloadLen,
        (Bandwidth =< 125000) and (SpreadingFactor >= 11)
    ),
    SymbolDuration * (4.25 + PreambleSymbols + PayloadSymbols).

%% @doc Returns the number of payload symbols required to send payload.
-spec payload_symbols(integer(), integer(), boolean(), integer(), boolean()) -> number().
payload_symbols(
    SpreadingFactor,
    CodeRate,
    ExplicitHeader,
    PayloadLen,
    LowDatarateOptimized
) ->
    EH = b2n(ExplicitHeader),
    LDO = b2n(LowDatarateOptimized),
    8 +
        (erlang:max(
            math:ceil(
                (8 * PayloadLen - 4 * SpreadingFactor + 28 +
                    16 - 20 * (1 - EH)) /
                    (4 * (SpreadingFactor - 2 * LDO))
            ) * (CodeRate),
            0
        )).

-spec symbol_duration(number(), number()) -> float().
symbol_duration(Bandwidth, SpreadingFactor) ->
    math:pow(2, SpreadingFactor) / Bandwidth.

%% @doc Returns a new handle for the given region.
-spec new(Ledger :: undefined | blockchain_ledger_v1:ledger(),
          Region :: region()) -> handle().
new(undefined, Region) ->
    case model(Region) of
        unsupported -> unsupported;
        Model -> {Model, []}
    end;
new(Ledger, _Region) ->
    case model_from_ledger(Ledger) of
        {error, not_found} -> unsupported;
        {ok, ModelFromLedger} -> {ModelFromLedger, []}
    end.

-spec b2n(boolean()) -> integer().
b2n(false) ->
    0;
b2n(true) ->
    1.
