# Chain Variable Transaction 52

## Changes

This transaction increments the POC target challenge age to 1000. The original
liveness check was 10x the challenge interval (previously 30 blocks). Now that
we've upped the challenge interval to 240 blocks, we wanted to increase the
liveness check as proportionally as possible.

## Rationale


| Chain Variable               |  Old Value   |   New Value   | Reason                                                                  |
|------------------------------|--------------|---------------|----------------------------------------------|
| poc_v4_target_challenge_age  |     300      |     1000      | Mirror the change in the challenge interval. |


## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,
    [{blockchain_var_v1_pb,"poc_v4_target_challenge_age","int",
         <<"1000">>}],
    0,
    <<48,69,2,33,0,229,26,119,78,118,89,109,162,88,247,163,86,
      206,12,41,78,244,123,53,209,3,150,21,130,104,68,131,201,
      14,18,64,28,2,32,87,128,197,102,1,89,244,186,224,190,
      253,180,69,65,144,170,204,84,211,18,219,243,47,131,101,
      29,83,86,114,36,228,185>>,
    <<>>,<<>>,[],[],52,[],[],[]}
```

## Acceptance block

653444

## Acceptance block time

Wed 30 Dec 2020 09:02:10 PM UTC
