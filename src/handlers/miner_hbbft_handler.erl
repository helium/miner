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
         sk :: tc_key_share:tc_key_share() | binary(),
         sigs_valid     = [] :: [blockchain_block:signature()],
         sigs_invalid   = [] :: [blockchain_block:signature()],
         sigs_unchecked = [] :: [blockchain_block:signature()],
         signatures_required = 0,
         sig_phase = unsent :: unsent | sig | gossip | done,
         artifact :: undefined | binary(),
         members :: [libp2p_crypto:pubkey_bin()],
         chain :: blockchain:blockchain(),
         last_round_signed = 0 :: non_neg_integer(),
         seen = #{} :: #{non_neg_integer() => boolean()},
         bba = <<>> :: binary(),

         %% For artifact re-signing on var-autoskip:
         swarm_keys :: {libp2p_crypto:pubkey(), libp2p_crypto:sig_fun()},
         skip_votes = #{} :: #{pos_integer() => pos_integer()}
        }).

-type hbbft_msg() ::
      hbbft_msg_signature()
    | hbbft_msg_signatures()
    | hbbft:acs_msg()
    | hbbft:dec_msg()
    | hbbft:sign_msg().

-type hbbft_msg_signature() ::
    {signature, Round :: pos_integer(), libp2p_crypto:pubkey_bin(), Sig :: binary()}.

-type hbbft_msg_signatures() ::
    {signatures, Round :: pos_integer(), [blockchain_block:signature()]}.

-spec metadata(V, M, C) -> binary()
    when V :: tuple | map,
         M :: #{} | #{seen => binary(), bba_completion => binary()},
         C :: blockchain:blockchain().
