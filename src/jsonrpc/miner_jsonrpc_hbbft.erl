-module(miner_jsonrpc_hbbft).

-include("miner_jsonrpc.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain_utils.hrl").

-behavior(miner_jsonrpc_handler).

%% jsonrpc_handler
-export([handle_rpc/2]).

%%
%% jsonrpc_handler
%%

handle_rpc(<<"hbbft_status">>, []) ->
    miner:hbbft_status();
handle_rpc(<<"hbbft_skip">>, []) ->
    Result = miner:hbbft_skip(),
    #{result => Result};
handle_rpc(<<"hbbft_queue">>, []) ->
    #{
        inbound := Inbound,
        outbound := Outbound
    } = miner:relcast_queue(consensus_group),
    Workers = miner:relcast_info(consensus_group),
    Outbound1 = maps:map(
        fun(K, V) ->
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
        end,
        Outbound
    ),
    #{
        inbound => length(Inbound),
        outbound => Outbound1
    };
handle_rpc(<<"hbbft_perf">>, []) ->
    #{
        consensus_members := ConsensusMembers,
        bba_totals := BBATotals,
        seen_totals := SeenTotals,
        max_seen := MaxSeen,
        group_with_penalties := GroupWithPenalties,
        election_start_height := ElectionStart,
        epoch_start_height := EpochStart,
        current_height := CurrentHeight
    } = miner_util:hbbft_perf(),
    PostElectionHeight = ElectionStart + 1,
    BlocksSince = CurrentHeight + 1 - EpochStart,
    #{
        current_height => CurrentHeight,
        blocks_since_epoch => BlocksSince,
        max_seen => MaxSeen,
        consensus_members => [ format_hbbft_entry(Member, CurrentHeight,
                                                  PostElectionHeight, BBATotals,
                                                  SeenTotals, GroupWithPenalties) || Member <- ConsensusMembers ]
    };
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).

-spec format_hbbft_entry(<<>>, integer(), integer(), map(), map(), list()) -> map().
format_hbbft_entry(CGMemberAddress, CurrentHeight, PostElectionHeight,
                   BBATotals, SeenTotals, GroupWithPenalties) ->
    {LastBBAHeight, Completions} = maps:get(CGMemberAddress, BBATotals),
    {LastSeenHeight, SeenVotes} = maps:get(CGMemberAddress, SeenTotals),
    {_Address, {Penalty, Tenure}} = lists:keyfind(CGMemberAddress, 1, GroupWithPenalties),
    B58Address = ?BIN_TO_B58(CGMemberAddress),
    #{
        name => ?B58_TO_ANIMAL(B58Address),
        address => B58Address,
        bba_completions => Completions,
        seen_votes => SeenVotes,
        last_bba => CurrentHeight - max(PostElectionHeight, LastBBAHeight),
        last_seen => CurrentHeight - max(PostElectionHeight, LastSeenHeight),
        tenure => Tenure,
        penalty => Penalty
    }.
