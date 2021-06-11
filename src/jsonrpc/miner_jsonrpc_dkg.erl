-module(miner_jsonrpc_dkg).

-include("miner_jsonrpc.hrl").
-include_lib("blockchain/include/blockchain_utils.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-behavior(miner_jsonrpc_handler).

%% jsonrpc_handler
-export([handle_rpc/2]).

%%
%% jsonrpc_handler
%%

handle_rpc(<<"dkg_status">>, _Params) ->
    Status = try
                 miner_consensus_mgr:dkg_status() of
                 Stat -> Stat
             catch _:_ ->
                       <<"not_running">>
             end,
    #{ status => Status };
handle_rpc(<<"dkg_queue">>, _Params) ->
    #{ inbound := Inbound,
       outbound := Outbound } = miner:relcast_queue(dkg_queue),
    Workers = miner:relcast_info(dkg_queue),
    Outbound1 = maps:map(fun(K, V) ->
                                 #{
                                   address := Raw,
                                   connected := Connected,
                                   ready := Ready,
                                   in_flight := InFlight,
                                   connects := Connects,
                                   last_take := LastTake,
                                   last_ack := LastAck
                                  } = maps:get(K, Workers),
                                 #{
                                   address => ?TO_B58(Raw),
                                   name => ?TO_ANIMAL_NAME(Raw),
                                   count => length(V),
                                   connected => Connected,
                                   blocked => not Ready,
                                   in_flight => InFlight,
                                   connects => Connects,
                                   last_take => LastTake,
                                   last_ack => erlang:system_time(seconds) - LastAck
                                  }
                         end, Outbound),
    #{ inbound => length(Inbound),
       outbound => Outbound1 };
handle_rpc(<<"dkg_running">>, _Params) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, Curr} = blockchain_ledger_v1:current_height(Ledger),
    {ok, ElectionInterval} = blockchain:config(?election_interval, Ledger),
    {ok, RestartInterval} = blockchain:config(?election_restart_interval, Ledger),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),

    #{start_height := EpochStart} = blockchain_election:election_info(Ledger),
    Height = EpochStart + ElectionInterval,
    Diff = Curr - Height,
    Delay = max(0, (Diff div RestartInterval) * RestartInterval),
    case Curr >= Height of
        false ->
            #{ error => <<"not running">> };
        _ ->
            {ok, Block} = blockchain:get_block(Height+Delay, Chain),
            Hash = blockchain_block:hash_block(Block),
            ConsensusAddrs = blockchain_election:new_group(Ledger, Hash, N, Delay),
            [ #{ name => ?TO_ANIMAL_NAME(A),
                 address => ?TO_B58(A) }
              || A <- ConsensusAddrs ]
    end;
handle_rpc(<<"dkg_next">>, _Params) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, Curr} = blockchain_ledger_v1:current_height(Ledger),
    {ok, ElectionInterval} = blockchain:config(?election_interval, Ledger),
    {ok, RestartInterval} = blockchain:config(?election_restart_interval, Ledger),

    #{start_height := EpochStart} = blockchain_election:election_info(Ledger),
    Height = EpochStart + ElectionInterval,
    Diff = Curr - Height,
    Delay = max(0, (Diff div RestartInterval) * RestartInterval),
    case Curr >= Height of
        false ->
            #{ running => false,
               next_election_height => Height,
               blocks_to_election => Height - Curr };
        _ ->
            NextRestart = Height + Delay + RestartInterval,
            #{ running => true,
               next_restart_height => NextRestart,
               blocks_to_restart => NextRestart - Curr }
    end;
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).
