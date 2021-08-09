#!/usr/bin/env bash

set -euo pipefail

TAG=$( git describe --abbrev=0 --tags | sed -e s/$1// )

PKGNAME="$1_${TAG}_amd64.deb"

buildkite-agent artifact download ${PKGNAME} .

# packagecloud name is seedS or validatorS
REPO="$1s"

curl -u "${PACKAGECLOUD_API_KEY}:" \
     -F "package[distro_version_id]=190" \
     -F "package[package_file]=@${PKGNAME}" \
     "https://packagecloud.io/api/v1/repos/helium/${REPO}/packages.json"
