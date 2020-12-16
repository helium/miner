# Chain Variable Transaction 50

## Changes

This transaction activates support for [HIP-15](https://github.com/helium/HIP/blob/master/0015-beaconing-rewards.md) and [HIP-17](https://github.com/helium/HIP/blob/master/0017-hex-density-based-transmit-reward-scaling.md).

## Rationale


| Chain Variable             |      Old Value        |      New Value        | Reason                                                                  |
|----------------------------|-----------------------|-----------------------|-------------------------------------------------------------------------|
| poc_path_limit             | 5                     | 1                     | Enabling Beacon PoC                                                     |
| poc_challengees_percent    | 0.18                  | 0.0531                | PoC Challengee Rewards                                                  |
| poc_witnesses_percent      | 0.0855                | 0.2124                | PoC Witnesses Rewards                                                   |
| witness_redundancy         | undefined             | 4                     | Optimum desired redundant witnesses for a PoC transmission              |
| poc_reward_decay_rate      | undefined             | 0.8                   | Decay rate for additional PoC transmission                              |
| hip17_res_0                | undefined             | <<"2,100000,100000">> | Default (unused)                                                        |
| hip17_res_1                | undefined             | <<"2,100000,100000">> | Default (unused)                                                        |
| hip17_res_2                | undefined             | <<"2,100000,100000">> | Default (unused)                                                        |
| hip17_res_3                | undefined             | <<"2,100000,100000">> | Default (unused)                                                        |
| hip17_res_4                | undefined             | <<"1,250,800">>       | Number of siblings: 1, density_tgt: 250, density_max: 800               |
| hip17_res_5                | undefined             | <<"1,100,400">>       | Number of siblings: 1, density_tgt: 100, density_max: 400               |
| hip17_res_6                | undefined             | <<"1,25,100">>        | Number of siblings: 1, density_tgt: 25, density_max: 100                |
| hip17_res_7                | undefined             | <<"2,5,20">>          | Number of siblings: 2, density_tgt: 5, density_max: 20                  |
| hip17_res_8                | undefined             | <<"2,1,4">>           | Number of siblings: 2, density_tgt: 1, density_max: 4                   |
| hip17_res_9                | undefined             | <<"2,1,2">>           | Number of siblings: 2, density_tgt: 1, density_max: 2                   |
| hip17_res_10               | undefined             | <<"2,1,1">>           | Number of siblings: 2, density_tgt: 1, density_max: 1                   |
| hip17_res_11               | undefined             | <<"2,100000,100000">> | Default (unused)                                                        |
| hip17_res_12               | undefined             | <<"2,100000,100000">> | Default (unused)                                                        |
| density_tgt_res            | undefined             | 4                     | Resolution to calculate density                                         |
| hip17_interactivity_blocks | undefined             | 3600                  | Number of blocks since last_poc_challenge a Hotspot is considered active|


## Version threshold

None

## Transaction

```
[{635109,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"density_tgt_res",
                                                     "int",<<"4">>},
                               {blockchain_var_v1_pb,"hip17_interactivity_blocks","int",
                                                     <<"3600">>},
                               {blockchain_var_v1_pb,"hip17_res_0","string",
                                                     <<"2,100000,100000">>},
                               {blockchain_var_v1_pb,"hip17_res_1","string",
                                                     <<"2,100000,100000">>},
                               {blockchain_var_v1_pb,"hip17_res_10","string",<<"2,1,1">>},
                               {blockchain_var_v1_pb,"hip17_res_11","string",
                                                     <<"2,100000,100000">>},
                               {blockchain_var_v1_pb,"hip17_res_12","string",
                                                     <<"2,100000,100000">>},
                               {blockchain_var_v1_pb,"hip17_res_2","string",
                                                     <<"2,100000,100000">>},
                               {blockchain_var_v1_pb,"hip17_res_3","string",
                                                     <<"2,100000,100000">>},
                               {blockchain_var_v1_pb,"hip17_res_4","string",
                                                     <<"1,250,800">>},
                               {blockchain_var_v1_pb,"hip17_res_5","string",
                                                     <<"1,100,400">>},
                               {blockchain_var_v1_pb,"hip17_res_6","string",<<"1,25,100">>},
                               {blockchain_var_v1_pb,"hip17_res_7","string",<<"2,5,20">>},
                               {blockchain_var_v1_pb,"hip17_res_8","string",<<"2,1,4">>},
                               {blockchain_var_v1_pb,"hip17_res_9","string",<<"2,1,2">>},
                               {blockchain_var_v1_pb,"poc_challengees_percent","float",
                                                     <<"5.31000000000000013656e-02">>},
                               {blockchain_var_v1_pb,"poc_path_limit","int",<<"1">>},
                               {blockchain_var_v1_pb,"poc_reward_decay_rate","float",
                                                     <<"8.00000000000000044409e-01">>},
                               {blockchain_var_v1_pb,"poc_witnesses_percent","float",
                                                     <<"2.12400000000000005462e-01">>},
                               {blockchain_var_v1_pb,"witness_redundancy","int",<<"4">>}],
                              0,
                              <<48,69,2,32,84,162,162,103,69,201,199,140,138,207,207,
                                201,128,132,199,16,243,159,110,143,151,119,231,110,230,
                                160,88,120,6,229,153,42,2,33,0,200,2,135,233,157,222,64,
                                249,60,41,179,153,101,207,82,238,196,107,77,229,181,173,
                                169,104,19,131,114,32,85,207,106,8>>,
                              <<>>,<<>>,[],[],50,[],[],[]}]}]
```

## Acceptance block

635109

## Acceptance block time

Wed Dec 16 06:07:49 PM UTC 2020
