-module(miner_ebus).

-behavior(ebus_object).

-include_lib("ebus/include/ebus.hrl").

-export([send_signal/2]).

-export([start_link/0, start_link/2, init/1, handle_message/3, handle_cast/2]).

-record(state, {}).

-define(SERVER, miner_ebus).

-define(MINER_APPLICATION_NAME, "com.helium.Miner").
-define(MINER_OBJECT_PATH, "/").
-define(MINER_INTERFACE, "com.helium.Miner").
-define(MINER_OBJECT(M), ?MINER_INTERFACE ++ "." ++ M).

-define(MINER_MEMBER_PUBKEY, "PubKey").
-define(MINER_MEMBER_ONBOARDING_KEY, "OnboardingKey").
-define(MINER_MEMBER_ADD_GW, "AddGateway").
-define(MINER_MEMBER_ASSERT_LOC, "AssertLocation").
-define(MINER_MEMBER_IS_CONNECTED, "IsConnected").

-define(MINER_ERROR_BADARGS, "com.helium.Miner.Error.BadArgs").
-define(MINER_ERROR_INTERNAL, "com.helium.Miner.Error.Internal").

start_link() ->
    {ok, Bus} = ebus:system(),
    start_link(Bus, []).

start_link(Bus, Args) ->
    ok = ebus:request_name(Bus, ?MINER_APPLICATION_NAME),
    ebus_object:start_link(Bus, ?MINER_OBJECT_PATH, ?MODULE, Args, []).

-spec send_signal(string(), string()) -> ok.
send_signal(Signal, Status) ->
    gen_server:cast(?SERVER, {send_signal, Signal, Status}).

init(_Args) ->
    erlang:register(?SERVER, self()),
    {ok, #state{}}.


handle_message(?MINER_OBJECT(?MINER_MEMBER_PUBKEY), _Msg, State=#state{}) ->
    PubKeyBin = miner:pubkey_bin(),
    {reply, [string], [libp2p_crypto:bin_to_b58(PubKeyBin)], State};
handle_message(?MINER_OBJECT(?MINER_MEMBER_ONBOARDING_KEY), _Msg, State=#state{}) ->
    PubKeyBin = miner:onboarding_key_bin(),
    {reply, [string], [libp2p_crypto:bin_to_b58(PubKeyBin)], State};
handle_message(?MINER_OBJECT(?MINER_MEMBER_ADD_GW)=Member, Msg, State=#state{}) ->
    case ebus_message:args(Msg) of
        {ok, [OwnerB58, Fee, StakingFee, PayerB58]} ->
            case (catch miner:add_gateway_txn(OwnerB58, PayerB58, Fee, StakingFee)) of
                {ok, TxnBin} ->
                    {reply, [{array, byte}], [TxnBin], State};
                {'EXIT', Why} ->
                    lager:warning("Error requesting assert loc: ~p", [Why]),
                    {reply_error, ?MINER_ERROR_BADARGS, Member, State}
            end;
        {ok, Args} ->
            lager:warning("Invalid add gateway args: ~p", [Args]),
            {reply_error, ?MINER_ERROR_BADARGS, Member, State};
        {error, Error} ->
            lager:warning("Invalid add gateway args: ~p", [Error]),
            {reply_error, ?MINER_ERROR_BADARGS, Member, State}
    end;
handle_message(?MINER_OBJECT(?MINER_MEMBER_ASSERT_LOC)=Member, Msg, State=#state{}) ->
    case ebus_message:args(Msg) of
        {ok, [H3String, OwnerB58, Nonce, StakingFee, Fee, PayerB58]} ->
            lager:info("Requesting assert for ~p", [H3String]),
            case (catch miner:assert_loc_txn(H3String, OwnerB58, PayerB58, Nonce, StakingFee, Fee)) of
                {ok, TxnBin} ->
                    {reply, [{array, byte}], [TxnBin], State};
                {'EXIT', Why} ->
                    lager:warning("Error requesting assert loc: ~p", [Why]),
                    {reply_error, ?MINER_ERROR_BADARGS, Member, State}
            end;
        {ok, Args} ->
            lager:warning("Invalid asset_loc args: ~p", [Args]),
            {reply_error, ?MINER_ERROR_BADARGS, Member, State};
        {error, Error} ->
            lager:warning("Invalid assert_loc args: ~p", [Error]),
            {reply_error, ?MINER_ERROR_BADARGS, Member, State}
    end;
handle_message(?MINER_OBJECT(?MINER_MEMBER_IS_CONNECTED), _, State=#state{}) ->
    Reply = case miner:is_connected() of
                ok -> ok;
                {error, Error} -> Error
            end,
    {reply, [{array, byte}], atom_to_binary(Reply, latin1), State};
handle_message(Member, _Msg, State) ->
    lager:warning("Unhandled dbus message ~p", [Member]),
    {reply_error, ?DBUS_ERROR_NOT_SUPPORTED, Member, State}.

handle_cast({send_signal, Signal, Status}, State) ->
    {noreply, State, {signal, ?MINER_OBJECT_PATH, ?MINER_INTERFACE, Signal, [string], [Status]}};
handle_cast(_Msg, State) ->
    lager:warning("unhandled msg: ~p", [_Msg]),
    {noreply, State}.
