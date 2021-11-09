%%%-------------------------------------------------------------------
%% @doc
%% == Miner PoC Statem ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_poc_statem).

-behavior(gen_statem).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    receipt/3,
    witness/2
]).

%% ------------------------------------------------------------------
%% gen_statem Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    code_change/3,
    callback_mode/0,
    terminate/2
]).

%% ------------------------------------------------------------------
%% gen_statem callbacks Exports
%% ------------------------------------------------------------------
-export([
    requesting/3,
    mining/3,
    receiving/3,
    waiting/3
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain_caps.hrl").

-define(SERVER, ?MODULE).
-define(MINING_TIMEOUT, 30).
-define(CHALLENGE_RETRY, 3).
-ifdef(TEST).
-define(RECEIVING_TIMEOUT, 10).
-define(RECEIPTS_TIMEOUT, 10).
-else.
-define(RECEIVING_TIMEOUT, 20).
-define(RECEIPTS_TIMEOUT, 20).
-endif.
-define(STATE_FILE, "miner_poc_statem.state").
-define(POC_RESTARTS, 3).
-define(ADDR_HASH_FP_RATE, 1.0e-9).

-ifdef(TEST).
-define(BLOCK_PROPOGATION_TIME, timer:seconds(1)).
-else.
-define(BLOCK_PROPOGATION_TIME, timer:seconds(300)).
-endif.

-record(addr_hash_filter, {
          start :: pos_integer(),
          height :: pos_integer(),
          byte_size :: pos_integer(),
          salt :: binary(),
          bloom :: bloom_nif:bloom()
         }).

-record(data, {
    base_dir :: file:filename_all() | undefined,
    blockchain :: blockchain:blockchain() | undefined,
    address :: libp2p_crypto:pubkey_bin() | undefined,
    poc_interval :: non_neg_integer() | undefined,

    state = requesting :: state(),
    secret :: binary() | undefined,
    onion_keys :: keys() | undefined,
    challengees = [] :: [{libp2p_crypto:pubkey_bin(), binary()}],
    packet_hashes = [] :: [{libp2p_crypto:pubkey_bin(), binary()}],
    responses = #{},
    receiving_timeout = ?RECEIVING_TIMEOUT :: non_neg_integer(),
    poc_hash  :: binary() | undefined,
    request_block_hash  :: binary() | undefined,
    mining_timeout = ?MINING_TIMEOUT :: non_neg_integer(),
    retry = ?CHALLENGE_RETRY :: non_neg_integer(),
    receipts_timeout = ?RECEIPTS_TIMEOUT :: non_neg_integer(),
    poc_restarts = ?POC_RESTARTS :: non_neg_integer(),
    txn_ref = make_ref() :: reference(),
    addr_hash_filter :: undefined | #addr_hash_filter{}
}).

-type state() :: requesting | mining | receiving | waiting.
-type data() :: #data{}.
-type keys() :: #{secret => libp2p_crypto:privkey(), public => libp2p_crypto:pubkey()}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_statem:start_link({local, ?SERVER}, ?SERVER, Args, [{hibernate_after, 5000}]).

receipt(Address, Data, PeerAddr) ->
    gen_statem:cast(?SERVER, {receipt, Address, Data, PeerAddr}).

witness(Address, Data) ->
    gen_statem:cast(?SERVER, {witness, Address, Data}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    ok = blockchain_event:add_handler(self()),
    ok = miner_poc:add_stream_handler(blockchain_swarm:tid()),
    ok = miner_onion:add_stream_handler(blockchain_swarm:tid()),
    Address = blockchain_swarm:pubkey_bin(),
    Blockchain = blockchain_worker:blockchain(),
    BaseDir = maps:get(base_dir, Args, undefined),
    %% this should really only be overriden for testing
    Delay = maps:get(delay, Args, undefined),
    lager:info("init with ~p", [Args]),
    case load_data(BaseDir) of
        {error, _} ->
            {ok, requesting, maybe_init_addr_hash(#data{base_dir=BaseDir, blockchain=Blockchain,
                                   address=Address, poc_interval=Delay, state=requesting})};
        %% we have attempted to unsuccessfully restart this POC too many times, give up and revert to default state
        {ok, _State, #data{poc_restarts=POCRestarts}} when POCRestarts == 0 ->
            {ok, requesting, maybe_init_addr_hash(#data{base_dir=BaseDir, blockchain=Blockchain,
                                   address=Address, poc_interval=Delay, state=requesting})};
        %% we loaded a state from the saved statem file, initialise with this if its an exported/supported state
        {ok, State, #data{poc_restarts = POCRestarts} = Data} ->
            case is_supported_state(State) of
                %% don't try to load the state file if we don't have a blockchain
                true when Blockchain /= undefined ->
                    %% to handle scenario whereby existing hotspots transition to light gateways
                    %% check the GW mode is compatible with the loaded state, if not default to requesting
                    Ledger = blockchain:ledger(Blockchain),
                    case miner_util:has_valid_local_capability(?GW_CAPABILITY_POC_CHALLENGER, Ledger) of
                        X when X == ok;
                               X == {error, gateway_not_found} ->
                            {ok, State, maybe_init_addr_hash(Data#data{base_dir=BaseDir, blockchain=Blockchain,
                                                  address=Address, poc_interval=Delay, state=State,
                                                  poc_restarts = POCRestarts - 1})};
                        _ ->
                            {ok, requesting, maybe_init_addr_hash(#data{base_dir=BaseDir, blockchain=Blockchain,
                                 address=Address, poc_interval=Delay, state=requesting})}
                    end;
                false ->
                    lager:debug("Loaded unsupported state ~p, ignoring and defaulting to requesting", [State]),
                    {ok, requesting, maybe_init_addr_hash(#data{base_dir=BaseDir, blockchain=Blockchain,
                                           address=Address, poc_interval=Delay, state=requesting})}
            end
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

callback_mode() -> [state_functions,state_enter].

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% gen_statem callbacks
%% ------------------------------------------------------------------


