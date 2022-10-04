-module(miner_poc_denylist).

-behaviour(gen_server).

-record(state, {
          type,
          keys,
          url,
          version=0,
          etag
         }).

-export([init/1, handle_info/2, handle_cast/2, handle_call/3]).

-export([start_link/0, check/1, get_version/0, get_binary/0]).

start_link() ->
    case application:get_env(miner, denylist_keys, undefined) of
        DenyKeys = [H|_] when is_list(H) ->
            case application:get_env(miner, denylist_url, undefined) of
                "none" ->
                    ignore;
                undefined ->
                    gen_server:start_link({local, ?MODULE}, ?MODULE, [github_release, "https://api.github.com/repos/helium/denylist/releases/latest", DenyKeys], []);
                DenyURL ->
                    Type = application:get_env(miner, denylist_type, github_release),
                    gen_server:start_link({local, ?MODULE}, ?MODULE, [Type, DenyURL, DenyKeys], [])
            end;
        "none" ->
            ignore;
        undefined ->
            gen_server:start_link({local, ?MODULE}, ?MODULE, [github_release, "https://api.github.com/repos/helium/denylist/releases/latest", []], []);
        Other ->
            lager:warning("unhandled denylist_keys format ~p", [Other]),
            ignore
    end.

-spec check(libp2p_crypto:pubkey_bin()) -> boolean().
check(PubkeyBin) ->
    try persistent_term:get(?MODULE) of
        Xor ->
            xorf:contains(Xor, xxhash:hash64(PubkeyBin))
    catch
        _:_ ->
            %% not enabled/ready
            false
    end.

-spec get_version() -> {ok, non_neg_integer()}.
get_version() ->
    gen_server:call(?MODULE, get_version).

-spec get_binary() -> {ok, binary()} | {error, term()}.
get_binary() ->
    BaseDir = application:get_env(blockchain, base_dir, "data"),
    DenyFile = filename:join([BaseDir, "denylist", "latest"]),
    file:read_file(DenyFile).

%% gen_server callbacks

