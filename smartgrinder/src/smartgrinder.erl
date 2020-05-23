-module(smartgrinder).

%% API exports
-export([main/1]).

%% in case you want to start this up in the shell and drive manually
-compile(export_all).

-record(s,
        {
         addrs :: #{},
         miners :: #{},
         up :: [],
         down = [] :: [],
         latest_height = 1 :: integer(),
         since_update = 0 :: integer()
        }).

%%====================================================================
%% API functions
%%====================================================================

%% escript Entry point
main(_Args) ->
    loop(init()).

%%====================================================================
%% Internal functions
%%====================================================================

init() ->
    Miners0 =
        [{miner(I), net_adm:ping(miner(I))}
         || I <- lists:seq(1, 16)],
    Miners1 =
        lists:filter(fun({_Name, pong}) -> true;
                        (_) -> false
                     end, Miners0),
    Miners = [Name || {Name, _Resp} <- Miners1],

    MinerAddrs = lists:map(fun(M) -> {rpc:call(M, blockchain_swarm, pubkey_bin, []), M} end, Miners),

    AddrsMap = maps:from_list(MinerAddrs),
    {Addrs, Miners} = lists:unzip(MinerAddrs),
    AddrMiners = lists:zip(Miners, Addrs),
    MinersMap = maps:from_list(AddrMiners),
    tee("miners ~p~n", [MinersMap]),

    #s{addrs = AddrsMap, miners = MinersMap, up = Miners}.

loop(#s{addrs = Addrs,
        miners = Miners,
        latest_height = Height,
        since_update = Since} = S) ->
    %% sleep for 5-15s
    SleepTime = rand:uniform(10000) + 5000,
    tee("sleeping for ~p", [SleepTime]),
    timer:sleep(SleepTime),

    {Up, Down} = up_down(Miners),
    Members = members(Addrs, Up),

    Stopped =
        case can_kill(Members, Up, Down, Since) of
            {true, Victim} ->
                %% do kill-y thing
                case rand:uniform(100) of
                    N when N > 90 ->
                        %% do a reset, but not on a consensus member
                        case lists:member(Victim, Members) of
                            true ->
                                none;
                            false ->
                                %% grab a working node
                                Donor = take(Up -- [Victim]),
                                I = index(Victim, maps:keys(Miners)),
                                D = index(Donor, maps:keys(Miners)),
                            tee("transferring snapshot from ~p to ~p",
                                [D, I]),
                            %% take a snapshot
                            Tag = erlang:unique_integer([positive]),
                            os:cmd("./cmd.sh " ++ D ++ " snapshot take /tmp/snap" ++ int(Tag)),
                            %% load the snapshot on the victim
                            os:cmd("./cmd.sh " ++ I ++ " snapshot load /tmp/snap" ++ int(Tag)),
                            Victim
                        end;
                    N when N > 60 ->
                        %% murder
                        Pid = getpid(Victim),
                        tee("killing ~p ~p -9", [Victim, Pid]),
                        os:cmd("kill -9 " ++ Pid),
                        Victim;
                    N when N > 10 ->
                        %% stop
                        tee("stopping ~p", [Victim]),
                        I = index(Victim, maps:keys(Miners)),
                        os:cmd("./cmd.sh " ++ I ++ " stop"),
                        Victim;
                    %% do nothing
                    _ ->
                        none
                end;
            _ ->
                tee("skipping kill: up ~p since ~p", [Up -- Members, Since]),
                none
        end,
    Up1 = rm_stopped(Stopped, Up),

    %% maybe restart something
    case rand:uniform(100) of
        N2 when N2 > 30 ->
            case take(Down) of
                empty ->
                    tee("no one is down"),
                    ok;
                AntiVictim ->
                    tee("starting ~p", [AntiVictim]),
                    I2 = index(AntiVictim, maps:keys(Miners)),
                    os:cmd("./cmd.sh " ++ I2 ++ " start"),
                    ok = wait_for_up(AntiVictim)
            end;
        _ -> ok
    end,
    Height1 =
        try
            %% update height, using Up1 to avoid trying a just-started node
            {ok, H1} = height(hd(Up1)),
            tee("height old ~p new ~p", [Height, H1]),
            H1
        catch _:_ ->
                Height
        end,

    %% we might check on an old or lagging node,  never go down
    {Height2, Since1} =
        case Height >= Height1 of
            true ->
                {Height, Since + 1};
            false ->
                {Height1, 0}
        end,

    case Since > 20 of
        true ->
            %% give up!
            %% os:cmd("./all-cmd.sh stop"),
            tee("no progress in too long, exiting"),
            ok;
        false ->
            loop(S#s{latest_height = Height2,
                     since_update = Since1})
    end.


