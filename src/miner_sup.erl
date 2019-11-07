%%%-------------------------------------------------------------------
%% @doc miner Supervisor
%% @end
%%%-------------------------------------------------------------------
-module(miner_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SUP(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => supervisor,
    modules => [I]
}).

-define(WORKER(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [I]
}).

%% ------------------------------------------------------------------
%% API functions
%% ------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ------------------------------------------------------------------
%% Supervisor callbacks
%% ------------------------------------------------------------------
init(_Args) ->
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 10,
        period => 10
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

    case application:get_env(blockchain, key, undefined) of
        undefined ->
            SwarmKey = filename:join([BaseDir, "miner", "swarm_key"]),
            ok = filelib:ensure_dir(SwarmKey),
            {PublicKey, ECDHFun, SigFun, OnboardingKey} =
                case libp2p_crypto:load_keys(SwarmKey) of
                    {ok, #{secret := PrivKey0, public := PubKey}} ->
                        {PubKey,
                         libp2p_crypto:mk_ecdh_fun(PrivKey0),
                         libp2p_crypto:mk_sig_fun(PrivKey0),
                         undefined};
                    {error, enoent} ->
                        KeyMap = #{secret := PrivKey0, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
                        ok = libp2p_crypto:save_keys(KeyMap, SwarmKey),
                        {PubKey,
                         libp2p_crypto:mk_ecdh_fun(PrivKey0),
                         libp2p_crypto:mk_sig_fun(PrivKey0),
                         undefined}
                end,
            ECCWorker = [];
        {ecc, Props} when is_list(Props) ->
            KeySlot0 = proplists:get_value(key_slot, Props, 0),
            OnboardingKeySlot = proplists:get_value(onboarding_key_slot, Props, 15),
            %% Create a temporary ecc link to get the public key and
            %% onboarding keys for the given slots as well as the
            {ok, ECCPid} = ecc508:start_link(),
            %% Define a helper funtion to retry automatic keyslot key
            %% generation and locking the first time we encounter an
            %% empty keyslot.
            GetPublicKey = fun GetPublicKey(KS) ->
                                   case ecc508:genkey(ECCPid, public, KS) of
                                       {ok, PubKey} ->
                                           case ecc_compact:is_compact(PubKey) of
                                               {true, _} ->
                                                   {ok, {ecc_compact, PubKey}, KS};
                                               false ->
                                                   %% initial hotspots had a bug where they
                                                   %% did not generate a compact key here.
                                                   %% This code is fallback to use a secondary
                                                   %% slot to handle this case.
                                                   GetPublicKey(KS+1)
                                           end;
                                       {error, ecc_response_exec_error} ->
                                           %% key is not present, generate one
                                           %%
                                           %% XXX this is really not the best thing to do here
                                           %% but deadlines rule everything around us
                                           ok = gen_compact_key(ECCPid, KS),
                                           GetPublicKey(KS)
                                   end
                           end,
            ecc508:wake(ECCPid),
            %% Get (or generate) the public and onboarding keys
            {ok, PublicKey, KeySlot} = GetPublicKey(KeySlot0),
            {ok, OnboardingKey} = ecc508:genkey(ECCPid, public, OnboardingKeySlot),
            %% The signing and ecdh functions will use an actual
            %% worker against a named process.
            SigFun = fun(Bin) ->
                             {ok, Sig} = miner_ecc_worker:sign(Bin),
                             Sig
                     end,
            ECDHFun = fun(PubKey) ->
                              {ok, Bin} = miner_ecc_worker:ecdh(PubKey),
                              Bin
                      end,
            %% Stop ephemeral ecc pid and let the named worker take
            %% over
            ecc508:stop(ECCPid),
            ECCWorker = [?WORKER(miner_ecc_worker, [KeySlot])];
        {PublicKey, ECDHFun, SigFun, OnboardingKey} ->
            ECCWorker = [],
            ok
    end,

    BlockchainOpts = [
        {key, {PublicKey, SigFun, ECDHFun}},
        {seed_nodes, SeedNodes ++ SeedAddresses},
        {max_inbound_connections, MaxInboundConnections},
        {port, Port},
        {num_consensus_members, NumConsensusMembers},
        {base_dir, BaseDir},
        {update_dir, application:get_env(miner, update_dir, undefined)},
        {group_delete_predicate, fun miner_consensus_mgr:group_predicate/1}
    ],

    %% Miner Options
    Curve = application:get_env(miner, curve, 'SS512'),
    BlockTime = application:get_env(miner, block_time, 15000),
    BatchSize = application:get_env(miner, batch_size, 500),
    RadioDevice = application:get_env(miner, radio_device, undefined),

    MinerOpts =
        [
         {block_time, BlockTime},
         {radio_device, RadioDevice},
         {election_interval, application:get_env(miner, election_interval, 30)},
         {onboarding_key, OnboardingKey}
        ],

    ElectOpts =
        [
         {curve, Curve},
         {batch_size, BatchSize}
        ],

    POCOpts = #{
        base_dir => BaseDir
    },

    OnionServer =
        case application:get_env(miner, radio_device, undefined) of
            {RadioBindIP, RadioBindPort, RadioSendIP, RadioSendPort} ->
                OnionOpts = #{
                    radio_udp_bind_ip => RadioBindIP,
                    radio_udp_bind_port => RadioBindPort,
                    radio_udp_send_ip => RadioSendIP,
                    radio_udp_send_port => RadioSendPort,
                    ecdh_fun => ECDHFun
                },
                [?WORKER(miner_onion_server, [OnionOpts])];
            _ ->
                []
        end,

    EbusServer =
        case application:get_env(miner, use_ebus, false) of
            true -> [?WORKER(miner_ebus, [])];
            _ -> []
        end,

    ChildSpecs =
        ECCWorker++
        [
         ?SUP(blockchain_sup, [BlockchainOpts]),
         ?WORKER(miner_hbbft_sidecar, []),
         ?WORKER(miner, [MinerOpts]),
         ?WORKER(miner_consensus_mgr, [ElectOpts])
        ] ++
        EbusServer ++
        OnionServer ++
        [?WORKER(miner_poc_statem, [POCOpts])],
    {ok, {SupFlags, ChildSpecs}}.


gen_compact_key(Pid, Slot) ->
    gen_compact_key(Pid, Slot, 100).

gen_compact_key(_Pid, _Slot, 0) ->
    {error, compact_key_create_failed};
gen_compact_key(Pid, Slot, N) when N > 0 ->
    case  ecc508:genkey(Pid, private, Slot) of
        {ok, PubKey} ->
            case ecc_compact:is_compact(PubKey) of
                {true, _} -> ok;
                false -> gen_compact_key(Pid, Slot, N - 1)
            end;
        {error, Error} ->
            {error, Error}
    end.
