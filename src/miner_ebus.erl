-module(miner_ebus).

-behavior(ebus_object).

-include_lib("ebus/include/ebus.hrl").

-export([start_link/0, start_link/2, init/1, handle_message/3]).

-record(state, {
               }).

-define(SERVER, miner_ebus).

-define(MINER_APPLICATION_NAME, "com.helium.Miner").
-define(MINER_OBJECT_PATH, "/").
-define(MINER_INTERFACE, "com.helium.Miner").
-define(MINER_OBJECT(M), ?MINER_INTERFACE ++ "." ++ M).

-define(MINER_MEMBER_PUBKEY, "PubKey").
-define(MINER_MEMBER_ADD_GW, "AddGateway").

-define(MINER_ERROR_BADARGS, "com.helium.Miner.Error.BadArgs").
-define(MINER_ERROR_GW_EXISTS, "com.helium.Miner.Error.GatewayExists").
-define(MINER_ERROR_INTERNAL, "com.helium.Miner.Error.Internal").

start_link() ->
    {ok, Bus} = ebus:system(),
    start_link(Bus, []).

start_link(Bus, Args) ->
    ok = ebus:request_name(Bus, ?MINER_APPLICATION_NAME),
    ebus_object:start_link(Bus, ?MINER_OBJECT_PATH, ?MODULE, Args, []).

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

handle_message(Member, _Msg, State) ->
    lager:warning("Unhandled dbus message ~p", [Member]),
    {reply_error, ?DBUS_ERROR_NOT_SUPPORTED, Member, State}.
