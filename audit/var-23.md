# Chain Variable Transaction 23

## Changes

This transaction updates a few existing chain variables detailed below.

## Rationale

| Var                      	| Existing  	| New   	| Rationale                                                                    	|
|--------------------------	|-----------	|-------	|------------------------------------------------------------------------------	|
| batch_size               	| 200       	| 400   	| Increase batch_size to allow bigger blocks with more txns                    	|
| election_selection_pct   	| 20        	| 1     	| Allow greater score variance for selecting potential consensus members       	|
| poc_good_bucket_low     	| -118      	| -130  	| Relax the lower bound for POC witness RSSI for custom antenna configurations 	|
| poc_good_bucket_high    	| -80        	| -70   	| Relax the upper bound for POC witness RSSI for custom antenna configurations 	|
| witness_refresh_interval 	| undefined 	| 10080 	| Probabilistically clean witnesses over the course of ~1 week                 	|
| witness_refresh_rand_n   	| undefined 	| 1000  	| Set on chain for making sure witness refresh is deterministic                	|

## Version threshold

None

## Transaction

```
[{339044,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"batch_size",
                                                     "int",<<"400">>},
                               {blockchain_var_v1_pb,"election_selection_pct","int",
                                                     <<"1">>},
                               {blockchain_var_v1_pb,"poc_good_bucket_high","int",
                                                     <<"-70">>},
                               {blockchain_var_v1_pb,"poc_good_bucket_low","int",
                                                     <<"-130">>},
                               {blockchain_var_v1_pb,"witness_refresh_interval","int",
                                                     <<"10080">>},
                               {blockchain_var_v1_pb,"witness_refresh_rand_n","int",
                                                     <<"1000">>}],
                              0,
                              <<48,69,2,32,5,218,164,65,231,80,140,105,113,4,41,102,211,
                                91,62,244,34,177,199,88,14,92,145,117,18,112,69,183,34,
                                58,130,120,2,33,0,231,6,9,42,161,138,187,125,71,32,65,
                                237,89,109,97,39,247,9,197,183,157,228,30,97,106,129,
                                150,87,92,24,142,223>>,
                              <<>>,<<>>,[],[],23}]}]
```

## Acceptance block

339044

## Acceptance block time
Mon 18 May 2020 06:20:31 PM UTC
