#!/usr/bin/env bash

set -euo pipefail

fpm -n validator \
    -v $(git describe --abbrev=0 --tags | sed -e s/val//) \
    -s dir \
    -t deb \
    --depends libssl1.1 \
    --depends libsodium23 \
    --deb-systemd deb/miner.service \
    --deb-no-default-config-files \
    _build/validator/rel/=/var/helium
