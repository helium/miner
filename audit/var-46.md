# Chain Variable Transaction 46

## Changes

This transaction updated `reward_version` from 3 to 4.


## Rationale

| Var                       	| Existing  	| New 	| Rationale                                                                  	|
|---------------------------	|-----------	|-----	|----------------------------------------------------------------------------	|
| reward_version               	| 3         	| 4  	| Incremented to fix data credit overpayments                                   |


## Version threshold

None

## Transaction

```
[{542235,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"reward_version",
                                                     "int",<<"4">>}],
                              0,
                              <<48,70,2,33,0,204,154,116,177,167,136,68,208,162,136,74,
                                224,76,14,70,104,230,141,192,223,69,254,95,153,150,118,
                                169,187,180,212,162,190,2,33,0,172,146,230,182,68,119,
                                29,225,221,119,114,28,218,91,24,0,162,3,149,200,84,13,
                                139,227,125,88,11,9,112,232,2,95>>,
                              <<>>,<<>>,[],[],46,[],[],[]}]}]
```

## Acceptance block

542235


## Acceptance block time

Tue Oct 13 06:22:07 PM UTC 2020