%% NOTE:
%% copied and modified from https://github.com/Bluehouse-Technology/grpc_client/blob/master/src/grpc_client_stream.erl
%% requires the gpb modules to have been created with the following config:
%%{gpb_opts, [
%%        {rename,{msg_fqname,base_name}},
%%        use_packages,
%%        {report_errors, false},
%%        {descriptor, false},
%%        {recursive, false},
%%        {i, "_build/default/lib/helium_proto/src"},
%%        {o, "src/grpc/autogen/client"},
%%        {module_name_prefix, ""},
%%        {module_name_suffix, "_client_pb"},
%%        {rename, {msg_name, {suffix, "_pb"}}},
%%        {strings_as_binaries, false},
%%        type_specs,
%%        {defs_as_proplists, true}
%%]}

%%%-------------------------------------------------------------------
%%% Licensed to the Apache Software Foundation (ASF) under one
%%% or more contributor license agreements.  See the NOTICE file
%%% distributed with this work for additional information
%%% regarding copyright ownership.  The ASF licenses this file
%%% to you under the Apache License, Version 2.0 (the
%%% "License"); you may not use this file except in compliance
%%% with the License.  You may obtain a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%

%% @private An a-synchronous client with a queue-like interface.
%% A gen_server is started for each stream, this keeps track
%% of the status of the http2 stream and it buffers responses in a queue.
-module(grpc_client_stream).

-behaviour(gen_server).

-export([new/6,
         send/2, send_last/2,
         get/1, rcv/1, rcv/2,
         state/1,
         call_rpc/3,
         stop/2]).

%% gen_server behaviors
-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-type stream() ::
    #{stream_id := integer(),
      package := string(),
      service := string(),
      rpc := string(),
      queue := queue:queue(),
      response_pending := boolean(),
      state := idle | open | half_closed_local | half_closed_remote | closed,
      encoder := module(),
      connection := grpc_client:connection(),
      headers_sent := boolean(),
      metadata := grpc_client:metadata(),
      compression := grpc_client:compression_method(),
      buffer := binary(),
      handler_callback := undefined,
      handler_state := undefined,
      type := unary | streaming | undefined,
      conn_monitor_ref := reference()
    }.

-export_type([stream/0]).

-spec new(Connection::grpc_client:connection(),
          Service::atom(),
          Rpc::atom(),
          Encoder::module(),
          Options::list(),
          HandlerMod::module() ) -> {ok, Pid::pid()} | {error, Reason::term()}.
new(Connection, Service, Rpc, Encoder, Options, HandlerMod) ->
    gen_server:start_link(?MODULE,
                          {Connection, Service, Rpc, Encoder, Options, HandlerMod}, []).

send(Pid, Message) ->
    gen_server:call(Pid, {send, Message}).

send_last(Pid, Message) ->
    gen_server:call(Pid, {send_last, Message}).

get(Pid) ->
    gen_server:call(Pid, get).

rcv(Pid) ->
    rcv(Pid, infinity).

rcv(Pid, Timeout) ->
    gen_server:call(Pid, {rcv, Timeout}, infinity).

%% @doc Get the state of the stream.
state(Pid) ->
    gen_server:call(Pid, state).

-spec stop(Stream::pid(), ErrorCode::integer()) -> ok.
%% @doc Close (stop/clean up) the stream.
%%
%% If the stream is in open or half closed state, a RST_STREAM frame
%% will be sent to the server.
stop(Pid, ErrorCode) ->
    gen_server:call(Pid, {stop, ErrorCode}).

%% @doc Call a unary rpc and process the response.
call_rpc(Pid, Message, Timeout) ->
    try send_last(Pid, Message) of
        ok ->
            process_response(Pid, Timeout)
    catch
        _:_ ->
            {error, #{error_type => client,
                      status_message => <<"failed to encode and send message">>}}
    end.

