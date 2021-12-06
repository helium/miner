#!/usr/bin/env bash

set -euo pipefail

VERSION=$(echo $VERSION_TAG | sed -e s/$1// -e s/_/-/ )

DIAGNOSTIC=1 ./rebar3 as $1 release -v $VERSION -n miner

fpm -n $1 \
    -v "${VERSION}" \
    -s dir \
    -t deb \
    --depends libssl1.1 \
    --depends libsodium23 \
    --depends libc6 \
    --depends libncurses5 \
    --depends libgcc1 \
    --depends libstdc++6 \
    --depends libwxbase3.0-0v5 \
    --depends libwxgtk3.0-gtk3-0v5 \
    --depends libsctp1 \
    --deb-systemd deb/miner.service \
    --deb-no-default-config-files \
    _build/$1/rel/=/var/helium
