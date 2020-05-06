#!/bin/bash

set -euo pipefail

MINER_REGISTRY_NAME="quay.io/team-helium/miner"
DOCKER_NAME="$(basename $(pwd))_${BUILDKITE_TAG}-amd64"

docker build \
    -t helium:$DOCKER_NAME -f .buildkite/scripts/Dockerfile-amd64 .

docker tag helium:$DOCKER_NAME "$MINER_REGISTRY_NAME:$DOCKER_NAME"

docker login -u="team-helium+buildkite" -p="${QUAY_BUILDKITE_PASSWORD}"
docker push "$MINER_REGISTRY_NAME:$DOCKER_NAME"