init([Type, URL, Keys]) ->
    %% load up any existing xor we have on disk
    BaseDir = application:get_env(blockchain, base_dir, "data"),
    DenyFile = filename:join([BaseDir, "denylist", "latest"]),
    ok = filelib:ensure_dir(DenyFile),
    %% filter version will be a positive integer or 0 depending on if we could load one from disk
    FilterVersion = case filelib:is_regular(DenyFile) of
                        true ->
                            case file:read_file(DenyFile) of
                                {ok, <<Version:8/integer, SignatureLen:16/integer-unsigned-little, Signature:SignatureLen/binary, Rest/binary>>} when Version == 1 ->
                                    %% check signature is still valid against our key
                                    case lists:any(fun(Key) -> verify_signature(Key, Rest, Signature) end, Keys) of
                                        true ->
                                            <<Serial:32/integer-unsigned-little, FilterBin/binary>> = Rest,
                                            case xorf:from_bin({exor, 32}, FilterBin) of
                                                {ok, Filter} ->
                                                    ok = persistent_term:put(?MODULE, Filter),
                                                    Serial;
                                                {error, Reason} ->
                                                    lager:notice("failed to deserialize denylist from disk: ~p", [Reason]),
                                                    0
                                            end;
                                        _ ->
                                            lager:notice("failed to verify signature on denylist on disk"),
                                            0
                                    end;
                                _ ->
                                    lager:notice("unrecognized or corrupt denylist on disk"),
                                    0
                            end;
                        false ->
                            0
                    end,
    {ok, schedule_check(#state{type=Type, url=URL, keys=Keys, version=FilterVersion}, 0)}.

handle_info(check, #state{type=github_release, url=URL, keys=Keys, version=Version, etag=Etag}=State) ->
    %% pull the release definition
    case httpc:request(get, {URL, [{"user-agent", "https://github.com/helium/miner"}] ++ [ {"if-none-match", Etag} || Etag /= undefined] }, [], [{body_format, binary}]) of
        {ok, {{_HttpVersion, 200, "OK"}, Headers, Body}} ->
            try jsx:decode(Body, [{return_maps, true}]) of
                Json ->
                    case maybe_binary_to_integer(maps:get(<<"tag_name">>, Json, undefined)) of
                        undefined ->
                            lager:notice("github release for ~p returning json without \"tag_name\" key"),
                            {noreply, schedule_check(State)};
                        Version->
                            lager:info("already have version ~p", [Version]),
                            {noreply, schedule_check(State#state{etag=proplists:get_value("etag", Headers)})};
                        NewVersion when NewVersion < Version->
                            lager:notice("denylist version has regressed from ~p to ~p, ignoring", [Version, NewVersion]),
                            {noreply, schedule_check(State#state{etag=proplists:get_value("etag", Headers)})};
                        NewVersion when NewVersion > Version ->
                            lager:info("new denylist version appeared: ~p have ~p", [NewVersion, Version]),
                            case maps:get(<<"assets">>, Json, undefined) of
                                undefined ->
                                    lager:notice("no zipball_url for release ~p", [NewVersion]),
                                    {noreply, schedule_check(State)};
                                Assets ->
                                    case lists:filter(fun(Asset) ->
                                                              maps:get(<<"name">>, Asset, undefined) == <<"filter.bin">>
                                                      end, Assets) of
                                        [] ->
                                            lager:notice("no filter.bin asset in release ~p", [NewVersion]),
                                            {noreply, schedule_check(State)};
                                        [Asset] ->
                                            AssetURL = maps:get(<<"browser_download_url">>, Asset),
                                            case httpc:request(get, {binary_to_list(AssetURL), [{"user-agent", "https://github.com/helium/miner"}]}, [], [{body_format, binary}, {full_result, false}]) of
                                                {ok, {200, AssetBin}} ->
                                                    case AssetBin of
                                                        <<AssetVersion:8/integer, SignatureLen:16/integer-unsigned-little, Signature:SignatureLen/binary, Rest/binary>> = Bin when AssetVersion == 1 ->
                                                            %% check signature is still valid against our key
                                                            case lists:any(fun(Key) -> verify_signature(Key, Rest, Signature) end, Keys) of
                                                                true ->
                                                                    case Rest of
                                                                        <<NewVersion:32/integer-unsigned-little, FilterBin/binary>> ->
                                                                            case xorf:from_bin({exor, 32}, FilterBin) of
                                                                                {ok, Filter} ->
                                                                                    BaseDir = application:get_env(blockchain, base_dir, "data"),
                                                                                    DenyFile = filename:join([BaseDir, "denylist", "latest"]),
                                                                                    TmpDenyFile = DenyFile ++ "-tmp",
                                                                                    case file:write_file(TmpDenyFile, Bin) of
                                                                                        ok ->
                                                                                            case file:rename(TmpDenyFile, DenyFile) of
                                                                                                ok ->
                                                                                                    ok;
                                                                                                {error, RenameReason} ->
                                                                                                    lager:notice("failed to rename ~p to ~p: ~p", [TmpDenyFile, DenyFile, RenameReason])
                                                                                            end;
                                                                                        {error, WriteReason} ->
                                                                                            lager:notice("failed to write denyfile ~p to disk ~p", [TmpDenyFile, WriteReason])
                                                                                    end,
                                                                                    ok = persistent_term:put(?MODULE, Filter),
                                                                                    {noreply, schedule_check(State#state{version=NewVersion, etag=proplists:get_value("etag", Headers)})};
                                                                                {error, Reason} ->
                                                                                    lager:notice("failed to deserialize denylist from disk: ~p", [Reason]),
                                                                                    {noreply, schedule_check(State)}
                                                                            end;
                                                                        <<OtherVersion:32/integer-unsigned-little, _/binary>> ->
                                                                            lager:notice("denylist release ~p contained wrong serial number ~p, rejecting", [NewVersion, OtherVersion]),
                                                                            {noreply, schedule_check(State)}
                                                                    end;
                                                                _ ->
                                                                    lager:notice("failed to verify signature on denylist"),
                                                                    {noreply, schedule_check(State)}
                                                            end;
                                                        Corrupt ->
                                                            lager:notice("unrecognized or corrupt denylist ~p", [Corrupt]),
                                                            {noreply, schedule_check(State)}
                                                    end;
                                                AssetDownloadOther ->
                                                    lager:notice("failed to download asset file release ~p : ~p", [AssetURL, AssetDownloadOther]),
                                                    {noreply, schedule_check(State)}
                                            end
                                    end
                            end
                    end
            catch
                _:_ ->
                    lager:notice("failed to decode github release json: ~p", [Body]),
                    {noreply, schedule_check(State)}
            end;
        {ok,{{_,304,"Not Modified"}, _, _}} ->
            lager:info("already have this etag"),
            {noreply, schedule_check(State)};
        OtherHttpResult ->
            lager:notice("failed to fetch github release info ~p", [OtherHttpResult]),
            {noreply, schedule_check(State)}
    end;
handle_info(Msg, State) ->
    lager:info("unhandled info msg ~p", [Msg]),
    {noreply, State}.

handle_cast(Msg, State) ->
    lager:info("unhandled cast msg ~p", [Msg]),
    {noreply, State}.

handle_call(get_version, _From, State) ->
    {reply, {ok, State#state.version}, State};
handle_call(Msg, _From, State) ->
    lager:info("unhandled call msg ~p", [Msg]),
    {reply, ok, State}.

verify_signature(Key, Binary, Signature) ->
    case catch libp2p_crypto:verify(Binary, Signature, libp2p_crypto:b58_to_pubkey(Key)) of
        true -> true;
        _ -> false
    end.

schedule_check(State) ->
    schedule_check(State, timer:hours(6)).

schedule_check(State, Time) ->
    erlang:send_after(Time, self(), check),
    State.

-spec maybe_binary_to_integer(binary() | undefined) -> integer() | undefined.
maybe_binary_to_integer(Bin) ->
    case Bin of
        undefined -> undefined;
        _         -> binary_to_integer(Bin)
    end.
