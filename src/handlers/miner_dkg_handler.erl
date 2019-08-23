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
         sent_conf = false :: boolean()
        }).

init([Members, Id, N, F, T, Curve,
      ThingToSign,
      {SigMod, SigFun},
      {DoneMod, DoneFun}, Round]) ->
    {G1, G2} = generate(Curve, Members),
    %% get the fun used to sign things with our swarm key
    {ok, _, ReadySigFun, _ECDHFun} = blockchain_swarm:keys(),
    DKG = dkg_hybriddkg:init(Id, N, F, T, G1, G2, Round, [{callback, true}, {elections, false}, {signfun, ReadySigFun}, {verifyfun, mk_verification_fun(Members)}]),
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
                members = Members}}.

handle_command(start, State) ->
    {NewDKG, {send, Msgs}} = dkg_hybriddkg:start(State#state.dkg),
    {reply, ok, fixup_msgs(Msgs), State#state{dkg=NewDKG}};
handle_command(get_info, #state{privkey = PKey, members = Members, n = N, f = F} = State) ->
    {reply, {info, PKey, Members, N, F}, [], State};
handle_command({stop, _Timeout}, #state{privkey = PKey, done_called = false} = State)
  when PKey /= undefined ->
    {reply, {error, not_done}, [], State};
handle_command({stop, Timeout}, State) ->
    {reply, ok, [{stop, Timeout}], State};
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
                                           sigmod = SigMod, sigfun = SigFun,
                                           donemod = DoneMod, donefun = DoneFun}) ->
    Msg = binary_to_term(BinMsg),
    %lager:info("DKG input ~s from ~p", [fakecast:print_message(Msg), Index]),
    case Msg of
        {conf, InSigs} ->
            Sigs1 = lists:foldl(fun({Address, Signature}, Acc) ->
                                        case lists:keymember(Address, 1, Acc) == false andalso
                                            libp2p_crypto:verify(State#state.artifact, Signature, libp2p_crypto:bin_to_pubkey(Address)) of
                                            true ->
                                                [{Address, Signature}|Acc];
                                            false ->
                                                Acc
                                        end
                                end, Sigs, InSigs),
            NewState = State#state{signatures = Sigs1},
            case enough_signatures(conf, NewState) of
                {ok, GoodSignatures} ->
                    case State#state.sent_conf of
                        false ->
                            %% relies on implicit self-send to hit the
                            %% other clause here in some cases
                            {State#state{sent_conf=true, signatures=GoodSignatures},
                             [{multicast, term_to_binary({conf, GoodSignatures})}]};
                        true when State#state.done_called == false ->
                            %% this needs to be a call so we know the callback succeeded so we
                            %% can terminate
                            lager:info("good len ~p sigs ~p", [length(GoodSignatures), GoodSignatures]),
                            ok = DoneMod:DoneFun(State#state.artifact, GoodSignatures,
                                                 Members, State#state.privkey),
                            %% rebroadcast the final set of signatures and stop the handler
                            {State#state{done_called = true, signatures = GoodSignatures},
                             [{multicast, term_to_binary({conf, GoodSignatures})}]};
                        _ ->
                            {State, []}
                    end;
                false ->
                    {State, []}
            end;
        {signature, Address, Signature} ->
            case {libp2p_crypto:verify(State#state.artifact, Signature, libp2p_crypto:bin_to_pubkey(Address)),
                  not lists:keymember(Address, 1, Sigs)} of
                {true, true} ->
                    NewState = State#state{signatures=[{Address, Signature}|State#state.signatures]},
                    case enough_signatures(sig, NewState) of
                        {ok, _Signatures} when State#state.sent_conf == false ->
                            {NewState#state{sent_conf=true}, [{multicast, term_to_binary({conf, NewState#state.signatures})}]};
                        {ok, _} ->
                            case enough_signatures(conf, NewState) of
                                {ok, GoodSignatures} when State#state.done_called == false ->
                                    %% this needs to be a call so we know the callback succeeded so we
                                    %% can terminate
                                    lager:info("good len ~p sigs ~p", [length(GoodSignatures), GoodSignatures]),
                                    ok = DoneMod:DoneFun(State#state.artifact, GoodSignatures,
                                                         Members, State#state.privkey),
                                    %% stop the handler
                                    {NewState#state{done_called = true, signatures = GoodSignatures}, [{stop, 60000}]};
                                _ ->
                                    %% not enough total signatures, or we've already completed
                                    {NewState, []}
                            end;
                        _ ->
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
    SerializedDKG = dkg_hybriddkg:serialize(State#state.dkg),
    G1 = erlang_pbc:element_to_binary(State#state.g1),
    G2 = erlang_pbc:element_to_binary(State#state.g2),
    PrivKey = case State#state.privkey of
                  undefined ->
                      undefined;
                  Other ->
                      tpke_privkey:serialize(Other)
              end,
    term_to_binary(State#state{dkg=SerializedDKG, g1=G1, g2=G2, privkey=PrivKey}, [compressed]).

deserialize(BinState) ->
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
            tpke_privkey:deserialize(Other)
    end,
    State#state{dkg=DKG, g1=G1, g2=G2, privkey=PrivKey}.

restore(#state{done_called = true, % if this is true on restore, we might not have started
                                   % this correctly yet
               donemod = DoneMod, donefun = DoneFun,
               artifact = Artifact, signatures = Sigs,
               members = Members, privkey = PrivKey
              } = OldState, _NewState) ->
    lager:info("restored dkg was completed, attempting to restart hbbft group"),
    ok = DoneMod:DoneFun(Artifact, Sigs, Members, PrivKey),
    {ok, OldState};
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

enough_signatures(sig, #state{signatures=Sigs, t = T}) when length(Sigs) < (T + 1) ->
    false;
enough_signatures(conf, #state{signatures=Sigs, signatures_required=Count}) when length(Sigs) < Count ->
    false;
enough_signatures(Phase, #state{artifact=Artifact, members=Members, signatures=Signatures,
                                t = T, signatures_required=Threshold0}) ->
    Threshold = case Phase of
                    sig -> T + 1;
                    conf -> Threshold0
                end,
    %% filter out any signatures that are invalid or are not for a member of this DKG and dedup
    %% in the unhappy case we have forged sigs, we can redo work here, but that should be uncommon
    case blockchain_block_v1:verify_signatures(Artifact, Members, Signatures, Threshold) of
        {true, ValidSignatures} ->
            {ok, lists:sublist(lists:sort(ValidSignatures), Threshold)};
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

