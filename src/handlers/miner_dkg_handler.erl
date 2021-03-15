%%%-------------------------------------------------------------------
%% @doc
%% == miner dkg_handler ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_dkg_handler).

-behavior(relcast).

-export([init/1, handle_message/3, handle_command/2, callback_message/3, serialize/1, deserialize/1, restore/2]).

-record(state,
        {
         n :: non_neg_integer(),
         f :: non_neg_integer(),
         t :: non_neg_integer(),
         id :: non_neg_integer(),
         dkg :: dkg_hybriddkg:dkg() | dkg_hybriddkg:serialized_dkg(),
         curve :: atom(),
         g1 :: erlang_pbc:element() | binary(),
         g2 :: erlang_pbc:element() | binary(),
         privkey :: undefined | tpke_privkey:privkey() | tpke_privkey:privkey_serialized(),
         members = [] :: [libp2p_crypto:address()],
         artifact :: binary(),
         signatures = [] :: [{libp2p_crypto:address(), binary()}],
         signatures_required :: pos_integer(),
         sigmod :: atom(),
         sigfun :: atom(),
         donemod :: atom(),
         donefun :: atom(),
         done_called = false :: boolean(),
         done_acked = false :: boolean(),
         sent_conf = false :: boolean(),
         dkg_completed = false :: boolean(),
         height :: pos_integer(),
         delay :: non_neg_integer()
        }).

init([Members, Id, N, F, T, Curve,
      ThingToSign,
      {SigMod, SigFun},
      {DoneMod, DoneFun}, Round,
      Height, Delay]) ->
    {G1, G2} = generate(Curve, Members),
    %% get the fun used to sign things with our swarm key
    {ok, _, ReadySigFun, _ECDHFun} = blockchain_swarm:keys(),
    DKG = dkg_hybriddkg:init(Id, N, F, T, G1, G2, Round, [{callback, true}, {elections, false},
                                                          {signfun, ReadySigFun},
                                                          {verifyfun, mk_verification_fun(Members)}]),
    lager:info("DKG~p started", [Id]),
    {ok, #state{n = N,
                id = Id,
                f = F,
                t = T,
                g1 = G1, g2 = G2,
                curve = Curve,
                dkg = DKG,
                signatures_required = N,
                artifact = ThingToSign,
                sigmod = SigMod, sigfun = SigFun,
                donemod = DoneMod, donefun = DoneFun,
                members = Members,
                height = Height,
                delay = Delay}}.

