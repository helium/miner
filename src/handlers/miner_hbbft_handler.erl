%%%-------------------------------------------------------------------
%% @Dec
%% == miner hbbft_handler ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_hbbft_handler).

-behavior(relcast).

-export([
         init/1,
         handle_message/3, handle_command/2, callback_message/3,
         serialize/1, deserialize/1, restore/2,
         metadata/3
        ]).

-include_lib("blockchain/include/blockchain_vars.hrl").
-include("miner_util.hrl").

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
         sig_phase = unsent :: unsent | sig | gossip | done,
         artifact :: undefined | binary(),
         members :: [libp2p_crypto:pubkey_bin()],
         chain :: undefined | blockchain:blockchain(),
         signed = 0 :: non_neg_integer(),
         seen = #{} :: #{non_neg_integer() => boolean()},
         bba = <<>> :: binary()
        }).

metadata(Version, Meta, Chain) ->
    {ok, HeadHash} = blockchain:head_hash(Chain),
    %% construct a 2-tuple of the system time and the current head block hash as our stamp data
    case Version of
        tuple ->
            term_to_binary({erlang:system_time(seconds), HeadHash});
        map ->
            ChainMeta0 = #{timestamp => erlang:system_time(seconds), head_hash => HeadHash},
            {ok, Height} = blockchain:height(Chain),
            Ledger = blockchain:ledger(Chain),
            ChainMeta = case blockchain:config(?snapshot_interval, Ledger) of
                            {ok, Interval} ->
                                lager:debug("snapshot interval is ~p h ~p rem ~p",
                                            [Interval, Height, Height rem Interval]),
                                case Height rem Interval == 0 of
                                    true ->
                                        Blocks = blockchain_ledger_snapshot_v1:get_blocks(Chain),
                                        case blockchain_ledger_snapshot_v1:snapshot(Ledger, Blocks) of
                                            {ok, Snapshot} ->
                                                ok = blockchain:add_snapshot(Snapshot, Chain),
                                                SHA = blockchain_ledger_snapshot_v1:hash(Snapshot),
                                                lager:info("snapshot hash is ~p", [SHA]),
                                                maps:put(snapshot_hash, SHA, ChainMeta0);
                                            _Err ->
                                                lager:warning("error constructing snapshot ~p", [_Err]),
                                                ChainMeta0
                                        end;
                                    false ->
                                        ChainMeta0
                                end;
                            _ ->
                                lager:info("no snapshot interval configured"),
                                ChainMeta0
                        end,
            term_to_binary(maps:merge(Meta, ChainMeta))
    end.

init([Members, Id, N, F, BatchSize, SK, Chain]) ->
    init([Members, Id, N, F, BatchSize, SK, Chain, 0, []]);
