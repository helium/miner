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

handle_rpc(<<"dkg_status">>, []) ->
    try
        miner_consensus_mgr:dkg_status() of
            not_running -> #{ running => false };
            Status -> #{ running => true, status => Status }
    catch _:_ ->
        #{ running => false }
    end;
handle_rpc(<<"dkg_queue">>, []) ->
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
                                   address => ?BIN_TO_B58(Raw),
                                   name => ?BIN_TO_ANIMAL(Raw),
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
handle_rpc(<<"dkg_running">>, []) ->
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
            #{ running => false };
        _ ->
            {ok, Block} = blockchain:get_block(Height+Delay, Chain),
            Hash = blockchain_block:hash_block(Block),
            ConsensusAddrs = blockchain_election:new_group(Ledger, Hash, N, Delay),
            #{
                running => true,
                consensus_members => [
                    #{
                        name => ?BIN_TO_ANIMAL(A),
                        address => ?BIN_TO_B58(A)
                   } || A <- ConsensusAddrs
                ]
            }
    end;
handle_rpc(<<"dkg_next">>, []) ->
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
