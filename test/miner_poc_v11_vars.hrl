%% NOTE: Only used for testing
%% Each of these is used to download a serialized copy of h3 region set
-define(region_as923_1_url,
    "https://github.com/JayKickliter/lorawan-h3-regions/blob/main/serialized/AS923-1.res7.h3idx?raw=true"
).

-define(region_as923_2_url,
    "https://github.com/JayKickliter/lorawan-h3-regions/blob/main/serialized/AS923-2.res7.h3idx?raw=true"
).

-define(region_as923_3_url,
    "https://github.com/JayKickliter/lorawan-h3-regions/blob/main/serialized/AS923-3.res7.h3idx?raw=true"
).

-define(region_au915_url,
    "https://github.com/JayKickliter/lorawan-h3-regions/blob/main/serialized/AU915.res7.h3idx?raw=true"
).

%% NOTE: This is incorrect in the sense that we're using 779 as 470,
%% we should fix it downstream in lorwawan regions
-define(region_cn470_url,
    "https://github.com/JayKickliter/lorawan-h3-regions/blob/main/serialized/CN779.res7.h3idx?raw=true"
).

-define(region_eu433_url,
    "https://github.com/JayKickliter/lorawan-h3-regions/blob/main/serialized/EU433.res7.h3idx?raw=true"
).

-define(region_eu868_url,
    "https://github.com/JayKickliter/lorawan-h3-regions/blob/main/serialized/EU868.res7.h3idx?raw=true"
).

-define(region_in865_url,
    "https://github.com/JayKickliter/lorawan-h3-regions/blob/main/serialized/IN865.res7.h3idx?raw=true"
).

-define(region_kr920_url,
    "https://github.com/JayKickliter/lorawan-h3-regions/blob/main/serialized/KR920.res7.h3idx?raw=true"
).

-define(region_ru864_url,
    "https://github.com/JayKickliter/lorawan-h3-regions/blob/main/serialized/RU864.res7.h3idx?raw=true"
).

-define(region_us915_url,
    "https://github.com/JayKickliter/lorawan-h3-regions/blob/main/serialized/US915.res7.h3idx?raw=true"
).

-define(regulatory_region_bin_str,
    <<"as923_1,as923_2,as923_3,au915,cn470,eu433,eu868,in865,kr920,ru864,us915">>
).
