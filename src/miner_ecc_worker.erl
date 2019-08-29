-module(miner_ecc_worker).

-behavior(gen_server).

-export([sign/1,
         ecdh/1]).

-export([start_link/1,
         init/1,
         handle_call/3,
         handle_cast/2,
         terminate/2]).

-record(state, {
                ecc_handle :: pid(),
                key_slot :: non_neg_integer()
               }).

-spec sign(binary()) -> {ok, Signature::binary()} | {error, term()}.
sign(Binary) ->
    gen_server:call(?MODULE, {sign, Binary}).

-spec ecdh(libp2p_crypto:pubkey()) -> {ok, Preseed::binary()} | {error, term()}.
ecdh({ecc_compact, PubKey}) ->
    gen_server:call(?MODULE, {ecdh, PubKey}).

start_link(KeySlot) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [KeySlot], []).


init([KeySlot]) ->
    {ok, ECCHandle} = ecc508:start_link(),
    {ok, #state{ecc_handle=ECCHandle, key_slot=KeySlot}}.


handle_call({sign, Binary}, _From, State=#state{ecc_handle=Pid}) ->
    Reply = txn(Pid, fun() ->
                             ecc508:sign(Pid, State#state.key_slot, Binary)
                     end, 10),
    {reply, Reply, State};
handle_call({ecdh, PubKey}, _From, State=#state{ecc_handle=Pid}) ->
    Reply = txn(Pid, fun() ->
                             ecc508:ecdh(Pid, State#state.key_slot, PubKey)
                     end, 10),
    {reply, Reply, State};

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
            timer:sleep(150),
            txn(Pid, Fun, Limit - 1);
        {error, ecc_response_watchdog_exp} ->
            %% There is insufficient time to execute the given command
            %% before the watchdog timer will expire. The system must
            %% reset the watchdog timer by entering the idle or sleep
            %% modes.
            ecc508:sleep(Pid),
            timer:sleep(10),
            txn(Pid, Fun, Limit - 1);
        {error, ecc_command_timeout} ->
            %% Command was not properly received by ATECC508A and should be
            %% re-transmitted by the I/O driver in the system. No attempt was made
            %% to parse or execute the command
            timer:sleep(10),
            txn(Pid, Fun, Limit - 1);
        {error, ecc_checksum_failed} ->
            %% Corruption may have occurred on the bus. Try again
            %% after cycling the volatile areas with a sleep
            ecc508:sleep(Pid),
            timer:sleep(10),
            txn(Pid, Fun, Limit - 1);
        {error, {ecc_unknown_response, _}} ->
            %% Got a weird status response back. Retry
            ecc508:sleep(Pid),
            timer:sleep(10),
            txn(Pid, Fun, Limit - 1);
        Result ->
            ecc508:sleep(Pid),
            Result
    end.
