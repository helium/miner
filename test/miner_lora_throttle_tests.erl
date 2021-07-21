-module(miner_lora_throttle_tests).

-include_lib("eunit/include/eunit.hrl").

%% Test cases generated with https://www.loratools.nl/#/airtime and
%% truncated to milliseconds.
us_time_on_air_test() ->
    ?assertEqual(991, ms(miner_lora_throttle:time_on_air(125.0e3, 12, 5, 8, true, 7))),
    ?assertEqual(2465, ms(miner_lora_throttle:time_on_air(125.0e3, 12, 5, 8, true, 51))),

    ?assertEqual(495, ms(miner_lora_throttle:time_on_air(125.0e3, 11, 5, 8, true, 7))),
    ?assertEqual(1314, ms(miner_lora_throttle:time_on_air(125.0e3, 11, 5, 8, true, 51))),

    ?assertEqual(247, ms(miner_lora_throttle:time_on_air(125.0e3, 10, 5, 8, true, 7))),
    ?assertEqual(616, ms(miner_lora_throttle:time_on_air(125.0e3, 10, 5, 8, true, 51))),

    ?assertEqual(123, ms(miner_lora_throttle:time_on_air(125.0e3, 9, 5, 8, true, 7))),
    ?assertEqual(328, ms(miner_lora_throttle:time_on_air(125.0e3, 9, 5, 8, true, 51))),

    ?assertEqual(72, ms(miner_lora_throttle:time_on_air(125.0e3, 8, 5, 8, true, 7))),
    ?assertEqual(184, ms(miner_lora_throttle:time_on_air(125.0e3, 8, 5, 8, true, 51))),

    ?assertEqual(36, ms(miner_lora_throttle:time_on_air(125.0e3, 7, 5, 8, true, 7))),
    ?assertEqual(102, ms(miner_lora_throttle:time_on_air(125.0e3, 7, 5, 8, true, 51))),

    ok.

