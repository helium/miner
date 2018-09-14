%%%-------------------------------------------------------------------
%% @doc miner_util
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_registry).

-define(CLI_MODULES, [
					  miner_cli_hbbft
					  ,miner_cli_genesis
					 ]).

-export([register_cli/0]).

register_cli() ->
	clique:register(?CLI_MODULES).
