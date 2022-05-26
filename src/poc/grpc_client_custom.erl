%% NOTE:
%% copied and modified from https://github.com/Bluehouse-Technology/grpc_client/blob/master/src/grpc_client.erl
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

%% @doc The interface for grpc_client.
%%
%% This module contains the functions use a gRPC service from Erlang.
%%
%% See the Readme in the root folder of the repository for a reference to a
%% more general (tutorial-style) introduction.
%%
-module(grpc_client).

-export([compile/1, compile/2,
         connect/3, connect/4,
         new_stream/4, new_stream/5,
         send/2, send_last/2,
         unary/6,
         rcv/1, rcv/2,
         get/1,
         ping/2,
         stop_stream/1, stop_stream/2,
         stop_connection/1]).

-type connection_option() ::
    verify_server_opt() |
    server_host_override_opt() |
    http2_client_opt() |
    {http2_options, [http2_option()]}.

-type verify_server_opt() :: {verify_server_identity, boolean()}.
%% If true (and if the transport is ssl), the client will verify
%% that the subject of the server certificate matches with the domain
%% of the server (use the 'server_host_override' to check against
%% another name).

-type server_host_override_opt() :: {server_host_override, string()}.
%% If the 'verify_server_identity' option is set, check the subject of
%% the server certificate against this name (rather than against the host name).

-type http2_client_opt() :: {http2_client, module()}.
%% A module that implements an HTPP/2 client (with a specific API).
%% By default 'http2_client' will be used. As an alternative
%% 'grpc_client_chatterbox_adapter' can be used, which provides an interface to the
%% chatterbox http/2 client, or any other HTTP/2 client implementation with the right
%% API.

-type http2_option() :: term().
%% Passed on to the HTTP/2 client. See the documentation of 'http2_client' for the options
%% that can be specified for the default HTTP2/2 client.

-type connection() :: #{http_connection := pid(),
                        host := binary(),
                        scheme := binary(),
                        client := module()}.

-type metadata_key() :: binary().
-type metadata_value() :: binary().
-type metadata() :: #{metadata_key() => metadata_value()}.
-type compression_method() :: none | gzip.

-type stream_option() ::
    {metadata, metadata()} |
    {compression, compression_method()} |
    {http2_options, [term()]}.

-type client_stream() :: pid().

-type rcv_response() :: {data, map()} |
                        {headers, metadata()} |
                        eof | {error, term()}.

-type get_response()  :: rcv_response() | empty.

-type unary_response() :: ok_response() | error_response().

-type ok_response() ::
    {ok, #{result := any(),
           status_message := binary(),
           http_status := 200,
           grpc_status := 0,
           headers := metadata(),
           trailers := metadata()}}.

-type error_response() ::
    {error, #{error_type => error_type(),
              http_status => integer(),
              grpc_status => integer(),
              status_message => binary(),
              headers => metadata(),
              result => any(),
              trailers => grpc:metadata()}}.

-type error_type() :: client | timeout | http | grpc.

-export_type([connection/0,
              stream_option/0,
              connection_option/0,
              client_stream/0,
              unary_response/0,
              metadata/0,
              compression_method/0
             ]).

-spec compile(FileName::string()) -> ok.
%% @equiv compile(FileName, [])
compile(FileName) ->
    grpc_client:compile(FileName, []).

-spec compile(FileName::string(), Options::gpb_compile:opts()) -> ok.
%% @doc Compile a .proto file to generate client stubs and a module
%% to encode and decode the protobuf messages.
%%
%% Refer to gpb for the options. grpc_client will always use the option
%% 'maps' (so that the protobuf messages are translated to and
%% from maps) and the option '{i, "."}' (so that .proto files in the
%% current working directory will be found).
compile(FileName, Options) ->
    grpc_lib_compile:file(FileName, [{generate, client} | Options]).

-spec connect(Transport::tcp|ssl,
              Host::string(),
              Port::integer()) -> {ok, connection()} | {error, term()}.
%% @equiv connect(Transport, Host, Port, [])
connect(Transport, Host, Port) ->
    connect(Transport, Host, Port, []).

-spec connect(Transport::tcp|ssl,
              Host::string(),
              Port::integer(),
              Options::[connection_option()]) -> {ok, connection()} | {error, term()}.
%% @doc Start a connection to a gRPC server.
%%
%% If 'verify_server_identity' is true (and Transport == ssl), the client will
%% check that the subject of the certificate received from the server is
%% identical to Host.
%%
%% If it is known that the server returns a certificate with another subject
%% than the host name, the 'server_host_override' option can be used to
%% specify that other subject.
%%
%% The transport options will be passed to the selected Transport when
%% establishing the connection.
%%
%% The option {'http2_client', module()} enables the selection of
%% an http2 client. The default is http2_client, as an alternative it
%% is possible to select 'grpc_client_chatterbox_adapter', which
%% implements an adapter for the chatterbox http/2 client.
connect(Transport, Host, Port, Options) ->
    grpc_client_connection:new(Transport, Host, Port, Options).

