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

-define(MINER_MEMBER_ADD_GW, "AddGateway").
-define(MINER_MEMBER_ASSERT_LOC, "AssertLocation").
-define(MINER_MEMBER_P2P_STATUS, "P2PStatus").
-define(MINER_MEMBER_BLOCK_AGE, "BlockAge").
-define(MINER_MEMBER_HEIGHT, "Height").

-define(MINER_ERROR_BADARGS, "com.helium.Miner.Error.BadArgs").
-define(MINER_ERROR_INTERNAL, "com.helium.Miner.Error.Internal").

start_link() ->
    {ok, Bus} = ebus:system(),
    start_link(Bus, []).

start_link(Bus, Args) ->
    NameOpts = [{replace_existing, true},
                {allow_replacement, true},
                {do_not_queue, true}
               ],
    ok = ebus:request_name(Bus, ?MINER_APPLICATION_NAME, NameOpts),
    ebus_object:start_link(Bus, ?MINER_OBJECT_PATH, ?MODULE, Args, []).

-spec send_signal(string(), string()) -> ok.
send_signal(Signal, Status) ->
    gen_server:cast(?SERVER, {send_signal, Signal, Status}).

init(_Args) ->
    erlang:register(?SERVER, self()),
    {ok, #state{}}.


handle_message(?MINER_OBJECT(?MINER_MEMBER_ADD_GW)=Member, Msg, State=#state{}) ->
    case ebus_message:args(Msg) of
        {ok, [OwnerB58, Fee, StakingFee, PayerB58]} ->
            case (catch blockchain:add_gateway_txn(OwnerB58, PayerB58, Fee, StakingFee)) of
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
            case (catch blockchain:assert_loc_txn(H3String, OwnerB58, PayerB58, Nonce, StakingFee, Fee)) of
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
handle_message(?MINER_OBJECT(?MINER_MEMBER_P2P_STATUS), _, State=#state{}) ->
    Status = miner:p2p_status(),
    {reply, [{array, {struct, [string, string]}}], [Status], State};
handle_message(?MINER_OBJECT(?MINER_MEMBER_BLOCK_AGE), _, State=#state{}) ->
    Age = miner:block_age(),
    {reply, [int32], [Age], State};
handle_message(?MINER_OBJECT(?MINER_MEMBER_HEIGHT), _, State=#state{}) ->
    Chain = blockchain_worker:blockchain(),
    {ok, Height} = blockchain:height(Chain),
    {reply, [int32], [Height], State};
handle_message(Member, _Msg, State) ->
    lager:warning("Unhandled dbus message ~p", [Member]),
    {reply_error, ?DBUS_ERROR_NOT_SUPPORTED, Member, State}.

handle_cast({send_signal, Signal, Status}, State) ->
    {noreply, State, {signal, ?MINER_OBJECT_PATH, ?MINER_INTERFACE, Signal, [string], [Status]}};
handle_cast(_Msg, State) ->
    lager:warning("unhandled msg: ~p", [_Msg]),
    {noreply, State}.
