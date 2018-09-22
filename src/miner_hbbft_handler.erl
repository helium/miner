%%%-------------------------------------------------------------------
%% @doc
%% == miner hbbft_handler ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_hbbft_handler).

-behavior(libp2p_group_relcast_handler).

-export([init/1, handle_message/3, handle_input/2, serialize_state/1, deserialize_state/1, stamp/0]).

-record(state, {
          n :: non_neg_integer()
          ,f :: non_neg_integer()
          ,id :: non_neg_integer()
          ,hbbft :: hbbft:hbbft_data()
          ,sk :: tpke_privkey:privkey() | tpke_privkey:privkey_serialized()
          ,seq = 0
          ,deferred = []
          ,signatures = []
          ,signatures_required = 0
          ,artifact :: undefined | binary()
          ,members :: [libp2p_crypto:address()]
         }).

stamp() ->
    Head = blockchain_worker:head_hash(),
    %% construct a 2-tuple of the system time and the current head block hash as our stamp data
    {erlang:system_time(seconds), Head}.

init([Members, Id, N, F, BatchSize, SK, _Worker]) ->
    HBBFT = hbbft:init(SK, N, F, Id-1, BatchSize, 1500, {?MODULE, stamp, []}),
    lager:info("HBBFT~p started~n", [Id]),
    {ok, Members, #state{n=N,
                         id=Id-1,
                         sk=SK,
                         f=F,
                         members=Members,
                         signatures_required=N-F,
                         hbbft=HBBFT}}.

handle_input(flush, State) ->
    maybe_deliver_deferred(State, ok);
