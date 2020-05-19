# Chain Variable Transaction 26

## Changes

This chain var txn reverts back witness_refresh_interval to approximately 1 week.

## Rationale

| Var                      	| Existing  	| New   	| Rationale                                                                    	|
|--------------------------	|-----------	|-------	|------------------------------------------------------------------------------	|
| witness_refresh_interval 	| 1 	        | 10080	    | Revert back to ~1 week interval       	                                    |
| witness_refresh_rand_n   	| 1000 	        | 1000	    | noop                                                                          |

## Version threshold

None

## Transaction

```
[{339406,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"witness_refresh_interval",
                                                     "int",<<"10080">>},
                               {blockchain_var_v1_pb,"witness_refresh_rand_n","int",
                                                     <<"1000">>}],
                              0,
                              <<48,69,2,32,120,79,248,0,192,147,87,105,207,131,65,215,
                                244,90,29,170,86,8,20,204,197,20,124,155,65,96,227,243,
                                234,245,230,190,2,33,0,170,9,207,17,205,61,145,201,88,
                                202,254,203,59,115,83,247,119,219,248,166,227,128,174,
                                24,56,132,24,137,73,191,122,186>>,
                              <<>>,<<>>,[],[],26}]}]
```

## Acceptance block
339406

## Acceptance block time
Tue 19 May 2020 08:48:43 PM UTC