-spec new_stream(Connection::connection(),
                 Service::atom(),
                 Rpc::atom(),
                 DecoderModule::module()) -> {ok, Pid::pid()} | {error, Reason::term()}.
%% @equiv new_stream(Connection, Service, Rpc, DecoderModule, [])
new_stream(Connection, Service, Rpc, DecoderModule) ->
    new_stream(Connection, Service, Rpc, DecoderModule, []).

-spec new_stream(Connection::connection(),
                 Service::atom(),
                 Rpc::atom(),
                 DecoderModule::module(),
                 Options::[stream_option()]) -> {ok, Pid::pid()} | {error, Reason::term()}.
%% @doc Create a new stream to start a new RPC.
new_stream(Connection, Service, Rpc, DecoderModule, Options) ->
    CBMod = proplists:get_value(callback_mod, Options),
    grpc_client_stream:new(Connection, Service, Rpc, DecoderModule, Options, CBMod).

-spec send(Stream::client_stream(), Msg::any()) -> ok.
%% @doc Send a message from the client to the server.
send(Stream, Msg) when is_pid(Stream) ->
    grpc_client_stream:send(Stream, Msg).

-spec send_last(Stream::client_stream(), Msg::map()) -> ok.
%% @doc Send a message to server and mark it as the last message
%% on the stream. For simple RPC and client-streaming RPCs that
%% will trigger the response from the server.
send_last(Stream, Msg) when is_pid(Stream)->
    grpc_client_stream:send_last(Stream, Msg).

-spec rcv(Stream::client_stream()) -> rcv_response().
%% @equiv rcv(Stream, infinity)
rcv(Stream) ->
    grpc_client_stream:rcv(Stream).

-spec rcv(Stream::client_stream(), Timeout::timeout()) -> rcv_response().
%% @doc Receive a message from the server. This is a blocking
%% call, it returns when a message has been received or after Timeout.
%% Timeout is in milliseconds.
%%
%% Returns 'eof' after the last message from the server has been read.
rcv(Stream, Timeout) ->
    grpc_client_stream:rcv(Stream, Timeout).

-spec get(Stream::client_stream()) -> get_response().
%% @doc Get a message from the stream, if there is one in the queue. If not return
%% 'empty'. This is a non-blocking call.
%%
%% Returns 'eof' after the last message from the server has been read.
get(Stream) ->
    grpc_client_stream:get(Stream).

-spec ping(
    Connection::connection(),
    Timeout::timeout()) -> {ok, RoundTripTime::integer()} | {error, term()}.
%% @doc Send a PING request.
ping(Connection, Timeout) ->
    grpc_client_connection:ping(Connection, Timeout).

-spec stop_stream(Stream::client_stream()) -> ok.
%% @equiv stop_stream(Stream, 0)
stop_stream(Stream) ->
    stop_stream(Stream, 0).

-spec stop_stream(Stream::client_stream(), ErrorCode::integer()) -> ok.
%% @doc
%% Stops a stream. Depending on the state of the connection a 'RST_STREAM'
%% frame may be sent to the server with the provided Errorcode (it should be
%% a HTTP/2 error code, see RFC7540).
stop_stream(Stream, ErrorCode) ->
    grpc_client_stream:stop(Stream, ErrorCode).

-spec stop_connection(Connection::connection()) -> ok.
%% @doc Stop a connection and clean up.
stop_connection(Connection) ->
    grpc_client_connection:stop(Connection).

-spec unary(Connection::connection(),
            Message::tuple(), Service::atom(), Rpc::atom(),
            Decoder::module(),
            Options::[stream_option() |
                      {timeout, timeout()} |
                      {callback_mod, atom()}]) -> unary_response().
%% @doc Call a unary rpc in one go.
%%
%% Set up a stream, receive headers, message and trailers, stop
%% the stream and assemble a response. This is a blocking function.
unary(Connection, Message, Service, Rpc, Decoder, Options) ->
    {Timeout, StreamOptions} = grpc_lib:keytake(timeout, Options, infinity),
    try
        {ok, Stream} = new_stream(Connection, Service,
                                  Rpc, Decoder, [{type, unary} | StreamOptions]),
        Response = grpc_client_stream:call_rpc(Stream, Message, Timeout),
        stop_stream(Stream),
        Response
    catch
        _Type:_Error:_Stack ->
            lager:warning("Failed to create stream. Type: ~p, Error: ~p, Stack:~p", [_Type, _Error, _Stack]),
            {error, #{error_type => client,
                      status_message => <<"stream create failed">>}}
    end.
