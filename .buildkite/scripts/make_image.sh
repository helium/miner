#!/bin/bash

set -euo pipefail

# MINER_REGISTRY_NAME
# IMAGE_ARCH
# IMAGE_FORMAT
# all come from pipeline.yml

MINER_REGISTRY_NAME="$REGISTRY_HOST/team-helium/$REGISTRY_NAME"
DOCKER_NAME="$(basename $(pwd))-${IMAGE_ARCH}_${BUILDKITE_TAG}"
DOCKERFILE_NAME=".buildkite/scripts/Dockerfile-${IMAGE_ARCH}"
TARNAME="${DOCKER_NAME}-oci.tar"

docker login -u="team-helium+buildkite" -p="${QUAY_BUILDKITE_PASSWORD}" ${REGISTRY_HOST}

if [ "$IMAGE_FORMAT" = "oci" ]; then
    docker buildx build -o type=oci,dest="${TARNAME}" -f "${DOCKERFILE_NAME}" .
    docker import "${TARNAME}" "$MINER_REGISTRY_NAME:$DOCKER_NAME"
else
    docker build -t helium:$DOCKER_NAME -f "${DOCKERFILE_NAME}" .
    docker tag helium:$DOCKER_NAME "$MINER_REGISTRY_NAME:$DOCKER_NAME"
fi

docker push "$MINER_REGISTRY_NAME:$DOCKER_NAME"
