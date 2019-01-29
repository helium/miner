%%%-------------------------------------------------------------------
%% @doc
%% == miner hbbft_handler ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_hbbft_handler).

-behavior(relcast).

-export([init/1, handle_message/3, handle_command/2, callback_message/3, serialize/1, deserialize/1, restore/2, stamp/1]).

-record(state,
        {
         n :: non_neg_integer(),
         f :: non_neg_integer(),
         id :: non_neg_integer(),
         hbbft :: hbbft:hbbft_data(),
         sk :: tpke_privkey:privkey() | tpke_privkey:privkey_serialized(),
         seq = 0,
         deferred = [],
         signatures = [],
         signatures_required = 0,
         artifact :: undefined | binary(),
         members :: [libp2p_crypto:pubkey_bin()],
         ledger :: undefined | blockchain_ledger_v1:ledger()
        }).

stamp(Chain) ->
    {ok, HeadHash} = blockchain:head_hash(Chain),
    %% construct a 2-tuple of the system time and the current head block hash as our stamp data
    term_to_binary({erlang:system_time(seconds), HeadHash}).

init([Members, Id, N, F, BatchSize, SK, Chain]) ->
    init([Members, Id, N, F, BatchSize, SK, Chain, 0, []]);
init([Members, Id, N, F, BatchSize, SK, Chain, Round, Buf]) ->
    HBBFT = hbbft:init(SK, N, F, Id-1, BatchSize, 1500,
                       {?MODULE, stamp, [Chain]}, Round, Buf),
    Ledger = blockchain_ledger_v1:new_context(blockchain:ledger(Chain)),

    lager:info("HBBFT~p started~n", [Id]),
    {ok, #state{n = N,
                id = Id - 1,
                sk = SK,
                f = F,
                members = Members,
                signatures_required = N - F,
                hbbft = HBBFT,
                ledger=Ledger}}.

