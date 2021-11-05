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
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ------------------------------------------------------------------
%% Supervisor callbacks
%% ------------------------------------------------------------------
init(_Args) ->
    SupFlags = #{
                 strategy => rest_for_one,
                 intensity => 0,
                 period => 1
                },

    BaseDir = application:get_env(blockchain, base_dir, "data"),

    ok = libp2p_crypto:set_network(application:get_env(miner, network, mainnet)),

    case application:get_env(blockchain, key, undefined) of
        undefined ->
            #{ pubkey := PublicKey,
               ecdh_fun := ECDHFun,
               sig_fun := SigFun
             } = miner_keys:keys({file, BaseDir}),
            CryptoWorker = [];
        {ecc, Props} when is_list(Props) ->
            #{ pubkey := PublicKey,
               key_slot := KeySlot,
               bus := Bus,
               address := Address,
               ecdh_fun := ECDHFun,
               sig_fun := SigFun
             } = miner_keys:keys({ecc, Props}),
            CryptoWorker = [?WORKER(miner_ecc_worker, [KeySlot, Bus, Address])];
        {tpm, Props} when is_list(Props) ->
            #{ pubkey := PublicKey,
               key_path := KeyPath,
               ecdh_fun := ECDHFun,
               sig_fun := SigFun
             } = miner_keys:keys({tpm, Props}),
            CryptoWorker = [?WORKER(miner_tpm_worker, [KeyPath])];
        {PublicKey, ECDHFun, SigFun} ->
            CryptoWorker = [],
            ok
    end,

    ChildSpecs =
        [
         ?SUP(miner_critical_sup, [PublicKey, SigFun, ECDHFun, CryptoWorker]),
         ?SUP(miner_restart_sup, [SigFun, ECDHFun])
        ],
    {ok, {SupFlags, ChildSpecs}}.
