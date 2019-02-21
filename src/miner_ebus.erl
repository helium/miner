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
-define(MINER_MEMBER_ADD_GW, "AddGateway").
-define(MINER_MEMBER_ASSERT_LOC, "AssertLocation").
-define(MINER_MEMBER_SYNC_STATUS, "SyncStatus").

-define(MINER_ERROR_BADARGS, "com.helium.Miner.Error.BadArgs").
-define(MINER_ERROR_GW_EXISTS, "com.helium.Miner.Error.GatewayExists").
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
handle_message(?MINER_OBJECT(?MINER_MEMBER_ADD_GW)=Member, Msg, State=#state{}) ->
    case ebus_message:args(Msg) of
        {ok, [OwnerB58]} ->
            case miner:add_gateway_txn(OwnerB58) of
                {ok, TxnBin} ->
                    {reply, [{array, byte}], [TxnBin], State};
                {error, Error} ->
                    lager:warning("Error requesting add gateway: ~p", [Error]),
                    Reply = case Error of
                                invalid_owner -> ?MINER_ERROR_BADARGS;
                                gateway_already_active -> ?MINER_ERROR_GW_EXISTS;
                                _ -> ?MINER_ERROR_INTERNAL
                            end,
                    {reply_error, Reply, Member, State}
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
        {ok, [H3String, OwnerB58, Nonce, Fee]} ->
            lager:info("Requesting assert for ~p", [H3String]),
            case (catch miner:assert_loc_txn(H3String, OwnerB58, Nonce, Fee)) of
                {ok, TxnBin} ->
                    {reply, [{array, byte}], [TxnBin], State};
                {error, Error} ->
                    lager:warning("Error requesting assert_loc: ~p", [Error]),
                    Reply = case Error of
                                invalid_owner -> ?MINER_ERROR_BADARGS;
                                _ -> ?MINER_ERROR_INTERNAL
                            end,
                    {reply_error, Reply, Member, State};
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
handle_message(?MINER_OBJECT(?MINER_MEMBER_SYNC_STATUS), _Msg, State) ->
    Status = case miner:syncing_status() of
        true -> "StartSyncing";
        false -> "StopSyncing"
    end,
    {reply, [string], [Status], State};
handle_message(Member, _Msg, State) ->
    lager:warning("Unhandled dbus message ~p", [Member]),
    {reply_error, ?DBUS_ERROR_NOT_SUPPORTED, Member, State}.

handle_cast({send_signal, Signal, Status}, State) ->
    {noreply, State, {signal, ?MINER_OBJECT_PATH, ?MINER_INTERFACE, Signal, [string], [Status]}};
handle_cast(_Msg, State) ->
    lager:warning("unhandled msg: ~p", [_Msg]),
    {noreply, State}.
