# Chain Variable Transaction 44

## Changes

This transaction reverts `poc_version` back from 9 to 8 and `data_aggregation_version` from 2 to 1.


## Rationale

| Var                       	| Existing  	| New 	| Rationale                                                                  	|
|---------------------------	|-----------	|-----	|----------------------------------------------------------------------------	|
| poc_version                 	| 9         	| 8  	| Reverted back for debugging                                                   |
| data_aggregation_version     	| 1         	| 2  	| Reverted back for debugging                                                   |


## Version threshold

None

## Transaction

```
[{502524,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"data_aggregation_version",
                                                     "int",<<"1">>},
                               {blockchain_var_v1_pb,"poc_version","int",<<"8">>}],
                              0,
                              <<48,70,2,33,0,182,110,124,21,113,166,205,101,137,169,215,
                                51,94,104,58,245,197,4,79,132,3,211,136,12,219,170,163,
                                59,29,226,242,164,2,33,0,177,16,242,31,240,252,199,182,
                                191,42,131,219,61,21,25,240,103,243,113,61,2,216,180,
                                169,237,26,15,188,145,174,73,204>>,
                              <<>>,<<>>,[],[],44,[],[],[]}]}]
```

## Acceptance block

502524

## Acceptance block time

Thu Sep 17 02:34:45 AM UTC 2020