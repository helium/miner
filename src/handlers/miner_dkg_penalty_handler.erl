%%%-------------------------------------------------------------------
%% @doc
%% == miner dkg_penalty_handler ==
%% When a DKG fails at the signature round (meaning at least 2f+1 nodes
%% completed the protocol) run this protocol to determine who to penalize
%% when selecting future groups.
%%
%% An important note here is that because we completed the DKG but not the
%% signature round we do have a working threshold key we can use, even if it's
%% weakened by having several nodes who probably did not get their key share.
%%
%% We re-use the Binary Byzantine Agreement sub protocol from HoneybadgerBFT.
%% Each node instances a list of BBA instances that is the size of the DKG
%% that was being attempted and then submits their vote if they saw a signature
%% from that node. When all the BBAs complete, the node signs that result
%% bitvector and broadcasts the signature. Once we have 2f+1 signatures we
%% have agreement on who to penalize.
%% @end
%%%-------------------------------------------------------------------
-module(miner_dkg_penalty_handler).

-behavior(relcast).

-export([init/1, handle_message/3, handle_command/2, callback_message/3, serialize/1, deserialize/1, restore/2]).


-record(state, {bbas :: #{pos_integer() => hbbft_bba:bba_data()},
                privkey :: tpke_privkey:privkey(),
                members :: [ libp2p_crypto:pubkey_bin()],
                f :: pos_integer(),
                dkg_results :: [boolean(),...],
                bba_results = #{} :: #{pos_integer() => 0 | 1},
                done_called = false :: boolean(),
                delay :: non_neg_integer(),
                height :: pos_integer(),
                artifact,
                signatures=[] :: [{libp2p_crypto:address(), binary()}]
               }).

init([Members, PrivKey, Signatures, Delay, Height]=Args) ->
    N = length(Members),
    F = floor((N - 1) / 3),
    BBAs = [ {I, hbbft_bba:init(PrivKey, N, F)} || I <- lists:seq(1, length(Members))],
    DKGResults = lists:map(fun(Member) ->
                                   lists:keymember(Member, 1, Signatures)
                           end, Members),
    {ok, #state{bbas=maps:from_list(BBAs),
                privkey=PrivKey,
                f=F,
                delay=Delay,
                height=Height,
                members=Members,
                dkg_results=DKGResults}}.

