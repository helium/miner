# Chain Variable Transaction 21

## Changes

This transaction sets the `allow_zero_amount` variable to false and thereby disables zero amount transactions.
Also, updates `batch_size` to allow making more blocks with lesser transactions than fewer bigger blocks with a lot of
transactions.

## Rationale

| Var               	| Existing  	| New   	| Rationale                                                         	|
|-------------------	|-----------	|-------	|-------------------------------------------------------------------	|
| allow_zero_amount 	| undefined 	| false 	| Disable zero amount transactions (payment v1, v2, htlcs)          	|
| batch_size        	| 2500      	| 200   	| Reduce this to allow more smaller blocks than fewer larger blocks 	|

## Version threshold

None

## Transaction

```
[{296150,                       
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"allow_zero_amount",
                                                     "atom",<<"false">>},
                               {blockchain_var_v1_pb,"batch_size","int",<<"200">>}],
                              0,
                              <<48,69,2,33,0,202,113,123,21,39,191,67,38,67,78,234,152,
                                246,137,114,46,224,33,38,194,210,93,101,254,86,12,242,
                                116,112,36,190,249,2,32,70,76,53,81,3,170,140,100,180,
                                150,255,24,158,41,147,110,245,179,219,4,17,53,115,117,
                                84,84,166,33,245,88,121,222>>,
                              <<>>,<<>>,[],[],21}]}]
```

## Acceptance block

296150

## Acceptance block time
Fri 17 Apr 2020 01:51:22 PM PDT
