# Chain Variable Transaction 32

## Changes

This transaction enables snr and frequency for poc_receipt and poc_witness.

## Rationale

| Var                      	| Existing  	| New 	| Rationale                                                       	|
|--------------------------	|-----------	|-----	|-----------------------------------------------------------------	|
| data_aggregation_version 	| undefined 	| 1   	| Enable SNR and frequency data for POC receipt and POC witnesses 	|

## Version threshold

None

## Transaction

```
[{424960,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"data_aggregation_version",
                                                     "int",<<"1">>}],
                              0,
                              <<48,70,2,33,0,169,91,41,77,193,6,108,126,156,6,101,21,45,
                                203,89,162,147,150,142,90,170,90,222,51,166,52,176,251,
                                172,54,133,11,2,33,0,236,92,167,112,140,127,148,245,77,
                                247,59,144,78,200,195,160,53,209,38,60,135,156,31,196,
                                53,4,24,255,81,255,160,19>>,
                              <<>>,<<>>,[],[],32}]}]
```

## Acceptance block
424960

## Acceptance block time
Tue 21 Jul 2020 09:25:04 PM UTC
