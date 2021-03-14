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
-module(miner_dkg_handler).

-behavior(relcast).

-export([init/1, handle_message/3, handle_command/2, callback_message/3, serialize/1, deserialize/1, restore/2]).


-record(state, {bbas :: #{pos_integer() => hbbft_bba:bba_data()},
                members :: [ libp2p_crypto:pubkey_bin()],
                dkg_results :: bitstring(),
                bba_results = #{} :: #{pos_integer() => 0 | 1},
                signatures=[] :: [{libp2p_crypto:address(), binary()}]
               }).

init([Members, PrivKey, DKGResultVector]) ->
    N = bit_size(DKGResultVector),
    F = floor((bit_size(DKGResultVector) - 1) / 3),
    BBAs = [ {I, hbbft_bba:init(PrivKey, N, F)} || I <- lists:seq(1, bit_size(DKGResultVector))],
    {ok, #state{bbas=maps:from_list(BBAs),
                members=Members,
                dkg_results=DKGResultVector}}.

handle_command(start, State) ->
    {NewBBAs, OutMsgs} = lists:foldl(fun({BBAIndex, Input}, {BBAs, Msgs}) ->
                                             {NewBBA, BBAMsgs} = hbbft_bba:input(maps:get(BBAIndex, State#state.bbas), Input),
                                             {maps:put(BBAIndex, NewBBA, BBAs), [fixup_bba_msgs(BBAMsgs, BBAIndex)|Msgs]}
                                     end, {State#state.bbas, []}, lists:zip(lists:seq(1, bit_size(State#state.dkg_results)), [ V || <<V:1/integer>> <= State#state.dkg_results ])),
    {reply, ok, OutMsgs, State#state{bbas=NewBBAs}}.

handle_message(BinMsg, Index, State) ->
    Msg = binary_to_term(BinMsg),
    case Msg of
        {signature, Address, Signature} ->
            %% got a signature from our peer, check it matches our BBA result vector
            %% it's from a member and it's not a duplicate
        {bba, I, BBAMsg} ->
            BBA = maps:get(I, State#state.bbas),
            case hbbft_bba:handle_msg(BBA, Index, BBAMsg) of
                {NewBBA, ok} ->
                    {State#state{bbas=maps:put(I, NewBBA, State#state.bbas)}, []};
                {_, defer} ->
                    defer;
                ignore ->
                    ignore;
                {NewBBA, {send, ToSend}} ->
                    {State#state{bbas=maps:put(I, NewBBA, State#state.bbas)}, fixup_bba_msgs(ToSend)};
                {NewBBA, {result_and_send, Result, ToSend}} ->
                    BBAResults = maps:put(I, Result, State#state.bba_results),
                    case maps:size(BBAResults) == bit_size(State#state.dkg_results) of
                        true ->
                            %% construct a vector of the BBA results, sign it and send it to our peers

                    {State#state{bbas=maps:put(I, NewBBA, State#state.bbas), bba_results= }, fixup_bba_msgs(ToSend)};




fixup_bba_msgs(Msgs, I) ->
    lists:map(fun({unicast, J, NextMsg}) ->
                      {unicast, J, t2b({bba, I, NextMsg})};
                 ({multicast, NextMsg}) ->
                      {multicast, t2b({bba, I, NextMsg})}
              end, Msgs).

t2b(Term) ->
    term_to_binary(Term, [{compressed, 1}]).
