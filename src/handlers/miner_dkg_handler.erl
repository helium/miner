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
         privkey :: undefined | tc_key_share:tc_key_share() | binary(),
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
         delay :: non_neg_integer(),
         commitment_cache_fun :: undefined | fun()
        }).

init([Members, Id, N, F, T,
      ThingToSign,
      {SigMod, SigFun},
      {DoneMod, DoneFun}, Round,
      Height, Delay]) ->
    %% get the fun used to sign things with our swarm key
    {ok, _, ReadySigFun, _ECDHFun} = blockchain_swarm:keys(),
    CCFun = commitment_cache_fun(),
    DKG = dkg_hybriddkg:init(Id, N, F, T, Round, [{callback, true}, {elections, false},
                                                          {signfun, ReadySigFun},
                                                          {verifyfun, mk_verification_fun(Members)},
                                                          {commitment_cache_fun, CCFun}]),
    lager:info("DKG~p started", [Id]),
    {ok, #state{n = N,
                id = Id,
                f = F,
                t = T,
                dkg = DKG,
                signatures_required = N,
                artifact = ThingToSign,
                sigmod = SigMod, sigfun = SigFun,
                donemod = DoneMod, donefun = DoneFun,
                members = Members,
                height = Height,
                commitment_cache_fun = CCFun,
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
handle_command(final_status, State) ->
    case State#state.dkg_completed of
        false ->
            %% we didn't overcome the BFT threshold so we cannot meaningfully
            %% report a state here
            {reply, dkg_not_complete, [], State};
        true ->
            case length(State#state.signatures) == State#state.signatures_required of
                true ->
                    %% we did the thing
                    {reply, complete, [], State};
                false ->
                    %% ok, here's where it gets interesting. We completed the DKG
                    %% which means that at least 2f+1 nodes completed the protocol
                    %% but we were unable to get to unanimous agreement. Return
                    %% the final state of the protocol we saw and try to get agreement
                    %% on who did not complete.
                    {reply, {ok, {State#state.privkey, State#state.signatures, State#state.members,
                             State#state.delay, State#state.height}}, [], State}
            end
    end;
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

handle_message(BinMsg, Index, State) when is_binary(BinMsg) ->
    try binary_to_term(BinMsg) of
        Msg ->
            handle_message(Msg, Index, State)
    catch _:_ ->
            lager:warning("got truncated message: ~p:", [BinMsg]),
            ignore
    end;
handle_message({conf, InSigs}, Index, State=#state{members = Members,
                                                   signatures = Sigs, f=F,
                                                   height = Height, delay = Delay,
                                                   donemod = DoneMod, donefun = DoneFun})
  when State#state.done_called == false ->
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
    case length(GoodSignatures) of
        SigLen when SigLen == State#state.signatures_required ->
            lager:debug("good len ~p sigs ~p", [length(GoodSignatures), GoodSignatures]),
            %% This now an async cast but we don't consider the handoff complete until
            %% we have gotten a `mark_done' message from the consensus manager
            ok = DoneMod:DoneFun(State#state.artifact, GoodSignatures,
                                 Members, State#state.privkey, Height, Delay),
            %% rebroadcast the final set of signatures and stop the handler
            {State#state{done_called = true,
                         signatures = GoodSignatures},[]};
        SigLen when SigLen >= (2*F) + 1 andalso State#state.sent_conf == false ->
            lager:debug("conf ~p/~p - ~p", [length(GoodSignatures), length(Members), State#state.signatures_required]),
            {State#state{sent_conf=true},
             [{multicast, t2b({conf, GoodSignatures})}]};
        _ ->
            lager:debug("not done, conf have ~p", [length(GoodSignatures)]),
            {State#state{signatures=GoodSignatures}, []}
    end;
handle_message({conf, _InSigs}, _Index, _State) ->
    %% don't bother, we've already completed and sent a conf message
    ignore;
handle_message({signature, Address, Signature}, Index, State=#state{members = Members,
                                                                    signatures = Sigs, f = F,
                                                                    height = Height, delay = Delay,
                                                                    donemod = DoneMod, donefun = DoneFun})
  when State#state.done_called == false ->
    case {lists:member(Address, Members) andalso %% valid signatory
          not lists:keymember(Address, 1, Sigs), %% not a duplicate
          libp2p_crypto:verify(State#state.artifact, Signature, libp2p_crypto:bin_to_pubkey(Address))} %% valid signature
    of
        {true, true} ->
            lager:debug("got good sig ~p from ~p, have ~p", [Signature, Index,
                                                             length(State#state.signatures) + 1]),
            NewState = State#state{signatures=[{Address, Signature}|State#state.signatures]},
            case length(NewState#state.signatures) of
                SigLen when SigLen == State#state.signatures_required ->
                    lager:debug("enough 1 ~p", [length(NewState#state.signatures)]),
                    %% This now an async cast but we don't consider the handoff complete until
                    %% we have gotten a `mark_done' message from the consensus manager
                    ok = DoneMod:DoneFun(State#state.artifact, NewState#state.signatures,
                                         Members, State#state.privkey, Height, Delay),
                    {NewState#state{done_called = true}, []};
                SigLen when SigLen == (2*F)+1 ->
                    lager:debug("conf ~p/~p - ~p", [length(NewState#state.signatures), length(Members), State#state.signatures_required]),
                    {NewState#state{sent_conf=true},
                     [{multicast, t2b({conf, NewState#state.signatures})}]};
                SigLen when SigLen == (2*F)+1 ->
                    lager:debug("sig echo ~p/~p - ~p", [length(NewState#state.signatures), length(Members), State#state.signatures_required]),
                    %% this is a new, valid signature so we can pass it on just in case we have some point to point failures
                    {NewState, [{multicast, t2b({signature, Address, Signature})}]};
                _ ->
                    lager:debug("not enough ~p/~p - ~p", [length(NewState#state.signatures), length(Members), State#state.signatures_required]),
                    {NewState, []}
            end;
        {false, _} ->
            %% duplicate, this is ok
            ignore;
        {true, false} ->
            lager:warning("got invalid signature ~p from ~p", [Signature, Address]),
            ignore
    end;
handle_message({signature, _Address, _Signature}, _Index, _State) ->
    %% we have already completed
    ignore;
handle_message(Msg, Index, State = #state{sigmod = SigMod, sigfun = SigFun}) ->
    case dkg_hybriddkg:handle_msg(State#state.dkg, Index, Msg) of
        %% NOTE: We cover all possible return values from handle_msg hence
        %% eliminating the need for a final catch-all clause
        {_, ignore} ->
            %% lager:info("ignoring ~p", [Msg]),
            ignore;
        {NewDKG, ok} ->
            {State#state{dkg=NewDKG}, []};
        {NewDKG, {send, Msgs}} ->
            {State#state{dkg=NewDKG}, fixup_msgs(Msgs)};
        {NewDKG, start_timer} ->
            %% this is unused, as it's used to time out DKG elections which we're not doing
            {State#state{dkg=NewDKG}, []};
        {NewDKG, {result, PrivateKey}} when State#state.privkey == undefined ->
            lager:info("Completed DKG ~p", [State#state.id]),
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
        {_NewDKG, {result, _PrivKey}} ->
            lager:info("dkg completed again?"),
            ignore
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
           privkey = PrivKey0,
           n = N,
           f = F,
           t = T,
           id = ID,
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
    PreSer = #{},
    PrivKey =
        case PrivKey0 of
            undefined ->
                undefined;
            Other ->
                tc_key_share:serialize(Other)
        end,
    M0 = #{dkg => SerializedDKG,
           privkey => PrivKey,
           n => N,
           f => F,
           t => T,
           id => ID,
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
    MapState = maps:map(fun(_K, undefined) ->
                                undefined;
                           (_K, B) ->
                                binary_to_term(B)
                        end, MapState0),
    #{n := N,
      f := F,
      t := T,
      id := ID,
      dkg := DKG0,
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
    CC = commitment_cache_fun(),
    DKG = dkg_hybriddkg:deserialize(DKG0, ReadySigFun,
                                    mk_verification_fun(Members), CC),
    PrivKey = case maps:get(privkey, MapState, undefined) of
        undefined ->
            undefined;
        Other ->
            tc_key_share:deserialize(Other)
    end,
    #state{dkg = DKG,
           privkey = PrivKey,
           n = N,
           f = F,
           t = T,
           id = ID,
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
           commitment_cache_fun=CC,
           delay = Delay}.

restore(OldState, NewState) ->
    lager:debug("called restore with ~p ~p", [OldState#state.privkey,
                                              NewState#state.privkey]),
    %% we needed to (re)create the funs in deserialize so there's nothing to do here
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
mk_verification_fun(Members) ->
    fun(PeerID, Msg, Signature) ->
            PeerAddr = lists:nth(PeerID, Members),
            PeerKey = libp2p_crypto:bin_to_pubkey(PeerAddr),
            libp2p_crypto:verify(Msg, Signature, PeerKey)
    end.

t2b(Term) ->
    term_to_binary(Term, [{compressed, 1}]).

commitment_cache_fun() ->
    T = ets:new(t, []),
    fun Self({Ser, DeSer0}) ->
            ets:insert(T, {erlang:phash2(Ser), DeSer0}),
            ok;
        Self(Ser) ->
            case ets:lookup(T, erlang:phash2(Ser)) of
                [] ->
                    DeSer = tc_bicommitment:deserialize(Ser),
                    ok = Self({Ser, DeSer}),
                    DeSer;
                [{_, Res}] ->
                    Res
            end
    end.
