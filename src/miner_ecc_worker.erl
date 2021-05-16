-module(miner_ecc_worker).
-behavior(gen_server).

-export([sign/1,
         ecdh/1,
         get_pid/0]).

-export([start_link/3,
         init/1,
         handle_call/3,
         handle_cast/2,
         terminate/2]).

-record(state, {
                ecc_handle :: pid(),
                key_slot :: non_neg_integer()
               }).

-define(SHORT_RETRY_WAIT, 10).
-define(LONG_RETRY_WAIT, 150).

-define(MAX_TXN_RETRIES, 10).
%% Make the call timeout quite long since this worker has to process
%% all signing requests for the system
-define(CALL_TIMEOUT, (?MAX_TXN_RETRIES * ?LONG_RETRY_WAIT) * 10).

-spec sign(binary()) -> {ok, Signature::binary()} | {error, term()}.
sign(Binary) ->
    gen_server:call(?MODULE, {sign, Binary}, ?CALL_TIMEOUT).

-spec ecdh(libp2p_crypto:pubkey()) -> {ok, Preseed::binary()} | {error, term()}.
ecdh({ecc_compact, PubKey}) ->
    gen_server:call(?MODULE, {ecdh, PubKey}, ?CALL_TIMEOUT).

get_pid() ->
    gen_server:call(?MODULE, get_pid).

start_link(KeySlot, Bus, Address) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [KeySlot, Bus, Address], []).


init([KeySlot, Bus, Address]) ->
    {ok, ECCHandle} = ecc508:start_link(Bus, Address),
    {ok, #state{ecc_handle=ECCHandle, key_slot=KeySlot}}.


handle_call({sign, Binary}, _From, State=#state{ecc_handle=Pid}) ->
    Reply = txn(Pid, fun() ->
                             ecc508:sign(Pid, State#state.key_slot, Binary)
                     end, ?MAX_TXN_RETRIES),
    {reply, Reply, State};
handle_call({ecdh, PubKey}, _From, State=#state{ecc_handle=Pid}) ->
    Reply = txn(Pid, fun() ->
                             ecc508:ecdh(Pid, State#state.key_slot, PubKey)
                     end, ?MAX_TXN_RETRIES),
    {reply, Reply, State};
handle_call(get_pid, _From, State=#state{ecc_handle=Pid}) ->
    {reply, {ok, Pid}, State};
handle_call(_Msg, _From, State) ->
    lager:warning("unhandled call ~p", [_Msg]),
    {reply, ok, State}.


handle_cast(_Msg, State) ->
    lager:warning("unhandled cast ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, State=#state{}) ->
    catch ecc508:stop(State#state.ecc_handle).


txn(_Pid, _Fun, 0) ->
    {error, retries_exceeded};
txn(Pid, Fun, Limit) ->
    ecc508:wake(Pid),
    case Fun() of
        {error, ecc_asleep} ->
            ecc508:sleep(Pid),
            %% let the chip timeout
            timer:sleep(?LONG_RETRY_WAIT),
            txn(Pid, Fun, Limit - 1);
        {error, ecc_response_watchdog_exp} ->
            %% There is insufficient time to execute the given command
            %% before the watchdog timer will expire. The system must
            %% reset the watchdog timer by entering the idle or sleep
            %% modes.
            ecc508:sleep(Pid),
            timer:sleep(?SHORT_RETRY_WAIT),
            txn(Pid, Fun, Limit - 1);
        {error, ecc_command_timeout} ->
            %% Command was not properly received by ATECC508A and should be
            %% re-transmitted by the I/O driver in the system. No attempt was made
            %% to parse or execute the command
            timer:sleep(?SHORT_RETRY_WAIT),
            txn(Pid, Fun, Limit - 1);
        {error, ecc_checksum_failed} ->
            %% Corruption may have occurred on the bus. Try again
            %% after cycling the volatile areas with a sleep
            ecc508:sleep(Pid),
            timer:sleep(?SHORT_RETRY_WAIT),
            txn(Pid, Fun, Limit - 1);
        {error, i2c_read_failed} ->
            %% Corruption may have occurred on the bus. Try again
            %% after cycling the volatile areas with a sleep
            ecc508:sleep(Pid),
            timer:sleep(?SHORT_RETRY_WAIT),
            txn(Pid, Fun, Limit - 1);
        {error, {ecc_unknown_response, Resp}} ->
            %% Got a weird status response back. Retry
            lager:warning("Unknown ECC response ~p, retrying", [Resp]),
            ecc508:sleep(Pid),
            timer:sleep(?SHORT_RETRY_WAIT),
            txn(Pid, Fun, Limit - 1);
        Result ->
            ecc508:sleep(Pid),
            Result
    end.
