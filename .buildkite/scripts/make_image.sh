#!/bin/bash

set -euo pipefail

# REGISTRY_HOST
# REGISTRY_NAME
# IMAGE_ARCH
# BUILD_TYPE
# all come from pipeline.yml

ERLANG_IMAGE="23.3.4.5-alpine"
ERLANG_IMAGE_SOURCE="erlang"

BASE_IMAGE="${ERLANG_IMAGE_SOURCE}:${ERLANG_IMAGE}"
if [[ "$IMAGE_ARCH" == "arm64" ]]; then
    BASE_IMAGE="arm64v8/$BASE_IMAGE"
fi

MINER_REGISTRY_NAME="$REGISTRY_HOST/team-helium/$REGISTRY_NAME"
BASE_DOCKER_NAME=$(basename $(pwd))

VERSION=$(git describe --abbrev=0 | sed -e "s/$BUILD_TYPE//" -e 's/_GA$//' )
DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
DOCKER_BUILD_ARGS="--build-arg VERSION=${VERSION}"

LATEST_TAG="$MINER_REGISTRY_NAME:latest-${IMAGE_ARCH}"

case "$BUILD_TYPE" in
    "val")
        echo "Doing a testnet validator image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="--build-arg BUILDER_IMAGE=${BASE_IMAGE} --build-arg RUNNER_IMAGE=${BASE_IMAGE} --build-arg REBAR_BUILD_TARGET=docker_testval ${DOCKER_BUILD_ARGS}"
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_testnet_${VERSION}"
        LATEST_TAG="$MINER_REGISTRY_NAME:latest-val-${IMAGE_ARCH}"
        ;;
    "validator")
        echo "Doing a mainnet validator image build for $IMAGE_ARCH"
        DOCKER_BUILD_ARGS="--build-arg BUILDER_IMAGE=${BASE_IMAGE} --build-arg RUNNER_IMAGE=${BASE_IMAGE} --build-arg REBAR_BUILD_TARGET=docker_val ${DOCKER_BUILD_ARGS}"
        ;;
    "miner")
        echo "Doing a miner image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="--build-arg EXTRA_BUILD_APK_PACKAGES=apk-tools --build-arg EXTRA_RUNNER_APK_PACKAGES=apk-tools --build-arg BUILDER_IMAGE=${BASE_IMAGE} --build-arg RUNNER_IMAGE=${BASE_IMAGE} --build-arg REBAR_BUILD_TARGET=docker ${DOCKER_BUILD_ARGS}"
        DOCKER_NAME="${DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
        ;;
    *)
        echo "I don't know how to do a build for ${BUILD_TYPE}"
        exit 1
        ;;
esac


docker login -u="team-helium+buildkite" -p="${QUAY_BUILDKITE_PASSWORD}" ${REGISTRY_HOST}

# update latest tag if github tag ends in `_GA` and don't do the rest of a build
if [[ "$BUILDKITE_TAG" =~ _GA$ ]]; then

    echo "GA release detected: Updating latest tag on ${REGISTRY_HOST} for ${BUILD_TYPE}"

    docker tag helium:$DOCKER_NAME "$MINER_REGISTRY_NAME:$LATEST_TAG"
    docker push "$MINER_REGISTRY_NAME:$LATEST_TAG"

    exit $?
fi

docker build "$DOCKER_BUILD_ARGS" -t "helium:${DOCKER_NAME}" .
docker tag "helium:$DOCKER_NAME" "$MINER_REGISTRY_NAME:$DOCKER_NAME"
docker push "$MINER_REGISTRY_NAME:$DOCKER_NAME"
