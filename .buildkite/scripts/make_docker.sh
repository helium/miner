#!/bin/bash

set -euo pipefail

MINER_REGISTRY_NAME="quay.io/team-helium/miner"
DOCKER_NAME="$(basename $(pwd))_${BUILDKITE_TAG}"

docker build -t helium:$DOCKER_NAME -f .buildkite/scripts/Dockerfile .
docker tag helium:$DOCKER_NAME "$MINER_REGISTRY_NAME:$DOCKER_NAME"

docker login -u="team-helium+buildkite" -p="QJQP7M6WWE00QJOTUIEBF8N16F4THA9O2MF6QBM1ZGGVK33TG2VLCGK50SUHSWED" quay.io
docker push "$MINER_REGISTRY_NAME:$DOCKER_NAME"