%% gen_server implementation
%% @private
init({#{http_connection := ConnPid} = Connection, Service, Rpc, Encoder, Options, HandlerMod}) ->
    try
        StreamType = proplists:get_value(type, Options, undefined),
        lager:info("init stream for RPC ~p and type ~p", [Rpc, StreamType]),
        Stream =  new_stream(Connection, Service, Rpc, Encoder, Options),
        lager:info("init stream success with state ~p, handle_mod: ~p", [Stream, HandlerMod]),
        HandlerState = HandlerMod:init(),
        %% monitor our connection, so we can tear down stream if conn dies
        Ref = monitor(process, ConnPid),
        {ok, Stream#{handler_state => HandlerState,
                     handler_callback => HandlerMod,
                     type => StreamType,
                     conn_monitor_ref => Ref}}
    catch
        _Class:_Error:_Stack ->
            lager:warning("failed to create stream, ~p ~p ~p", [_Class, _Error, _Stack]),
            {stop, <<"failed to create stream">>}
    end.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
handle_call(state, _From, #{state := State} = Stream) ->
    {reply, State, Stream};
handle_call({stop, ErrorCode}, _From, Stream) ->
    {stop, normal, ok, rst_stream(Stream, ErrorCode)};
handle_call({send_last, Message}, _From, Stream) ->
    {reply, ok, send_msg(Stream, Message, true)};
handle_call({send, Message}, _From, Stream) ->
    {reply, ok, send_msg(Stream, Message, false)};
handle_call(get, _From, #{queue := Queue,
                          state := StreamState} = Stream) ->
    {Value, NewQueue} = queue:out(Queue),
    Response = case {Value, StreamState} of
                   {{value, V}, _} ->
                       V;
                   {empty, S} when S == closed;
                                   S == half_closed_remote ->
                       eof;
                   {empty, _} ->
                       empty
               end,
    {reply, Response, Stream#{queue => NewQueue}};
handle_call({rcv, Timeout}, From, #{queue := Queue,
                                    state := StreamState} = Stream) ->
    {Value, NewQueue} = queue:out(Queue),
    NewStream = Stream#{queue => NewQueue},
    case {Value, StreamState} of
        {{value, V}, _} ->
            {reply, V, NewStream};
        {empty, S} when S == closed;
                        S == half_closed_remote ->
            {reply, eof, NewStream};
        {empty, _} ->
            {noreply, NewStream#{client => From,
                                 response_pending => true}, Timeout}
    end.

%% @private
handle_cast(_, State) ->
    {noreply, State}.

%% @private
handle_info({'RECV_DATA', StreamId, Bin}, Stream) ->
    %% This is a workaround to deal with the different format from Chatterbox.
    %% TODO: find a better way to do this.
    handle_info({'RECV_DATA', StreamId, Bin, false, false}, Stream);
