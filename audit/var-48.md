# Chain Variable Transaction 48

## Changes

This transaction updates `election_version` from `3` to `4` and sets `transfer_hotspot_stale_poc_blocks` to `1200`.


## Rationale

| Var                       	        | Existing  	| New 	| Rationale                                                                  	|
|---------------------------	        |-----------	|-----	|----------------------------------------------------------------------------	|
| election_version            	        | 3         	| 4  	| Updated to allow random consensus group selection                             |
| transfer_hotspot_stale_poc_blocks    	| undefined   	| 1200 	| Enable transfer hotspot transaction                                           |


## Version threshold

None

## Transaction

```
[{599928,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"election_version",
                                                     "int",<<"4">>},
                               {blockchain_var_v1_pb,"transfer_hotspot_stale_poc_blocks",
                                                     "int",<<"1200">>}],
                              0,
                              <<48,68,2,32,13,80,23,97,37,243,95,63,97,61,225,208,84,
                                169,3,78,193,95,52,121,39,168,237,69,69,26,76,154,34,30,
                                200,245,2,32,112,177,49,0,105,66,87,32,240,107,222,110,
                                73,195,30,138,232,143,40,37,33,67,149,187,4,24,190,241,
                                109,206,252,103>>,
                              <<>>,<<>>,[],[],48,[],[],[]}]}]
```

## Acceptance block

599928

## Acceptance block time

Mon Nov 23 06:28:01 PM UTC 2020