%% TODO No need to pass Meta when tuple. Use sum type: {map, Meta} | tuple
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
                                        Infos = blockchain_ledger_snapshot_v1:get_infos(Chain),
                                        case blockchain_ledger_snapshot_v1:snapshot(Ledger, Blocks, Infos) of
                                            {ok, Snapshot} ->
                                                {ok, _SnapHeight, SnapHash} = blockchain:add_snapshot(Snapshot, Chain),
                                                lager:info("snapshot hash is ~p", [SnapHash]),
                                                maps:put(snapshot_hash, SnapHash, ChainMeta0);
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
            t2b(maps:merge(Meta, ChainMeta))
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
    {ok, MyPubKey, SignFun, _ECDHFun} = blockchain_swarm:keys(),

    lager:info("HBBFT~p started~n", [Id]),
    {ok, #state{n = N,
                id = Id - 1,
                sk = SK,
                f = F,
                members = Members,
                signatures_required = N - F,
                hbbft = HBBFT,
                swarm_keys = {MyPubKey, SignFun},  % For re-signing on var-autoskip
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
handle_command(get_buf, State) ->
    {reply, {ok, hbbft:buf(State#state.hbbft)}, ignore};
handle_command({set_buf, Buf}, State) ->
    {reply, ok, [], State#state{hbbft = hbbft:buf(Buf, State#state.hbbft)}};
handle_command(stop, State) ->
    %% TODO add ignore support for this four tuple to use ignore
    lager:info("stop called without timeout"),
    {reply, ok, [{stop, 0}], State};
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
    SigMemIds = addr_sigs_to_mem_pos(State#state.sigs_valid, State),
    PubKeyHash = crypto:hash(sha256, term_to_binary(tc_pubkey:serialize(tc_key_share:public_key(State#state.sk)))),
    Worker ! {Ref, maps:merge(#{signatures_required =>
                                    max(State#state.signatures_required - length(SigMemIds), 0),
                                signatures => SigMemIds,
                                sig_phase => State#state.sig_phase,
                                last_round_signed => State#state.last_round_signed,
                                skip_votes => State#state.skip_votes,
                                artifact_hash => ArtifactHash,
                                public_key_hash => blockchain_utils:bin_to_hex(PubKeyHash)
                               }, maps:remove(sig_sent, Map))},
    {reply, ok, ignore};
handle_command(mark_done, _State) ->
    {reply, ok, ignore};
%% XXX this is a hack because we don't yet have a way to message this process other ways
handle_command(
    {next_round, NextRound, TxnsToRemove, _Sync},
    #state{chain=Chain, hbbft=HBBFT}=S
) ->
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
            Ledger = blockchain:ledger(Chain),
            Version = md_version(Ledger),
            Seen = blockchain_utils:map_to_bitvector(S#state.seen),
            HBBFT2 = hbbft:set_stamp_fun(?MODULE, metadata, [Version,
                                                             #{seen => Seen,
                                                               bba_completion => S#state.bba},
                                                             Chain], HBBFT1),
            case hbbft:next_round(HBBFT2, NextRound, []) of
                {HBBFT3, ok} ->
                    {reply, ok, [new_epoch], state_reset(HBBFT3, S)};
                {HBBFT3, {send, Msgs}} ->
                    {reply, ok, [new_epoch] ++ fixup_msgs(Msgs), state_reset(HBBFT3, S)}
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
handle_command(maybe_skip, State = #state{hbbft = HBBFT,
                                          id = MyIndex,
                                          skip_votes = Skips}) ->
    MyRound = hbbft:round(HBBFT),
    %% put in a fake local vote here for the case where we have no skips
    ProposedRound = median_not_taken(maps:merge(#{MyIndex => {0, MyRound}}, Skips)),
    lager:info("voting for round ~p", [ProposedRound]),
    {reply, ok, [{multicast, term_to_binary({proposed_skip, ProposedRound, MyRound})}], State};
handle_command(UnknownCommand, _State) ->
    lager:warning("Unknown command: ~p", [UnknownCommand]),
    {reply, ignored, ignore}.

-spec handle_message(binary(), pos_integer(), #state{}) ->
    defer | ignore | {#state{}, [RelcastMsg]} when
    RelcastMsg ::
          {multicast, binary()}
        | {unicast, pos_integer(), binary()}.
handle_message(<<BinMsgIn/binary>>, Index, #state{hbbft = HBBFT, skip_votes = Skips}=S0) ->
    CurRound = hbbft:round(HBBFT),
    case bin_to_msg(BinMsgIn) of
        %% Multiple sigs
        {ok, {signatures, SigRound, _   }} when SigRound > CurRound ->
            defer;
        {ok, {signatures, SigRound, _   }} when SigRound < CurRound ->
            ignore;
        {ok, {signatures, _, SigsIn}} ->
            handle_sigs({received, SigsIn}, S0);

        %% Single sig
        {ok, {signature, SigRound, _, _}} when SigRound > CurRound ->
            defer;
        {ok, {signature, SigRound, _, _}} when SigRound < CurRound ->
            ignore;
        {ok, {signature, _, Addr, Sig}} ->
            handle_sigs({received, [{Addr, Sig}]}, S0);

        {ok, {proposed_skip, ProposedRound, IndexRound}} when ProposedRound =/= CurRound ->
            lager:info("proposed skip to round ~p", [ProposedRound]),
            case process_skips(ProposedRound, IndexRound, S0#state.f, Index, Skips) of
                {skip, Skips1} ->
                    lager:info("skipping"),
                    %% ask for some time
                    miner:reset_late_block_timer(),
                    SkipGossip = {multicast, t2b({proposed_skip, ProposedRound, CurRound})},
                    %% skip but don't discard votes until we get a clean round
                    {HBBFT1, ToSend1} =
                        case hbbft:next_round(HBBFT, ProposedRound, []) of
                            {H1, ok} ->
                                {H1, []};
                            {H1, {send, NextMsgs}} ->
                                {H1, NextMsgs}
                        end,
                    {HBBFT2, ToSend2} =
                        case hbbft:start_on_demand(HBBFT1) of
                            {H2, already_started} ->
                                {H2, []};
                            {H2, {send, Msgs}} ->
                                {H2, Msgs}
                        end,
                    ToSend = fixup_msgs(ToSend1 ++ ToSend2),
                    %% we retain the skip votes here because we may not succeed and we want the
                    %% algorithm to converge more quickly in that case
                    {(state_reset(HBBFT2, S0))#state{skip_votes = Skips1},
                     [ new_epoch, SkipGossip ] ++ ToSend};
                {wait, Skips1} ->
                    lager:info("waiting: ~p", [Skips1]),
                    {S0#state{skip_votes = Skips1}, []}
            end;
        {ok, {proposed_skip, ProposedRound, IndexRound}} ->
            Skips1 = Skips#{Index => {ProposedRound, IndexRound}},
            {S0#state{skip_votes = Skips1}, []};
        %% Other
        {ok, MsgIn} ->
            handle_msg_hbbft(MsgIn, Index, S0);
        {error, truncated} ->
            lager:warning("got truncated message: ~p:", [BinMsgIn]),
            ignore
    end.

callback_message(_, _, _) -> none.

-spec handle_msg_hbbft(MsgHBBFT, pos_integer(), #state{}) ->
    defer | ignore | {#state{}, [MsgRelcast]} when
    MsgHBBFT :: hbbft:acs_msg() | hbbft:dec_msg() | hbbft:sign_msg(),
    MsgRelcast ::
          {multicast, binary()}
        | {unicast, pos_integer(), binary()}.
handle_msg_hbbft(Msg, Index, #state{hbbft=HBBFT0}=S0) ->
    S1 = S0#state{seen = (S0#state.seen)#{Index => true}},
    case hbbft:handle_msg(HBBFT0, Index - 1, Msg) of
        ignore ->
            ignore;
        {HBBFT1, ok} ->
            {S1#state{hbbft=HBBFT1}, []};
        {_, defer} ->
            defer;
        {HBBFT1, {send, MsgsOut}} ->
            {S1#state{hbbft=HBBFT1}, fixup_msgs(MsgsOut)};
        {HBBFT1, {result, {transactions, Metadata0, BinTxns}}} ->
            Metadata = lists:map(fun({Id, BMap}) -> {Id, binary_to_term(BMap)} end, Metadata0),
            Txns = [blockchain_txn:deserialize(B) || B <- BinTxns],
            CurRound = hbbft:round(HBBFT0),
            lager:info("Reached consensus ~p ~p", [Index, CurRound]),
            ?mark(done_protocol),
            %% send agreed upon Txns to the parent blockchain worker
            %% the worker sends back its address, signature and txnstoremove which contains all or a subset of
            %% transactions depending on its buffer
            NewRound = hbbft:round(HBBFT1),
            Before = erlang:monotonic_time(millisecond),
            case miner:create_block(Metadata, Txns, NewRound) of
                {ok,
                    #{
                        address               := Address,
                        unsigned_binary_block := Artifact,
                        signature             := Signature,
                        pending_txns          := PendingTxns,
                        invalid_txns          := InvalidTxns
                     }
                } ->
                    ?mark(block_success),
                    %% call hbbft finalize round
                    Duration = erlang:monotonic_time(millisecond) - Before,
                    lager:info("block creation for round ~p took: ~p ms", [NewRound, Duration]),
                    %% remove any pending txns or invalid txns from the buffer
                    BinTxnsToRemove = [blockchain_txn:serialize(T) || T <- PendingTxns ++ InvalidTxns],
                    HBBFT2 = hbbft:finalize_round(HBBFT1, BinTxnsToRemove),
                    Buf = hbbft:buf(HBBFT2),
                    %% do an async filter of the remaining txn buffer while we finish off the block
                    Buf1 = miner_hbbft_sidecar:prefilter_round(Buf, PendingTxns),
                    put(filtered, NewRound),
                    S2 = S1#state{
                        hbbft     = hbbft:buf(Buf1, HBBFT2),
                        sig_phase = sig,
                        bba       = make_bba(S1#state.n, Metadata),
                        artifact  = Artifact
                    },
                    ?mark(finalize_round),
                    handle_sigs({produced, {Address, Signature}, NewRound}, S2);
                {error, Reason} ->
                    ?mark(block_failure),
                    %% this is almost certainly because we got the new block gossipped before we completed consensus locally
                    %% which is harmless
                    lager:warning("failed to create new block ~p", [Reason]),
                    {S1#state{hbbft=HBBFT1}, []}
            end
    end.

-spec make_bba(non_neg_integer(), [{non_neg_integer(), _}]) -> binary().
make_bba(Sz, Metadata) ->
    %% note that BBA indices are 0 indexed, but bitvectors are 1 indexed
    %% so we correct that here
    M = maps:from_list([{Id + 1, true} || {Id, _} <- Metadata]),
    M1 = lists:foldl(fun(Id, Acc) ->
                             case Acc of
                                 #{Id := _} ->
                                     Acc;
                                 _ ->
                                     Acc#{Id => false}
                             end
                     end, M, lists:seq(1, Sz)),
    blockchain_utils:map_to_bitvector(M1).

-spec serialize(#state{}) -> #{atom() => binary()}.
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
                   ({skip_votes, _}, M) ->
                        M;
                   ({K, V}, M)->
                        VB = term_to_binary(V, [compressed]),
                        M#{K => VB}
                end,
                #{},
                lists:zip(Fields, StateList)).

-spec deserialize(binary() | #{atom() => binary()}) -> #state{}.
deserialize(BinState) when is_binary(BinState) ->
    State = binary_to_term(BinState),
    SK = tc_key_share:deserialize(State#state.sk),
    HBBFT = hbbft:deserialize(State#state.hbbft, SK),
    State#state{hbbft=HBBFT, sk=SK};
deserialize(#{sk := SKSer,
              hbbft := HBBFTSer} = StateMap) ->
    SK = tc_key_share:deserialize(binary_to_term(SKSer)),
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
             (skip_votes) ->
                  #{};
             (K)->
                  case StateMap of
                      #{K := V} when V /= undefined andalso
                                     V /= Bundef ->
                          binary_to_term(V);
                      _ when K == sig_phase ->
                          sig;
                      _ when K == seen ->
                          #{};
                      _ when K == sigs_valid ->
                          [];
                      _ when K == sigs_invalid ->
                          [];
                      _ when K == sigs_unchecked ->
                          [];
                      _ when K == last_round_signed ->
                          0;
                      _ when K == bba ->
                          <<>>;
                      _ ->
                          undefined
                  end
          end,
          Fields),
    list_to_tuple([state | DeserList]).

-spec restore(#state{}, #state{}) -> {ok, #state{}}.
restore(OldState, NewState) ->
    %% replace the stamp fun from the old state with the new one
    %% because we have non-serializable data in it (rocksdb refs)
    HBBFT = OldState#state.hbbft,
    {M, F, A} = hbbft:get_stamp_fun(NewState#state.hbbft),
    Buf = hbbft:buf(HBBFT),
    Buf1 = miner_hbbft_sidecar:new_round(Buf, []),
    HBBFT1 = hbbft:buf(Buf1, HBBFT),
    Chain = NewState#state.chain,
    SwarmKeys = NewState#state.swarm_keys,
    {ok, OldState#state{hbbft = hbbft:set_stamp_fun(M, F, A, HBBFT1),
                        chain=Chain, swarm_keys=SwarmKeys}}.

%% helper functions
-spec fixup_msgs([MsgIn]) -> [MsgOut] when
    MsgIn  :: {unicast, non_neg_integer(), term()}   | {multicast, term()},
    MsgOut :: {unicast, non_neg_integer(), binary()} | {multicast, binary()}.
fixup_msgs(Msgs) ->
    lists:map(fun({unicast, J, NextMsg}) ->
                      {unicast, J+1, msg_to_bin(NextMsg)};
                 ({multicast, NextMsg}) ->
                      {multicast, msg_to_bin(NextMsg)}
              end, Msgs).

%% @doc Finds unique member positions (if any) of addresses in the given
%% `{Address, Signature}' tuples.
%% @end
-spec addr_sigs_to_mem_pos([blockchain_block:signature()], #state{}) ->
    [pos_integer()].
addr_sigs_to_mem_pos(AddrSigs, #state{members=MemberAddresses}) ->
    lists:usort(positions([Addr || {Addr, _} <- AddrSigs], MemberAddresses)).

-spec positions([A], [A]) -> [pos_integer()].
positions(Unordered, Ordered) ->
    Positions = lists:zip(Ordered, lists:seq(1, length(Ordered))),
    FindPosition = fun (X) -> {_, I} = lists:keyfind(X, 1, Positions), I end,
    lists:map(FindPosition, Unordered).

-spec md_version(blockchain_ledger_v1:ledger()) -> map | tuple.
md_version(Ledger) ->
    case blockchain:config(?election_version, Ledger) of
        {ok, N} when N >= 3 ->
            map;
        _ ->
            tuple
    end.

-spec state_reset(hbbft:hbbft_data(), #state{}) -> #state{}.
state_reset(HBBFT, #state{}=S) ->
    %% default to the full bit vector, not the empty one
    DefaultBBAVote = blockchain_utils:map_to_bitvector(
                       maps:from_list([ {I, true}
                                        || I <- lists:seq(1, length(S#state.members))])),
    S#state{
        hbbft          = HBBFT,
        sigs_valid     = [],
        sigs_invalid   = [],
        sigs_unchecked = [],
        artifact       = undefined,
        sig_phase      = unsent,
        bba            = DefaultBBAVote,
        seen           = #{},
        skip_votes     = #{}
    }.

-spec handle_sigs(
    {received, [blockchain_block:signature()]}
    | {produced, blockchain_block:signature(), non_neg_integer()},
    #state{}
) ->
    {#state{}, [{multicast, binary()}]}.
handle_sigs(Given, #state{hbbft=HBBFT}=S0) ->
    SigsIn =
        case Given of
            {received, Sigs} -> Sigs;
            {produced, Sig, _} -> [Sig]
        end,
    CurRound = hbbft:round(HBBFT),
    case state_sigs_input(SigsIn, S0) of
        {{done, SigsOut}, S1} ->
            ?mark(done_sigs),
            MsgOut = msg_to_bin({signatures, CurRound, SigsOut}),
            {S1, [{multicast, MsgOut}]};
        {{gossip, SigsOut}, S1} ->
            ?mark(gossip_sigs),
            MsgOut = msg_to_bin({signatures, CurRound, SigsOut}),
            {S1, [{multicast, MsgOut}]};
        {pending, S1} ->
            MsgsOut =
                case Given of
                    {received, _} ->
                        [];
                    {produced, {SelfAddr, SelfSig}, NewRound} ->
                        [{multicast, {signature, NewRound, SelfAddr, SelfSig}}]
                end,
            {S1, fixup_msgs(MsgsOut)}
    end.

-spec state_sigs_input([blockchain_block:signature()], #state{}) ->
    {
        {done, [blockchain_block:signature()]}
        | {gossip, [blockchain_block:signature()]}
        | pending,
        #state{}
    }.
state_sigs_input(SigsIn, #state{hbbft=HBBFT}=S0) ->
    CurRound = hbbft:round(HBBFT),
    S1 = state_sigs_add(SigsIn, S0),
    S2 = state_sigs_retry_unchecked(S1),
    case state_sigs_check_if_enough(S2) of
        {{enough_for, {gossip, _}=Gossip}, S3} ->
            {Gossip, S3#state{sig_phase = gossip}};
        {
            {enough_for, {done, Sigs}=Done},
            #state{artifact = <<Art/binary>>, last_round_signed=LastRoundSigned}=S3
        } when CurRound > LastRoundSigned ->
            ok = miner:signed_block(Sigs, Art),
            S4 =
                S3#state{
                    last_round_signed = CurRound,
                    sig_phase = done
                },
            {Done, S4};
        {{enough_for, {done, _}}, S3} ->
            {pending, S3};
        {not_enough, S3} ->
            case state_sigs_maybe_switch_to_varless(S3) of
                {{varless, SigsVarless}, S4} ->
                    {{gossip, SigsVarless}, S4};
                {original, S4} ->
                    {pending, S4}
            end
    end.

-spec state_sigs_maybe_switch_to_varless(#state{}) ->
    {{varless, [blockchain_block:signature()]} | original, #state{}}.
state_sigs_maybe_switch_to_varless(
    #state{
        artifact     = <<_/binary>>,
        f            = F,
        sigs_invalid = SigsInvalid,
        swarm_keys   = {PubKey, SignFun}
    }=S0
) when length(SigsInvalid) >= F + 1 ->
    S1 = state_remove_var_txns_from_artifact(S0),
    SigsVarlesslyValid0 =
        lists:filter(
            fun ({_, _}=AddrSig) -> sig_is_valid(AddrSig, S1) end,
            SigsInvalid
        ),
    case length(SigsVarlesslyValid0) >= F + 1 of
        true ->
            #state{artifact = <<ArtVarless/binary>>} = S1,
            <<Addr/binary>> = libp2p_crypto:pubkey_to_bin(PubKey),
            <<Sig/binary>> = SignFun(ArtVarless),
            SigsVarlesslyValid1 = kvl_set(Addr, Sig, SigsVarlesslyValid0),
            S2 = S1#state{
                sigs_valid     = SigsVarlesslyValid1,
                sigs_invalid   = [],
                sigs_unchecked = []
            },
            lager:warning(
                "Autoskip to varlessly valid sigs from: ~p",
                [addr_sigs_to_mem_pos(SigsVarlesslyValid0, S2)]
                %% _not_ including self!
            ),
            {{varless, SigsVarlesslyValid1}, S2};
        false ->
            {original, S0}
    end;
state_sigs_maybe_switch_to_varless(#state{}=S) ->
    {original, S}.

-spec state_remove_var_txns_from_artifact(#state{}) ->
    #state{}.
state_remove_var_txns_from_artifact(#state{artifact=Art0}=S) ->
    Block0 = blockchain_block:deserialize(Art0),
    Block1 = blockchain_block_v1:remove_var_txns(Block0),
    Art1 = blockchain_block:serialize(Block1),
    S#state{artifact=Art1}.

-spec state_sigs_add([blockchain_block:signature()], #state{}) -> #state{}.
state_sigs_add(Sigs, #state{}=S) ->
    lists:foldl(fun state_sigs_add_one/2, S, Sigs).

-spec state_sigs_add_one(blockchain_block:signature(), #state{}) -> #state{}.
state_sigs_add_one({Addr, Sig}, #state{artifact = undefined, sigs_unchecked=Unchecked}=S) ->
    %% Provisionally accept signatures if we don't have the means to
    %% verify them yet. We'll retry verifying them later.
    S#state{sigs_unchecked = kvl_set(Addr, Sig, Unchecked)};
state_sigs_add_one({Addr, Sig}, #state{}=S) ->
    case sig_is_valid({Addr, Sig}, S) of
        true  -> S#state{sigs_valid   = kvl_set(Addr, Sig, S#state.sigs_valid)};
        false -> S#state{sigs_invalid = kvl_set(Addr, Sig, S#state.sigs_invalid)}
    end.

-spec state_sigs_retry_unchecked(#state{}) -> #state{}.
state_sigs_retry_unchecked(#state{artifact=undefined}=S0) ->
    S0;
state_sigs_retry_unchecked(#state{artifact = <<_/binary>>, sigs_unchecked = Unchecked}=S) ->
    state_sigs_add(Unchecked, S).

-spec state_sigs_check_if_enough(#state{}) ->
    {not_enough | {enough_for, Next}, #state{}} when
    Next ::
        {gossip, [blockchain_block:signature()]}
        | {done, [blockchain_block:signature()]}.
state_sigs_check_if_enough(#state{artifact=undefined}=S) ->
    {not_enough, S};
state_sigs_check_if_enough(#state{sig_phase = sig, sigs_valid = Sigs, f = F}=S) when length(Sigs) < F + 1 ->
    {not_enough, S};
state_sigs_check_if_enough(#state{sig_phase = done, sigs_valid = SigsValid}=S) ->
    {{enough_for, {done, SigsValid}}, S};
state_sigs_check_if_enough(
    #state{
        sig_phase = Phase,
        artifact = <<_/binary>>,
        f = F,
        sigs_valid = SigsValidAll,
        signatures_required = Threshold0
    }=S0
) ->
    Threshold1 =
        case Phase of
            sig -> F + 1;
            gossip -> Threshold0
        end,
    case
        length(SigsValidAll) =< (3*F)+1 andalso
        length(SigsValidAll) >= Threshold1
    of
        true ->
            %% So, this is a little dicey, if we don't need all N signatures,
            %% we might have competing subsets depending on message order.
            %% Given that the underlying artifact they're signing is the same
            %% though, it should be ok as long as we disregard the signatures
            %% for testing equality but check them for validity
            SigsValidRandSubset =
                lists:sublist(lists:sort(SigsValidAll), Threshold0),
            case Phase of
                gossip ->
                    {{enough_for, {done, SigsValidRandSubset}}, S0};
                sig ->
                    case length(SigsValidAll) >= Threshold0 of
                        true ->
                            {{enough_for, {done, SigsValidRandSubset}}, S0};
                        false ->
                            {{enough_for, {gossip, lists:sort(SigsValidAll)}}, S0}
                    end
            end;
        false ->
            {not_enough, S0}
    end.

-spec sig_is_valid(blockchain_block:signature(), #state{}) -> boolean().
sig_is_valid(
    {<<Addr/binary>>, <<Sig/binary>>}=AddrSig,
    #state{artifact=Art, members=MemberAddresses, hbbft=HBBFT}=S
) ->
    IsMember = lists:member(Addr, MemberAddresses),
    IsValid =
        IsMember
        andalso
        libp2p_crypto:verify(Art, Sig, libp2p_crypto:bin_to_pubkey(Addr)),
    case IsValid of
        true ->
            ok;
        false ->
            CurRound = hbbft:round(HBBFT),
            case IsMember of
                true ->
                    [MemId] = addr_sigs_to_mem_pos([AddrSig], S),
                    lager:warning("Invalid signature from member ~b in our round ~p", [MemId, CurRound]);
                false ->
                    lager:warning("Invalid signature from non-member ~s in our round ~p", [b58(Addr), CurRound])
            end
    end,
    IsValid.

-spec kvl_set(K, V, KVL) -> KVL when KVL :: [{K, V}].
kvl_set(K, V, KVL) ->
    lists:keystore(K, 1, KVL, {K, V}).

-spec b58(binary()) -> string().
b58(<<Bin/binary>>) ->
    libp2p_crypto:bin_to_b58(Bin).

%% do nothing if we've advanced
process_skips(Proposed, SenderRound, F, Sender, Votes) ->
    Votes1 = Votes#{Sender => {Proposed, SenderRound}},
    PropVotes = maps:fold(fun(_Sender, {Vote, _OwnRound}, Acc) when Vote =:= Proposed ->
                                  Acc + 1;
                             (_Sender, {_OtherVote, _OwnRound}, Acc) ->
                                  Acc
                          end,
                          0,
                          Votes1),
    %% equal here because we only want to go once, at the point of saturation
    case PropVotes == (2 * F) + 1 of
        true -> {skip, Votes1};
        false -> {wait, Votes1}
    end.

%% the idea here is to take a clean round that's higher than the median, which should be relatively
%% hard to manipulate by cheating
-spec median_not_taken(#{pos_integer() => {pos_integer(), pos_integer()}}) ->
                              pos_integer().
median_not_taken(Map) ->
    {_Votes, Rounds} = lists:unzip(maps:values(Map)),
    lager:info("rounds ~p", [lists:sort(Rounds)]),
    Median = miner_util:median(Rounds),
    search_lowest(Median, lists:sort(Rounds)).

%% once we have the median, we look for the lowest "hole" in the sorted list.  we need a fresh round
%% for everything to skip to or anything that's on the used round will not send any messages and
%% might have dirty state in its relcast.  this walks up the list until it finds a number that is
%% higher than the initial try and is not present on the list.
-spec search_lowest(pos_integer(), [pos_integer()]) -> pos_integer().
search_lowest(Try, []) ->
    Try;
%% skip past stuff below the median
search_lowest(Try, [Lower | Tail]) when Try > Lower ->
    search_lowest(Try, Tail);
%% we have a node on this round, and want the round to be fresh
search_lowest(Try, [Try | Tail]) ->
    search_lowest(Try + 1, Tail);
%% here, we should have the next gap that's larger than the median round
search_lowest(Try, [_OtherValue | _Tail]) ->
    Try.

-spec t2b(term()) -> binary().
t2b(Term) ->
    term_to_binary(Term, [{compressed, 1}]).

-spec msg_to_bin(hbbft_msg()) -> binary().
msg_to_bin(Msg) ->
    t2b(Msg).

-spec bin_to_msg(binary()) -> {ok, hbbft_msg()} | {error, truncated}.
bin_to_msg(<<Bin/binary>>) ->
    try
        {ok, binary_to_term(Bin)}
    catch _:_ ->
        {error, truncated}
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

positions_test() ->
    ?assertMatch([1], positions([a], [a]), "Position 1 of 1"),
    ?assertMatch([1], positions([a], [a, b]), "Position 1 of 2"),
    ?assertMatch([2], positions([b], [a, b, c]), "Position 2 of 3"),
    ?assertMatch([2, 2], positions([b, b], [a, b, c]), "Position 2,2 of 3").

search_lowest_test() ->
    ?assertMatch(33, search_lowest(33, []), "empty"),
    ?assertMatch(2, search_lowest(1, [1, 1, 1, 1, 41231231]), "ignore outliers"),
    ?assertMatch(6, search_lowest(3, [1, 2, 3, 4, 5]), "lowest untaken"),
    ?assertMatch(8, search_lowest(3, [1, 2, 3, 4, 5, 6, 7, 9]), "lowest untaken 2"),
    ?assertMatch(8, search_lowest(3, [1, 3, 4, 5, 6, 7, 9]), "lowest untaken 3"),
    ?assertMatch(2, search_lowest(1, [1, 1, 1, 1, 4]), "basic"),
    ?assertMatch(3, search_lowest(3, [1, 1, 1, 1, 4]), "don't go lower than try").

-endif.
