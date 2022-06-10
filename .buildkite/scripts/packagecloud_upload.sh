#!/usr/bin/env bash

set -euo pipefail

TAG=$(echo $VERSION_TAG | sed -e s/$1// )
DEBNAME=$( echo $1 | sed -e s/_/-/ )

PKGNAME=$"${DEBNAME}_${TAG}_amd64.deb"

buildkite-agent artifact download ${PKGNAME} .

# packagecloud name is testnet_seedS, seedS or validatorS
REPO="$1s"

curl -u "${PACKAGECLOUD_API_KEY}:" \
     -F "package[distro_version_id]=210" \
     -F "package[package_file]=@${PKGNAME}" \
     "https://packagecloud.io/api/v1/repos/helium/${REPO}/packages.json"
