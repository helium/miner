# Chain Variable Transaction 17

## Changes

This transaction updates:

- `poc_version` from 7 to 8
- `poc_v4_prob_rssi_wt` from 0.2 to 0.0
- `poc_v4_prob_count_wt` from 0.2 to 0.0
- `poc_v4_prob_time_wt` from 0.2 to 0.0
- `poc_v4_prob_randomness_wt` from 0.4 to 0.5

Introduces:
- `poc_centrality_wt`, sets it to 0.5
- `poc_max_hop_cells`, sets it to 2000
- `poc_good_bucket_high`, sets it to -80
- `poc_good_bucket_low`, sets it to -115

## Rationale

| Var                  	| Existing  	| Proposed 	| Rationale                                                                                                                                                                             	|
|----------------------	|-----------	|----------	|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------	|
| poc_version          	| 7         	| 8        	| Bump poc_version                                                                                                                                                                      	|
| poc_v4_prob_rssi_wt  	| 0.2       	| 0.0      	| Zeroed because centrality weight takes precedence with v8                                                                                                                             	|
| poc_v4_prob_time_wt  	| 0.2       	| 0.0      	| Zeroed because centrality weight takes precedence with v8                                                                                                                             	|
| poc_v4_prob_count_wt 	| 0.2       	| 0.0      	| Zeroed because centrality weight takes precedence with v8                                                                                                                             	|
| poc_v4_randomness_wt 	| 0.4       	| 0.5      	| Increased to still keep 50% chance of picking a random witness as next hop _after_ filtering.                                                                                         	|
| poc_centrality_wt    	| undefined 	| 0.5      	| Introduced to pick potentially legitimate witnesses as next hops when constructing paths.                                                                                             	|
| poc_max_hop_cells    	| undefined 	| 2000     	| Introduced to limit max next hop distance. A rough estimate is given by: sqrt(3).a.(n-1), where, a: hex_edge_length and n: poc_max_hop_cells. For hexagons at resolution 12, ~32.5kms 	|
| poc_good_bucket_high 	| undefined 	| -80     	| Upper bound for a good RSSI value                                                                                                                                                     	|
| poc_good_bucket_low  	| undefined 	| -115     	| Lower bound for a good RSSI value                                                                                                                                                     	|

## Version threshold

None

## Transaction

```
[{200500,
  [{blockchain_txn_vars_v1_pb,
       [{blockchain_var_v1_pb,"poc_centrality_wt","float",
            <<"5.00000000000000000000e-01">>},
        {blockchain_var_v1_pb,"poc_good_bucket_low","int",
            <<"-115">>},
        {blockchain_var_v1_pb,"poc_good_bucket_high","int",
            <<"-80">>},
        {blockchain_var_v1_pb,"poc_max_hop_cells","int",<<"2000">>},
        {blockchain_var_v1_pb,"poc_v4_prob_count_wt","float",
            <<"0.00000000000000000000e+00">>},
        {blockchain_var_v1_pb,"poc_v4_prob_rssi_wt","float",
            <<"0.00000000000000000000e+00">>},
        {blockchain_var_v1_pb,"poc_v4_prob_time_wt","float",
            <<"0.00000000000000000000e+00">>},
        {blockchain_var_v1_pb,"poc_v4_randomness_wt","float",
            <<"5.00000000000000000000e-01">>},
        {blockchain_var_v1_pb,"poc_version","int",<<"8">>}],
       0,
       <<48,69,2,32,102,195,247,179,244,74,65,178,68,26,191,11,
         57,146,165,6,70,45,80,231,107,179,254,53,120,245,142,
         134,95,51,29,255,2,33,0,254,10,217,0,1,102,155,238,209,
         129,88,12,60,12,159,156,175,178,177,39,50,156,85,100,
         207,170,44,125,38,215,213,95>>,
       <<>>,<<>>,[],[],17}]}]
```

## Acceptance block

200500

## Acceptance block time

Tue 11 Feb 2020 01:11:13 AM UTC