init([Members, Id, N, F, BatchSize, SK, Chain, Round, Buf]) ->
    %% if we're first starting up, we don't know anything about the
    %% metadata.
    ?mark(init),
    Ledger0 = blockchain:ledger(Chain),
    Version = md_version(Ledger0),
    HBBFT = hbbft:init(SK, N, F, Id-1, BatchSize, 1500,
                       {?MODULE, metadata, [Version, #{}, Chain]}, Round, Buf),
    Ledger = blockchain_ledger_v1:new_context(Ledger0),
    Chain1 = blockchain:ledger(Ledger, Chain),

    lager:info("HBBFT~p started~n", [Id]),
    {ok, #state{n = N,
                id = Id - 1,
                sk = SK,
                f = F,
                members = Members,
                signatures_required = N - F,
                hbbft = HBBFT,
                chain = Chain1}}.

handle_command(start_acs, State) ->
    case hbbft:start_on_demand(State#state.hbbft) of
        {_HBBFT, already_started} ->
            ?mark(start_acs_already),
            {reply, ok, ignore};
        {NewHBBFT, {send, Msgs}} ->
            ?mark(start_acs_new),
            lager:notice("Started HBBFT round because of a block timeout"),
            {reply, ok, fixup_msgs(Msgs), State#state{hbbft=NewHBBFT}}
    end;
handle_command(have_key, State) ->
    {reply, hbbft:have_key(State#state.hbbft), [], State};
handle_command(get_buf, State) ->
    {reply, {ok, hbbft:buf(State#state.hbbft)}, ignore};
handle_command({set_buf, Buf}, State) ->
    {reply, ok, [], State#state{hbbft = hbbft:buf(Buf, State#state.hbbft)}};
handle_command(stop, State) ->
    %% TODO add ignore support for this four tuple to use ignore
    lager:info("stop called without timeout"),
    {reply, ok, [{stop, timer:minutes(1)}], State};
handle_command({stop, Timeout}, State) ->
    %% TODO add ignore support for this four tuple to use ignore
    lager:info("stop called with timeout: ~p", [Timeout]),
    {reply, ok, [{stop, Timeout}], State};
handle_command({status, Ref, Worker}, State) ->
    Map = hbbft:status(State#state.hbbft),
    ArtifactHash = case State#state.artifact of
                       undefined -> undefined;
                       A -> blockchain_utils:bin_to_hex(crypto:hash(sha256, A))
                   end,
    Sigs = map_ids(State#state.signatures, State#state.members),
    Worker ! {Ref, maps:merge(#{signatures_required =>
                                    max(State#state.signatures_required - length(Sigs), 0),
                                signatures => Sigs,
                                sig_phase => State#state.sig_phase,
                                artifact_hash => ArtifactHash,
                                public_key_hash => blockchain_utils:bin_to_hex(crypto:hash(sha256, term_to_binary(tpke_pubkey:serialize(tpke_privkey:public_key(State#state.sk)))))
                               }, maps:remove(sig_sent, Map))},
    {reply, ok, ignore};
handle_command({skip, Ref, Worker}, State) ->
    Chain = blockchain_worker:blockchain(),
    Version = md_version(blockchain:ledger(Chain)),
    HBBFT = hbbft:set_stamp_fun(?MODULE, metadata, [Version, #{}, Chain], State#state.hbbft),
    ?mark(skip),
    case hbbft:next_round(HBBFT) of
        {NextHBBFT, ok} ->
            Worker ! {Ref, ok},
            {reply, ok, [new_epoch],
             State#state{hbbft=NextHBBFT, signatures=[], artifact=undefined, sig_phase=unsent,
                         bba = <<>>, seen = #{}}};
        {NextHBBFT, {send, NextMsgs}} ->
            {reply, ok, [new_epoch | fixup_msgs(NextMsgs)],
             State#state{hbbft=NextHBBFT, signatures=[], artifact=undefined, sig_phase=unsent,
                         bba = <<>>, seen = #{}}}
    end;
handle_command(mark_done, _State) ->
    {reply, ok, ignore};
%% XXX this is a hack because we don't yet have a way to message this process other ways
handle_command({next_round, NextRound, TxnsToRemove, _Sync}, State=#state{hbbft=HBBFT}) ->
    PrevRound = hbbft:round(HBBFT),
    case NextRound - PrevRound of
        N when N > 0 ->
            %% we've advanced to a new round, we need to destroy the old ledger context
            %% (with the old speculatively absorbed changes that may now be invalid/stale)
            %% and create a new one, and then use that new context to filter the pending
            %% transactions to remove any that have become invalid
            lager:info("Advancing from PreviousRound: ~p to NextRound ~p and emptying hbbft buffer",
                       [PrevRound, NextRound]),
            ?mark(next_round),
            HBBFT1 =
                case get(filtered) of
                    Done when Done == NextRound ->
                        HBBFT;
                    _ ->
                        Buf = hbbft:buf(HBBFT),
                        BinTxnsToRemove = [blockchain_txn:serialize(T) || T <- TxnsToRemove],
                        Buf1 = miner_hbbft_sidecar:new_round(Buf, BinTxnsToRemove),
                        hbbft:buf(Buf1, HBBFT)
                end,
            Chain = blockchain_worker:blockchain(),
            Ledger = blockchain:ledger(Chain),
            Version = md_version(Ledger),
            Seen = blockchain_utils:map_to_bitvector(State#state.seen),
            HBBFT2 = hbbft:set_stamp_fun(?MODULE, metadata, [Version,
                                                             #{seen => Seen,
                                                               bba_completion => State#state.bba},
                                                             Chain], HBBFT1),
            case hbbft:next_round(HBBFT2, NextRound, []) of
                {NextHBBFT, ok} ->
                    {reply, ok, [ new_epoch ], State#state{hbbft=NextHBBFT, signatures=[],
                                                           artifact=undefined, sig_phase=unsent,
                                                           bba = <<>>, seen = #{}}};
                {NextHBBFT, {send, NextMsgs}} ->
                    {reply, ok, [ new_epoch ] ++ fixup_msgs(NextMsgs),
                     State#state{hbbft=NextHBBFT, signatures=[], artifact=undefined, sig_phase=unsent,
                                 bba = <<>>, seen = #{}}}
            end;
        0 ->
            lager:warning("Already at the current Round: ~p", [NextRound]),
            {reply, ok, ignore};
        _ ->
            lager:warning("Cannot advance to NextRound: ~p from PrevRound: ~p", [NextRound, PrevRound]),
            {reply, error, ignore}
    end;
%% these are coming back from the sidecar, they don't need to be
%% validated further.
handle_command({txn, Txn}, State=#state{hbbft=HBBFT}) ->
    Buf = hbbft:buf(HBBFT),
    case lists:member(blockchain_txn:serialize(Txn), Buf) of
        true ->
            {reply, ok, ignore};
        false ->
            case hbbft:input(State#state.hbbft, blockchain_txn:serialize(Txn)) of
                {NewHBBFT, ok} ->
                    {reply, ok, [], State#state{hbbft=NewHBBFT}};
                {_HBBFT, full} ->
                    {reply, {error, full}, ignore};
                {NewHBBFT, {send, Msgs}} ->
                    {reply, ok, fixup_msgs(Msgs), State#state{hbbft=NewHBBFT}}
            end
    end;
handle_command(_, _State) ->
    {reply, ignored, ignore}.

handle_message(BinMsg, Index, State=#state{hbbft = HBBFT}) ->
    Msg = binary_to_term(BinMsg),
    %lager:info("HBBFT input ~s from ~p", [fakecast:print_message(Msg), Index]),
    Round = hbbft:round(HBBFT),
    case Msg of
        {signatures, R, _Signatures} when R > Round ->
            defer;
        {signatures, R, _Signatures} when R < Round ->
            ignore;
        {signatures, _R, Signatures} ->
            Sigs = dedup_signatures(Signatures, State),
            NewState = State#state{signatures = Sigs},
            case enough_signatures(NewState) of
                {ok, done, MySignatures} when Round > NewState#state.signed ->
                    ?mark(done_sigs),
                    %% no point in doing this more than once
                    ok = miner:signed_block(MySignatures, State#state.artifact),
                    {NewState#state{signed = Round, sig_phase = done},
                     [{multicast, term_to_binary({signatures, Round, MySignatures})}]};
                {ok, gossip, MySignatures} ->
                    {NewState#state{sig_phase = gossip},
                     [{multicast, term_to_binary({signatures, Round, MySignatures})}]};
                _ ->
                    {NewState, []}
            end;
        {signature, R, Address, Signature} ->
            case R == Round andalso lists:member(Address, State#state.members) andalso
                 %% provisionally accept signatures if we don't have the means to verify them yet, they get filtered later
                 (State#state.artifact == undefined orelse libp2p_crypto:verify(State#state.artifact, Signature, libp2p_crypto:bin_to_pubkey(Address))) of
                true ->
                    NewState = State#state{signatures=lists:keystore(Address, 1, State#state.signatures, {Address, Signature})},
                    case enough_signatures(NewState) of
                        {ok, done, Signatures} when Round > NewState#state.signed ->
                            ?mark(done_sigs),
                            %% no point in doing this more than once
                            ok = miner:signed_block(Signatures, State#state.artifact),
                            {NewState#state{signed = Round, sig_phase = done},
                             [{multicast, term_to_binary({signatures, Round, Signatures})}]};
                        {ok, gossip, Signatures} ->
                            ?mark(gossip_sigs),
                            {NewState#state{sig_phase = gossip},
                             [{multicast, term_to_binary({signatures, Round, Signatures})}]};
                        _ ->
                            {NewState, []}
                    end;
                false when R > Round ->
                    defer;
                false when R < Round ->
                    %% don't log on late sigs
                    ignore;
                false ->
                    lager:warning("Invalid signature ~p from ~p for round ~p in our round ~p", [Signature, Address, R, Round]),
                    lager:warning("member? ~p", [lists:member(Address, State#state.members)]),
                    lager:warning("valid? ~p", [libp2p_crypto:verify(State#state.artifact, Signature, libp2p_crypto:bin_to_pubkey(Address))]),
                    %% invalid signature somehow
                    ignore
            end;
        _ ->
            Seen = (State#state.seen)#{Index => true},
            case hbbft:handle_msg(HBBFT, Index - 1, Msg) of
                ignore -> ignore;
                {NewHBBFT, ok} ->
                    {State#state{hbbft=NewHBBFT, seen = Seen}, []};
                {_, defer} ->
                    defer;
                {NewHBBFT, {send, Msgs}} ->
                    {State#state{hbbft=NewHBBFT, seen = Seen}, fixup_msgs(Msgs)};
                {NewHBBFT, {result, {transactions, Metadata0, BinTxns}}} ->
                    Metadata = lists:map(fun({Id, BMap}) -> {Id, binary_to_term(BMap)} end, Metadata0),
                    Txns = [blockchain_txn:deserialize(B) || B <- BinTxns],
                    lager:info("Reached consensus ~p ~p", [Index, Round]),
                    ?mark(done_protocol),
                    %% send agreed upon Txns to the parent blockchain worker
                    %% the worker sends back its address, signature and txnstoremove which contains all or a subset of
                    %% transactions depending on its buffer
                    NewRound = hbbft:round(NewHBBFT),
                    Before = erlang:monotonic_time(millisecond),
                    case miner:create_block(Metadata, Txns, NewRound) of
                        {ok, Address, Artifact, Signature, PendingTxns, InvalidTxns} ->
                            ?mark(block_success),
                            %% call hbbft finalize round
                            Duration = erlang:monotonic_time(millisecond) - Before,
                            lager:info("block creation for round ~p took: ~p ms", [NewRound, Duration]),
                            %% remove any pending txns or invalid txns from the buffer
                            BinTxnsToRemove = [blockchain_txn:serialize(T) || T <- PendingTxns ++ InvalidTxns],
                            NewerHBBFT = hbbft:finalize_round(NewHBBFT, BinTxnsToRemove),
                            Buf = hbbft:buf(NewerHBBFT),
                            %% do an async filter of the remaining txn buffer while we finish off the block
                            Buf1 = miner_hbbft_sidecar:prefilter_round(Buf, PendingTxns),
                            NewerHBBFT1 = hbbft:buf(Buf1, NewerHBBFT),
                            put(filtered, NewRound),
                            Msgs = [{multicast, {signature, NewRound, Address, Signature}}],
                            BBA = make_bba(State#state.n, Metadata),
                            NewState = filter_signatures(State#state{hbbft = NewerHBBFT1, sig_phase = sig, bba = BBA,
                                                                     signatures=lists:keystore(Address, 1, State#state.signatures, {Address, Signature}),
                                                                     seen = Seen, artifact = Artifact}),
                            ?mark(finalize_round),
                            case enough_signatures(NewState) of
                                {ok, done, Signatures} when Round > NewState#state.signed ->
                                    %% no point in doing this more than once
                                    ok = miner:signed_block(Signatures, State#state.artifact),
                                    {NewState#state{signed = Round, sig_phase = done, seen = Seen},
                                     [{multicast, term_to_binary({signatures, Round, Signatures})}]};
                                {ok, gossip, Signatures} ->
                                    {NewState#state{sig_phase = gossip, seen = Seen},
                                     [{multicast, term_to_binary({signatures, Round, Signatures})}]};
                                _ ->
                                    {NewState#state{seen = Seen}, fixup_msgs(Msgs)}
                            end;
                        {error, Reason} ->
                            ?mark(block_failure),
                            %% this is almost certainly because we got the new block gossipped before we completed consensus locally
                            %% which is harmless
                            lager:warning("failed to create new block ~p", [Reason]),
                            {State#state{hbbft=NewHBBFT, seen = Seen}, []}
                    end
            end
    end.

callback_message(_, _, _) -> none.

make_bba(Sz, Metadata) ->
    M = maps:from_list([{Id, true} || {Id, _} <- Metadata]),
    M1 = lists:foldl(fun(Id, Acc) ->
                             case Acc of
                                 #{Id := _} ->
                                     Acc;
                                 _ ->
                                     Acc#{Id => false}
                             end
                     end, M, lists:seq(1, Sz)),
    blockchain_utils:map_to_bitvector(M1).

serialize(State) ->
    {SerializedHBBFT, SerializedSK} = hbbft:serialize(State#state.hbbft, true),
    Fields = record_info(fields, state),
    StateList0 = tuple_to_list(State),
    StateList = tl(StateList0),
    lists:foldl(fun({K = hbbft, _}, M) ->
                        M#{K => SerializedHBBFT};
                   ({K = sk, _}, M) ->
                        M#{K => term_to_binary(SerializedSK,  [compressed])};
                   ({chain, _}, M) ->
                        M;
                   ({K, V}, M)->
                        VB = term_to_binary(V, [compressed]),
                        M#{K => VB}
                end,
                #{},
                lists:zip(Fields, StateList)).

deserialize(BinState) when is_binary(BinState) ->
    State = binary_to_term(BinState),
    SK = tpke_privkey:deserialize(State#state.sk),
    HBBFT = hbbft:deserialize(State#state.hbbft, SK),
    State#state{hbbft=HBBFT, sk=SK};
deserialize(#{sk := SKSer,
              hbbft := HBBFTSer} = StateMap) ->
    SK = tpke_privkey:deserialize(binary_to_term(SKSer)),
    HBBFT = hbbft:deserialize(HBBFTSer, SK),
    Fields = record_info(fields, state),
    Bundef = term_to_binary(undefined, [compressed]),
    DeserList =
        lists:map(
          fun(hbbft) ->
                  HBBFT;
             (sk) ->
                  SK;
             (chain) ->
                  undefined;
             (K)->
                  case StateMap of
                      #{K := V} when V /= undefined andalso
                                     V /= Bundef ->
                          binary_to_term(V);
                      _ when K == sig_phase ->
                          sig;
                      _ when K == seen ->
                          #{};
                      _ when K == bba ->
                          <<>>;
                      _ ->
                          undefined
                  end
          end,
          Fields),
    list_to_tuple([state | DeserList]).

restore(OldState, NewState) ->
    %% replace the stamp fun from the old state with the new one
    %% because we have non-serializable data in it (rocksdb refs)
    HBBFT = OldState#state.hbbft,
    {M, F, A} = hbbft:get_stamp_fun(NewState#state.hbbft),
    Buf = hbbft:buf(HBBFT),
    Buf1 = miner_hbbft_sidecar:new_round(Buf, []),
    HBBFT1 = hbbft:buf(Buf1, HBBFT),
    {ok, OldState#state{hbbft = hbbft:set_stamp_fun(M, F, A, HBBFT1)}}.

%% helper functions
fixup_msgs(Msgs) ->
    lists:map(fun({unicast, J, NextMsg}) ->
                      {unicast, J+1, term_to_binary(NextMsg)};
                 ({multicast, NextMsg}) ->
                      {multicast, term_to_binary(NextMsg)}
              end, Msgs).

dedup_signatures(InSigs, #state{signatures = Sigs}) ->
    %% favor existing sigs, in case they differ, but don't revalidate
    %% at this point
    lists:usort(Sigs ++ InSigs).

enough_signatures(#state{artifact=undefined}) ->
    false;
enough_signatures(#state{sig_phase = sig, signatures = Sigs, f = F}) when length(Sigs) < F + 1 ->
    false;
enough_signatures(#state{sig_phase = done, signatures = Signatures}) ->
    {ok, done, Signatures};
enough_signatures(#state{sig_phase = Phase, artifact = Artifact, members = Members,
                         f = F, signatures = Signatures, signatures_required = Threshold0}) ->
    Threshold = case Phase of
                    sig -> F + 1;
                    gossip -> Threshold0
                end,

    %% filter out any signatures that are invalid or are not for a member of this DKG and dedup
    case blockchain_block:verify_signatures(blockchain_block:deserialize(Artifact),
                                            Members,
                                            Signatures,
                                            Threshold) of
        {true, ValidSignatures} ->
            %% So, this is a little dicey, if we don't need all N signatures, we might have competing subsets
            %% depending on message order. Given that the underlying artifact they're signing is the same though,
            %% it should be ok as long as we disregard the signatures for testing equality but check them for validity
            case Phase of
                gossip ->
                    {ok, done, lists:sublist(lists:sort(ValidSignatures), Threshold0)};
                sig ->
                    case length(ValidSignatures) >= Threshold0 of
                        true ->
                            {ok, done, lists:sublist(lists:sort(ValidSignatures), Threshold0)};
                        false ->
                            {ok, gossip, lists:sort(ValidSignatures)}
                    end
            end;
        false ->
            false
    end.

filter_signatures(State=#state{artifact=Artifact, signatures=Signatures, members=Members}) ->
    FilteredSignatures = lists:filter(fun({Address, Signature}) ->
                         lists:member(Address, Members) andalso
                         libp2p_crypto:verify(Artifact, Signature, libp2p_crypto:bin_to_pubkey(Address))
                 end, Signatures),
    State#state{signatures=FilteredSignatures}.

map_ids(Sigs, Members0) ->
    Members = lists:zip(Members0, lists:seq(1, length(Members0))),
    IDs = lists:map(fun({Addr, _Sig}) ->
                            %% find member index
                            {_, ID} = lists:keyfind(Addr, 1, Members),
                            ID
                    end,
                    Sigs),
    lists:usort(IDs).

md_version(Ledger) ->
    case blockchain:config(?election_version, Ledger) of
        {ok, N} when N >= 3 ->
            map;
        _ ->
            tuple
    end.
