# Chain Variable Transaction 25

## Changes

Reintroduce witness refresh chain variables for potential chain halt fix.


## Rationale

| Var                      	| Existing  	| New   	| Rationale                                                                    	|
|--------------------------	|-----------	|-------	|------------------------------------------------------------------------------	|
| witness_refresh_interval 	| undefined     | 1	        | Set to 1 to allow witness refresh at each block                               |
| witness_refresh_rand_n   	| undefined	    | 1000	    | Set on chain for making sure witness refresh is deterministic                 |

## Version threshold

None

## Transaction

```
[{339303,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"witness_refresh_interval",
                                                     "int",<<"1">>},
                               {blockchain_var_v1_pb,"witness_refresh_rand_n","int",
                                                     <<"1000">>}],
                              0,
                              <<48,68,2,32,94,80,223,101,150,32,69,215,244,65,32,184,
                                150,110,20,227,9,32,103,68,161,112,179,41,222,205,68,
                                203,167,230,31,173,2,32,48,92,5,72,12,237,66,144,203,98,
                                188,106,60,147,104,243,22,102,3,150,236,169,176,233,69,
                                120,227,132,220,92,139,0>>,
                              <<>>,<<>>,[],[],25}]}]
```

## Acceptance block
339303

## Acceptance block time
Tue 19 May 2020 06:45:04 PM UTC
