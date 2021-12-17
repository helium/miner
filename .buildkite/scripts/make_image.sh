#!/bin/bash

set -euo pipefail

# REGISTRY_HOST
# REGISTRY_ORG
# REGISTRY_NAME
# IMAGE_ARCH
# BUILD_TYPE
# BUILD_NET
# all come from pipeline.yml

TEST_BUILD=${TEST_BUILD:-0}

ERLANG_IMAGE="24-alpine"
ERLANG_IMAGE_SOURCE="erlang"

BUILD_IMAGE="${ERLANG_IMAGE_SOURCE}:${ERLANG_IMAGE}"

RUN_IMAGE="alpine:3.15"

if [[ "$IMAGE_ARCH" == "arm64" ]]; then
    BUILD_IMAGE="arm64v8/$BUILD_IMAGE"
    RUN_IMAGE="arm64v8/$RUN_IMAGE"
fi

VERSION=$(echo $VERSION_TAG | sed -e "s/$BUILD_TYPE//")
DOCKER_BUILD_ARGS="--build-arg VERSION=$VERSION --build-arg BUILD_NET=$BUILD_NET"

if [[ ! $TEST_BUILD -eq "0" ]]; then
    REGISTRY_NAME="test-builds"
    DOCKER_BUILD_ARGS="--build-arg REBAR_DIAGNOSTIC=1 $DOCKER_BUILD_ARGS"
fi
MINER_REGISTRY_NAME="$REGISTRY_HOST/$REGISTRY_ORG/$REGISTRY_NAME"

LATEST_TAG="latest-${IMAGE_ARCH}"

case "$BUILD_TYPE" in
    "val")
        echo "Doing a testnet validator image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="--build-arg BUILDER_IMAGE=$BUILD_IMAGE --build-arg RUNNER_IMAGE=$RUN_IMAGE --build-arg REBAR_BUILD_TARGET=docker_testval $DOCKER_BUILD_ARGS"
        BASE_DOCKER_NAME="validator"
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_testnet_${VERSION}"
        LATEST_TAG="latest-val-${IMAGE_ARCH}"
        ;;
    "validator")
        echo "Doing a mainnet validator image build for $IMAGE_ARCH"
        DOCKER_BUILD_ARGS="--build-arg BUILDER_IMAGE=${BUILD_IMAGE} --build-arg RUNNER_IMAGE=${RUN_IMAGE} --build-arg REBAR_BUILD_TARGET=docker_val ${DOCKER_BUILD_ARGS}"
        BASE_DOCKER_NAME="validator"
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
        ;;
    "miner")
        echo "Doing a miner image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="--build-arg EXTRA_BUILD_APK_PACKAGES=apk-tools --build-arg EXTRA_RUNNER_APK_PACKAGES=apk-tools --build-arg BUILDER_IMAGE=${BUILD_IMAGE} --build-arg RUNNER_IMAGE=${RUN_IMAGE} --build-arg REBAR_BUILD_TARGET=docker ${DOCKER_BUILD_ARGS}"
        BASE_DOCKER_NAME=$(basename $(pwd))
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
        ;;
    "miner-testnet")
        echo "Doing a testnet miner image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="--build-arg EXTRA_BUILD_APK_PACKAGES=apk-tools --build-arg EXTRA_RUNNER_APK_PACKAGES=apk-tools --build-arg BUILDER_IMAGE=${BUILD_IMAGE} --build-arg RUNNER_IMAGE=${RUN_IMAGE} --build-arg REBAR_BUILD_TARGET=docker_testminer ${DOCKER_BUILD_ARGS}"
        BASE_DOCKER_NAME=$(basename $(pwd))
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_testnet_${VERSION}"
        ;;
    *)
        echo "I don't know how to do a build for ${BUILD_TYPE}"
        exit 1
        ;;
esac


if [[ ! $TEST_BUILD ]]; then
    docker login -u="${REGISTRY_ORG}+buildkite" -p="${QUAY_BUILDKITE_PASSWORD}" ${REGISTRY_HOST}
fi

# update latest tag if github tag ends in `_GA` and don't do the rest of a build
if [[ "$VERSION_TAG" =~ _GA$ ]]; then

    echo "GA release detected: Updating latest tag on ${REGISTRY_HOST} for ${BUILD_TYPE}"

    DOCKER_NAME=$(echo "$DOCKER_NAME" | sed -e 's/_GA//')

    docker pull "$MINER_REGISTRY_NAME:$DOCKER_NAME"
    docker tag "$MINER_REGISTRY_NAME:$DOCKER_NAME" "$MINER_REGISTRY_NAME:$LATEST_TAG"
    docker push "$MINER_REGISTRY_NAME:$LATEST_TAG"

    if [[ "$BUILD_TYPE" == "miner" ]]; then
        echo "miner GA release detected: Updating 'GA' tag on ${REGISTRY_HOST} for ${VERSION}"
        docker tag "$MINER_REGISTRY_NAME:$DOCKER_NAME" "$MINER_REGISTRY_NAME:${DOCKER_NAME}_GA"
        docker push "$MINER_REGISTRY_NAME:${DOCKER_NAME}_GA"
    fi

    exit $?
fi

docker build $DOCKER_BUILD_ARGS -t "helium:${DOCKER_NAME}" .
docker tag "helium:$DOCKER_NAME" "$MINER_REGISTRY_NAME:$DOCKER_NAME"
docker push "$MINER_REGISTRY_NAME:$DOCKER_NAME"