handle_command(start_acs, State) ->
    case hbbft:start_on_demand(State#state.hbbft) of
        {_HBBFT, already_started} ->
            {reply, ok, ignore};
        {NewHBBFT, {send, Msgs}} ->
            lager:notice("Started HBBFT round because of a block timeout"),
            {reply, ok, fixup_msgs(Msgs), State#state{hbbft=NewHBBFT}}
    end;
handle_command(get_buf, State) ->
    {reply, {ok, hbbft:buf(State#state.hbbft)}, ignore};
handle_command(stop, State) ->
    %% TODO add ignore support for this four tuple to use ignore
    {reply, ok, [{stop, timer:minutes(5)}], State};
handle_command({status, Ref, Worker}, State) ->
    Map = hbbft:status(State#state.hbbft),
    ArtifactHash = case State#state.artifact of
                       undefined -> undefined;
                       A -> blockchain_util:bin_to_hex(crypto:hash(sha256, A))
                   end,
    Worker ! {Ref, maps:merge(#{signatures_required => State#state.signatures_required,
                                signatures => length(State#state.signatures),
                                artifact_hash => ArtifactHash,
                                public_key_hash => blockchain_util:bin_to_hex(crypto:hash(sha256, term_to_binary(tpke_pubkey:serialize(tpke_privkey:public_key(State#state.sk)))))
                               }, Map)},
    {reply, ok, ignore};
handle_command({skip, Ref, Worker}, State) ->
    case hbbft:next_round(State#state.hbbft) of
        {NextHBBFT, ok} ->
            Worker ! {Ref, ok},
            {reply, ok, [new_epoch], State#state{hbbft=NextHBBFT, signatures=[], artifact=undefined}};
        {NextHBBFT, {send, NextMsgs}} ->
            {reply, ok, [new_epoch | fixup_msgs(NextMsgs)], State#state{hbbft=NextHBBFT, signatures=[], artifact=undefined}}
    end;
%% XXX this is a hack because we don't yet have a way to message this process other ways
handle_command({next_round, NextRound, TxnsToRemove, _Sync}, State=#state{hbbft=HBBFT, ledger=Ledger0}) ->
    PrevRound = hbbft:round(HBBFT),
    case NextRound - PrevRound of
        N when N > 0 ->
            Ledger = blockchain_ledger_v1:new_context(blockchain_ledger_v1:delete_context(Ledger0)),

            lager:info("Advancing from PreviousRound: ~p to NextRound ~p and emptying hbbft buffer", [PrevRound, NextRound]),
            case hbbft:next_round(filter_txn_buf(HBBFT, Ledger), NextRound, TxnsToRemove) of
                {NextHBBFT, ok} ->
                    {reply, ok, [ new_epoch ], State#state{ledger=Ledger, hbbft=NextHBBFT, signatures=[], artifact=undefined}};
                {NextHBBFT, {send, NextMsgs}} ->
                    {reply, ok, [ new_epoch ] ++ fixup_msgs(NextMsgs), State#state{ledger=Ledger, hbbft=NextHBBFT, signatures=[], artifact=undefined}}
            end;
        0 ->
            lager:warning("Already at the current Round: ~p", [NextRound]),
            {reply, ok, ignore};
        _ ->
            lager:warning("Cannot advance to NextRound: ~p from PrevRound: ~p", [NextRound, PrevRound]),
            {reply, error, ignore}
    end;
handle_command(Txn, State=#state{ledger=Ledger}) ->
    case blockchain_txn:absorb(Txn, Ledger) of
        ok ->
            case hbbft:input(State#state.hbbft, blockchain_txn:serialize(Txn)) of
                {NewHBBFT, ok} ->
                    {reply, ok, [], State#state{hbbft=NewHBBFT}};
                {_HBBFT, full} ->
                    {reply, {error, full}, ignore};
                {NewHBBFT, {send, Msgs}} ->
                    {reply, ok, fixup_msgs(Msgs), State#state{hbbft=NewHBBFT}}
            end;
        Error ->
            lager:error("hbbft_handler speculative absorb failed, error: ~p", [Error]),
            {reply, Error, ignore}
    end.

handle_message(BinMsg, Index, State=#state{hbbft = HBBFT}) ->
    Msg = binary_to_term(BinMsg),
    %lager:info("HBBFT input ~s from ~p", [fakecast:print_message(Msg), Index]),
    Round = hbbft:round(HBBFT),
    case Msg of
        {signature, R, Address, Signature} ->
            case R == Round andalso lists:member(Address, State#state.members) andalso
                 %% provisionally accept signatures if we don't have the means to verify them yet, they get filtered later
                 (State#state.artifact == undefined orelse libp2p_crypto:verify(State#state.artifact, Signature, libp2p_crypto:bin_to_pubkey(Address))) of
                true ->
                    NewState = State#state{signatures=lists:keystore(Address, 1, State#state.signatures, {Address, Signature})},
                    case enough_signatures(NewState) of
                        {ok, Signatures} ->
                            ok = miner:signed_block(Signatures, State#state.artifact);
                        false ->
                            false
                    end,
                    {NewState, []};
                false when R > Round ->
                    defer;
                false ->
                    lager:warning("Invalid signature ~p from ~p for round ~p in our round ~p", [Signature, Address, R, Round]),
                    %% invalid signature somehow
                    ignore
            end;
        _ ->
            case hbbft:handle_msg(HBBFT, Index - 1, Msg) of
                ignore -> ignore;
                {NewHBBFT, ok} ->
                    %lager:debug("HBBFT Status: ~p", [hbbft:status(NewHBBFT)]),
                    {State#state{hbbft=NewHBBFT}, []};
                {_, defer} ->
                    defer;
                {NewHBBFT, {send, Msgs}} ->
                    %lager:debug("HBBFT Status: ~p", [hbbft:status(NewHBBFT)]),
                    {State#state{hbbft=NewHBBFT}, fixup_msgs(Msgs)};
                {NewHBBFT, {result, {transactions, Stamps0, BinTxns}}} ->
                    Stamps = [{Id, binary_to_term(S)} || {Id, S} <- Stamps0],
                    Txns = [blockchain_txn:deserialize(B) || B <- BinTxns],
                    lager:info("Reached consensus"),
                    %% lager:info("stamps ~p~n", [Stamps]),
                    %lager:info("HBBFT Status: ~p", [hbbft:status(NewHBBFT)]),
                    %% send agreed upon Txns to the parent blockchain worker
                    %% the worker sends back its address, signature and txnstoremove which contains all or a subset of
                    %% transactions depending on its buffer
                    NewRound = hbbft:round(NewHBBFT),
                    case miner:create_block(Stamps, Txns, NewRound) of
                        {ok, Address, Artifact, Signature, TxnsToRemove} ->
                            %% call hbbft finalize round
                            BinTxnsToRemove = [blockchain_txn:serialize(T) || T <- TxnsToRemove],
                            NewerHBBFT = hbbft:finalize_round(NewHBBFT, BinTxnsToRemove),
                            Msgs = [{multicast, {signature, NewRound, Address, Signature}}],
                            {filter_signatures(State#state{hbbft=NewerHBBFT, artifact=Artifact}), fixup_msgs(Msgs)};
                        {error, Reason} ->
                            %% this is almost certainly because we got the new block gossipped before we completed consensus locally
                            %% which is harmless
                            lager:warning("failed to create new block ~p", [Reason]),
                            {State#state{hbbft=NewHBBFT}, []}
                    end
            end
    end.

callback_message(_, _, _) -> none.

serialize(State) ->
    {SerializedHBBFT, SerializedSK} = hbbft:serialize(State#state.hbbft, true),
    term_to_binary(State#state{hbbft=SerializedHBBFT, sk=SerializedSK, ledger=undefined}, [compressed]).

deserialize(BinState) ->
    State = binary_to_term(BinState),
    SK = tpke_privkey:deserialize(State#state.sk),
    HBBFT = hbbft:deserialize(State#state.hbbft, SK),
    State#state{hbbft=HBBFT, sk=SK}.

restore(OldState, NewState) ->
    %% replace the stamp fun from the old state with the new one
    %% because we have non-serializable data in it (rocksdb refs)
    {M, F, A} = hbbft:get_stamp_fun(NewState#state.hbbft),
    Ledger = NewState#state.ledger,
    {ok, OldState#state{hbbft=filter_txn_buf(hbbft:set_stamp_fun(M, F, A, OldState#state.hbbft), Ledger), ledger=Ledger}}.

%% helper functions
fixup_msgs(Msgs) ->
    lists:map(fun({unicast, J, NextMsg}) ->
                      {unicast, J+1, term_to_binary(NextMsg)};
                 ({multicast, NextMsg}) ->
                      {multicast, term_to_binary(NextMsg)}
              end, Msgs).

enough_signatures(#state{artifact=undefined}) ->
    false;
enough_signatures(#state{signatures=Sigs, signatures_required=Count}) when length(Sigs) < Count ->
    false;
enough_signatures(#state{artifact=Artifact, members=Members, signatures=Signatures, signatures_required=Threshold}) ->
    %% filter out any signatures that are invalid or are not for a member of this DKG and dedup
    case blockchain_block:verify_signatures(blockchain_block:deserialize(Artifact),
                                            Members,
                                            Signatures,
                                            Threshold) of
        {true, ValidSignatures} ->
            %% So, this is a little dicey, if we don't need all N signatures, we might have competing subsets
            %% depending on message order. Given that the underlying artifact they're signing is the same though,
            %% it should be ok as long as we disregard the signatures for testing equality but check them for validity
            {ok, lists:sublist(lists:sort(ValidSignatures), Threshold)};
        false ->
            false
    end.

filter_signatures(State=#state{artifact=Artifact, signatures=Signatures, members=Members}) ->
    FilteredSignatures = lists:filter(fun({Address, Signature}) ->
                         lists:member(Address, Members) andalso
                         libp2p_crypto:verify(Artifact, Signature, libp2p_crypto:bin_to_pubkey(Address))
                 end, Signatures),
    State#state{signatures=FilteredSignatures}.

filter_txn_buf(HBBFT, Ledger) ->
    Buf = hbbft:buf(HBBFT),
    NewBuf = lists:filter(fun(BinTxn) ->
                                  Txn = blockchain_txn:deserialize(BinTxn),
                                  ok == blockchain_txn:absorb(Txn, Ledger)
                          end, Buf),
    hbbft:buf(NewBuf, HBBFT).
