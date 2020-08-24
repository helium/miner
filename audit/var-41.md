# Chain Variable Transaction 41

## Changes

This transaction updates `reward_version` from 2 to 3 to comply with [HIP-10](https://github.com/helium/HIP/blob/master/0010-usage-based-data-transfer-rewards.md).


## Rationale

| Var                       	| Existing  	| New 	| Rationale                                                                  	|
|---------------------------	|-----------	|-----	|----------------------------------------------------------------------------	|
| reward_version               	| 2         	| 3   	| Incremented to allow reward distribution according to HIP-10                  |


## Version threshold

None

## Transaction

```
[{466894,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"reward_version",
                                                     "int",<<"3">>}],
                              0,
                              <<48,69,2,32,9,68,105,251,190,209,131,23,178,106,235,211,
                                109,143,111,44,170,129,96,78,208,201,202,24,32,223,196,
                                42,251,156,222,114,2,33,0,249,194,247,57,251,74,97,129,
                                179,115,5,208,153,68,45,254,181,99,166,131,245,236,0,
                                227,120,62,108,196,65,146,128,162>>,
                              <<>>,<<>>,[],[],41}]}]
```

## Acceptance block

466894

## Acceptance block time

Mon 24 Aug 2020 07:04:13 PM UTC