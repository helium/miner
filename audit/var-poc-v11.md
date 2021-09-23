# POCv11 Chain Variable Proposal

The following chain variables would be required for POCv11 activation.

* `regulatory_region_bin_str`. Binary string of supported regulatory regions. This determines _all_ supported LoraWAN regions on the Helium network. This will be set to:

```
<<"region_as923_1,region_as923_2,region_as923_3,region_as923_4,region_au915,region_cn470,region_eu433,region_eu868,region_in865,region_kr920,region_ru864,region_us915">>
```

* The following chain variables will be binary blobs containing the H3 GeoJson data for specific geographic region. Each of the following are available in serialized form [here](https://github.com/helium/lorawan-h3/tree/main/serialized).

```
region_as923_1
region_as923_2
region_as923_3
region_as923_4
region_au915
region_cn470
region_eu433
region_eu868
region_in865
region_kr920
region_ru864
region_us915
```

* For each of the above `region_*` variables there will be a corresponding `region_*_params` chain variable which determines the specific LoraWAN region parameters a device is allowed to operate legally. These are binary blobs with encoding driven using protobuf available [here](https://github.com/helium/proto/blob/master/src/blockchain_region_param_v1.proto). A deserialized version of the below variables is available [here](https://gist.github.com/vihu/ac2d6761318672376db7a12fa915519c).

```
region_as923_1_params
region_as923_2_params
region_as923_3_params
region_as923_4_params
region_au915_params
region_cn470_params
region_eu433_params
region_eu868_params
region_in865_params
region_kr920_params
region_ru864_params
region_us915_params
```

* `poc_version` will be updated from `10` to `11`.

* `data_aggregation_version` will be updated from `2` to `3`.

* `poc_distance_limit` will be set to `50` Km.

* `fspl_loss` will be set to `1.3` dBm.
