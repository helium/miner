# Chain Variable Transaction 47

## Changes

This transaction updated `reward_version` from 4 to 5.


## Rationale

| Var                       	| Existing  	| New 	| Rationale                                                                  	|
|---------------------------	|-----------	|-----	|----------------------------------------------------------------------------	|
| reward_version               	| 4         	| 5  	| Incremented to fix missing dc rewards in an epoch                             |


## Version threshold

None

## Transaction

```
[{549522,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"reward_version",
                                                     "int",<<"5">>}],
                              0,
                              <<48,68,2,32,122,184,214,168,126,97,4,53,217,49,156,188,
                                230,212,213,80,58,250,255,158,16,225,99,90,56,133,25,
                                115,104,197,132,18,2,32,100,71,52,155,231,35,88,96,50,
                                94,84,48,143,21,87,31,48,189,125,225,161,182,99,205,255,
                                108,98,231,35,36,218,177>>,
                              <<>>,<<>>,[],[],47,[],[],[]}]}]
```

## Acceptance block

549522

## Acceptance block time

Mon Oct 19 06:02:24 PM UTC 2020
