# Chain Variable Transaction 61

## Changes

This transaction updates the `poc_challenge_interval` from `240` to `480` to reduce the amout of data that needs to be processed by the miners in every block.

## Version threshold

None

## Transaction

```
[{844410,
  [{blockchain_txn_vars_v1_pb,
       [{blockchain_var_v1_pb,"poc_challenge_interval","int",
            <<"480">>}],
       0,
       <<48,69,2,33,0,249,35,227,178,97,135,128,101,42,129,195,
         211,212,16,176,72,124,246,220,140,119,255,52,186,50,152,
         7,115,250,128,169,3,2,32,36,14,49,254,30,125,180,240,
         200,110,125,14,253,189,214,194,132,232,22,91,200,61,252,
         95,184,115,161,77,87,188,30,79>>, 
       <<>>,<<>>,[],[],61,[],[],[]}]}]
```

## Acceptance block

844410

## Acceptance block time

Fri May 14 10:27:43 PM UTC 2021
