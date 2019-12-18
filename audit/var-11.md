# Chain Variable Transaction 11

## Changes

This transaction updates `poc_version` to 5 from 4.

and introduces the following new chain variable:

```
poc_v5_target_prob_randomness_wt
```

## Rationale

| Var                              	| Existing  	| Proposed 	| Rationale                                                                                                                                                                              	|
|----------------------------------	|-----------	|----------	|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------	|
| poc_version           	        | 4            	| 5        	| Update poc_version to 5
| poc_v4_exclusion_cells           	| 10        	| 8        	| This will change min hop from ~433m to ~300m                                                                                                                                           	|
| poc_v4_prob_rssi_wt              	| 0.3       	| 0.0      	| Removed to compensate for poc_v4_randomness_wt                                                                                                                                         	|
| poc_v4_prob_time_wt              	| 0.3       	| 0.0      	| Removed to compensate for poc_v4_randomness_wt                                                                                                                                         	|
| poc_v4_prob_count_wt             	| 0.3       	| 0.0      	| Removed to compensate for poc_v4_randomness_wt                                                                                                                                         	|
| poc_v4_randomness_wt             	| 0.1       	| 1.0      	| Bias entirely towards picking a next hop witness randomly                                                                                                                                	|
| poc_v4_target_prob_score_wt      	| 0.8       	| 0.0      	| Removed to compensate for poc_v5_target_prob_randomness_wt                                                                                                                             	|
| poc_v4_target_prob_edge_wt      	| 0.2       	| 0.0      	| Removed to compensate for poc_v5_target_prob_randomness_wt                                                                                                                             	|
| poc_v5_target_prob_randomness_wt 	| undefined 	| 1.0      	| Introduced to make target selection entirely random. Currently high scoring hotspots are always getting targeted, this causes a feedback loop where, high scoring will keep gaining score	|

## Version threshold

None

## Transaction

```
  {blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"poc_v4_exclusion_cells",
                                                     "int",<<"8">>},
                               {blockchain_var_v1_pb,"poc_v4_prob_count_wt","float",
                                                     <<"0.00000000000000000000e+00">>},
                               {blockchain_var_v1_pb,"poc_v4_prob_rssi_wt","float",
                                                     <<"0.00000000000000000000e+00">>},
                               {blockchain_var_v1_pb,"poc_v4_prob_time_wt","float",
                                                     <<"0.00000000000000000000e+00">>},
                               {blockchain_var_v1_pb,"poc_v4_randomness_wt","float",
                                                     <<"1.00000000000000000000e+00">>},
                               {blockchain_var_v1_pb,"poc_v4_target_prob_edge_wt","float",
                                                     <<"0.00000000000000000000e+00">>},
                               {blockchain_var_v1_pb,"poc_v4_target_prob_score_wt","float",
                                                     <<"0.00000000000000000000e+00">>},
                               {blockchain_var_v1_pb,"poc_v5_target_prob_randomness_wt",
                                                     "float",<<"1.00000000000000000000e+00">>},
                               {blockchain_var_v1_pb,"poc_version","int",<<"5">>}],
                              0,
                              <<48,69,2,32,121,0,151,116,147,113,233,89,151,70,173,189,
                                221,220,164,55,203,115,115,191,96,88,196,217,155,118,27,
                                245,173,201,249,157,2,33,0,223,69,3,52,160,64,202,232,
                                13,59,33,249,235,220,255,201,199,255,61,125,72,130,221,
                                52,37,240,170,110,107,42,86,228>>,
                              <<>>,<<>>,[],[],11}]}
```


## Acceptance block

140479

## Acceptance block time

Wed 18 Dec 2019 01:48:52 AM UTC
