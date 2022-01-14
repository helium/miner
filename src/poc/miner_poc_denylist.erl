-module(miner_poc_denylist).

-behaviour(gen_server).

-record(state, {
          type,
          key,
          url,
          version,
          etag
         }).

-export([init/1, handle_info/2, handle_cast/2, handle_call/3]).

-export([start_link/3, check/1, get_version/0, get_binary/0]).

start_link(Type, URL, Key) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Type, URL, Key], []).

-spec check(libp2p_crypto:pubkey_bin()) -> boolean().
check(PubkeyBin) ->
    try persistent_term:get(?MODULE) of
        Xor ->
            xorf:contains(Xor, xxhash:xxhash64(PubkeyBin))
    catch
        _:_ ->
            %% not enabled/ready
            false
    end.

-spec get_version() -> pos_integer().
get_version() ->
    gen_server:call(?MODULE, get_version).

-spec get_binary() -> binary().
get_binary() ->
    gen_server:call(?MODULE, get_binary).


%% gen_server callbacks

init([Type, URL, Key]) ->
    %% load up any existing xor we have on disk
    BaseDir = application:get_env(blockchain, base_dir, "data"),
    DenyFile = filename:join([BaseDir, "denylist", "latest"]),
    ok = filelib:ensure_dir(DenyFile),
    %% filter version will be an integer or undefined, depending on if we could load one from disk
    FilterVersion = case filelib:is_regular(DenyFile) of
                        true ->
                            case file:read_file(DenyFile) of
                                {ok, <<Version:8/integer, SignatureLen:16/integer-unsigned-little, Signature:SignatureLen/binary, Rest/binary>>} when Version == 1 ->
                                    %% check signature is still valid against our key
                                    case libp2p_crypto:verify(Rest, Signature, libp2p_crypto:b58_to_pubkey(Key)) of
                                        true ->
                                            <<Serial:32/integer-unsigned-little, FilterBin/binary>> = Rest,
                                            case xorf:from_bin(FilterBin) of
                                                {ok, Filter} ->
                                                    ok = persistent_term:put(?MODULE, Filter),
                                                    Serial;
                                                {error, Reason} ->
                                                    lager:notice("failed to deserialize denylist from disk: ~p", [Reason]),
                                                    undefined
                                            end;
                                        false ->
                                            lager:notice("failed to verify signature on denylist on disk"),
                                            undefined
                                    end;
                                _ ->
                                    lager:notice("unrecognized or corrupt denylist on disk"),
                                    undefined
                            end;
                        false ->
                            undefined
                    end,
    {ok, schedule_check(#state{type=Type, url=URL, key=Key, version=FilterVersion}, 0)}.

handle_info(check, #state{type=github_release, url=URL, key=Key, version=Version, etag=Etag}=State0) ->
    %% pull the release definition
    case httpc:request(get, {URL, [{"user-agent", "https://github.com/helium/miner"}] ++ [ {"if-none-match", Etag} || Etag /= undefined] }, [], [{body_format, binary}]) of
        {ok, {{_HttpVersion, 200, "OK"}, Headers, Body}} ->
            %% update the etag, no matter how the download/parse turns out
            State = State0#state{etag=proplists:get_value("etag", Headers)},
            try jsx:decode(Body, [{return_maps, true}]) of
                Json ->
                    VersionBin = integer_to_binary(Version),
                    case maps:get(<<"tag_name">>, Json, undefined) of
                        undefined ->
                            lager:notice("github release for ~p returning json without \"tag_name\" key"),
                            {noreply, schedule_check(State)};
                        VersionBin ->
                            {noreply, schedule_check(State)};
                        NewVersion when Version /= undefined andalso NewVersion < Version ->
                            lager:notice("denylist version has regressed from ~p to ~p", [Version, NewVersion]),
                            {noreply, schedule_check(State)};
                        NewVersion when Version == undefined orelse NewVersion > Version ->
                            lager:info("new denylist version appeared: ~p have ~p", [NewVersion, Version]),
                            case maps:get(<<"zipball_url">>, Json, undefined) of
                                undefined ->
                                    lager:notice("no zipball_url for release ~p", [NewVersion]),
                                    {noreply, schedule_check(State)};
                                ZipURL ->
                                    case httpc:request(get, {ZipURL, [{"user-agent", "https://github.com/helium/miner"}]}, [], [{body_format, binary}, {full_result, false}]) of
                                        {ok, {200, ZipBin}} ->
                                            case catch zip:foldl(fun(<<"denyfile">>, _I, B, _Acc) ->
                                                                         %% got what we wanted
                                                                         throw(B());
                                                                    (_, _, _, Acc) ->
                                                                            Acc
                                                                    end, none, {"zipfile", ZipBin}) of
                                                none ->
                                                    lager:notice("zip file for denylist release did not contain \"denyfile\" file"),
                                                    {noreply, schedule_check(State)};
                                                <<Version:8/integer, SignatureLen:16/integer-unsigned-little, Signature:SignatureLen/binary, Rest/binary>> = Bin when Version == 1 ->
                                                    %% check signature is still valid against our key
                                                    case libp2p_crypto:verify(Rest, Signature, libp2p_crypto:b58_to_pubkey(Key)) of
                                                        true ->
                                                            <<Serial:32/integer-unsigned-little, FilterBin/binary>> = Rest,
                                                            case xorf:from_bin(FilterBin) of
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
                                                                    {noreply, schedule_check(State#state{version=Serial})};
                                                                {error, Reason} ->
                                                                    lager:notice("failed to deserialize denylist from disk: ~p", [Reason]),
                                                                    {noreply, schedule_check(State)}
                                                            end;
                                                        false ->
                                                            lager:notice("failed to verify signature on denylist"),
                                                            {noreply, schedule_check(State)}
                                                    end;
                                                _ ->
                                                    lager:notice("unrecognized or corrupt denylist"),
                                                    {noreply, schedule_check(State)}
                                            end;
                                        ZipDownloadOther ->
                                            lager:notice("failed to download zip file release ~p : ~p", [ZipURL, ZipDownloadOther]),
                                            {noreply, schedule_check(State)}
                                    end
                            end
                    end
            catch
                _:_ ->
                    lager:notice("failed to decode github release json: ~p", [Body])
            end;
        {ok,{{_,304,"Not Modified"}, _}} ->
            schedule_check(State0);
        OtherHttpResult ->
            lager:notice("failed to fetch github release info ~p", [OtherHttpResult]),
            schedule_check(State0)
    end;
handle_info(Msg, State) ->
    lager:info("unhandled info msg ~p", [Msg]),
    {noreply, State}.

handle_cast(Msg, State) ->
    lager:info("unhandled cast msg ~p", [Msg]),
    {noreply, State}.

handle_call(Msg, _From, State) ->
    lager:info("unhandled call msg ~p", [Msg]),
    {reply, ok, State}.



schedule_check(State) ->
    schedule_check(State, timer:hours(6)).

schedule_check(State, Time) ->
    erlang:send_after(Time, self(), check),
    State.

