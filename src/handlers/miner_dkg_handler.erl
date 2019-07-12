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
         signatures = #{} :: #{non_neg_integer() => {libp2p_crypto:pubkey_bin(), binary()}},
         signatures_required :: pos_integer(),
         sigmod :: atom(),
         sigfun :: atom(),
         donemod :: atom(),
         donefun :: atom(),
         done_called = false :: boolean(),
         sent_conf = false :: boolean(),
         timer :: undefined | pid()
        }).

init([Members, Id, N, F, T, Curve,
      ThingToSign,
      {SigMod, SigFun},
      {DoneMod, DoneFun}]) ->
    {G1, G2} = generate(Curve, Members),
    DKG = dkg_hybriddkg:init(Id, N, F, T, G1, G2, 0, [{callback, true}]),
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
handle_command({stop, Timeout}, State) ->
    {reply, ok, [{stop, Timeout}], State};
handle_command(status, State) ->
    Map = dkg_hybriddkg:status(State#state.dkg),
    Map1 = maps:merge(#{
                        id => State#state.id,
                        members => State#state.members,
                        signatures_required => State#state.signatures_required,
                        signatures => maps:size(State#state.signatures),
                        sent_conf => State#state.sent_conf
                       }, Map),
    {reply, Map1, ignore};
handle_command(timeout, State) ->
    case dkg_hybriddkg:handle_msg(State#state.dkg, State#state.id, timeout) of
        {_DKG, ok} ->
            {reply, ok, [], State#state{timer=undefined}};
        {NewDKG, {send, Msgs}} ->
            {reply, ok, fixup_msgs(Msgs), State#state{dkg=NewDKG, timer=undefined}}
    end.

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
            %% Sigs1 = lists:usort(lists:append(InSigs, Sigs)),
            lager:info("InSigs: ~p", [InSigs]),
            NewState = State#state{signatures = maps:from_list(InSigs)},
            case enough_signatures(conf, NewState) of
                {ok, GoodSignatures} ->
                    case State#state.sent_conf of
                        false ->
                            %% relies on implicit self-send to hit the
                            %% other clause here in some cases
                            {State#state{sent_conf=true, signatures=maps:from_list(GoodSignatures)},
                             [{multicast, term_to_binary({conf, GoodSignatures})}]};
                        true when State#state.done_called == false ->
                            %% this needs to be a call so we know the callback succeeded so we
                            %% can terminate
                            lager:info("good len ~p sigs ~p", [length(GoodSignatures), GoodSignatures]),
                            ok = DoneMod:DoneFun(State#state.artifact, maps:values(maps:from_list(GoodSignatures)),
                                                 Members, State#state.privkey),
                            %% stop the handler
                            {State#state{done_called = true}, [{stop, 60000}]};
                        _ ->
                            {State, []}
                    end;
                false ->
                    {State, []}
            end;
        {signature, Address, Signature} ->
            NewState = State#state{signatures=maps:put(Index, {Address, Signature}, State#state.signatures)},
            case enough_signatures(sig, NewState) of
                {ok, Signatures} when State#state.sent_conf == false ->
                    {NewState#state{sent_conf=true}, [{multicast, term_to_binary({conf, Signatures})}]};
                _ ->
                    %% already sent a CONF, or not enough signatures
                    {NewState, []}
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
                    case State#state.timer of
                        undefined -> ok;
                        OldTimer ->
                            OldTimer  ! cancel
                    end,
                    Parent = self(),
                    Pid = spawn(fun() ->
                                        receive
                                            cancel -> ok
                                        after 300000 ->
                                                  libp2p_group_relcast_server:handle_input(Parent, timeout)
                                        end
                                end),
                    {State#state{dkg=NewDKG, timer=Pid}, []};
                {NewDKG, {result, {Shard, VK, VKs}}} ->
                    lager:info("Completed DKG ~p", [State#state.id]),
                    PrivateKey = tpke_privkey:init(tpke_pubkey:init(N, T, G1, G2, VK, VKs, Curve),
                                                   Shard, State#state.id - 1),
                    case State#state.timer of
                        undefined -> ok;
                        OldTimer ->
                            OldTimer ! cancel
                    end,
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
                                 signatures_required=Threshold, timer=undefined,
                                 signatures=maps:put(Index, {Address, Signature}, State#state.signatures)},
                     [{multicast, term_to_binary({signature, Address, Signature})}]}
            end
    end.

callback_message(Actor, Message, _State) ->
    case binary_to_term(Message) of
        {Id, {send, {Session, SerializedCommitment, Shares}}} ->
            term_to_binary({Id, {send, {Session, SerializedCommitment, lists:nth(Actor, Shares)}}});
        {Id, {echo, {Session, SerializedCommitment, Shares}}} ->
            term_to_binary({Id, {echo, {Session, SerializedCommitment, lists:nth(Actor, Shares)}}});
        {Id, {ready, {Session, SerializedCommitment, Shares}}} ->
            term_to_binary({Id, {ready, {Session, SerializedCommitment, lists:nth(Actor, Shares)}}})
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
    Group = erlang_pbc:group_new(State#state.curve),
    G1 = erlang_pbc:binary_to_element(Group, State#state.g1),
    G2 = erlang_pbc:binary_to_element(Group, State#state.g2),
    DKG = dkg_hybriddkg:deserialize(State#state.dkg, G1),
    PrivKey = case State#state.privkey of
        undefined ->
            undefined;
        Other ->
            tpke_privkey:deserialize(Other)
    end,
    State#state{dkg=DKG, g1=G1, g2=G2, privkey=PrivKey}.

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

enough_signatures(_, #state{artifact=Artifact,
                            members=Members,
                            signatures=Signatures,
                            signatures_required=Threshold,
                            t=T}) ->
    NumSignatures = maps:size(Signatures),
    case NumSignatures < (T + 1) of
        true -> false;
        false ->
            case NumSignatures < Threshold of
                true -> false;
                false ->
                    %% filter out any signatures that are invalid or are not for a member of this DKG and dedup
                    %% in the unhappy case we have forged sigs, we can redo work here, but that should be uncommon
                    case blockchain_block_v1:verify_signatures(Artifact, Members, maps:values(Signatures), Threshold) of
                        {true, ValidSignatures} ->
                            case length(ValidSignatures) >= Threshold of
                                true ->
                                    {ok, lists:sublist(lists:sort(maps:to_list(Signatures)), Threshold)};
                                false ->
                                    false
                            end;
                        false ->
                            false
                    end
            end
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
