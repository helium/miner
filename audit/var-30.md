# Chain Variable Transaction 30

## Changes

This txn enables support for transaction fees for most blockchain transactions. Additionally we've retired one price oracle key and replaced it with a new one.

## Rationale

| Var                           	| Existing  	| New           	| Rationale                                                               	|
|-------------------------------	|-----------	|---------------	|-------------------------------------------------------------------------	|
| txn_fees | undefined | true | Require transaction fees for most blockchain transactions |
| txn_fee_multiplier | undefined | 5000 | The size of a transaction, rounded up to the next multiple of `dc_payload_size`, is multiplied by this value to compute the minimum txn fee. |
| price_oracle_public_keys      	| see audit-28 	| see txn below 	| We've removed oracle `13dUGHis1PdrSwxdseoyZKzQhc8WuWcueAWdT95sDVGDNhGRWV9` and added `14t33QjopqCUVr8FXG4sr58FTu5HnPwGBLPrVK1BFXLR3UsnQSn`                    	|
| staking_fee_txn_add_gateway_v1  | undefined | 4000000 | The cost for adding a gateway to the helium network is now $40 USD. |
| staking_fee_txn_assert_location_v1 | undefined | 1000000 | The cost for (re)asserting a gateway's location is now $10 USD. |
| staking_fee_txn_oui_v1 | undefined | 10000000 | The cost for purchasing an Organisationally Unique Identifier (OUI) for routing packets is now $100 USD. |
| staking_fee_txn_oui_v1_per_address | undefined | 10000000 | The cost for purchasing end-device addresses to route to an OUI's routers is now $100 USD per address. |
| staking_keys | undefined | see below | The list of keys allowed to add gateways to the network |

## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,
    [{blockchain_var_v1_pb,"price_oracle_public_keys","string",
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
           211,177,78,82,113,122,149,47,240,33,1,170,219,208,73,
           156,141,219,148,7,148,253,209,66,48,218,91,71,232,244,
           198,253,236,40,201,90,112,61,236,156,69,235,109,33,1,
           154,235,195,88,165,97,21,203,1,161,96,71,236,193,188,
           50,185,214,15,14,86,61,245,131,110,22,150,8,48,174,104,
           66,33,1,254,248,78,138,218,174,201,86,100,210,209,229,
           149,130,203,83,149,204,154,58,32,192,118,144,129,178,
           83,253,8,199,161,128>>},
     {blockchain_var_v1_pb,"staking_fee_txn_add_gateway_v1",
         "int",<<"4000000">>},
     {blockchain_var_v1_pb,"staking_fee_txn_assert_location_v1",
         "int",<<"1000000">>},
     {blockchain_var_v1_pb,"staking_fee_txn_oui_v1","int",
         <<"10000000">>},
     {blockchain_var_v1_pb,"staking_fee_txn_oui_v1_per_address",
         "int",<<"10000000">>},
     {blockchain_var_v1_pb,"staking_keys","string",
         <<33,1,227,161,42,33,88,58,219,234,66,213,92,117,229,47,
           57,205,53,126,55,102,56,207,160,154,207,237,120,176,92,
           105,178,141,33,1,218,132,178,224,73,95,7,138,99,31,33,
           226,68,91,210,143,193,42,37,244,232,67,45,207,68,137,
           25,48,4,228,227,88>>},
     {blockchain_var_v1_pb,"txn_fee_multiplier","int",<<"5000">>},
     {blockchain_var_v1_pb,"txn_fees","atom",<<"true">>}],
    0,
    <<48,68,2,32,9,181,82,96,230,148,129,181,53,62,5,238,90,
      180,150,234,246,255,133,183,235,235,140,241,115,129,23,
      133,151,103,184,194,2,32,53,26,95,57,156,198,226,156,
      159,58,127,105,147,97,130,62,131,108,178,144,41,196,33,
      191,241,193,160,103,220,43,181,108>>,
    <<>>,<<>>,[],[],30}
```

## Acceptance block
393023

## Acceptance block time
2020-06-29 21:21:52 UTC
