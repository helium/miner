#!/usr/bin/env bash

set -euo pipefail

TAG=$(echo $VERSION_TAG | sed -e 's,testnet_validator,,' -e 's/validator//')

PKG_STEM="${PKG_STEM:-validator}"
REPO="${REPO:-validators}"
PKGNAME="${PKG_STEM}_${TAG}_amd64.deb"

buildkite-agent artifact download ${PKGNAME} .

curl -u "${PACKAGECLOUD_API_KEY}:" \
     -F "package[distro_version_id]=210" \
     -F "package[package_file]=@${PKGNAME}" \
     https://packagecloud.io/api/v1/repos/helium/${REPO}/packages.json
