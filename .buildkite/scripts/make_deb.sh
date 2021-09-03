#!/usr/bin/env bash

set -euo pipefail

VERSION=$(git describe --abbrev=0 | sed -e 's,validator,,')
./rebar3 as validator release -v ${VERSION}

./rebar3 as validator release -n miner -v ${TAG}

fpm -n validator \
    -v "${VERSION}" \
    -s dir \
    -t deb \
    --depends libssl1.1 \
    --depends libsodium23 \
    --deb-systemd deb/miner.service \
    --deb-no-default-config-files \
    _build/validator/rel/=/var/helium
