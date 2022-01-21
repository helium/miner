%%%----------------------------------------------------
%% @doc miner_info
%%      return metadata about the miner for
%%      various APIs such as cli or jsonrpc
%% @end
%%%
-module(miner_info).

-export([firmware_version/0,
         height_info/0,
         version/0]).

-include_lib("blockchain/include/blockchain.hrl").

-define(RELEASE_FILE, "/etc/os-release").

-spec firmware_version() -> string().
firmware_version() ->
    ReleaseInfo = os:cmd("cat " ++ ?RELEASE_FILE),
    PrettyName0 = case re:run(ReleaseInfo, "PRETTY_NAME=\"(.*)\"", [{capture, all_but_first, list}]) of
                      {match, [PrettyNameCapture]} -> PrettyNameCapture;
                      _ -> "unknown"
                  end,
    MinerVzn = version(),
    PrettyName = case re:run(PrettyName0, MinerVzn) of
                     nomatch ->
                         PrettyName0 ++ ", " ++ MinerVzn;
                     {match, _} ->
                         PrettyName0
                 end,
    PrettyName.

-spec height_info() -> #{height => non_neg_integer(), sync_height => non_neg_integer(), epoch => non_neg_integer()}.
height_info() ->
    Chain = blockchain_worker:blockchain(),
    {ok, SyncHeight} = blockchain:sync_height(Chain),
    {ok, #block_info_v2{election_info={Epoch, _}, height=Height}} = blockchain:head_block_info(Chain),
    #{height => Height, sync_height => SyncHeight, epoch => Epoch}.

-spec version() -> string().
version() ->
    Releases = release_handler:which_releases(permanent),
    case erlang:hd(Releases) of
        {_, ReleaseVersion, _, _} -> ReleaseVersion;
        {error, _} -> "unknown"
    end.
