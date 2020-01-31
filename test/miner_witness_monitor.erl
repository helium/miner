-module(miner_witness_monitor).

-behaviour(gen_server).

-include("miner_ct_macros.hrl").

-export([
         start_link/1,
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,

         save_witnesses/0,
         check_witness_monotonic/1,
         check_witness_refresh/0
        ]).

-record(state,
        {
         miner,
         max_height
        }).

start_link(Miner) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Miner, []).

save_witnesses() ->
    gen_server:call(?MODULE, save_witnesses, infinity).

check_witness_monotonic(Span) ->
    gen_server:call(?MODULE, {check_witness_monotonic, Span}, infinity).

check_witness_refresh() ->
    gen_server:call(?MODULE, check_witness_refresh, infinity).

init(Miner) ->
    ct:pal("starting ~p, for: ~p", [?MODULE, Miner]),
    %% witness_ets: [{a1, [{hi, wi}, {hj, wj}, ...]}, {a2, [{hi, wi}, {hj, wj}, ...]}, ...]
    ets:new(witness_ets, [ordered_set, named_table]),
    {ok, #state{miner=Miner}}.

handle_call({check_witness_monotonic, Span}, _From,
            #state{max_height = MaxHeight} = State) ->
    Witnesses = ets:tab2list(witness_ets),


    %% For each hotspot, check whether in a subsequent height, its witness
    %% list has grown monotonically
    Check =
        case MaxHeight > Span of
            false -> false;
            true ->
                lists:all(
                  fun(X) -> X end,
                  lists:map(
                    fun({_Addr, WitnessList}) ->
                            is_tuple(
                              lists:foldl(
                                fun(_TaggedWitnesses, false) ->
                                        false;
                                   ({Height, ListWitnesses} = Curr, {PriorHeight, Prior}) ->
                                        case length(ListWitnesses) < length(Prior) of
                                            true ->
                                                ct:pal("witnesses shrank ~p: ~p -> ~p: ~p",
                                                       [PriorHeight, Prior, Height, Witnesses]),
                                                false;
                                            _ ->
                                                Curr
                                        end
                                end,
                                {0, []},
                                lists:keysort(1, WitnessList)))
                    end,
                    Witnesses))
        end,
    {reply, Check, State};
handle_call(check_witness_refresh, _From, State) ->
    Witnesses = ets:tab2list(witness_ets),

    %% For each hotspot, check whether in a subsequent height, it's witness
    %% list has emptied out or not
    RefreshResults = lists:map(fun({A, WitnessList}) ->
                                       Len = length(WitnessList),
                                       Results = lists:sort(lists:foldl(fun({I, {HI, WI}}, Acc) ->
                                                                                case I < Len of
                                                                                    false ->
                                                                                        %% Nothing more to check
                                                                                        Acc;
                                                                                    true ->
                                                                                        {H, W} = lists:nth(I + 1, WitnessList),
                                                                                        %% Check if the next witness list is empty
                                                                                        %% given that it previously had witnesses
                                                                                        Res = (W == [] andalso WI /= []),
                                                                                        [{HI, H, Res} | Acc]
                                                                                end

                                                                        end,
                                                                        [],
                                                                        lists:zip(lists:seq(1, Len), WitnessList))),
                                       %% ct:pal("A: ~p, Results: ~p", [A, Results]),
                                       {A, lists:any(fun({_, _, X}) -> X == true end, Results)}
                               end,
                               Witnesses),

    ct:pal("Witnesses: ~p", [Witnesses]),
    ct:pal("RefreshResults: ~p", [RefreshResults]),

    Check = lists:any(fun({_A, R}) -> R == true end, RefreshResults),

    {reply, Check, State};
handle_call(save_witnesses, _From, #state{miner=Miner}=State) ->
    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Miner, blockchain, ledger, [Chain]),
    {ok, Height} = ct_rpc:call(Miner, blockchain_ledger_v1, current_height, [Ledger]),
    AG = ct_rpc:call(Miner, blockchain_ledger_v1, active_gateways, [Ledger]),

    ok = lists:foreach(
           fun({PubkeyBin, GW}) ->
                   Key = libp2p_crypto:bin_to_b58(PubkeyBin),
                   Witnesses = [libp2p_crypto:bin_to_b58(A)
                                || A <- maps:keys(blockchain_ledger_gateway_v2:witnesses(GW))],
                   Val = {Height, Witnesses},
                   case ets:member(witness_ets, Key) of
                       false ->
                           true = ets:insert(witness_ets, {Key, [Val]});
                       true ->
                           [{_, TaggedWitnessList}] = ets:take(witness_ets, Key),
                           true = ets:insert(witness_ets,
                                             {Key, lists:usort(
                                                     lists:flatten([Val | TaggedWitnessList]))})
                   end
           end,
           maps:to_list(AG)),

    ct:pal("save_witnesses at height: ~p, ~p", [Height, ets:tab2list(witness_ets)]),

    {reply, ok, State#state{max_height = Height}};
handle_call(Msg, _From, State) ->
    lager:warning("unhandled call ~p", [Msg]),
    {reply, error, State}.

handle_cast(Msg, State) ->
    lager:warning("unhandled cast ~p", [Msg]),
    {noreply, State}.

handle_info(Msg, State) ->
    ct:pal("unhandled info ~p", [Msg]),
    {noreply, State}.
