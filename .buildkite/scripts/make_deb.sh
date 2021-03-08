#!/usr/bin/env bash

set -euo pipefail

fpm -n validator \
    -v $(git describe --long --always) \
    -s dir \
    -t deb \
    --depends libssl1.1 \
    --depends libsodium23 \
    --deb-systemd deb/miner.service \
    --deb-no-default-config-files \
    _build/prod/rel/=/var/helium
