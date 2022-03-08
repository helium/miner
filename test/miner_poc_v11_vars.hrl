%% NOTE: Only used for testing
%% Each of these is used to download a serialized copy of h3 region set

-define(region_as923_1_url,
    "https://github.com/helium/lorawan-h3/blob/main/serialized/AS923-1.res7.h3idx?raw=true"
).

-define(region_as923_2_url,
    "https://github.com/helium/lorawan-h3/blob/main/serialized/AS923-2.res7.h3idx?raw=true"
).

-define(region_as923_3_url,
    "https://github.com/helium/lorawan-h3/blob/main/serialized/AS923-3.res7.h3idx?raw=true"
).

-define(region_as923_4_url,
    "https://github.com/helium/lorawan-h3/blob/main/serialized/AS923-4.res7.h3idx?raw=true"
).

-define(region_au915_url,
    "https://github.com/helium/lorawan-h3/blob/main/serialized/AU915.res7.h3idx?raw=true"
).

-define(region_cn470_url,
    "https://github.com/helium/lorawan-h3/blob/main/serialized/CN470.res7.h3idx?raw=true"
).

-define(region_eu433_url,
    "https://github.com/helium/lorawan-h3/blob/main/serialized/EU433.res7.h3idx?raw=true"
).

-define(region_eu868_url,
    "https://github.com/helium/lorawan-h3/blob/main/serialized/EU868.res7.h3idx?raw=true"
).

-define(region_in865_url,
    "https://github.com/helium/lorawan-h3/blob/main/serialized/IN865.res7.h3idx?raw=true"
).

-define(region_kr920_url,
    "https://github.com/helium/lorawan-h3/blob/main/serialized/KR920.res7.h3idx?raw=true"
).

-define(region_ru864_url,
    "https://github.com/helium/lorawan-h3/blob/main/serialized/RU864.res7.h3idx?raw=true"
).

-define(region_us915_url,
    "https://github.com/helium/lorawan-h3/blob/main/serialized/US915.res7.h3idx?raw=true"
).

-define(regulatory_region_bin_str,
    <<"region_as923_1,region_as923_2,region_as923_3,region_as923_4,region_au915,region_cn470,region_eu433,region_eu868,region_in865,region_kr920,region_ru864,region_us915">>
).

-define(REGION_PARAMS_US915, [
    [
        % in hz
        {<<"channel_frequency">>, 903900000},
        % in hz
        {<<"bandwidth">>, 125000},
        % dBi x 10
        {<<"max_eirp">>, 360},
        % will be converted to atoms
        {<<"spreading">>,
         [{25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 904100000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 360},
        {<<"spreading">>,
         [{25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 904300000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 360},
        {<<"spreading">>,
         [{25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 904500000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 360},
        {<<"spreading">>,
         [{25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 904700000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 360},
        {<<"spreading">>,
         [{25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 904900000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 360},
        {<<"spreading">>,
         [{25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 905100000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 360},
        {<<"spreading">>,
         [{25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 905300000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 360},
        {<<"spreading">>,
         [{25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ]
]).

-define(REGION_PARAMS_EU868, [
    [
        {<<"channel_frequency">>, 868100000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 161},
        {<<"spreading">>,
         [{65, 'SF12'}, {129, 'SF9'}, {238, 'SF8'}]}
    ],
    [
        {<<"channel_frequency">>, 868300000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 161},
        {<<"spreading">>,
         [{65, 'SF12'}, {129, 'SF9'}, {238, 'SF8'}]}
    ],
    [
        {<<"channel_frequency">>, 868500000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 161},
        {<<"spreading">>,
         [{65, 'SF12'}, {129, 'SF9'}, {238, 'SF8'}]}
    ],
    [
        {<<"channel_frequency">>, 868500000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 161},
        {<<"spreading">>,
         [{65, 'SF12'}, {129, 'SF9'}, {238, 'SF8'}]}
    ],
    [
        {<<"channel_frequency">>, 867100000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 161},
        {<<"spreading">>,
         [{65, 'SF12'}, {129, 'SF9'}, {238, 'SF8'}]}
    ],
    [
        {<<"channel_frequency">>, 867300000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 161},
        {<<"spreading">>,
         [{65, 'SF12'}, {129, 'SF9'}, {238, 'SF8'}]}
    ],
    [
        {<<"channel_frequency">>, 867500000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 161},
        {<<"spreading">>,
         [{65, 'SF12'}, {129, 'SF9'}, {238, 'SF8'}]}
    ],
    [
        {<<"channel_frequency">>, 867700000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 161},
        {<<"spreading">>,
         [{65, 'SF12'}, {129, 'SF9'}, {238, 'SF8'}]}
    ],
    [
        {<<"channel_frequency">>, 867900000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 161},
        {<<"spreading">>,
         [{65, 'SF12'}, {129, 'SF9'}, {238, 'SF8'}]}
    ]
]).

-define(REGION_PARAMS_AU915, [
    [
        {<<"channel_frequency">>, 916800000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 300},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 917000000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 300},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 917200000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 300},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 917400000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 300},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 917600000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 300},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 917800000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 300},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 918000000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 300},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 918200000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 300},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ]
]).

-define(REGION_PARAMS_AS923_1, [
    [
        {<<"channel_frequency">>, 923200000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 923400000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 922200000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 922400000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 922600000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 922800000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 923000000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 922000000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ]
]).

-define(REGION_PARAMS_AS923_2, [
    [
        {<<"channel_frequency">>, 923200000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 923400000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 923600000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 923800000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 924000000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 924200000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 924400000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 924600000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ]
]).

-define(REGION_PARAMS_AS923_3, [
    [
        {<<"channel_frequency">>, 916600000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 916800000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ]
    %% This is incomplete...
]).

-define(REGION_PARAMS_AS923_4, [
    [
        {<<"channel_frequency">>, 917300000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 917500000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ]
    %% This is incomplete...
]).

-define(REGION_PARAMS_RU864, [
    [
        {<<"channel_frequency">>, 868900000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 869100000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 160},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ]
]).

-define(REGION_PARAMS_CN470, [
    [
        {<<"channel_frequency">>, 486300000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 191},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 486500000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 191},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 486700000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 191},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 486900000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 191},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 487100000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 191},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 487300000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 191},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 487500000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 191},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 487700000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 191},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ]
]).

-define(REGION_PARAMS_IN865, [
    [
        {<<"channel_frequency">>, 865062500},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 300},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 865985000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 300},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 865402500},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 300},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ]
]).

-define(REGION_PARAMS_KR920, [
    [
        {<<"channel_frequency">>, 922100000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 140},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 922300000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 140},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 922500000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 140},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 922700000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 140},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 922900000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 140},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 923100000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 140},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 923300000},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 140},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ]
]).

-define(REGION_PARAMS_EU433, [
    [
        {<<"channel_frequency">>, 43317500},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 121},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 43337500},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 121},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ],
    [
        {<<"channel_frequency">>, 43357500},
        {<<"bandwidth">>, 125000},
        {<<"max_eirp">>, 121},
        {<<"spreading">>,
         [{25, 'SF12'}, {25, 'SF11'}, {25, 'SF10'}, {67, 'SF9'}, {139, 'SF8'}, {256, 'SF7'}]}
    ]
]).
