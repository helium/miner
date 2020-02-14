# Chain Variable Transaction 18

## Changes

This transaction updates `election_cluster_res` and `poc_good_bucket_low`.

## Rationale

| Var                  	| Existing 	| New  	| Rationale                                                                                       	|
|----------------------	|----------	|------	|-------------------------------------------------------------------------------------------------	|
| election_cluster_res 	| 8        	| 4    	| Decreased to ensure more geographic diversity when selecting new consensus members              	|
| poc_good_bucket_high 	| -115     	| -118 	| Decreased to allow potentially good witnesses to be considered eligible when constructing paths 	|

## Version threshold

None

## Transaction

```
[{203976,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"election_cluster_res",
                                                     "int",<<"4">>},
                               {blockchain_var_v1_pb,"poc_good_bucket_low","int",
                                                     <<"-118">>}],
                              0,
                              <<48,70,2,33,0,254,76,15,127,240,63,245,2,176,59,250,65,
                                94,51,114,121,217,214,125,60,40,100,87,57,130,219,195,
                                196,241,58,231,183,2,33,0,241,94,17,53,87,187,103,157,
                                20,86,190,246,202,177,68,227,146,153,165,158,8,117,234,
                                100,37,191,126,243,89,63,228,86>>,
                              <<>>,<<>>,[],[],18}]}]
```

## Acceptance block

203976

## Acceptance block time

Thu 13 Feb 2020 09:29:39 PM UTC
