# Chain Variable Transaction 43

## Changes

This transaction updates `poc_version` from 8 to 9 and `data_aggregation_version` from 1 to 2.
Details available [here](https://engineering.helium.com/2020/09/15/major-blockchain-release-multisig-and-poc-v9.html).


## Rationale

| Var                       	| Existing  	| New 	| Rationale                                                                  	|
|---------------------------	|-----------	|-----	|----------------------------------------------------------------------------	|
| poc_version                 	| 8         	| 9  	| Revved to allow new POC                                                       |
| data_aggregation_version     	| 1         	| 2  	| Revved to gather channel and datarate information for POC witness/receipt     |


## Version threshold

None

## Transaction

```
[{502316,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"data_aggregation_version",
                                                     "int",<<"2">>},
                               {blockchain_var_v1_pb,"poc_version","int",<<"9">>}],
                              0,
                              <<48,69,2,33,0,183,71,151,0,202,133,223,46,89,206,238,116,
                                156,113,86,40,13,178,199,39,227,196,18,26,97,76,137,77,
                                155,220,143,118,2,32,33,181,4,87,250,229,212,213,113,56,
                                116,154,254,22,193,37,179,98,21,208,185,237,169,105,69,
                                203,182,117,74,67,200,0>>,
                              <<>>,<<>>,[],[],43,[],[],[]}]}]
```

## Acceptance block

502316

## Acceptance block time

Wed Sep 16 07:09:40 PM UTC 2020