handle_info({'RECV_DATA', StreamId, Bin,
             _StreamWindowError, _ConnectionWindowError},
            #{stream_id := StreamId,
              buffer := Buffer} = Stream) ->
    case <<Buffer/binary, Bin/binary>> of
        <<Encoded:8, Size:32, Message:Size/binary, Rest/binary>> ->
            Response =
                try
                   {data, decode(Encoded, Message, Stream#{buffer => Rest})}
                catch
                   throw:{error, Message} ->
                        {error, Message};
                    _Error:_Message ->
                        {error, <<"failed to decode message">>}
                end,
            info_response(Response, Stream#{buffer => Rest});
        NotComplete ->
            {noreply, Stream#{buffer => NotComplete}}
    end;

handle_info({'RECV_HEADERS', StreamId, Headers},
            #{stream_id := StreamId,
              state := StreamState} = Stream) ->
    HeadersMap = maps:from_list([grpc_lib:maybe_decode_header(H)
                                 || H <- Headers]),
    Encoding = maps:get(<<"grpc-encoding">>, HeadersMap, none),
    NewState = case StreamState of
                   idle ->
                       open;
                   _ ->
                       StreamState
               end,
    info_response({headers, HeadersMap},
                  Stream#{response_encoding => Encoding,
                          state => NewState});
handle_info({'END_STREAM', StreamId},
            #{stream_id := StreamId,
              state := StreamState} = Stream) ->
    NewState = case StreamState of
                   half_closed_local ->
                       closed;
                   _ ->
                       half_closed_remote
               end,
    info_response(eof, Stream#{state => NewState});
handle_info({ClosedMessage, StreamId, _ErrorCode},
            #{stream_id := StreamId} = Stream)
  when ClosedMessage == 'RESET_BY_PEER';
       ClosedMessage == 'CLOSED_BY_PEER' ->
    info_response(eof, Stream#{state => closed});
handle_info(timeout, #{response_pending := true,
                       client := Client} = Stream) ->
    gen_server:reply(Client, {error, timeout}),
    {noreply, Stream#{response_pending => false}};
handle_info({'DOWN', Ref, process, _, _Reason}, #{conn_mon := Ref} = C) ->
    %% our connection is down, nothing more stream can do other then terminate
    {stop, connection_down, C};
handle_info(Msg, #{handler_callback := HandlerCB} = Stream) ->
    NewState =
        case erlang:function_exported(HandlerCB, handle_info, 2) of
            true -> HandlerCB:handle_info(Msg, Stream);
            false -> Stream
        end,
    {noreply, NewState}.

%% @private
terminate(_Reason, _State) ->
    ok.


%% internal methods

new_stream(Connection, Service, Rpc, Encoder, Options) ->
    Compression = proplists:get_value(compression, Options, none),
    Metadata = proplists:get_value(metadata, Options, #{}),
    TransportOptions = proplists:get_value(http2_options, Options, []),
    {ok, StreamId} = grpc_client_connection:new_stream(Connection, TransportOptions),
    RpcDef = Encoder:find_rpc_def(Service, Rpc),
    RpcDefMap = maps:from_list(RpcDef),
    %% the gpb rpc def has 'input', 'output' etc.
    %% All the information is combined in 1 map,
    %% which is is the state of the gen_server.
    RpcDefMap#{stream_id => StreamId,
            package => [],
            service => Service,
            rpc => Rpc,
            queue => queue:new(),
            response_pending => false,
            state => idle,
            encoder => Encoder,
            connection => Connection,
            headers_sent => false,
            metadata => Metadata,
            compression => Compression,
            buffer => <<>>}.

send_msg(#{stream_id := StreamId,
           connection := Connection,
           headers_sent := HeadersSent,
           metadata := Metadata,
           state := State
          } = Stream, Message, EndStream) ->
    Encoded = encode(Stream, Message),
    case HeadersSent of
        false ->
            DefaultHeaders = default_headers(Stream),
            AllHeaders = add_metadata(DefaultHeaders, Metadata),
            ok = grpc_client_connection:send_headers(Connection, StreamId, AllHeaders);
        true ->
            ok
    end,
    Opts = [{end_stream, EndStream}],
    NewState =
        case {EndStream, State} of
            {false, _} when State == idle ->
                open;
            {false, _} ->
                State;
            {true, _} when State == open;
                           State == idle ->
                half_closed_local;
            {true, _} ->
                closed
        end,
    ok = grpc_client_connection:send_body(Connection, StreamId, Encoded, Opts),
    Stream#{headers_sent => true,
            state => NewState}.

rst_stream(#{connection := Connection,
             stream_id := StreamId} = Stream, ErrorCode) ->
    grpc_client_connection:rst_stream(Connection, StreamId, ErrorCode),
    Stream#{state => closed}.

default_headers(#{service := Service,
                  rpc := Rpc,
                  package := Package,
                  compression := Compression,
                  connection := #{host := Host,
                                  scheme := Scheme}
                 }) ->
    Path = iolist_to_binary(["/", Package, atom_to_list(Service),
                             "/", atom_to_list(Rpc)]),
    Headers1 = case Compression of
                   none ->
                       [];
                   _ ->
                       [{<<"grpc-encoding">>,
                         atom_to_binary(Compression, unicode)}]
               end,
    [{<<":method">>, <<"POST">>},
     {<<":scheme">>, Scheme},
     {<<":path">>, Path},
     {<<":authority">>, Host},
     {<<"content-type">>, <<"application/grpc+proto">>},
     {<<"user-agent">>, <<"grpc-erlang/0.0.1">>},
     {<<"te">>, <<"trailers">>} | Headers1].

add_metadata(Headers, Metadata) ->
    lists:foldl(fun(H, Acc) ->
                        {K, V} = grpc_lib:maybe_encode_header(H),
                        %% if the key exists, replace it.
                        lists:keystore(K, 1, Acc, {K,V})
                end, Headers, maps:to_list(Metadata)).

info_response(Response, #{response_pending := true,
                          client := Client} = Stream) ->
    gen_server:reply(Client, Response),
    {noreply, Stream#{response_pending => false}};
info_response(Response, #{queue := Queue, type := unary} = Stream) ->
    NewQueue = queue:in(Response, Queue),
    {noreply, Stream#{queue => NewQueue}};
info_response(eof = Response, #{type := Type, state := closed} = Stream) ->
    lager:info("info_response ~p, stream type: ~p", [Response, Type]),
    {stop, normal, Stream};
%% pass any unmatched info msg to our handler
info_response(Response, #{handler_callback := CB, handler_state := CBState} = Stream) ->
    lager:info("info_response ~p, CB: ~p", [Response, CB]),
    NewCBState = CB:handle_msg(Response, CBState),
    {noreply, Stream#{handler_callback_state => NewCBState}}.
%% TODO: fix the error handling, currently it is very hard to understand the
%% error that results from a bad message (Map).
encode(#{encoder := Encoder,
         input := MsgType,
         compression := CompressionMethod}, Map) ->
    %% RequestData = Encoder:encode_msg(Map, MsgType),
    try Encoder:encode_msg(Map, MsgType) of
        RequestData ->
            maybe_compress(RequestData, CompressionMethod)
    catch
        error:function_clause ->
          throw({error, {failed_to_encode, MsgType, Map}});
        Error:Reason ->
          throw({error, {Error, Reason}})
    end.

maybe_compress(Encoded, none) ->
    Length = byte_size(Encoded),
    <<0, Length:32, Encoded/binary>>;
maybe_compress(Encoded, gzip) ->
    Compressed = zlib:gzip(Encoded),
    Length = byte_size(Compressed),
    <<1, Length:32, Compressed/binary>>;
maybe_compress(_Encoded, Other) ->
    throw({error, {compression_method_not_supported, Other}}).

decode(Encoded, Binary,
       #{response_encoding := Method,
         encoder := Encoder,
         output := MsgType}) ->
    Message = case Encoded of
                  1 -> decompress(Binary, Method);
                  0 -> Binary
              end,
    Encoder:decode_msg(Message, MsgType).

decompress(Compressed, <<"gzip">>) ->
    zlib:gunzip(Compressed);
decompress(_Compressed, Other) ->
    throw({error, {decompression_method_not_supported, Other}}).

process_response(Pid, Timeout) ->
    case rcv(Pid, Timeout) of
        {headers, #{<<":status">> := <<"200">>,
                    <<"grpc-status">> := GrpcStatus} = Trailers}
          when GrpcStatus /= <<"0">> ->
            %% "trailers only" response.
            grpc_response(#{}, #{}, Trailers);
        {headers, #{<<":status">> := <<"200">>} = Headers} ->
            get_message(Headers, Pid, Timeout);
        {headers, #{<<":status">> := HttpStatus} = Headers} ->
            {error, #{error_type => http,
                      status => {http, HttpStatus},
                      headers => Headers}};
        {headers, #{<<"grpc-status">> := GrpcStatus} = Headers}
          when GrpcStatus == <<"14">> ->
            {error, #{error_type => http,
                      status => {http, <<"503">>},
                      headers => Headers}};
        {error, timeout} ->
            {error, #{error_type => timeout}}
    end.

get_message(Headers, Pid, Timeout) ->
    case rcv(Pid, Timeout) of
        {data, Response} ->
            get_trailer(Response, Headers, Pid, Timeout);
        {headers, Trailers} ->
            grpc_response(Headers, #{}, Trailers);
        {error, timeout} ->
            {error, #{error_type => timeout,
                      headers => Headers}}
    end.

get_trailer(Response, Headers, Pid, Timeout) ->
    case rcv(Pid, Timeout) of
        {headers, Trailers} ->
            grpc_response(Headers, Response, Trailers);
        {error, timeout} ->
            {error, #{error_type => timeout,
                      headers => Headers,
                      result => Response}}
    end.

grpc_response(Headers, Response, #{<<"grpc-status">> := <<"0">>} = Trailers) ->
    StatusMessage = maps:get(<<"grpc-message">>, Trailers, <<"">>),
    {ok, #{status_message => StatusMessage,
           http_status => 200,
           grpc_status => 0,
           headers => Headers,
           result => Response,
           trailers => Trailers}};
grpc_response(Headers, Response, #{<<"grpc-status">> := ErrorStatus} = Trailers) ->
    StatusMessage = maps:get(<<"grpc-message">>, Trailers, <<"">>),
    {error, #{error_type => grpc,
              http_status => 200,
              grpc_status => binary_to_integer(ErrorStatus),
              status_message => StatusMessage,
              headers => Headers,
              result => Response,
              trailers => Trailers}}.
