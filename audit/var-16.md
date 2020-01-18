# Chain Variable Transaction 16

## Changes

This transaction updates `poc_version` from 6 to 7.
Also introduces `poc_target_hex_parent_res` chain variable and sets it to `5`.

## Rationale

| Var                       | Old       | New  | Rationale                                                                       |
|---------------------------|-----------|------|---------------------------------------------------------------------------------|
| poc_version               | 6         | 7    | Update poc version to allow targeting within a h3 zone                          |
| poc_target_hex_parent_res | undefined | 5    | Set h3 zone resolution to create sub-regions of hotspots to target in           |

## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"poc_target_hex_parent_res",
    "int",<<"5">>},
    {blockchain_var_v1_pb,"poc_version","int",<<"7">>}],
    0,
    <<48,69,2,33,0,196,244,215,93,178,145,16,170,152,110,99,
    233,49,144,12,86,231,37,78,205,124,127,121,101,114,232,
    187,198,123,144,116,108,2,32,107,168,100,174,130,47,157,
    132,178,98,175,81,63,162,30,164,20,12,100,149,37,44,27,
    7,175,116,37,53,180,85,246,7>>,
    <<>>,<<>>,[],[],16}
```

## Acceptance block

173558

## Acceptance block time

Sat 18 Jan 2020 12:46:58 AM UTC
