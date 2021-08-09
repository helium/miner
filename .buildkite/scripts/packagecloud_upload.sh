#!/usr/bin/env bash

set -euo pipefail

TAG=$( git describe --abbrev=0 --tags | sed -e s/$1// )

PKGNAME="$1_${TAG}_amd64.deb"

buildkite-agent artifact download ${PKGNAME} .

if [[ "$1" == "validator" ]]; then
    # it's _validatorS_ in packagecloud
    REPO="$1s"
else
    REPO="$1"
fi

curl -u "${PACKAGECLOUD_API_KEY}:" \
     -F "package[distro_version_id]=190" \
     -F "package[package_file]=@${PKGNAME}" \
     "https://packagecloud.io/api/v1/repos/helium/${REPO}/packages.json"
