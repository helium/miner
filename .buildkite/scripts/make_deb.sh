#!/usr/bin/env bash

set -euo pipefail

if [[ ! -n "$BUILD_NET" ]]; then
    wget -O /tmp/genesis https://snapshots.helium.wtf/genesis.${BUILD_NET}
    PKG_GENESIS="/tmp/genesis=/opt/miner/update/genesis"
else
    PKG_GENESIS="#"
fi

TAG=$(echo $VERSION_TAG | sed -e s/$1// )
DEBNAME=$( echo $1 | sed -e s/_/-/ )

DIAGNOSTIC=1 ./rebar3 as $1 release -n miner -v ${VERSION} || ./rebar3 as $1 release -n miner -v ${VERSION}

fpm -n ${DEBNAME} \
    -v "${VERSION}" \
    -s dir \
    -t deb \
    --depends libssl1.1 \
    --depends libsodium23 \
    --depends libncurses5 \
    --depends dbus \
    --depends libstdc++6 \
    --deb-systemd deb/miner.service \
    --before-install deb/before_install.sh \
    --after-install deb/after_install.sh \
    --after-remove deb/after_remove.sh \
    --before-upgrade deb/before_upgrade.sh \
    --after-upgrade deb/after_upgrade.sh \
    --deb-no-default-config-files \
    --deb-systemd-enable \
    --deb-systemd-auto-start \
    --deb-systemd-restart-after-upgrade \
    --deb-user helium \
    --deb-group helium \
    _build/$1/rel/=/opt \
    ${PACKAGE_GENESIS}

rm -f /tmp/genesis
