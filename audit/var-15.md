# Chain Variable Transaction 15

## Changes

This increases the challenge interval so as to make challenges less common, since there are likely too many of them given the side and density of the network.

## Rationale

| Var            | Old       | New  | Rationale                                                                       |
|----------------|-----------|------|---------------------------------------------------------------------------------|
| poc_challenge_interval    | 30   | 60  | Double the challenge interval to lower consensus group load.    |


## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,
    [{blockchain_var_v1_pb,"poc_challenge_interval","int",
         <<"60">>}],
    0,
    <<48,69,2,32,85,121,222,145,49,146,58,248,154,171,25,78,
      170,5,177,43,55,173,58,191,107,153,236,77,252,250,155,
      223,6,162,76,48,2,33,0,209,250,125,75,123,220,173,53,
      100,134,251,39,129,59,142,160,187,172,151,54,30,240,37,
      226,170,242,119,35,245,48,13,31>>,
    <<>>,<<>>,[],[],15}]}
```

## Acceptance block

166098

## Acceptance block time

Thu 09 Jan 2020 02:35:55 AM UTC
