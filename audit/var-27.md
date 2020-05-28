# Chain Variable Transaction 27

## Changes

This txn enables snapshots support on chain.

## Rationale

| Var               	| Existing  	| New 	| Rationale                                             	|
|-------------------	|-----------	|-----	|-------------------------------------------------------	|
| snapshot_interval 	| undefined 	| 720 	| Determines how often to take a snapshot of the ledger 	|
| snapshot_version  	| undefined 	| 1   	| Indicates whether snapshots are enabled on chain      	|

## Version threshold

None

## Transaction

```
[{352052,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"snapshot_interval",
                                                     "int",<<"720">>},
                               {blockchain_var_v1_pb,"snapshot_version","int",<<"1">>}],
                              0,
                              <<48,68,2,32,73,15,151,103,164,98,52,17,188,220,41,220,36,
                                61,194,123,183,156,123,238,136,49,194,179,134,205,144,
                                174,228,158,220,148,2,32,127,209,251,41,128,14,180,19,
                                164,205,86,38,172,96,27,147,114,86,180,235,255,227,167,
                                17,70,50,155,22,62,114,119,196>>,
                              <<>>,<<>>,[],[],27}]}]
```

## Acceptance block
352052

## Acceptance block time
Thu 28 May 2020 10:34:17 PM UTC
