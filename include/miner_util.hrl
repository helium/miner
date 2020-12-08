-define(mark(Mark), miner_util:mark(?MODULE, Mark)).

-define(IDENTIFY(Conn),
        case libp2p_connection:session(Conn) of
            {ok, Session} ->
                libp2p_session:identify(Session, self(), ?MODULE),
                receive
                    {handle_identify, ?MODULE, {ok, Identify}} ->
                        libp2p_identify:pubkey_bin(Identify)
                after 10000 ->
                          erlang:error(failed_identify_timeout)
                end;
            {error, closed} ->
                erlang:error(dead_session)
        end).
