# Chain Variable Transaction 19

## Changes

This transaction sets the `max_payments` variable and thereby enables payment_v2 transactions.

## Rationale

| Var          	| Existing  	| New 	| Rationale                                                 	|
|--------------	|-----------	|-----	|-----------------------------------------------------------	|
| max_payments 	| undefined 	| 50  	| Set maximum payments with a single payment_v2 transaction 	|

## Version threshold

None

## Transaction

```
[{272463,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"max_payments",
                                                     "int",<<"50">>}],
                              0,
                              <<48,68,2,32,43,220,3,101,250,219,214,248,251,42,4,253,
                                120,136,52,211,221,...>>,
                              <<>>,<<>>,[],[],19}]}]
```

## Acceptance block

272463

## Acceptance block time

Wed 01 Apr 2020 02:06:47 AM UTC
