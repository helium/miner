%%%-------------------------------------------------------------------
%% @doc miner Supervisor
%% @end
%%%-------------------------------------------------------------------
-module(miner_critical_sup).

-behaviour(supervisor).

%% API
-export([start_link/4]).

%% Supervisor callbacks
-export([init/1]).

-define(SUP(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => infinity,
    type => supervisor,
    modules => [I]
}).

-define(WORKER(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 15000,
    type => worker,
    modules => [I]
}).

%% ------------------------------------------------------------------
%% API functions
%% ------------------------------------------------------------------
start_link(PublicKey, SigFun, ECDHFun, ECCWorker) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [PublicKey, SigFun, ECDHFun, ECCWorker]).

%% ------------------------------------------------------------------
%% Supervisor callbacks
%% ------------------------------------------------------------------
init([PublicKey, SigFun, ECDHFun, ECCWorker]) ->
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 0,
        period => 1
    },

    %% Blockchain Supervisor Options
    SeedNodes =
        case application:get_env(blockchain, seed_nodes) of
            {ok, ""} -> [];
            {ok, Seeds} -> string:split(Seeds, ",", all);
            _ -> []
        end,
    SeedNodeDNS = application:get_env(blockchain, seed_node_dns, []),
    % look up the DNS record and add any resulting addresses to the SeedNodes
    % no need to do any checks here as any bad combination results in an empty list
    SeedAddresses = string:tokens(lists:flatten([string:prefix(X, "blockchain-seed-nodes=") || [X] <- inet_res:lookup(SeedNodeDNS, in, txt), string:prefix(X, "blockchain-seed-nodes=") /= nomatch]), ","),
    Port = application:get_env(blockchain, port, 0),
    NumConsensusMembers = application:get_env(blockchain, num_consensus_members, 4),
    BaseDir = application:get_env(blockchain, base_dir, "data"),
    %% TODO: Remove when cuttlefish
    MaxInboundConnections = application:get_env(blockchain, max_inbound_connections, 10),

    %% downlink packets from state channels go here
    application:set_env(blockchain, sc_client_handler, miner_lora),

    %% create a ed25519 based key
    %% this will be used as part of libp2p streams negotiation process
    %% this is a temporary measure until libp2p streams is fully fledged out
    %% this key will be in addition to the existing ECC key for the time being
    Ed25519KeyPair =
        case application:get_env(blockchain, ed25519_keypair) of
            undefined ->
                libp2p_keypair:new(ed25519);
            {ok, KeyPair} ->
                KeyPair
        end,

    BlockchainOpts = [
        {key, {PublicKey, SigFun, ECDHFun}},
        {ed25519_keypair, Ed25519KeyPair},
        {seed_nodes, SeedNodes ++ SeedAddresses},
        {max_inbound_connections, MaxInboundConnections},
        {port, Port},
        {num_consensus_members, NumConsensusMembers},
        {base_dir, BaseDir},
        {update_dir, application:get_env(miner, update_dir, undefined)},
        {group_delete_predicate, fun miner_consensus_mgr:group_predicate/1}
    ],

    ChildSpecs =
        ECCWorker++
        [
         ?SUP(blockchain_sup, [BlockchainOpts]),
         ?WORKER(miner_consensus_mgr, [ignored])
        ],
    {ok, {SupFlags, ChildSpecs}}.
