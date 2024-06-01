%% Copyright (c) 2011-2012, 2014 Basho Technologies, Inc.  All Rights Reserved.
%% Copyright (c) 2021 Helium Systems Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

%% @doc Telemetry backend for lager.
%% Configuration is a proplist with the following keys:
%% <ul>
%%    <li>`level' - log level to use</li>
%%    <li>`formatter' - the module to use when formatting log messages. Defaults to
%%                      `lager_default_formatter'</li>
%%    <li>`formatter_config' - the format configuration string. Defaults to
%%                             `time [ severity ] message'</li>
%% </ul>

-module(miner_lager_telemetry_backend).

-behaviour(gen_event).

-export([
    init/1,
    handle_call/2,
    handle_event/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    level :: {'mask', integer()},
    id :: atom() | {atom(), any()},
    formatter :: atom(),
    format_config :: any()
}).

-include_lib("lager/include/lager.hrl").

-define(TERSE_FORMAT, [date, " ", time, " ", module, ": [", severity, "] ", message]).
-define(DEFAULT_FORMAT_CONFIG, ?TERSE_FORMAT).

%% @private
init(Options) when is_list(Options) ->
    true = validate_options(Options),

    Level = get_option(level, Options, undefined),
    try lager_util:config_to_mask(Level) of
        L ->
            [ID, Formatter, Config] = [
                get_option(K, Options, Default)
             || {K, Default} <- [
                    {id, ?MODULE},
                    {formatter, lager_default_formatter},
                    {formatter_config, ?DEFAULT_FORMAT_CONFIG}
                ]
            ],
            {ok, #state{
                level = L,
                id = ID,
                formatter = Formatter,
                format_config = Config
            }}
    catch
        _:_ ->
            {error, {fatal, bad_log_level}}
    end;
init(Other) ->
    {error, {fatal, {bad_telemetry_config, Other}}}.

validate_options([]) ->
    true;
validate_options([{level, L} | T]) when is_atom(L) ->
    case lists:member(L, ?LEVELS) of
        false ->
            throw({error, {fatal, {bad_level, L}}});
        true ->
            validate_options(T)
    end;
validate_options([{use_stderr, true} | T]) ->
    validate_options(T);
validate_options([{use_stderr, false} | T]) ->
    validate_options(T);
validate_options([{formatter, M} | T]) when is_atom(M) ->
    validate_options(T);
validate_options([{formatter_config, C} | T]) when is_list(C) ->
    validate_options(T);
validate_options([{group_leader, L} | T]) when is_pid(L) ->
    validate_options(T);
validate_options([{id, {?MODULE, _}} | T]) ->
    validate_options(T);
validate_options([H | _]) ->
    throw({error, {fatal, {bad_telemetry_config, H}}}).

get_option(K, Options, Default) ->
    case lists:keyfind(K, 1, Options) of
        {K, V} -> V;
        false -> Default
    end.

%% @private
handle_call(get_loglevel, #state{level = Level} = State) ->
    {ok, Level, State};
handle_call({set_loglevel, Level}, State) ->
    try lager_util:config_to_mask(Level) of
        Levels ->
            {ok, ok, State#state{level = Levels}}
    catch
        _:_ ->
            {ok, {error, bad_log_level}, State}
    end;
handle_call(_Request, State) ->
    {ok, ok, State}.

%% @private
handle_event(
    {log, Message},
    #state{level = L, formatter = Formatter, format_config = FormatConfig, id = ID} = State
) ->
    case lager_util:is_loggable(Message, L, ID) of
        true ->
            miner_telemetry:log(
              [{severity, lager_msg:severity(Message)} | lager_msg:metadata(Message)],
              iolist_to_binary(Formatter:format(Message, FormatConfig, []))),
            {ok, State};
        false ->
            {ok, State}
    end;
handle_event(_Event, State) ->
    {ok, State}.

%% @private
handle_info(_Info, State) ->
    {ok, State}.

%% @private
terminate(remove_handler, _State = #state{id = ID}) ->
    %% have to do this asynchronously because we're in the event handlr
    spawn(fun() -> lager:clear_trace_by_destination(ID) end),
    ok;
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