handle_command(start, State) ->
    {NewBBAs, OutMsgs} = lists:foldl(fun({BBAIndex, SawSig}, {BBAs, Msgs}) ->
                                             Input = case SawSig of
                                                         true -> 1;
                                                         false -> 0
                                                     end,
                                             {NewBBA, BBAMsgs} = hbbft_bba:input(maps:get(BBAIndex, State#state.bbas), Input),
                                             {maps:put(BBAIndex, NewBBA, BBAs), fixup_bba_msgs(BBAMsgs, BBAIndex)++Msgs}
                                     end, {State#state.bbas, []}, lists:zip(lists:seq(1, length(State#state.members)), State#state.dkg_results)),
    {reply, ok, OutMsgs, State#state{bbas=NewBBAs}}.

handle_message(BinMsg, Index, State) ->
    Msg = binary_to_term(BinMsg),
    case Msg of
        {conf, Signatures} when State#state.artifact /= undefined andalso State#state.done_called == false ->
            GoodSignatures = lists:foldl(fun({Address, Signature}, Acc) ->
                                        %% only check signatures from members we have not already verified and have not already appeared in this list
                                        case {lists:keymember(Address, 1, Acc) == false andalso
                                             lists:member(Address, State#state.members),
                                             blockchain_txn_consensus_group_failure_v1:verify_signature(State#state.artifact, Address, Signature)} of
                                            {true, true} ->
                                                lager:debug("adding sig from conf"),
                                                [{Address, Signature}|Acc];
                                            {true, false} ->
                                                lager:debug("got invalid signature ~p from ~p", [Signature, Address]),
                                                Acc;
                                            {false, _} ->
                                                Acc
                                        end
                                end, State#state.signatures, Signatures),
            case length(GoodSignatures) >= (2*State#state.f)+1 of
                true ->
                    done(GoodSignatures, State#state.artifact),
                    {State#state{signatures=GoodSignatures, done_called=true}, [{multicast, t2b({conf, GoodSignatures})}]};
                false ->
                    {State#state{signatures=GoodSignatures}, []}
            end;
        {conf, Signatures} when State#state.artifact == undefined ->
            %% don't have artifact yet so cannot verify signatures
            {State#state{signatures=Signatures++State#state.signatures}, []};
        {conf, _Signatures} ->
            ignore;
        {signature, Address, Signature} when State#state.artifact /= undefined andalso State#state.done_called == false ->
            %% got a signature from our peer, check it matches our BBA result vector
            %% it's from a member and it's not a duplicate
            case {lists:member(Address, State#state.members) andalso not lists:keymember(Address, 1, State#state.signatures),
                  blockchain_txn_consensus_group_failure_v1:verify_signature(State#state.artifact, Address, Signature)} of
                {true, true} ->
                    NewSignatures = [{Address, Signature}|State#state.signatures],
                    case length(NewSignatures) == (2*State#state.f)+1 of
                        true ->
                            done(NewSignatures, State#state.artifact),
                            {State#state{signatures=NewSignatures, done_called=true}, [{multicast, t2b({conf, NewSignatures})}]};
                        false ->
                            {State#state{signatures=NewSignatures}, [{multicast, t2b({signature, Address, Signature})}]}
                    end;
                {true, false} ->
                    lager:debug("got invalid signature ~p from ~p", [Signature, Address]),
                    ignore;
                {false, _} ->
                    ignore
            end;
        {signature, Address, Signature} when State#state.artifact == undefined ->
            %% don't have artifact yet so cannot verify signatures
            {State#state{signatures=[{Address, Signature}|State#state.signatures]}, []};
        {signature, _Address, _Signature} ->
            ignore;
        {bba, I, BBAMsg} ->
            BBA = maps:get(I, State#state.bbas),
            case hbbft_bba:handle_msg(BBA, Index, BBAMsg) of
                {NewBBA, ok} ->
                    {State#state{bbas=maps:put(I, NewBBA, State#state.bbas)}, []};
                {_, defer} ->
                    defer;
                ignore ->
                    ignore;
                {NewBBA, {send, _}=ToSend} ->
                    {State#state{bbas=maps:put(I, NewBBA, State#state.bbas)}, fixup_bba_msgs(ToSend, I)};
                {NewBBA, {result_and_send, Result, ToSend}} ->
                    BBAResults = maps:put(I, Result, State#state.bba_results),
                    case maps:size(BBAResults) == length(State#state.members) of
                        true ->
                            %% construct a vector of the BBA results, sign it and send it to our peers
                            %% TODO this should be an actual transaction
                            Vector = [ B || {_, B} <- lists:keysort(1, maps:to_list(BBAResults)) ],
                            FailedMembers = [ M || {M, F} <- lists:zip(State#state.members, Vector), F == 0 ],
                            {ok, {MyKey, SigFun}} = miner:keys(),
                            Txn = blockchain_txn_consensus_group_failure_v1:new(FailedMembers, State#state.height, State#state.delay),
                            MyAddress = libp2p_crypto:pubkey_to_bin(MyKey),
                            MySignature = blockchain_txn_consensus_group_failure_v1:sign(Txn, SigFun),
                            GoodSignatures = lists:foldl(fun({Address, Signature}, Acc) ->
                                                                 %% only check signatures from members we have not already verified and have not already appeared in this list
                                                                 case {lists:keymember(Address, 1, Acc) == false andalso
                                                                       lists:member(Address, State#state.members),
                                                                       blockchain_txn_consensus_group_failure_v1:verify_signature(State#state.artifact, Address, Signature)} of
                                                                     {true, true} ->
                                                                         lager:debug("adding sig from conf"),
                                                                         [{Address, Signature}|Acc];
                                                                     {true, false} ->
                                                                         lager:debug("got invalid signature ~p from ~p", [Signature, Address]),
                                                                         Acc;
                                                                     {false, _} ->
                                                                         Acc
                                                                 end
                                                         end, [{MyAddress, MySignature}], State#state.signatures),
                            case length(GoodSignatures) >= (2*State#state.f)+1 of
                                true ->
                                    done(GoodSignatures, Txn),
                                    {State#state{bbas=maps:put(I, NewBBA, State#state.bbas), bba_results=BBAResults, signatures=GoodSignatures, artifact=Txn, done_called=true}, [{multicast, t2b({conf, GoodSignatures})} | fixup_bba_msgs(ToSend, I)]};
                                false ->
                                    {State#state{bbas=maps:put(I, NewBBA, State#state.bbas), bba_results=BBAResults, signatures=GoodSignatures, artifact=Txn}, [{multicast, t2b({signature, MyAddress, MySignature})} | fixup_bba_msgs(ToSend, I)]}
                            end;
                        false ->
                            {State#state{bbas=maps:put(I, NewBBA, State#state.bbas), bba_results=BBAResults}, fixup_bba_msgs(ToSend, I)}
                    end
            end
    end.

callback_message(_, _, _) -> none.

-spec serialize(#state{}) -> binary().
serialize(State) ->
    t2b(State#state{privkey=tpke_privkey:serialize(State#state.privkey),
                    bbas=maps:map(fun(_, BBA) ->
                                          hbbft_bba:serialize(BBA)
                                  end, State#state.bbas)}).

-spec deserialize(binary()) -> #state{}.
deserialize(M) ->
    State0 = binary_to_term(M),
    PrivKey = tpke_privkey:deserialize(State0#state.privkey),
    State0#state{privkey=PrivKey,
                 bbas=maps:map(fun(_, BBA) ->
                                       hbbft_bba:deserialize(BBA, PrivKey)
                               end, State0#state.bbas)}.

restore(OldState, _NewState) ->
    OldState.

done(Signatures, Txn) ->
    NewTxn = blockchain_txn_consensus_group_failure_v1:set_signatures(Txn, Signatures),
    blockchain_worker:submit_txn(NewTxn).

fixup_bba_msgs(ok, _) ->
    [];
fixup_bba_msgs({send, Msgs}, I) ->
    lists:map(fun({unicast, J, NextMsg}) ->
                      {unicast, J, t2b({bba, I, NextMsg})};
                 ({multicast, NextMsg}) ->
                      {multicast, t2b({bba, I, NextMsg})}
              end, Msgs).

t2b(Term) ->
    term_to_binary(Term, [{compressed, 1}]).
