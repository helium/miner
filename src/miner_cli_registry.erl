%%%-------------------------------------------------------------------
%% @doc miner_cli_registry
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_registry).

-define(CLI_MODULES, [
                      miner_cli_hbbft
                      ,miner_cli_genesis
                      ,miner_cli_info
                      ,miner_cli_dkg
                     ]).

-export([register_cli/0]).

register_cli() ->
    clique:register(?CLI_MODULES).
