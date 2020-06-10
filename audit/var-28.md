# Chain Variable Transaction 28

## Changes

This txn enables support for price oracles on chain.

## Rationale

| Var                           	| Existing  	| New           	| Rationale                                                               	|
|-------------------------------	|-----------	|---------------	|-------------------------------------------------------------------------	|
| price_oracle_public_keys      	| undefined 	| see txn below 	| Array of ed25519 binary public keys of price oracles                    	|
| price_oracle_refresh_interval 	| undefined 	| 10            	| Number of blocks between price recalculation                            	|
| price_oracle_height_delta     	| undefined 	| 10            	| Delta allowed between current block height and the price_submission txn 	|
| price_oracle_price_scan_delay 	| undefined 	| 3600          	| Number of seconds to delay scanning for prices                          	|
| price_oracle_price_scan_max   	| undefined 	| 90000         	| Number of seconds to stop scanning for prices                           	|

## Version threshold

None

## Transaction

```
[{365778,                       
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"price_oracle_height_delta",
                                                     "int",<<"10">>},
                               {blockchain_var_v1_pb,"price_oracle_price_scan_delay","int",
                                                     <<"3600">>},
                               {blockchain_var_v1_pb,"price_oracle_price_scan_max","int",
                                                     <<"90000">>},
                               {blockchain_var_v1_pb,"price_oracle_public_keys","string",
                                                     <<33,1,32,30,226,70,15,7,0,161,150,108,195,90,205,113,
                                                       146,41,110,194,43,86,168,161,93,241,68,41,125,160,229,
                                                       130,205,140,33,1,32,237,78,201,132,45,19,192,62,81,209,
                                                       208,156,103,224,137,51,193,160,15,96,238,160,42,235,
                                                       174,99,128,199,20,154,222,33,1,143,166,65,105,75,56,
                                                       206,157,86,46,225,174,232,27,183,145,248,50,141,210,
                                                       144,155,254,80,225,240,164,164,213,12,146,100,33,1,20,
                                                       131,51,235,13,175,124,98,154,135,90,196,83,14,118,223,
                                                       189,221,154,181,62,105,183,135,121,105,101,51,163,119,
                                                       206,132,33,1,254,129,70,123,51,101,208,224,99,172,62,
                                                       126,252,59,130,84,93,231,214,248,207,139,84,158,120,
                                                       232,6,8,121,243,25,205,33,1,148,214,252,181,1,33,200,
                                                       69,148,146,34,29,22,91,108,16,18,33,45,0,210,100,253,
                                                       211,177,78,82,113,122,149,47,240,33,1,90,51,177,136,
                                                       251,61,186,74,70,104,60,110,117,210,185,180,2,206,243,
                                                       127,214,101,24,180,190,163,157,45,198,21,200,194,33,1,
                                                       170,219,208,73,156,141,219,148,7,148,253,209,66,48,218,
                                                       91,71,232,244,198,253,236,40,201,90,112,61,236,156,69,
                                                       235,109,33,1,154,235,195,88,165,97,21,203,1,161,96,71,
                                                       236,193,188,50,185,214,15,14,86,61,245,131,110,22,150,
                                                       8,48,174,104,66>>},
                               {blockchain_var_v1_pb,"price_oracle_refresh_interval","int",
                                                     <<"10">>}],
                              0,
                              <<48,69,2,32,93,185,230,92,30,230,55,181,24,195,57,57,213,
                                128,109,207,58,177,158,113,105,77,254,239,149,82,140,
                                130,235,85,157,6,2,33,0,142,145,83,135,182,210,190,182,
                                85,225,240,182,190,113,77,236,162,134,221,187,1,82,23,
                                65,13,238,137,69,66,126,3,35>>,
                              <<>>,<<>>,[],[],28}]}]
```

## Acceptance block
365778

## Acceptance block time
Mon 08 Jun 2020 08:09:52 PM UTC
