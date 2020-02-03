
%% packet forwarder protocol
-define(PROTOCOL_2, 2).
-define(PUSH_DATA, 0).
-define(PUSH_ACK, 1).
-define(PULL_DATA, 2).
-define(PULL_RESP, 3).
-define(PULL_ACK, 4).
-define(TX_ACK, 5).

%% lorawan message types
-define(JOIN_REQUEST, 2#000).
-define(JOIN_ACCEPT, 2#001).
-define(UNCONFIRMED_UP, 2#010).
-define(UNCONFIRMED_DOWN, 2#011).
-define(CONFIRMED_UP, 2#100).
-define(CONFIRMED_DOWN, 2#101).


