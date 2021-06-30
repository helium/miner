#!/usr/bin/env bash

set -euo pipefail

TAG=$( git describe --abbrev=0 --tags | sed -e s/validator// )

fpm -n validator \
    -v "${TAG}" \
    -s dir \
    -t deb \
    --depends libssl1.1 \
    --depends libsodium23 \
    --deb-systemd deb/miner.service \
    --deb-no-default-config-files \
    _build/validator/rel/=/var/helium
