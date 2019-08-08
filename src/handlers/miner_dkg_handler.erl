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
         sent_conf = false :: boolean(),
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
handle_command({stop, _Timeout}, #state{privkey = PKey, done_called = false} = State)
  when PKey /= undefined ->
    {reply, {error, not_done}, [], State};
handle_command({stop, Timeout}, State) ->
    {reply, ok, [{stop, Timeout}], State};
handle_command(mark_done, State) ->
    {reply, ok, [], State#state{done_called = true}};
handle_command(status, State) ->
    Map = dkg_hybriddkg:status(State#state.dkg),
    Map1 = maps:merge(#{
                        id => State#state.id,
                        members => State#state.members,
                        signatures_required => State#state.signatures_required,
                        signatures => length(State#state.signatures),
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
        {conf, InSigs} ->
            lager:info("got conf from ~p with ~p", [length(InSigs), Index]),
            Sigs1 = lists:foldl(fun({Address, Signature}, Acc) ->
                                        case lists:keymember(Address, 1, Acc) == false andalso
                                            libp2p_crypto:verify(State#state.artifact, Signature, libp2p_crypto:bin_to_pubkey(Address)) of
                                            true ->
                                                lager:info("adding sig from conf"),
                                                [{Address, Signature}|Acc];
                                            false ->
                                                Acc
                                        end
                                end, Sigs, InSigs),
            NewState = State#state{signatures = Sigs1},
            case enough_signatures(conf, NewState) of
                {ok, GoodSignatures} when State#state.done_called == false ->
                    %% this needs to be a call so we know the callback succeeded so we
                    %% can terminate
                    lager:info("good len ~p sigs ~p", [length(GoodSignatures), GoodSignatures]),
                    ok = DoneMod:DoneFun(State#state.artifact, GoodSignatures,
                                         Members, State#state.privkey, Height, Delay),
                    %% rebroadcast the final set of signatures and stop the handler
                    {State#state{done_called = true, sent_conf = true,
                                 signatures = GoodSignatures},
                     [{multicast, term_to_binary({conf, GoodSignatures})}]};
                {ok, _GoodSignatures} ->
                    lager:info("already done"),
                    {State, []};
                _ ->
                    lager:info("not done, conf have ~p", [length(Sigs1)]),
                    {State, []}
            end;
        {signature, Address, Signature} ->
            case {libp2p_crypto:verify(State#state.artifact, Signature, libp2p_crypto:bin_to_pubkey(Address)),
                  not lists:keymember(Address, 1, Sigs)} of
                {true, true} ->
                    lager:info("got good sig ~p from ~p, have ~p", [Signature, Index,
                                                                    length(State#state.signatures) + 1]),
                    NewState = State#state{signatures=[{Address, Signature}|State#state.signatures]},
                    case enough_signatures(sig, NewState) of
                        {ok, Signatures} when State#state.sent_conf == false ->
                            lager:info("enough 1 ~p", [length(Signatures)]),
                            case length(Signatures) == length(Members) of
                                true ->
                                    case State#state.done_called of
                                        false ->
                                            %% this needs to be a call so we know the callback succeeded so we
                                            %% can terminate
                                            lager:info("good len ~p sigs ~p", [length(Signatures), Signatures]),
                                            ok = DoneMod:DoneFun(State#state.artifact, Signatures,
                                                                 Members, State#state.privkey, Height, Delay),
                                            {NewState#state{done_called = true, signatures = Signatures},
                                             [{multicast, term_to_binary({conf, Signatures})}]};
                                        _ ->
                                            %% not enough total signatures, or we've already completed
                                            {NewState, []}
                                    end;
                                false ->
                                    {NewState#state{sent_conf=true, signatures = Signatures},
                                     [{multicast, term_to_binary({conf, NewState#state.signatures})}]}
                            end;
                        {ok, Signatures} ->
                            lager:info("enough 2 ~p", [length(Signatures)]),
                            case length(Signatures) == length(Members) of
                                true ->
                                    case State#state.done_called of
                                        false ->
                                            %% this needs to be a call so we know the callback succeeded so we
                                            %% can terminate
                                            lager:info("good len ~p sigs ~p", [length(Signatures), Signatures]),
                                            ok = DoneMod:DoneFun(State#state.artifact, Signatures,
                                                                 Members, State#state.privkey, Height, Delay),
                                            {NewState#state{done_called = true, signatures = Signatures},
                                             [{multicast, term_to_binary({conf, Signatures})}]};
                                        _ ->
                                            %% not enough total signatures, or we've already completed
                                            {NewState, []}
                                    end;
                                false ->
                                    %% already sent a CONF, or not enough signatures
                                    {NewState, []}
                            end;
                        false ->
                            lager:info("not enough"),
                            %% already sent a CONF, or not enough signatures
                            {NewState, []}
                    end;
                {true, _} ->
                    %% duplicate, this is ok
                    {State, []};
                {false, _} ->
                    lager:warning("got invalid signature ~p from ~p", [Signature, Address]),
                    {State, []}
            end;
        _ ->
            case dkg_hybriddkg:handle_msg(State#state.dkg, Index, Msg) of
                %% NOTE: We cover all possible return values from handle_msg hence
                %% eliminating the need for a final catch-all clause
                {_, ignore} ->
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
                                 signatures=[{Address, Signature}|State#state.signatures]},
                     [{multicast, term_to_binary({signature, Address, Signature})}]};
                {_NewDKG, {result, {_Shard, _VK, _VKs}}} ->
                    ignore
            end
    end.

callback_message(Actor, Message, _State) ->
    case binary_to_term(Message) of
        {Id, {send, {Session, SerializedCommitment, Shares}}} ->
            term_to_binary({Id, {send, {Session, SerializedCommitment, lists:nth(Actor, Shares)}}});
        {Id, {echo, {Session, SerializedCommitment, Shares}}} ->
            term_to_binary({Id, {echo, {Session, SerializedCommitment, lists:nth(Actor, Shares)}}});
        {Id, {ready, {Session, SerializedCommitment, Shares, Proof}}} ->
            term_to_binary({Id, {ready, {Session, SerializedCommitment, lists:nth(Actor, Shares), Proof}}})
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
           sent_conf = SentConf} = State,
    SerializedDKG = dkg_hybriddkg:serialize(DKG0),
    G1 = erlang_pbc:element_to_binary(G1_0),
    G2 = erlang_pbc:element_to_binary(G2_0),
    PreSer0 = #{g1 => G1, g2 => G2},
    PreSer =
        case PrivKey0 of
            undefined ->
                PreSer0;
            Other ->
                maps:put(privkey, tpke_privkey:serialize(Other), PreSer0)
        end,
    M0 = #{dkg => SerializedDKG,
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
           sent_conf => SentConf},
    M = maps:map(fun(_K, Term) -> term_to_binary(Term) end, M0),
    maps:merge(PreSer, M).

deserialize(BinState) when is_binary(BinState) ->
    State = binary_to_term(BinState),
    %% get the fun used to sign things with our swarm key
    {ok, _, ReadySigFun, _ECDHFun} = blockchain_swarm:keys(),
    Group = erlang_pbc:group_new(State#state.curve),
    G1 = erlang_pbc:binary_to_element(Group, State#state.g1),
    G2 = erlang_pbc:binary_to_element(Group, State#state.g2),
    DKG = dkg_hybriddkg:deserialize(State#state.dkg, G1, ReadySigFun, mk_verification_fun(State#state.members)),
    PrivKey = case State#state.privkey of
        undefined ->
            undefined;
        Other ->
            term_to_binary(tpke_privkey:deserialize(Other))
    end,
    State#state{dkg=DKG, g1=G1, g2=G2, privkey=PrivKey};
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
      sent_conf := SentConf} = MapState,
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
            tpke_privkey:deserialize(binary_to_term(Other))
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
           sent_conf = SentConf}.

restore(OldState, _NewState) ->
    {ok, OldState}.

fixup_msgs(Msgs) ->
    lists:map(fun({unicast, J, NextMsg}) ->
                      {unicast, J, term_to_binary(NextMsg)};
                 ({multicast, NextMsg}) ->
                      {multicast, term_to_binary(NextMsg)};
                 ({callback, NextMsg}) ->
                      {callback, term_to_binary(NextMsg)}
              end, Msgs).

enough_signatures(sig, #state{signatures=Sigs, n = N, t = T}) when length(Sigs) < (N - T) ->
    lager:debug("failsig n ~p t ~p sigs ~p", [N, T, length(Sigs)]),
    false;
enough_signatures(conf, #state{signatures=Sigs, signatures_required=Count}) when length(Sigs) < Count ->
    lager:debug("failconf count ~p sigs ~p", [Count, length(Sigs)]),
    false;
enough_signatures(_Phase, #state{artifact=Artifact, members=Members, signatures=Signatures,
                                 signatures_required=Threshold}) ->
    lager:debug("checking using ~p", [Threshold]),
    %% filter out any signatures that are invalid or are not for a member of this DKG and dedup
    %% in the unhappy case we have forged sigs, we can redo work here, but that should be uncommon
    case blockchain_block_v1:verify_signatures(Artifact, Members, Signatures, Threshold) of
        {true, ValidSignatures} ->
            {ok, ValidSignatures};
        false ->
            false
    end.

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