%%
%% requesting: in requesting state we handle blockchain_event of type 'add block'
%% if we are ready to kick of a new POC
%% The height of the new block combined with the POC interval is
%% used to determine if we should start the new POC
%% When starting a POC, we submit a new poc request txn and then transition to mining state
%%
requesting(enter, _State, Data)->
    %% each time we enter requesting state we assume we are starting a new POC and thus we reset our restart count allocation
    {keep_state, Data#data{poc_restarts=?POC_RESTARTS, retry=?CHALLENGE_RETRY, mining_timeout=?MINING_TIMEOUT}};
requesting(info, Msg, #data{blockchain = Chain} = Data) when Chain =:= undefined ->
    case blockchain_worker:blockchain() of
        undefined ->
            lager:warning("dropped ~p cause chain is still undefined", [Msg]),
            {keep_state, Data};
        NewChain ->
            {keep_state, Data#data{blockchain=NewChain}, [{next_event, info, Msg}]}
    end;
requesting(info, {blockchain_event, {add_block, BlockHash, Sync, Ledger}} = Msg,
           #data{address=Address}=Data) ->
    Now = erlang:system_time(seconds),
    case blockchain:get_block(BlockHash, Data#data.blockchain) of
        {ok, Block} ->
            case Sync andalso (Now - blockchain_block:time(Block) > 3600) of
                false ->
                    case allow_request(BlockHash, Data) of
                        false ->
                            lager:debug("request not allowed @ ~p", [BlockHash]),
                            {keep_state, save_data(maybe_init_addr_hash(Data))};
                        true ->
                            {Txn, Keys, Secret} = create_request(Address, BlockHash, Ledger),
                            #{public := PubKey} = Keys,
                            lager:md([{poc_id, blockchain_utils:poc_id(libp2p_crypto:pubkey_to_bin(PubKey))}]),
                            lager:info("request allowed @ ~p", [BlockHash]),
                            Self = self(),
                            TxnRef = make_ref(),
                            ok = blockchain_worker:submit_txn(Txn, fun(Result) -> Self ! {TxnRef, Result} end),
                            lager:info("submitted poc request ~p", [Txn]),
                            {next_state, mining, save_data(maybe_init_addr_hash(Data#data{state=mining, secret=Secret,
                                                                     onion_keys=Keys, responses=#{},
                                                                     poc_hash=BlockHash, txn_ref=TxnRef}))}
                    end;
                true ->
                    handle_event(info, Msg, save_data(maybe_init_addr_hash(Data)))
            end;
        {error, _Reason} ->
            {keep_state, Data}
    end;
requesting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).




%%
%% mining: in mining state we handle blockchain_event of type 'add block'
%% for each block added we inspect the txn list included in the block
%% if our POC request is contained in that list then we run the targetting/challenging
%% and transition to receiving state
%% if we dont see our POC request txn having been mined within the Mining Timeout period ( 5 blocks )
%% then we give up on the request and transition back to requesting state
%%
mining(enter, _State, Data)->
    {keep_state, Data};
mining(info, Msg, #data{blockchain=undefined}=Data) ->
    handle_event(info, Msg, Data);
mining(info, {TxnRef, Result}, #data{txn_ref=TxnRef}=Data) ->
    lager:info("PoC request submission result ~p", [Result]),
    {keep_state, Data};
mining(info, {blockchain_event, {add_block, BlockHash, _, PinnedLedger}},
       #data{blockchain = _Chain, address = Challenger,
             mining_timeout = MiningTimeout, secret = Secret} = Data) ->
    case find_request(BlockHash, Data) of
        {ok, Block} ->
            Height = blockchain_block:height(Block),
            %% TODO discuss making this delay verifiable so you can't punish a hotspot by
            %% intentionally fast-challenging them before they have the block
            %% Is this timer necessary ??
            timer:sleep(?BLOCK_PROPOGATION_TIME),
            %% NOTE: if we crash out whilst handling targetting, effectively the POC is abandoned
            %% as when this statem is restarted, it will init in mining state but the block with the request txns
            %% will already have passed, as such we will then hit the MiningTimeout and transition to requesting state
            handle_targeting(<<Secret/binary, BlockHash/binary, Challenger/binary>>, Height, PinnedLedger,
                                maybe_init_addr_hash(Data#data{mining_timeout = Data#data.poc_interval, request_block_hash=BlockHash}));
        {error, _Reason} ->
             case MiningTimeout > 0 of
                true ->
                    {keep_state, maybe_init_addr_hash(Data#data{mining_timeout=MiningTimeout-1})};
                false ->
                    lager:error("did not see PoC request in last ~p block, giving up on this POC", [Data#data.poc_interval]),
                    {next_state, requesting, save_data(maybe_init_addr_hash(Data#data{state=requesting}))}
            end
    end;
mining(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%
%% receiving: in receiving state we handle receipts and witness events
%% and do so until the next block is added
%% at that point if we have received no responses then we revert to requesting state
%% otherwise we will generate and submit a txn containing all received receipts and witness reports
%% and then transition to waiting state
%%
receiving(enter, _State, Data)->
    {keep_state, Data#data{receiving_timeout=?RECEIVING_TIMEOUT}};
receiving(info, {blockchain_event, {add_block, _Hash, _, _}}, #data{receiving_timeout=0, responses=Responses}=Data) ->
    case maps:size(Responses) of
        0 ->
            lager:warning("timing out, no receipts @ ~p", [_Hash]),
            %% we got nothing, no reason to submit
            {next_state, requesting, save_data(maybe_init_addr_hash(Data#data{state=requesting}))};
        _ ->
            lager:warning("timing out, submitting receipts @ ~p", [_Hash]),
            try
                Ref = submit_receipts(Data),
                {next_state, waiting, save_data(maybe_init_addr_hash(Data#data{state=waiting, txn_ref=Ref}))}
            catch C:E:S ->
                    lager:warning("error ~p:~p submitting requests: ~p", [C, E, S]),
                    {next_state, requesting, save_data(maybe_init_addr_hash(Data#data{state=requesting}))}
            end
    end;
receiving(info, {blockchain_event, {add_block, _Hash, _, _}}, #data{receiving_timeout=T}=Data) ->
    lager:info("got block ~p decreasing timeout", [_Hash]),
    {keep_state, save_data(maybe_init_addr_hash(Data#data{receiving_timeout=T-1}))};
receiving(cast, {witness, Address, Witness}, #data{responses=Responses0,
                                                   packet_hashes=PacketHashes,
                                                   blockchain=Chain}=Data) ->
    lager:info("got witness ~p", [Witness]),

    GatewayWitness = blockchain_poc_witness_v1:gateway(Witness),
    %% Check that the receiving `Address` is of the `Witness`
    case Address == GatewayWitness of
        false ->
            lager:warning("witness gw: ~p, recv addr: ~p mismatch!",
                          [libp2p_crypto:bin_to_b58(GatewayWitness),
                           libp2p_crypto:bin_to_b58(Address)]),
            {keep_state, Data};
        true ->
            %% Validate the witness is correct
            Ledger = blockchain:ledger(Chain),
            LocationOK = miner_lora:location_ok(),
            case {LocationOK, validate_witness(Witness, Ledger)} of
                {false, Valid} ->
                    lager:warning("location is bad, validity: ~p", [Valid]),
                    {keep_state, Data};
                {_, false} ->
                    lager:warning("ignoring invalid witness ~p", [Witness]),
                    {keep_state, Data};
                {_, true} ->
                    PacketHash = blockchain_poc_witness_v1:packet_hash(Witness),
                    %% check this is a known layer of the packet
                    case lists:keyfind(PacketHash, 2, PacketHashes) of
                        false ->
                            lager:warning("Saw invalid witness with packet hash ~p", [PacketHash]),
                            {keep_state, Data};
                        {GatewayWitness, PacketHash} ->
                            lager:warning("Saw self-witness from ~p", [GatewayWitness]),
                            {keep_state, Data};
                        _ ->
                            Witnesses = maps:get(PacketHash, Responses0, []),
                            %% Don't allow putting duplicate response in the witness list resp
                            Predicate = fun({_, W}) -> blockchain_poc_witness_v1:gateway(W) == GatewayWitness end,
                            Responses1 =
                            case lists:any(Predicate, Witnesses) of
                                false ->
                                    maps:put(PacketHash, lists:keystore(Address, 1, Witnesses, {Address, Witness}), Responses0);
                                true ->
                                    Responses0
                            end,
                            {keep_state, save_data(Data#data{responses=Responses1})}
                    end
            end
    end;

receiving(cast, {receipt, Address, Receipt, PeerAddr}, #data{responses=Responses0, challengees=Challengees, blockchain=Chain}=Data) ->
    lager:info("got receipt ~p", [Receipt]),
    Gateway = blockchain_poc_receipt_v1:gateway(Receipt),
    LayerData = blockchain_poc_receipt_v1:data(Receipt),
    LocationOK = miner_lora:location_ok(),
    Ledger = blockchain:ledger(Chain),
    case {LocationOK, blockchain_poc_receipt_v1:is_valid(Receipt, Ledger)} of
        {false, Valid} ->
            lager:warning("location is bad, validity: ~p", [Valid]),
            {keep_state, Data};
        {_, false} ->
            lager:warning("ignoring invalid receipt ~p", [Receipt]),
            {keep_state, Data};
        {_, true} ->
            %% Also check onion layer secret
            case lists:keyfind(Gateway, 1, Challengees) of
                {Gateway, LayerData} ->
                    case maps:get(Gateway, Responses0, undefined) of
                        undefined ->
                            IsFirstChallengee = case hd(Challengees) of
                                                    {Gateway, _} ->
                                                        true;
                                                    _ ->
                                                        false
                                                end,
                            %% compute address hash and compare to known ones
                            case check_addr_hash(PeerAddr, Data) of
                                true when IsFirstChallengee ->
                                    %% drop whole challenge because we should always be able to get the first hop's receipt
                                    {next_state, requesting, save_data(Data#data{state=requesting})};
                                true ->
                                    {keep_state, Data};
                                undefined ->
                                    Responses1 = maps:put(Gateway, {Address, Receipt}, Responses0),
                                    {keep_state, save_data(Data#data{responses=Responses1})};
                                PeerHash ->
                                    Responses1 = maps:put(Gateway, {Address, blockchain_poc_receipt_v1:addr_hash(Receipt, PeerHash)}, Responses0),
                                    {keep_state, save_data(Data#data{responses=Responses1})}
                            end;
                        _ ->
                            lager:warning("Already got this receipt ~p for ~p ignoring", [Receipt, Gateway]),
                            {keep_state, Data}
                    end;
                {Gateway, OtherData} ->
                    lager:warning("Got incorrect layer data ~p from ~p (expected ~p)", [Gateway, OtherData, Data]),
                    {keep_state, Data};
                false ->
                    lager:warning("Got unexpected receipt from ~p", [Gateway]),
                    {keep_state, Data}
            end
    end;
receiving(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).



%%
%% waiting: in waiting state we await and listen for blockchain_events of type 'add_block'
%% when a block is received we inspect the txn list
%% if the block contains our submitted receipts then transition to requesting state
%% otherwise continue awaiting for and inspecting N next blocks
%% if we dont see our receipts after N blocks then give up and transition to requesting state
%%
waiting(enter, _State, Data)->
    {keep_state, Data#data{receipts_timeout=?RECEIPTS_TIMEOUT}};
waiting(info, {blockchain_event, {add_block, _BlockHash, _, _}}, #data{receipts_timeout=0}=Data) ->
    lager:warning("I have been waiting for ~p blocks abandoning last request", [?RECEIPTS_TIMEOUT]),
    {next_state, requesting,  save_data(maybe_init_addr_hash(Data#data{state=requesting, receipts_timeout=?RECEIPTS_TIMEOUT}))};
waiting(info, {TxnRef, Result}, #data{txn_ref=TxnRef}=Data) ->
    lager:info("PoC receipt submission result ~p", [Result]),
    {keep_state, Data};
waiting(info, {blockchain_event, {add_block, BlockHash, _, _}}, #data{receipts_timeout=Timeout}=Data) ->
    case find_receipts(BlockHash, Data) of
        ok ->
            {next_state, requesting, save_data(maybe_init_addr_hash(Data#data{state=requesting}))};
        {error, _Reason} ->
             lager:info("receipts not found in block ~p : ~p", [BlockHash, _Reason]),
            {keep_state, save_data(maybe_init_addr_hash(Data#data{receipts_timeout=Timeout-1}))}
    end;
waiting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).



%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

is_supported_state(State)->
    erlang:function_exported(?MODULE, State, 3).

handle_event(info, {blockchain_event, {new_chain, NC}},
             #data{address = Address, poc_interval = Delay}) ->
    {next_state, requesting, save_data(#data{state = requesting, blockchain=NC,
                                              address=Address, poc_interval=Delay})};
handle_event(info, {blockchain_event, {add_block, _, _, _}}, Data) ->
    %% suppress the warning here
    {keep_state, maybe_init_addr_hash(Data)};
handle_event(_EventType, _EventContent, Data) ->
    lager:warning("ignoring event [~p] ~p", [_EventType, _EventContent]),
    {keep_state, Data}.

handle_targeting(_, _, _, Data = #data{retry = Retry})
  when Retry =< 0 ->
    lager:error("targeting/challenging failed ~p times back to requesting", [?CHALLENGE_RETRY]),
    {next_state, requesting, save_data(Data#data{state=requesting, retry=?CHALLENGE_RETRY})};
handle_targeting(Entropy, Height, Ledger, Data) ->
    %% Challenger details
    ChallengerAddr = blockchain_swarm:pubkey_bin(),
    {ok, ChallengerGw} = blockchain_ledger_v1:find_gateway_info(ChallengerAddr, Ledger),
    case blockchain_ledger_gateway_v2:location(ChallengerGw) of
        undefined ->
            lager:warning("poc no challenger location, back to requesting"),
            {next_state, requesting, save_data(Data#data{state=requesting, retry=?CHALLENGE_RETRY})};
        ChallengerLoc ->
            Vars = blockchain_utils:vars_binary_keys_to_atoms(
                     maps:from_list(blockchain_ledger_v1:snapshot_vars(Ledger))),

            case blockchain:config(?poc_version, Ledger) of
                {ok, V} when V < 4 ->
                    case blockchain_poc_path:target(Entropy, Ledger, blockchain_swarm:pubkey_bin()) of
                        {Target, Gateways} ->
                            lager:info("target found ~p, challenging, hash: ~p", [Target, Entropy]),
                            handle_challenging({Entropy, ignored}, Target, Gateways, Height, Ledger, #{}, Data#data{challengees=[]});
                        no_target ->
                            lager:warning("no target found, back to requesting"),
                            {next_state, requesting, save_data(Data#data{state=requesting, retry=?CHALLENGE_RETRY})}
                    end;
                {ok, V} when V < 7 ->
                    %% Create tagged score map
                    GatewayScoreMap = blockchain_utils:score_gateways(Ledger),

                    %% Filtered gateways
                    GatewayScores = blockchain_poc_target_v2:filter(GatewayScoreMap, ChallengerAddr, ChallengerLoc, Height, Vars, Ledger),
                    case blockchain_poc_target_v2:target(Entropy, GatewayScores, Vars) of
                        {error, no_target} ->
                            lager:info("Limit: ~p~n", [maps:get(poc_path_limit, Vars)]),
                            lager:info("POCVersion: ~p~n", [V]),
                            lager:info("GatewayScores: ~p~n", [GatewayScores]),
                            lager:info("poc_v4 no target found, back to requesting"),
                            {next_state, requesting, save_data(Data#data{state=requesting, retry=?CHALLENGE_RETRY})};
                        {ok, TargetPubkeyBin} ->
                            lager:info("Limit: ~p~n", [maps:get(poc_path_limit, Vars)]),
                            lager:info("POCVersion: ~p~n", [V]),
                            lager:info("GatewayScores: ~p~n", [GatewayScores]),
                            lager:info("poc_v4 target found ~p, challenging, hash: ~p", [TargetPubkeyBin, Entropy]),
                            handle_challenging({Entropy, ignored}, TargetPubkeyBin, GatewayScores, Height, Ledger, Vars, Data#data{challengees=[]})
                    end;
                {ok, V} when V < 8 ->
                    {ok, TargetPubkeyBin} = blockchain_poc_target_v2:target_v2(Entropy, Ledger, Vars),
                    lager:info("poc_v~p target found ~p, challenging, hash: ~p", [V, TargetPubkeyBin, Entropy]),
                    self() ! {challenge, Entropy, TargetPubkeyBin, ignored, Height, Ledger, Vars},
                    handle_challenging({Entropy, ignored}, TargetPubkeyBin, ignored, Height, Ledger, Vars, Data#data{challengees=[]});
                {ok, V} ->
                    {ok, {TargetPubkeyBin, TargetRandState}} = blockchain_poc_target_v3:target(ChallengerAddr, Entropy, Ledger, Vars),
                    lager:info("poc_v~p challenger: ~p, challenger_loc: ~p", [V, libp2p_crypto:bin_to_b58(ChallengerAddr), ChallengerLoc]),
                    lager:info("poc_v~p target found ~p, challenging, target_rand_state: ~p", [V, libp2p_crypto:bin_to_b58(TargetPubkeyBin), TargetRandState]),
                    %% NOTE: We pass in the TargetRandState along with the entropy here
                    handle_challenging({Entropy, TargetRandState}, TargetPubkeyBin, ignored, Height, Ledger, Vars, Data#data{challengees=[]})
            end
    end.

handle_challenging({Entropy, TargetRandState}, Target, Gateways, Height, Ledger, Vars, #data{  retry=Retry,
                                                                                               onion_keys=OnionKey,
                                                                                               poc_hash=BlockHash,
                                                                                               blockchain=Chain}=Data) ->

    Self = self(),
    Attempt = make_ref(),
    Timeout = application:get_env(miner, path_validation_budget_ms, 5000),
    {ok, LastChallenge} = blockchain_ledger_v1:current_height(Ledger),
    {ok, B} = blockchain:get_block(LastChallenge, Chain),
    Time = blockchain_block:time(B),
    %% spawn of the path building and have it return a response when its ready
    {Pid, Ref} =
    spawn_monitor(fun() ->
                          case blockchain:config(?poc_version, Ledger) of
                              {ok, V} when V < 4 ->
                                  Self ! {Attempt, blockchain_poc_path:build(Entropy, Target, Gateways, Height, Ledger)};
                              {ok, V} when V < 7 ->
                                  Path = blockchain_poc_path_v2:build(Target, Gateways, Time, Entropy, Vars, Ledger),
                                  lager:info("poc_v4 Path: ~p~n", [Path]),
                                  Self ! {Attempt, {ok, Path}};
                              {ok, V} when V < 8 ->
                                  Path = blockchain_poc_path_v3:build(Target, Ledger, Time, Entropy, Vars),
                                  lager:info("poc_v~p Path: ~p~n", [V, Path]),
                                  Self ! {Attempt, {ok, Path}};
                              {ok, V} ->
                                  %% NOTE: v8 onwards path:build signature has changed to use rand_state instead of entropy
                                  Path = blockchain_poc_path_v4:build(Target, TargetRandState, Ledger, Time, Vars),
                                  lager:info("poc_v~p Path: ~p~n", [V, Path]),
                                  Self ! {Attempt, {ok, Path}}
                          end
                  end),
    lager:info("starting blockchain_poc_path:build in ~p", [Pid]),
    receive
        {Attempt, {error, Reason}} ->
            erlang:demonitor(Ref, [flush]),
            lager:error("could not build path for ~p: ~p", [Target, Reason]),
            lager:info("selecting new target"),
            handle_targeting(Entropy, Height, Ledger, Data#data{retry=Retry-1});
        {Attempt, {ok, Path}} ->
            erlang:demonitor(Ref, [flush]),
            lager:info("path created ~p", [Path]),
            N = erlang:length(Path),
            [<<IV:16/integer-unsigned-little, _/binary>> | LayerData] = blockchain_txn_poc_receipts_v1:create_secret_hash(Entropy, N+1),
            OnionList = lists:zip([ libp2p_crypto:bin_to_pubkey(P) || P <- Path], LayerData),
            {Onion, Layers} = blockchain_poc_packet:build(OnionKey, IV, OnionList, BlockHash, Ledger),
            %% no witness will exist for the first layer hash as it is delivered over p2p
            [_|LayerHashes] = [ crypto:hash(sha256, L) || L <- Layers ],
            lager:info("onion of length ~p created ~p", [byte_size(Onion), Onion]),
            [Start|_] = Path,
            P2P = libp2p_crypto:pubkey_bin_to_p2p(Start),
            case send_onion(P2P, Onion, 3) of
                ok ->
                    {next_state, receiving, save_data(Data#data{state=receiving, challengees=lists:zip(Path, LayerData),
                        packet_hashes=lists:zip(Path, LayerHashes)})};

                {error, Reason} ->
                    lager:error("failed to dial 1st hotspot (~p): ~p", [P2P, Reason]),
                    lager:info("selecting new target"),
                    handle_targeting(Entropy, Height, Ledger, Data#data{retry=Retry-1})
            end;
        {'DOWN', Ref, process, _Pid, Reason} ->
            lager:error("blockchain_poc_path went down ~p: ~p", [Reason, {Entropy, Target, Gateways, Height}]),
            handle_targeting(Entropy, Height, Ledger, Data#data{retry=Retry-1})
    after Timeout ->
        erlang:demonitor(Ref, [flush]),
        erlang:exit(Pid, kill),
        lager:error("blockchain_poc_path took too long: Entropy ~p Target ~p Height ~p", [Entropy, Target, Height]),
        {next_state, requesting, save_data(Data#data{state=requesting})}

    end.



-spec save_data(data()) -> data().
save_data(#data{base_dir=undefined}=State) ->
    State;
save_data(#data{base_dir = BaseDir,
                state = CurrState,
                secret = Secret,
                onion_keys = Keys,
                challengees = Challengees,
                packet_hashes = PacketHashes,
                responses = Responses,
                receiving_timeout = RecTimeout,
                poc_hash = PoCHash,
                request_block_hash = BlockHash,
                mining_timeout = MiningTimeout,
                retry = Retry,
                addr_hash_filter = Filter,
                receipts_timeout = ReceiptTimeout} = State) ->
    StateMap = #{
                 state => CurrState,
                 secret => Secret,
                 onion_keys => Keys,
                 challengees => Challengees,
                 packet_hashes => PacketHashes,
                 responses => Responses,
                 receiving_timeout => RecTimeout,
                 poc_hash => PoCHash,
                 request_block_hash => BlockHash,
                 mining_timeout => MiningTimeout,
                 retry => Retry,
                 receipts_timeout => ReceiptTimeout,
                 addr_hash_filter => serialize_addr_hash_filter(Filter)
                },
    BinState = erlang:term_to_binary(StateMap),
    File = filename:join([BaseDir, ?STATE_FILE]),
    ok = file:write_file(File, BinState),
    State.

-spec load_data(file:filename_all()) -> {error, any()} | {ok, state(), data()}.
load_data(undefined) ->
    {error, base_dir_undefined};
load_data(BaseDir) ->
    File = filename:join([BaseDir, ?STATE_FILE]),
    try file:read_file(File) of
        {error, _Reason}=Error ->
            Error;
        {ok, <<>>} ->
            {error, empty_file};
        {ok, Binary} ->
            try erlang:binary_to_term(Binary) of
                    Map = #{state := State,
                      secret := Secret,
                      onion_keys := Keys,
                      challengees := Challengees,
                      packet_hashes := PacketHashes,
                      responses := Responses,
                      receiving_timeout := RecTimeout,
                      poc_hash := PoCHash,
                      request_block_hash := BlockHash,
                      mining_timeout := MiningTimeout,
                      retry := Retry,
                      receipts_timeout := ReceiptTimeout} ->
                        {ok, State,
                         #data{base_dir = BaseDir,
                               state = State,
                               secret = Secret,
                               onion_keys = Keys,
                               challengees = Challengees,
                               packet_hashes = PacketHashes,
                               responses = Responses,
                               receiving_timeout = RecTimeout,
                               poc_hash = PoCHash,
                               request_block_hash = BlockHash,
                               mining_timeout = MiningTimeout,
                               retry = Retry,
                               addr_hash_filter = deserialize_addr_hash_filter(maps:get(addr_hash_filter, Map, undefined)),
                               receipts_timeout = ReceiptTimeout}};
                    _ ->
                        {error, wrong_data}
            catch
                error:badarg ->
                    {error, bad_term}
            end

    catch _:_ ->
            {error, read_error}
    end.

-spec maybe_init_addr_hash(#data{}) -> #data{}.
maybe_init_addr_hash(#data{blockchain=undefined}=Data) ->
    %% no chain
    Data;
maybe_init_addr_hash(#data{blockchain=Blockchain, addr_hash_filter=undefined}=Data) ->
    %% check if we have the block we need
    Ledger = blockchain:ledger(Blockchain),
    case blockchain:config(?poc_addr_hash_byte_count, Ledger) of
        {ok, Bytes} when is_integer(Bytes), Bytes > 0 ->
            case blockchain:config(?poc_challenge_interval, Ledger) of
                {ok, Interval} ->
                    {ok, Height} = blockchain:height(Blockchain),
                    StartHeight = max(Height - (Height rem Interval), 1),
                    %% check if we have this block
                    case blockchain:get_block(StartHeight, Blockchain) of
                        {ok, Block} ->
                            Hash = blockchain_block:hash_block(Block),
                            %% ok, now we can build the filter
                            Gateways = blockchain_ledger_v1:gateway_count(Ledger),
                            {ok, Bloom} = bloom:new_optimal(Gateways, ?ADDR_HASH_FP_RATE),
                            sync_filter(Block, Bloom, Blockchain),
                            Data#data{addr_hash_filter=#addr_hash_filter{start=StartHeight, height=Height, byte_size=Bytes, salt=Hash, bloom=Bloom}};
                        _ ->
                            Data
                    end;
                _ ->
                    Data
            end;
        _ ->
            Data
    end;
maybe_init_addr_hash(#data{blockchain=Blockchain, addr_hash_filter=#addr_hash_filter{start=StartHeight, height=Height, byte_size=Bytes, salt=Hash, bloom=Bloom}}=Data) ->
    Ledger = blockchain:ledger(Blockchain),
    case blockchain:config(?poc_addr_hash_byte_count, Ledger) of
        {ok, Bytes} when is_integer(Bytes), Bytes > 0 ->
            case blockchain:config(?poc_challenge_interval, Ledger) of
                {ok, Interval} ->
                    {ok, CurHeight} = blockchain:height(Blockchain),
                    case max(Height - (Height rem Interval), 1) of
                        StartHeight ->
                            case CurHeight of
                                Height ->
                                    %% ok, everything lines up
                                    Data;
                                _ ->
                                    case blockchain:get_block(Height+1, Blockchain) of
                                        {ok, Block} ->
                                            sync_filter(Block, Bloom, Blockchain),
                                            Data#data{addr_hash_filter=#addr_hash_filter{start=StartHeight, height=CurHeight, byte_size=Bytes, salt=Hash, bloom=Bloom}};
                                        _ ->
                                            Data
                                    end
                            end;
                        _NewStart ->
                            %% filter is stale
                            maybe_init_addr_hash(Data#data{addr_hash_filter=undefined})
                    end;
                _ ->
                    Data
            end;
        _ ->
            Data#data{addr_hash_filter=undefined}
    end.

sync_filter(StopBlock, Bloom, Blockchain) ->
    blockchain:fold_chain(fun(Blk, _) ->
                                  blockchain_utils:find_txn(Blk, fun(T) ->
                                                                         case blockchain_txn:type(T) == blockchain_txn_poc_receipts_v1 of
                                                                             true ->
                                                                                 %% abuse side effects here for PERFORMANCE
                                                                                 [ update_addr_hash(Bloom, E) ||  E <- blockchain_txn_poc_receipts_v1:path(T) ];
                                                                             false ->
                                                                                 ok
                                                                         end,
                                                                         false
                                                                 end),
                                  case Blk == StopBlock of
                                      true ->
                                          return;
                                      false ->
                                          continue
                                  end
                          end, any, element(2, blockchain:head_block(Blockchain)), Blockchain).


-spec update_addr_hash(Bloom :: bloom_nif:bloom(), Element :: blockchain_poc_path_element_v1:poc_element()) -> ok.
update_addr_hash(Bloom, Element) ->
    case blockchain_poc_path_element_v1:receipt(Element) of
        undefined ->
            ok;
        Receipt ->
            case blockchain_poc_receipt_v1:addr_hash(Receipt) of
                undefined ->
                    ok;
                Hash ->
                    bloom:set(Bloom, Hash)
            end
    end.

serialize_addr_hash_filter(undefined) ->
    undefined;
serialize_addr_hash_filter(Filter=#addr_hash_filter{bloom=Bloom}) ->
    case bloom:serialize(Bloom) of
        {ok, SerBloom} ->
            Filter#addr_hash_filter{bloom=SerBloom};
        _ ->
            undefined
    end.

deserialize_addr_hash_filter(undefined) ->
    undefined;
deserialize_addr_hash_filter(Filter=#addr_hash_filter{bloom=SerBloom}) ->
    case bloom:deserialize(SerBloom) of
        {ok, Bloom} ->
            Filter#addr_hash_filter{bloom=Bloom};
        _ ->
            undefined
    end.


check_addr_hash(_PeerAddr, #data{addr_hash_filter=undefined}) ->
    undefined;
check_addr_hash(PeerAddr, #data{addr_hash_filter=#addr_hash_filter{byte_size=Size, salt=Hash, bloom=Bloom}}) ->
    case multiaddr:protocols(PeerAddr) of
        [{"ip4",Address},{_,_}] ->
            {ok, Addr} = inet:parse_ipv4_address(Address),
            Val = binary:part(enacl:pwhash(list_to_binary(tuple_to_list(Addr)), binary:part(Hash, {0, enacl:pwhash_SALTBYTES()})), {0, Size}),
            case bloom:check_and_set(Bloom, Val) of
                true ->
                    true;
                false ->
                    Val
            end;
        _ ->
            undefined
    end.

-spec validate_witness(blockchain_poc_witness_v1:witness(), blockchain_ledger_v1:ledger()) -> boolean().
validate_witness(Witness, Ledger) ->
    Gateway = blockchain_poc_witness_v1:gateway(Witness),
    %% TODO this should be against the ledger at the time the receipt was mined

    case blockchain_poc_witness_v1:frequency(Witness) of
        0.0 ->
            %% Witnesses with 0.0 frequency are considered invalid
            false;
        _ ->
            case blockchain_ledger_v1:find_gateway_info(Gateway, Ledger) of
                {error, _Reason} ->
                    lager:warning("failed to get witness ~p info ~p", [Gateway, _Reason]),
                    false;
                {ok, GwInfo} ->
                    case blockchain_ledger_gateway_v2:location(GwInfo) of
                        undefined ->
                            lager:warning("ignoring witness ~p location undefined", [Gateway]),
                            false;
                        _ ->
                            blockchain_poc_witness_v1:is_valid(Witness, Ledger)
                    end
            end
    end.


-spec allow_request(binary(), data()) -> boolean().
allow_request(BlockHash, #data{blockchain=Blockchain,
                               address=Address,
                               poc_interval=POCInterval0}) ->
    Ledger = blockchain:ledger(Blockchain),
    POCInterval =
        case POCInterval0 of
            undefined ->
                blockchain_utils:challenge_interval(Ledger);
            _ ->
                POCInterval0
        end,
    try
        case blockchain_ledger_v1:find_gateway_info(Address, Ledger) of
            {ok, GwInfo} ->
                GwMode = blockchain_ledger_gateway_v2:mode(GwInfo),
                case blockchain_ledger_gateway_v2:is_valid_capability(GwMode, ?GW_CAPABILITY_POC_CHALLENGER, Ledger) of
                    true ->
                        {ok, Block} = blockchain:get_block(BlockHash, Blockchain),
                        Height = blockchain_block:height(Block),
                        ChallengeOK =
                            case blockchain_ledger_gateway_v2:last_poc_challenge(GwInfo) of
                                undefined ->
                                    lager:info("got block ~p @ height ~p (never challenged before)", [BlockHash, Height]),
                                    true;
                                LastChallenge ->
                                    case (Height - LastChallenge) > POCInterval of
                                        true -> 1 == rand:uniform(max(10, POCInterval div 10));
                                        false -> false
                                    end
                            end,
                        LocationOK = true,
                        LocationOK = miner_lora:location_ok(),
                        ChallengeOK andalso LocationOK;
                    _ ->
                        %% the GW is not allowed to send POC challenges
                        false
                end;
            %% mostly this is going to be unasserted full nodes
            _ ->
                false
        end
    catch Class:Err:Stack ->
            lager:warning("error determining if request allowed: ~p:~p ~p",
                          [Class, Err, Stack]),
            false
    end.

-spec create_request(libp2p_crypto:pubkey_bin(), binary(), blockchain_ledger_v1:ledger()) ->
    {blockchain_txn_poc_request_v1:txn_poc_request(), keys(), binary()}.
create_request(Address, BlockHash, Ledger) ->
    Keys = libp2p_crypto:generate_keys(ecc_compact),
    Secret = libp2p_crypto:keys_to_bin(Keys),
    #{public := OnionCompactKey} = Keys,
    Version = blockchain_txn_poc_request_v1:get_version(Ledger),
    Tx = blockchain_txn_poc_request_v1:new(
        Address,
        crypto:hash(sha256, Secret),
        crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(OnionCompactKey)),
        BlockHash,
        Version
    ),
    {ok, _, SigFun, _ECDHFun} = blockchain_swarm:keys(),
    {blockchain_txn:sign(Tx, SigFun), Keys, Secret}.

-spec find_request(binary(), data()) -> {ok, blockchain_block:block()} | {error, any()}.
find_request(BlockHash, #data{blockchain=Blockchain,
                              address=Challenger,
                              secret=Secret,
                              onion_keys= #{public := OnionCompactKey}}) ->
    lager:info("got block ~p checking content", [BlockHash]),
    case blockchain:get_block(BlockHash, Blockchain) of
        {error, _Reason}=Error ->
            lager:error("failed to get block ~p : ~p", [BlockHash, _Reason]),
            Error;
        {ok, Block} ->
            Txns = blockchain_block:transactions(Block),
            Filter =
                fun(Txn) ->
                    SecretHash = crypto:hash(sha256, Secret),
                    OnionKeyHash = crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(OnionCompactKey)),
                    blockchain_txn:type(Txn) =:= blockchain_txn_poc_request_v1  andalso
                    blockchain_txn_poc_request_v1:challenger(Txn) =:= Challenger andalso
                    blockchain_txn_poc_request_v1:secret_hash(Txn) =:= SecretHash andalso
                    blockchain_txn_poc_request_v1:onion_key_hash(Txn) =:= OnionKeyHash
                end,
            case lists:filter(Filter, Txns) of
                [_POCReq] ->
                    {ok, Block};
                _ ->
                    lager:info("request not found in block ~p", [BlockHash]),
                    {error, not_found}
            end
    end.

-spec submit_receipts(data()) -> reference().
submit_receipts(#data{address=Challenger,
                      responses=Responses0,
                      secret=Secret,
                      packet_hashes=LayerHashes,
                      request_block_hash=BlockHash,
                      blockchain=Chain,
                      onion_keys= #{public := OnionCompactKey}} = _Data) ->
    OnionKeyHash = crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(OnionCompactKey)),
    Path1 = lists:foldl(
        fun({Challengee, LayerHash}, Acc) ->
            {Address, Receipt} = maps:get(Challengee, Responses0, {make_ref(), undefined}),
            %% get any witnesses not from the same p2p address and also ignore challengee as a witness (self-witness)
            Witnesses = [W || {A, W} <- maps:get(LayerHash, Responses0, []), A /= Address, A /= Challengee],
            PerHopMaxWitnesses = blockchain_utils:poc_per_hop_max_witnesses(blockchain:ledger(Chain)),
            %% randomize the ordering of the witness list
            Witnesses1 = blockchain_utils:shuffle(Witnesses),
            %% take only the limit
            Witnesses2 = lists:sublist(Witnesses1, PerHopMaxWitnesses),
            E = blockchain_poc_path_element_v1:new(Challengee, Receipt, Witnesses2),
            [E|Acc]
        end,
        [],
        LayerHashes
    ),
    Txn0 = case blockchain:config(?poc_version, blockchain:ledger(Chain)) of
               {ok, PoCVersion} when PoCVersion >= 10 ->
                   blockchain_txn_poc_receipts_v1:new(Challenger, Secret, OnionKeyHash, BlockHash, lists:reverse(Path1));
               _ ->
                   blockchain_txn_poc_receipts_v1:new(Challenger, Secret, OnionKeyHash, lists:reverse(Path1))
           end,
    {ok, _, SigFun, _ECDHFun} = blockchain_swarm:keys(),
    Txn1 = blockchain_txn:sign(Txn0, SigFun),
    lager:info("submitting blockchain_txn_poc_receipts_v1 ~p", [Txn0]),
    TxnRef = make_ref(),
    Self = self(),
    blockchain_worker:submit_txn(Txn1, fun(Result) -> Self ! {TxnRef, Result} end),
    TxnRef.


-spec find_receipts(binary(), data()) -> ok | {error, any()}.
find_receipts(BlockHash, #data{blockchain=Blockchain,
                               address=Challenger,
                               secret=Secret}) ->
    lager:info("got block ~p checking content", [BlockHash]),
    case blockchain:get_block(BlockHash, Blockchain) of
        {error, _Reason}=Error ->
            lager:error("failed to get block ~p : ~p", [BlockHash, _Reason]),
            Error;
        {ok, Block} ->
            Txns = blockchain_block:transactions(Block),
            Filter =
                fun(Txn) ->
                    blockchain_txn:type(Txn) =:= blockchain_txn_poc_receipts_v1 andalso
                    blockchain_txn_poc_receipts_v1:challenger(Txn) =:= Challenger andalso
                    blockchain_txn_poc_receipts_v1:secret(Txn) =:= Secret
                end,
            case lists:filter(Filter, Txns) of
                [_POCReceipts] ->
                    ok;
                _ ->
                    lager:info("request not found in block ~p", [BlockHash]),
                    {error, not_found}
            end
    end.

send_onion(_P2P, _Onion, 0) ->
    {error, retries_exceeded};
send_onion(P2P, Onion, Retry) ->
    case miner_onion:dial_framed_stream(blockchain_swarm:tid(), P2P, []) of
        {ok, Stream} ->
            unlink(Stream),
            _ = miner_onion_handler:send(Stream, Onion),
            lager:info("onion sent"),
            ok;
        {error, Reason} ->
            lager:error("failed to dial 1st hotspot (~p): ~p", [P2P, Reason]),
            timer:sleep(timer:seconds(10)),
            send_onion(P2P, Onion, Retry-1)
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

%% target_test() ->
%%     meck:new(blockchain_ledger_v1, [passthrough]),
%%     meck:new(blockchain_worker, [passthrough]),
%%     meck:new(blockchain_swarm, [passthrough]),
%%     meck:new(blockchain, [passthrough]),
%%     LatLongs = [
%%         {{37.782061, -122.446167}, 1.0, 1.0},
%%         {{37.782604, -122.447857}, 1000.0, 1.0},
%%         {{37.782074, -122.448528}, 1000.0, 1.0},
%%         {{37.782002, -122.44826}, 1000.0, 1.0},
%%         {{37.78207, -122.44613}, 1000.0, 1.0},
%%         {{37.781909, -122.445411}, 1000.0, 1.0},
%%         {{37.783371, -122.447879}, 1000.0, 1.0},
%%         {{37.780827, -122.44716}, 1000.0, 1.0}
%%     ],
%%     ActiveGateways = lists:foldl(
%%         fun({LatLong, Alpha, Beta}, Acc) ->
%%             Owner = <<"test">>,
%%             Address = crypto:hash(sha256, erlang:term_to_binary(LatLong)),
%%             Index = h3:from_geo(LatLong, 12),
%%             G0 = blockchain_ledger_gateway_v2:new(Owner, Index),
%%             G1 = blockchain_ledger_gateway_v2:set_alpha_beta_delta(Alpha, Beta, 1, G0),
%%             maps:put(Address, G1, Acc)

%%         end,
%%         maps:new(),
%%         LatLongs
%%     ),

%%     meck:expect(blockchain_ledger_v1, active_gateways, fun(_) -> ActiveGateways end),
%%     meck:expect(blockchain_ledger_v1, current_height, fun(_) -> {ok, 1} end),
%%     meck:expect(blockchain_ledger_v1, gateway_score, fun(_, _) -> {ok, 0.5} end),
%%     meck:expect(blockchain_worker, blockchain, fun() -> blockchain end),
%%     meck:expect(blockchain_swarm, pubkey_bin, fun() -> <<"unknown">> end),
%%     meck:expect(blockchain, ledger, fun(_) -> ledger end),
%%     meck:expect(blockchain,
%%                 config,
%%                 fun(min_score, _) ->
%%                         {ok, 0.2};
%%                    (h3_exclusion_ring_dist, _) ->
%%                         {ok, 2};
%%                    (h3_max_grid_distance, _) ->
%%                         {ok, 13};
%%                    (h3_neighbor_res, _) ->
%%                         {ok, 12};
%%                    (alpha_decay, _) ->
%%                         {ok, 0.007};
%%                    (beta_decay, _) ->
%%                         {ok, 0.0005};
%%                    (max_staleness, _) ->
%%                         {ok, 100000};
%%                    (correct_min_score, _) ->
%%                         {ok, true}
%%                 end),

%%     Block = blockchain_block_v1:new(#{prev_hash => <<>>,
%%                                       height => 2,
%%                                       transactions => [],
%%                                       signatures => [],
%%                                       hbbft_round => 0,
%%                                       time => 0,
%%                                       election_epoch => 1,
%%                                       epoch_start => 0
%%                                      }),
%%     Hash = blockchain_block:hash_block(Block),
%%     {Target, Gateways} = blockchain_poc_path:target(Hash, undefined, blockchain_swarm:pubkey_bin()),

%%     [{LL, _, _}|_] = LatLongs,
%%     ?assertEqual(crypto:hash(sha256, erlang:term_to_binary(LL)), Target),
%%     ?assertEqual(ActiveGateways, Gateways),

%%     ?assert(meck:validate(blockchain_ledger_v1)),
%%     ?assert(meck:validate(blockchain_worker)),
%%     ?assert(meck:validate(blockchain_swarm)),
%%     ?assert(meck:validate(blockchain)),
%%     meck:unload(blockchain_ledger_v1),
%%     meck:unload(blockchain_worker),
%%     meck:unload(blockchain_swarm),
%%     meck:unload(blockchain).

-endif.