handle_input(start_acs, State) ->
    case hbbft:start_on_demand(State#state.hbbft) of
        {NewHBBFT, already_started} ->
            {State#state{hbbft=NewHBBFT}, ok};
        {NewHBBFT, {send, Msgs}} ->
            lager:notice("Started HBBFT round because of a block timeout"),
            maybe_deliver_deferred(State#state{hbbft=NewHBBFT}, {send, fixup_msgs(Msgs)})
    end;
handle_input({status, Ref, Worker}, State) ->
    Map = hbbft:status(State#state.hbbft),
    Worker ! {Ref, maps:merge(#{deferred =>[ {Index - 1, binary_to_term(Msg)} || {Index, Msg} <- State#state.deferred], signatures_required => State#state.signatures_required, signatures => length(State#state.signatures)}, Map)},
    {State, ok};
%% XXX this is a hack because we don't yet have a way to message this process other ways
handle_input({next_round, NextRound, TxnsToRemove}, State=#state{hbbft=HBBFT}) ->
    PrevRound = hbbft:round(HBBFT),
    case NextRound - PrevRound of
        N when N > 0 ->
            lager:info("Advancing from PreviousRound: ~p to NextRound ~p and emptying hbbft buffer", [PrevRound, NextRound]),
            %% filter any stale messages
            libp2p_group_relcast_server:filter(self(), fun(_Index, Key) ->
                                                               case binary_to_term(Key) of
                                                                   {{acs, R}, _} when R >= NextRound ->
                                                                       done;
                                                                   {dec, R, _, _} when R >= NextRound ->
                                                                       done;
                                                                   {signature, R, _, _} when R >= NextRound ->
                                                                       done;
                                                                   {{acs, _}, _} ->
                                                                       %% stale message
                                                                       false;
                                                                   {dec, _, _, _} ->
                                                                       %% stale message
                                                                       false;
                                                                   {signature, _, _, _} ->
                                                                       false;
                                                                   _ ->
                                                                       %% unknown message, keep it
                                                                       true
                                                               end
                                                       end),
            case hbbft:next_round(HBBFT, NextRound, TxnsToRemove) of
                {NextHBBFT, ok} ->
                    maybe_deliver_deferred(State#state{hbbft=NextHBBFT, signatures=[], artifact=undefined}, ok);
                {NextHBBFT, {send, NextMsgs}} ->
                    maybe_deliver_deferred(State#state{hbbft=NextHBBFT, signatures=[], artifact=undefined}, {send, fixup_msgs(NextMsgs)})
            end;
        0 ->
            lager:warning("Already at the current Round: ~p", [NextRound]),
            {State, ok};
        _ ->
            lager:warning("Cannot advance to NextRound: ~p from PrevRound: ~p", [NextRound, PrevRound]),
            {State, ok}
    end;
handle_input(Txn, State) ->
    case hbbft:input(State#state.hbbft, Txn) of
        {NewHBBFT, ok} ->
            maybe_deliver_deferred(State#state{hbbft=NewHBBFT}, ok);
        {HBBFT, full} ->
            {State#state{hbbft=HBBFT}, ok};
        {NewHBBFT, {send, Msgs}} ->
            maybe_deliver_deferred(State#state{hbbft=NewHBBFT}, {send, fixup_msgs(Msgs)})
    end.

handle_message(Index, Msg, State=#state{hbbft=HBBFT}) ->
    lager:info("HBBFT input ~p from ~p", [binary_to_term(Msg), Index]),
    case binary_to_term(Msg) of
        {signature, _R, Address, Signature} ->
            NewState = State#state{signatures=[{Address, Signature}|State#state.signatures]},
            case enough_signatures(NewState) of
                {ok, Signatures} ->
                    ok = miner:signed_block(Signatures, State#state.artifact);
                false ->
                    ok
            end,
            {NewState, ok};
        _ ->
            case hbbft:handle_msg(HBBFT, Index - 1, binary_to_term(Msg)) of
                {HBBFT, ok} ->
                    %% nothing changed, no need to evaluate deferred messages
                    {State, ok};
                {NewHBBFT, ok} ->
                    %lager:debug("HBBFT Status: ~p", [hbbft:status(NewHBBFT)]),
                    maybe_deliver_deferred(State#state{hbbft=NewHBBFT}, ok);
                {NewHBBFT, defer} ->
                    lager:warning("~p deferring message ~p from ~p", [State#state.id + 1, binary_to_term(Msg), Index]),
                    %lager:warning("HBBFT Status: ~p", [hbbft:status(NewHBBFT)]),
                    Deferred = case lists:member({Index, Msg}, State#state.deferred) of
                        true ->
                            State#state.deferred;
                        false ->
                            State#state.deferred ++ [{Index, Msg}]
                    end,
                    {State#state{hbbft=NewHBBFT, deferred=Deferred}, defer};
                {NewHBBFT, {send, Msgs}} ->
                    %lager:debug("HBBFT Status: ~p", [hbbft:status(NewHBBFT)]),
                    maybe_deliver_deferred(State#state{hbbft=NewHBBFT}, {send, fixup_msgs(Msgs)});
                {NewHBBFT, {result, {transactions, Stamps, Txns}}} ->
                    lager:info("Reached consensus"),
                    lager:info("stamps ~p~n", [Stamps]),
                    %lager:info("HBBFT Status: ~p", [hbbft:status(NewHBBFT)]),
                    %% send agreed upon Txns to the parent blockchain worker
                    %% the worker sends back its address, signature and txnstoremove which contains all or a subset of
                    %% transactions depending on its buffer
                    Round = hbbft:round(NewHBBFT),
                    case miner:create_block(Stamps, Txns, Round) of
                        {ok, Address, Artifact, Signature, TxnsToRemove} ->
                            %% call hbbft finalize round
                            NewerHBBFT = hbbft:finalize_round(NewHBBFT, TxnsToRemove),
                            Msgs = [{multicast, {signature, Round, Address, Signature}}],
                            maybe_deliver_deferred(State#state{hbbft=NewerHBBFT, artifact=Artifact}, {send, fixup_msgs(Msgs)});
                        {error, Reason} ->
                            %% this is almost certainly because we got the new block gossipped before we completed consensus locally
                            %% which is harmless
                            lager:warning("failed to create new block ~p", [Reason]),
                            {State#state{hbbft=NewHBBFT}, ok}
                    end
            end
    end.

serialize_state(State) ->
    {SerializedHBBFT, SerializedSK} = hbbft:serialize(State#state.hbbft, true),
    term_to_binary(State#state{hbbft=SerializedHBBFT, sk=SerializedSK}).

deserialize_state(BinState) ->
    State = binary_to_term(BinState),
    SK = tpke_privkey:deserialize(State#state.sk),
    HBBFT = hbbft:deserialize(State#state.hbbft, SK),
    State#state{hbbft=HBBFT, sk=SK}.

%% helper functions
fixup_msgs(Msgs) ->
    lists:map(fun({unicast, J, NextMsg}) ->
                      {unicast, J+1, term_to_binary(NextMsg)};
                 ({multicast, NextMsg}) ->
                      {multicast, term_to_binary(NextMsg)}
              end, Msgs).

maybe_deliver_deferred(State, Resp) ->
    {NewState, NewResp} = maybe_deliver_deferred(State#state{deferred=[]}, ok, State#state.deferred),
    {NewState, merge_resp(Resp, NewResp)}.

maybe_deliver_deferred(State, Resp, []) ->
    {State, Resp};
maybe_deliver_deferred(State, Resp, [{Index, Msg}|Tail]) ->
    case hbbft:handle_msg(State#state.hbbft, Index - 1, binary_to_term(Msg)) of
        {NewHBBFT, ok} ->
            %% XXX ACK group
            %lager:debug("HBBFT Status: ~p", [hbbft:status(NewHBBFT)]),
            undefer(State#state.id, Index, Msg),
            maybe_deliver_deferred(State#state{hbbft=NewHBBFT, deferred=State#state.deferred ++ Tail}, Resp);
        {NewHBBFT, defer} ->
            lager:warning("~p continuing to defer ~p from ~p", [State#state.id + 1, binary_to_term(Msg), Index]),
            %lager:warning("HBBFT Status: ~p", [hbbft:status(NewHBBFT)]),
            %% just put it back in the deferred list
            maybe_deliver_deferred(State#state{hbbft=NewHBBFT, deferred=State#state.deferred ++ [{Index, Msg}]}, Resp, Tail);
        {NewHBBFT, {send, Msgs}} ->
            %% XXX ACK group
            %lager:debug("HBBFT Status: ~p", [hbbft:status(NewHBBFT)]),
            undefer(State#state.id, Index, Msg),
            maybe_deliver_deferred(State#state{hbbft=NewHBBFT, deferred=State#state.deferred ++ Tail}, merge_resp(Resp, {send, fixup_msgs(Msgs)}));
        {NewHBBFT, {result, {transactions, Stamps, Txns}}} ->
            %% XXX ACK group
            undefer(State#state.id, Index, Msg),
            lager:info("Reached consensus"),
            lager:info("stamps ~p~n", [Stamps]),
            %lager:info("HBBFT Status: ~p", [hbbft:status(NewHBBFT)]),
            %% send agreed upon Txns to the parent blockchain worker
            %% the worker sends back its address, signature and txnstoremove which contains all or a subset of
            %% transactions depending on its buffer
            Round = hbbft:round(NewHBBFT),
            case miner:create_block(Stamps, Txns, Round) of
                {ok, Address, Artifact, Signature, TxnsToRemove} ->
                    %% call hbbft finalize round
                    NewerHBBFT = hbbft:finalize_round(NewHBBFT, TxnsToRemove),
                    Msgs = [{multicast, {signature, Round, Address, Signature}}],
                    maybe_deliver_deferred(State#state{hbbft=NewerHBBFT, artifact=Artifact}, merge_resp(Resp, {send, fixup_msgs(Msgs)}));
                {error, Reason} ->
                    %% this is almost certainly because we got the new block gossipped before we completed consensus locally
                    %% which is harmless
                    lager:warning("failed to create new block ~p", [Reason]),
                    maybe_deliver_deferred(State#state{hbbft=NewHBBFT}, Resp, Tail)
            end
    end.

undefer(Id, Index, Msg) ->
    lager:info("~p undeferred message ~p from ~p", [Id+1, binary_to_term(Msg), Index]),
    libp2p_group_relcast_server:send_ack(self(), Index).

merge_resp(ok, Resp) ->
    Resp;
merge_resp(Resp, ok) ->
    Resp;
merge_resp({send, A}, {send, B}) ->
    {send, A++B}.

enough_signatures(#state{artifact=undefined}) ->
    false;
enough_signatures(#state{signatures=Sigs, signatures_required=Count}) when length(Sigs) < Count ->
    false;
enough_signatures(#state{artifact=Artifact, members=Members, signatures=Signatures, signatures_required=Threshold}) ->
    %% filter out any signatures that are invalid or are not for a member of this DKG and dedup
    case blockchain_block:verify_signature(Artifact,
                                           Members,
                                           term_to_binary(Signatures),
                                           Threshold) of
        {true, ValidSignatures} ->
            %% So, this is a little dicey, if we don't need all N signatures, we might have competing subsets
            %% depending on message order. Given that the underlying artifact they're signing is the same though,
            %% it should be ok as long as we disregard the signatures for testing equality but check them for validity
            {ok, lists:sublist(lists:sort(ValidSignatures), Threshold)};
        false ->
            false
    end.