us915_dwell_time_test() ->
    MaxDwell = 400,
    Period = 20000,
    HalfMax = MaxDwell div 2,
    QuarterMax = MaxDwell div 4,
    %% There are no special frequencies in region US915, so the
    %% lorareg API doesn't care what values you use for Frequency
    %% arguments as long as they are distinct and comparable. We can
    %% use channel number instead like so.
    Ch0 = 0,
    Ch1 = 1,
    %% Time naught. Times can be negative as the only requirement
    %% lorareg places is on time is that it is monotonically
    %% increasing and expressed as milliseconds.
    T0 = -123456789,

    S0 = miner_lora_throttle:new('US915'),
    S1 = miner_lora_throttle:track_sent(S0, T0, Ch0, MaxDwell),
    S2 = miner_lora_throttle:track_sent(S1, T0, Ch1, HalfMax),

    ?assertEqual(false, miner_lora_throttle:can_send(S2, T0 + 100, Ch0, MaxDwell)),
    ?assertEqual(true, miner_lora_throttle:can_send(S2, T0, Ch1, HalfMax)),
    ?assertEqual(false, miner_lora_throttle:can_send(S2, T0 + 1, Ch0, MaxDwell)),
    ?assertEqual(true, miner_lora_throttle:can_send(S2, T0 + 1, Ch1, HalfMax)),

    ?assertEqual(false, miner_lora_throttle:can_send(S2, T0 + Period - 1, Ch0, MaxDwell)),
    ?assertEqual(true, miner_lora_throttle:can_send(S2, T0 + Period, Ch0, MaxDwell)),
    ?assertEqual(true, miner_lora_throttle:can_send(S2, T0 + Period + 1, Ch0, MaxDwell)),

    %% The following cases are all allowed because no matter how you
    %% vary the start time this transmission, (HalfMax + HalfMax)
    %% ratifies the constrain of `=< MaxDwell'.
    ?assertEqual(true, miner_lora_throttle:can_send(S2, T0 + Period - HalfMax - 1, Ch1, HalfMax)),
    ?assertEqual(true, miner_lora_throttle:can_send(S2, T0 + Period - HalfMax, Ch1, HalfMax)),
    ?assertEqual(true, miner_lora_throttle:can_send(S2, T0 + Period - HalfMax + 1, Ch1, HalfMax)),

    %% None of the following cases are allowed because they all exceed
    %% maximum dwell time by 1.
    ?assertEqual(false, miner_lora_throttle:can_send(S2, T0 + Period - HalfMax - 1, Ch1, HalfMax + 1)),
    ?assertEqual(false, miner_lora_throttle:can_send(S2, T0 + Period - HalfMax - 2, Ch1, HalfMax + 1)),
    ?assertEqual(false, miner_lora_throttle:can_send(S2, T0 + Period - HalfMax - 3, Ch1, HalfMax + 1)),

    %% The following cases are all allowed because they all begin a full
    %% period of concern after the currently tracked transmissions.
    ?assertEqual(true, miner_lora_throttle:can_send(S2, T0 + Period + MaxDwell, Ch0, MaxDwell)),
    ?assertEqual(true, miner_lora_throttle:can_send(S2, T0 + Period + MaxDwell, Ch1, MaxDwell)),

    %% Let's finish of by tracking two more small packets of 1/4
    %% maximum dwell in length and asserting that there is no more
    %% time left in the [T0, T0 + Period) for even a packet of 1ms in duration.
    ?assertEqual(true, miner_lora_throttle:can_send(S2, T0 + Period div 4, Ch1, QuarterMax)),
    S3 = miner_lora_throttle:track_sent(S2, T0 + Period div 4, Ch1, QuarterMax),
    ?assertEqual(true, miner_lora_throttle:can_send(S3, T0 + (Period * 0.75), Ch1, QuarterMax)),
    S4 = miner_lora_throttle:track_sent(S3, T0 + (Period * 3) div 4, Ch1, QuarterMax),
    ?assertEqual(false, miner_lora_throttle:can_send(S4, T0 + Period - 1, Ch1, 1)),

    %% ... but one ms later, we're all clear to send a packet. Note
    %% that if had sent that first packet on channel 1 even a ms later
    %% this would fail too.
    ?assertEqual(true, miner_lora_throttle:can_send(S4, T0 + Period, Ch1, 1)),
    ok.

eu868_duty_cycle_test() ->
    MaxTimeOnAir = 400,
    Ten_ms = 10,
    Ch0 = 0,
    Ch1 = 1,

    S0 = miner_lora_throttle:new('EU868'),

    ?assertEqual(true, miner_lora_throttle:can_send(S0, 0, Ch0, MaxTimeOnAir)),
    ?assertEqual(false, miner_lora_throttle:can_send(S0, 0, Ch0, MaxTimeOnAir + 1)),
    %% Send 3599 packets of duration 10ms on a single channel over the
    %% course of one hour. All should be accepted because 3599 * 10ms
    %% = 35.99s, or approx 0.9997 % duty-cycle.
    {S1, Now} = lists:foldl(
        fun (N, {State, _T}) ->
            Now = (N - 1) * 1000,
            ?assertEqual(true, miner_lora_throttle:can_send(State, Now, Ch0, Ten_ms)),
            {miner_lora_throttle:track_sent(State, Now, Ch0, Ten_ms), Now + 1000}
        end,
        {miner_lora_throttle:new('EU868'), 0},
        lists:seq(1, 3599)
    ),

    %% Let's try sending on a different channel. This will fail
    %% because, unlike FCC, ETSI rules limit overall duty-cycle and
    %% not per-channel dwell. So despite being a different channel, if
    %% this transmission were allowed, it raise our overall duty cycle
    %% to exactly 1 %.
    ?assertEqual(false, miner_lora_throttle:can_send(S1, Now, Ch1, Ten_ms)),

    ok.

%% Converts floating point seconds to integer seconds to remove
%% floating point ambiguity from test cases.
ms(Seconds) ->
    erlang:trunc(Seconds * 1000.0).
