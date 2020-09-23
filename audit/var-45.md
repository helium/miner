# Chain Variable Transaction 45

## Changes

This transaction updated `poc_version` from 8 to 10 and `data_aggregation_version` from 1 to 2.


## Rationale

| Var                       	| Existing  	| New 	| Rationale                                                                  	|
|---------------------------	|-----------	|-----	|----------------------------------------------------------------------------	|
| poc_version                 	| 8         	| 10  	| Updated for witness/receipt validation                                        |
| data_aggregation_version     	| 1         	| 2  	| Updated for poc-v10                                                           |


## Version threshold

None

## Transaction

```
[{513356,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"data_aggregation_version",
                                                     "int",<<"2">>},
                               {blockchain_var_v1_pb,"poc_version","int",<<"10">>}],
                              0,
                              <<48,69,2,33,0,231,83,168,13,117,97,91,100,116,214,2,195,
                                205,110,61,92,247,255,26,204,122,163,241,30,247,225,13,
                                89,146,183,187,236,2,32,121,169,203,49,55,56,188,244,
                                253,71,43,100,86,167,164,204,145,82,235,214,53,171,133,
                                190,35,29,77,50,253,250,64,209>>,
                              <<>>,<<>>,[],[],45,[],[],[]}]}]
```

## Acceptance block

513356


## Acceptance block time

Wed Sep 23 08:54:29 PM UTC 2020
