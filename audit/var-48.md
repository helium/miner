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
                                169,3,78,193,...>>,
                              <<>>,<<>>,[],[],48,[],[],[]}]}]
```

## Acceptance block

599928

## Acceptance block time

Mon Nov 23 06:28:01 PM UTC 2020
