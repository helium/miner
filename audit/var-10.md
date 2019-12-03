# Chain Variable Transaction 10

## Changes

This transaction updates `poc_version` to 4 from 3.

and introduces the following new chain variables:

```
poc_v4_exclusion_cells
poc_v4_parent_res
poc_v4_prob_bad_rssi
poc_v4_prob_count_wt
poc_v4_prob_good_rssi
poc_v4_prob_no_rssi
poc_v4_prob_rssi_wt
poc_v4_prob_time_wt
poc_v4_randomness_wt
poc_v4_target_challenge_age
poc_v4_target_exclusion_cells
poc_v4_target_prob_edge_wt
poc_v4_target_prob_score_wt
poc_v4_target_score_curve
```

## Rationale

|-------------------------------|-----------|-------|---------------------------------------------------------------------------------------|
|Var                            | Old       | New   | Rationale                                                                             |
|-------------------------------|-----------|-------|---------------------------------------------------------------------------------------|
|poc_version                    |3          |4      |update to new poc version                                                              |
|poc_v4_parent_res              |undefined  |11     |normalize hotspot witnesses to this h3 resolution                                      |
|poc_v4_exclusion_cells         |undefined  |10     |number of h3 grid cells to exclude when building path                                  |
|poc_v4_target_exclusion_cells  |undefined  |6000   |number of exclusion cells from challenger to target                                    |
|poc_v4_prob_no_rssi            |undefined  |0.5    |probability associated with a next path hop having no rssi information                 |
|poc_v4_prob_bad_rssi           |undefined  |0.01   |probability associated with a next hop having bad rssi information                     |
|poc_v4_prob_good_rssi          |undefined  |1.0    |probability associated with a next hop having good rssi information                    |
|poc_v4_prob_rssi_wt            |undefined  |0.3    |weight associated with next hop rssi probability                                       |
|poc_v4_prob_count_wt           |undefined  |0.3    |weight associated with next hop witness count probability                              |
|poc_v4_prob_time_wt            |undefined  |0.3    |weight associated with next hop recent time probability                                |
|poc_v4_randomness_wt           |undefined  |0.1    |quantifies how much randomness we want when assigning probabilities to the witnesses   |
|poc_v4_target_challenge_age    |undefined  |300    |potential target must have a last poc challenge within this challenge_age              |
|poc_v4_target_score_curve      |undefined  |5      |score curve to calculate the target score probability                                  |
|poc_v4_target_prob_score_wt    |undefined  |0.8    |weight associated with target score probability                                        |
|poc_v4_target_prob_edge_wt     |undefined  |0.2    |weight associated with target being loosely connected probability                      |
|-------------------------------|-----------|-------|---------------------------------------------------------------------------------------|


## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"poc_v4_exclusion_cells",
                                                  "int",<<"10">>},
                            {blockchain_var_v1_pb,"poc_v4_parent_res","int",<<"11">>},
                            {blockchain_var_v1_pb,"poc_v4_prob_bad_rssi","float",
                                                  <<"1.00000000000000002082e-02">>},
                            {blockchain_var_v1_pb,"poc_v4_prob_count_wt","float",
                                                  <<"2.99999999999999988898e-01">>},
                            {blockchain_var_v1_pb,"poc_v4_prob_good_rssi","float",
                                                  <<"1.00000000000000000000e+00">>},
                            {blockchain_var_v1_pb,"poc_v4_prob_no_rssi","float",
                                                  <<"5.00000000000000000000e-01">>},
                            {blockchain_var_v1_pb,"poc_v4_prob_rssi_wt","float",
                                                  <<"2.99999999999999988898e-01">>},
                            {blockchain_var_v1_pb,"poc_v4_prob_time_wt","float",
                                                  <<"2.99999999999999988898e-01">>},
                            {blockchain_var_v1_pb,"poc_v4_randomness_wt","float",
                                                  <<"1.00000000000000005551e-01">>},
                            {blockchain_var_v1_pb,"poc_v4_target_challenge_age","int",
                                                  <<"300">>},
                            {blockchain_var_v1_pb,"poc_v4_target_exclusion_cells","int",
                                                  <<"6000">>},
                            {blockchain_var_v1_pb,"poc_v4_target_prob_edge_wt","float",
                                                  <<"2.00000000000000011102e-01">>},
                            {blockchain_var_v1_pb,"poc_v4_target_prob_score_wt","float",
                                                  <<"8.00000000000000044409e-01">>},
                            {blockchain_var_v1_pb,"poc_v4_target_score_curve","int",
                                                  <<"5">>},
                            {blockchain_var_v1_pb,"poc_version","int",<<"4">>}],
                           0,
                           <<48,69,2,33,0,175,138,62,103,241,64,103,116,144,252,90,
                             57,32,1,136,122,202,128,217,80,150,209,168,37,152,179,
                             131,64,75,70,137,154,2,32,121,34,163,144,190,52,157,25,
                             96,98,216,77,251,113,27,81,161,61,210,198,196,184,249,
                             216,21,108,132,178,248,213,203,71>>,
                           <<>>,<<>>,[],[],10}
```

## Acceptance block

123479

## Acceptance block time

Mon 02 Dec 2019 09:46:19 PM UTC
