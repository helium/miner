# Chain Variable Transaction 73

## Changes

This transaction adds support for light and data-only gateways.

## Version threshold

None

## Transaction

```
[{918630,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"dataonly_gateway_capabilities_mask",
                                                     "int",<<"1">>},
                               {blockchain_var_v1_pb,"full_gateway_capabilities_mask",
                                                     "int",<<"63">>},
                               {blockchain_var_v1_pb,"light_gateway_capabilities_mask",
                                                     "int",<<"31">>},
                               {blockchain_var_v1_pb,"staking_fee_txn_add_dataonly_gateway_v1",
                                                     "int",<<"1000000">>},
                               {blockchain_var_v1_pb,"staking_fee_txn_add_light_gateway_v1",
                                                     "int",<<"4000000">>},
                               {blockchain_var_v1_pb,"staking_fee_txn_assert_location_dataonly_gateway_v1",
                                                     "int",<<"500000">>},
                               {blockchain_var_v1_pb,"staking_fee_txn_assert_location_light_gateway_v1",
                                                     "int",<<"1000000">>}],
                              0,
                              <<48,69,2,33,0,166,117,63,54,236,112,150,72,156,231,145,
                                167,121,109,222,205,46,87,50,118,180,228,2,240,236,185,
                                87,241,215,231,117,211,2,32,43,8,187,102,255,105,221,
                                178,218,57,242,25,182,4,181,49,189,131,20,139,139,148,
                                147,125,10,235,112,136,181,230,53,102>>,
                              <<>>,<<>>,[],[],73,[],[],[]}]}]
```

## Acceptance block

918630

## Acceptance block time

Mon Jul 12 07:09:49 PM UTC 2021