handle_command(start, State) ->
    {NewDKG, {send, Msgs}} = dkg_hybriddkg:start(State#state.dkg),
    {reply, ok, fixup_msgs(Msgs), State#state{dkg=NewDKG}};
handle_command(get_info, #state{privkey = undefined} = State) ->
    {reply, {error, not_done}, [], State};
handle_command(get_info, #state{privkey = PKey, members = Members} = State) ->
    {reply, {ok, PKey, Members}, [], State};
handle_command(stop, State) ->
    {reply, ok, [{stop, 0}], State};
handle_command({stop, _Timeout}, #state{privkey = PKey, done_acked = false} = State)
  when PKey /= undefined ->
    {reply, {error, not_done}, [], State};
handle_command({stop, Timeout}, State) ->
    {reply, ok, [{stop, Timeout}], State};
handle_command(mark_done, State) ->
    {reply, ok, [], State#state{done_called = true, done_acked = true}};
handle_command(status, State) ->
    Map = dkg_hybriddkg:status(State#state.dkg),
    MembersWithIndex = lists:zip(lists:seq(1, State#state.n), State#state.members),
    MissingSignatures = lists:foldl(fun({Id, M}, Acc) ->
                                            case lists:keymember(M, 1, State#state.signatures) of
                                                true ->
                                                    Acc;
                                                false ->
                                                    [Id | Acc]
                                            end
                                    end, [], MembersWithIndex),
    Map1 = maps:merge(#{
                        id => State#state.id,
                        members => State#state.members,
                        signatures_required => State#state.signatures_required,
                        signatures => length(State#state.signatures),
                        missing_signatures_from => lists:reverse(MissingSignatures),
                        dkg_completed => State#state.dkg_completed,
                        sent_conf => State#state.sent_conf
                       }, Map),
    {reply, Map1, ignore}.

handle_message(BinMsg, Index, State=#state{n = N, t = T,
                                           curve = Curve,
                                           g1 = G1, g2 = G2,
                                           members = Members,
                                           signatures = Sigs,
                                           height = Height, delay = Delay,
                                           sigmod = SigMod, sigfun = SigFun,
                                           donemod = DoneMod, donefun = DoneFun}) ->
    Msg = binary_to_term(BinMsg),
    %lager:info("DKG input ~s from ~p", [fakecast:print_message(Msg), Index]),
    case Msg of
        {conf, InSigs} when State#state.done_called == false ->
            lager:debug("got conf from ~p with ~p", [Index, length(InSigs)]),
            GoodSignatures = lists:foldl(fun({Address, Signature}, Acc) ->
                                        %% only check signatures from members we have not already verified and have not already appeared in this list
                                        case {lists:keymember(Address, 1, Acc) == false andalso
                                             lists:member(Address, Members),
                                            libp2p_crypto:verify(State#state.artifact, Signature, libp2p_crypto:bin_to_pubkey(Address))} of
                                            {true, true} ->
                                                lager:debug("adding sig from conf"),
                                                [{Address, Signature}|Acc];
                                            {true, false} ->
                                                lager:debug("got invalid signature ~p from ~p", [Signature, Address]),
                                                Acc;
                                            {false, _} ->
                                                Acc
                                        end
                                end, Sigs, InSigs),
            case length(GoodSignatures) == State#state.signatures_required of
                true when State#state.done_called == false ->
                    lager:debug("good len ~p sigs ~p", [length(GoodSignatures), GoodSignatures]),
                    %% This now an async cast but we don't consider the handoff complete until
                    %% we have gotten a `mark_done' message from the consensus manager
                    ok = DoneMod:DoneFun(State#state.artifact, GoodSignatures,
                                         Members, State#state.privkey, Height, Delay),
                    %% rebroadcast the final set of signatures and stop the handler
                    {State#state{done_called = true, sent_conf = true,
                                 signatures = GoodSignatures},
                     [{multicast, t2b({conf, GoodSignatures})}]};
                true ->
                    lager:debug("already done"),
                    {State, []};
                _ ->
                    lager:debug("not done, conf have ~p", [length(GoodSignatures)]),
                    {State#state{signatures=GoodSignatures}, []}
            end;
        {conf, _} ->
            %% don't bother, we've already completed and sent a conf message
            ignore;
        {signature, Address, Signature} when State#state.done_called == false ->
            case {lists:member(Address, Members) andalso %% valid signatory
                 not lists:keymember(Address, 1, Sigs), %% not a duplicate
                 libp2p_crypto:verify(State#state.artifact, Signature, libp2p_crypto:bin_to_pubkey(Address))} %% valid signature
            of
                {true, true} ->
                    lager:debug("got good sig ~p from ~p, have ~p", [Signature, Index,
                                                                    length(State#state.signatures) + 1]),
                    NewState = State#state{signatures=[{Address, Signature}|State#state.signatures]},
                    case length(NewState#state.signatures) == State#state.signatures_required of
                        true when State#state.sent_conf == false ->
                            lager:debug("enough 1 ~p", [length(NewState#state.signatures)]),
                            %% This now an async cast but we don't consider the handoff complete until
                            %% we have gotten a `mark_done' message from the consensus manager
                            ok = DoneMod:DoneFun(State#state.artifact, NewState#state.signatures,
                                                 Members, State#state.privkey, Height, Delay),
                            {NewState#state{done_called = true},
                             [{multicast, t2b({conf, NewState#state.signatures})}]};
                        false ->
                            lager:debug("not enough ~p/~p - ~p", [length(NewState#state.signatures), length(Members), State#state.signatures_required]),
                            {NewState, []}
                    end;
                {false, _} ->
                    %% duplicate, this is ok
                    {State, []};
                {true, false} ->
                    lager:warning("got invalid signature ~p from ~p", [Signature, Address]),
                    {State, []}
            end;
        {signature, _Address, _Signature} ->
            %% we have already completed
            ignore;
        _ ->
            case dkg_hybriddkg:handle_msg(State#state.dkg, Index, Msg) of
                %% NOTE: We cover all possible return values from handle_msg hence
                %% eliminating the need for a final catch-all clause
                {_, ignore} ->
                    % lager:info("ignoring ~p", [Msg]),
                    ignore;
                {NewDKG, ok} ->
                    {State#state{dkg=NewDKG}, []};
                {NewDKG, {send, Msgs}} ->
                    {State#state{dkg=NewDKG}, fixup_msgs(Msgs)};
                {NewDKG, start_timer} ->
                    %% this is unused, as it's used to time out DKG elections which we're not doing
                    {State#state{dkg=NewDKG}, []};
                {NewDKG, {result, {Shard, VK, VKs}}} when State#state.privkey == undefined ->
                    lager:info("Completed DKG ~p", [State#state.id]),
                    PrivateKey = tpke_privkey:init(tpke_pubkey:init(N, T, G1, G2, VK, VKs, Curve),
                                                   Shard, State#state.id - 1),
                    %% We need to accumulate `Threshold` count ECDSA signatures over
                    %% the provided artifact.  The artifact is (just once) going to be
                    %% a genesis block, the other times it will be the evidence an
                    %% election was run.
                    {Address, Signature, Threshold} =
                        case SigMod:SigFun(State#state.artifact, PrivateKey) of
                            {ok, A, S, Th} ->
                                {A, S, Th};
                            {ok, A, S} ->
                                %% don't change the signature threshold, leave it as
                                %% the default of N
                                Th = State#state.signatures_required,
                                {A, S, Th}
                        end,
                    {State#state{dkg=NewDKG, privkey=PrivateKey,
                                 signatures_required=Threshold,
                                 dkg_completed=true,
                                 signatures=[{Address, Signature}|State#state.signatures]},
                     [{multicast, t2b({signature, Address, Signature})}]};
                {_NewDKG, {result, {_Shard, _VK, _VKs}}} ->
                    lager:info("dkg completed again?"),
                    ignore
            end
    end.

callback_message(Actor, Message, _State) ->
    case binary_to_term(Message) of
        {Id, {send, {Session, SerializedCommitment, Shares}}} ->
            t2b({Id, {send, {Session, SerializedCommitment, lists:nth(Actor, Shares)}}});
        {Id, {echo, {Session, SerializedCommitment, Shares}}} ->
            t2b({Id, {echo, {Session, SerializedCommitment, lists:nth(Actor, Shares)}}});
        {Id, {ready, {Session, SerializedCommitment, Shares, Proof}}} ->
            t2b({Id, {ready, {Session, SerializedCommitment, lists:nth(Actor, Shares), Proof}}})
    end.

%% helper functions
serialize(State) ->
    #state{dkg = DKG0,
           g1 = G1_0, g2 = G2_0,
           privkey = PrivKey0,
           n = N,
           f = F,
           t = T,
           id = ID,
           curve = Curve,
           members = Members,
           artifact = Artifact,
           signatures = Sigs,
           signatures_required = SigsRequired,
           sigmod = SigMod,
           sigfun = SigFun,
           donemod = DoneMod,
           donefun = DoneFun,
           done_called = DoneCalled,
           done_acked = DoneAcked,
           sent_conf = SentConf,
           height = Height,
           delay = Delay} = State,
    SerializedDKG = dkg_hybriddkg:serialize(DKG0),
    G1 = erlang_pbc:element_to_binary(G1_0),
    G2 = erlang_pbc:element_to_binary(G2_0),
    PreSer = #{g1 => G1, g2 => G2},
    PrivKey =
        case PrivKey0 of
            undefined ->
                undefined;
            Other ->
                tpke_privkey:serialize(Other)
        end,
    M0 = #{dkg => SerializedDKG,
           privkey => PrivKey,
           n => N,
           f => F,
           t => T,
           id => ID,
           curve => Curve,
           members => Members,
           artifact => Artifact,
           signatures => Sigs,
           signatures_required => SigsRequired,
           sigmod => SigMod,
           sigfun => SigFun,
           donemod => DoneMod,
           donefun => DoneFun,
           done_called => DoneCalled,
           done_acked => DoneAcked,
           sent_conf => SentConf,
           height => Height,
           delay => Delay},
    M = maps:map(fun(_K, Term) -> t2b(Term) end, M0),
    maps:merge(PreSer, M).

%% to make dialyzer happy till I fix the relcast typing
deserialize(_Bin) when is_binary(_Bin) ->
    {error, format_deprecated};
deserialize(MapState0) when is_map(MapState0) ->
    MapState = maps:map(fun(g1, B) ->
                                B;
                           (g2, B) ->
                                B;
                           (_K, undefined) ->
                                undefined;
                           (_K, B) ->
                                binary_to_term(B)
                        end, MapState0),
    #{n := N,
      f := F,
      t := T,
      id := ID,
      dkg := DKG0,
      curve := Curve,
      g1 := G1_0,
      g2 := G2_0,
      members := Members,
      artifact := Artifact,
      signatures := Sigs,
      signatures_required := SigsRequired,
      sigmod := SigMod,
      sigfun := SigFun,
      donemod := DoneMod,
      donefun := DoneFun,
      done_called := DoneCalled,
      sent_conf := SentConf,
      height := Height,
      delay := Delay} = MapState,
    {ok, _, ReadySigFun, _ECDHFun} = blockchain_swarm:keys(),
    Group = erlang_pbc:group_new(Curve),
    G1 = erlang_pbc:binary_to_element(Group, G1_0),
    G2 = erlang_pbc:binary_to_element(Group, G2_0),
    DKG = dkg_hybriddkg:deserialize(DKG0, G1, ReadySigFun,
                                    mk_verification_fun(Members)),
    PrivKey = case maps:get(privkey, MapState, undefined) of
        undefined ->
            undefined;
        Other ->
            tpke_privkey:deserialize(Other)
    end,
    #state{dkg = DKG,
           g1 = G1, g2 = G2,
           privkey = PrivKey,
           n = N,
           f = F,
           t = T,
           id = ID,
           curve = Curve,
           members = Members,
           artifact = Artifact,
           signatures = Sigs,
           signatures_required = SigsRequired,
           sigmod = SigMod,
           sigfun = SigFun,
           donemod = DoneMod,
           donefun = DoneFun,
           done_called = DoneCalled,
           done_acked = maps:get(done_acked, MapState, false),
           sent_conf = SentConf,
           height = Height,
           delay = Delay}.

restore(OldState, _NewState) ->
    lager:debug("called restore with ~p ~p", [OldState#state.privkey,
                                              _NewState#state.privkey]),
    {ok, OldState}.

fixup_msgs(Msgs) ->
    lists:map(fun({unicast, J, NextMsg}) ->
                      {unicast, J, t2b(NextMsg)};
                 ({multicast, NextMsg}) ->
                      {multicast, t2b(NextMsg)};
                 ({callback, NextMsg}) ->
                      {callback, t2b(NextMsg)}
              end, Msgs).

%% ==================================================================
%% Internal functions
%% ==================================================================
generate(Curve, Members) ->
    Group = erlang_pbc:group_new(Curve),
    G1 = erlang_pbc:element_from_hash(erlang_pbc:element_new('G1', Group), term_to_binary(Members)),
    G2 = case erlang_pbc:pairing_is_symmetric(Group) of
             true -> G1;
             %% XXX breaks for asymmetric curve
             false -> erlang_pbc:element_from_hash(erlang_pbc:element_new('G2', Group), crypto:strong_rand_bytes(32))
         end,
    {G1, G2}.

mk_verification_fun(Members) ->
    fun(PeerID, Msg, Signature) ->
            PeerAddr = lists:nth(PeerID, Members),
            PeerKey = libp2p_crypto:bin_to_pubkey(PeerAddr),
            libp2p_crypto:verify(Msg, Signature, PeerKey)
    end.

t2b(Term) ->
    term_to_binary(Term, [{compressed, 1}]).