up_down(M) ->
    L = maps:size(M),
    Miners =
        [{miner(I), net_adm:ping(miner(I))}
         || I <- lists:seq(1, L)],
    Up =
        lists:filter(fun({_Name, pong}) -> true;
                        (_) -> false
                     end, Miners),
    Down = Miners -- Up,
    Up1 = [Name || {Name, _} <- Up],
    Down1 = [Name || {Name, _} <- Down],
    {Up1, Down1}.

rm_stopped(none, Up) ->
    Up;
rm_stopped(M, Up) ->
    Up -- [M].

miner(N) ->
    list_to_atom("miner" ++ integer_to_list(N) ++ "@127.0.0.1").

height(Node) ->
    Chain = chain(Node),
    rpc([Node], blockchain, height, [Chain]).

chain(Node) ->
    rpc([Node], blockchain_worker, blockchain, []).

ledger(Node) ->
    Chain = chain(Node),
    ledger(Node, Chain).

ledger(Node, Chain) ->
    rpc([Node], blockchain, ledger, [Chain]).

tee(Fmt) ->
    tee(Fmt, []).

tee(Fmt, Args) ->
    %% add lager later so there's a record
    io:format(Fmt ++ "~n", Args).

take([]) ->
    empty;
take(Lst) ->
    lists:nth(rand:uniform(length(Lst)), Lst).

getpid(Node) ->
    rpc([Node], os, getpid, []).

rpc([], _M, _F, _A) ->
    {error, no_up_nodes};
rpc([H|T], M, F, A) ->
    case rpc(H, M, F, A, 5) of
        down ->
            rpc(T, M, F, A);
        Else ->
            Else
    end.

rpc(_Node, _M, _F, _A, 0) ->
    down;
rpc(Node, M, F, A, Tries) ->
    case rpc:call(Node, M, F, A, 250) of
        {badrpc, nodedown} ->
            timer:sleep(500),
            rpc(Node, M, F, A, Tries - 1);
        {error, {nodedown, _}} ->
            timer:sleep(500),
            rpc(Node, M, F, A, Tries - 1);
        Else ->
            Else
    end.


rpc_with_ledger([H|T], M, F) ->
    rpc_with_ledger([H|T], M, F, 3).

rpc_with_ledger([H|T], M, F, Tries) ->
    case ledger(H) of
        {error, _} ->
            rpc_with_ledger(T, M, F);
        Ledger ->
            case rpc:call(H, M, F, [Ledger], 250) of
                {badrpc, nodedown} ->
                    timer:sleep(500),
                    rpc(T, M, F, Tries - 1);
                {error, {nodedown, _}} ->
                    timer:sleep(500),
                    rpc(T, M, F, Tries - 1);
                Else ->
                    Else
            end
    end.

index(Node, Nodelist) ->
    index(Node, Nodelist, 1).

index(Node, [Node | _], Idx) ->
    integer_to_list(Idx);
index(Node, [_ | Rest], Idx) ->
    index(Node, Rest, Idx + 1).

members(Addrs, Nodes) ->
    {ok, CMs} = rpc_with_ledger(Nodes, blockchain_ledger_v1, consensus_members),
    %% sometimes get a weird crash here?
    try
        lists:map(fun(CM) -> maps:get(CM, Addrs) end, CMs)
    catch _:_ ->
            %% try again?
            members(Addrs, Nodes)
    end.

%% if we haven't made progress in a while, wait for starts to put the
%% cluster back together
can_kill(_Members, _Up, _Down, Since) when Since > 5 ->
    false;
%% error fetching members, can't do anything sensible, try again
can_kill(Members, _Up, _Down, _Since) when is_tuple(Members)->
    false;
can_kill(Members, Up, Down, _Since) ->
    F = fails(length(Members)),
    %% if the consensus group has only f or less down and up is not
    %% empty, return someone
    case length(Members) - length(Members -- Down) of
        N when N < F ->
            {true, take(Up)};
        _ ->
            case take(Up -- Members) of
                empty ->
                    false;
                Victim ->
                    {true, Victim}
            end
    end.

fails(N) ->
    (N - 1) div 3.

int(N) ->
    integer_to_list(N).

wait_for_up(Node) ->
    wait_for_up(Node, 60).

wait_for_up(Node, 0) ->
    {error, {node, Node, did_not_start}};
wait_for_up(Node, Tries) ->
    case net_adm:ping(Node) of
        pong ->
            case rpc([Node], erlang, whereis, [blockchain_worker]) of
                undefined ->
                    wait_for_up(Node, Tries - 1);
                _ ->
                    ok
            end;
        _ ->
            timer:sleep(500),
            wait_for_up(Node, Tries - 1)
    end.

