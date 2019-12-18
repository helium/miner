# Chain Variable Transaction 12

## Changes

This transaction updates the following chain variables:

```
poc_v4_prob_count_wt
poc_v4_prob_rssi_wt
poc_v4_prob_time_wt
poc_v4_randomness_wt
```

## Rationale

|-------------------------------|-----------|-------|---------------------------------------------------------------------------------------|
|Var                            | Old       | New   | Rationale                                                                             |
|-------------------------------|-----------|-------|---------------------------------------------------------------------------------------|
|poc_v4_prob_rssi_wt            |0.0        |0.2    |Re-introduce weight associated with next hop rssi probability                          |
|poc_v4_prob_count_wt           |0.0        |0.2    |Re-introduce weight associated with next hop witness count probability                 |
|poc_v4_prob_time_wt            |0.0        |0.2    |Re-introduce weight associated with next hop recent time probability                   |
|poc_v4_randomness_wt           |1.0        |0.4    |Reduce next hop randomness when assigning probabilities to the witnesses               |
|-------------------------------|-----------|-------|---------------------------------------------------------------------------------------|


## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"poc_v4_prob_count_wt",
                                                   "float",<<"2.00000000000000011102e-01">>},
                             {blockchain_var_v1_pb,"poc_v4_prob_rssi_wt","float",
                                                   <<"2.00000000000000011102e-01">>},
                             {blockchain_var_v1_pb,"poc_v4_prob_time_wt","float",
                                                   <<"2.00000000000000011102e-01">>},
                             {blockchain_var_v1_pb,"poc_v4_randomness_wt","float",
                                                   <<"4.00000000000000022204e-01">>}],
                            0,
                            <<48,70,2,33,0,233,156,119,217,123,1,173,131,14,77,1,24,
                              190,191,216,37,54,151,149,2,91,255,145,26,217,188,60,98,
                              102,140,68,74,2,33,0,244,206,119,193,16,68,106,211,200,
                              54,136,122,52,81,103,137,178,247,156,95,88,86,112,146,
                              128,192,195,17,64,72,60,105>>,
                            <<>>,<<>>,[],[],12}

```

## Acceptance block

140720

## Acceptance block time

Wed 18 Dec 2019 05:50:44 AM UTC
