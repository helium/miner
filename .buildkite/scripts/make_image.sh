#!/bin/bash

set -euo pipefail

# REGISTRY_HOST
# REGISTRY_NAME
# IMAGE_ARCH
# BUILD_TYPE
# all come from pipeline.yml

TEST_BUILD=${TEST_BUILD:-0}

ERLANG_IMAGE="23.3.4.6-alpine"
ERLANG_IMAGE_SOURCE="erlang"

BASE_IMAGE="${ERLANG_IMAGE_SOURCE}:${ERLANG_IMAGE}"
if [[ "$IMAGE_ARCH" == "arm64" ]]; then
    BASE_IMAGE="arm64v8/$BASE_IMAGE"
fi

MINER_REGISTRY_NAME="$REGISTRY_HOST/team-helium/$REGISTRY_NAME"

VERSION=$(git describe --abbrev=0 | sed -e "s/$BUILD_TYPE//" -e 's/_GA$//' -e 's/+/-/')
DOCKER_BUILD_ARGS="--build-arg VERSION=$VERSION"

LATEST_TAG="latest-${IMAGE_ARCH}"

case "$BUILD_TYPE" in
    "val")
        echo "Doing a testnet validator image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="--build-arg BUILDER_IMAGE=$BASE_IMAGE --build-arg RUNNER_IMAGE=$BASE_IMAGE --build-arg REBAR_BUILD_TARGET=docker_testval $DOCKER_BUILD_ARGS"
        BASE_DOCKER_NAME="validator"
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_testnet_${VERSION}"
        LATEST_TAG="latest-val-${IMAGE_ARCH}"
        ;;
    "val_tpm")
        echo "Doing a testnet validator with TPM image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="--build-arg BUILDER_IMAGE=$BASE_IMAGE --build-arg RUNNER_IMAGE=$BASE_IMAGE --build-arg REBAR_BUILD_TARGET=docker_testval_tpm $DOCKER_BUILD_ARGS"
        BASE_DOCKER_NAME="validator_tpm"
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_testnet_${VERSION}"
        LATEST_TAG="$MINER_REGISTRY_NAME:latest-val-tpm-${IMAGE_ARCH}"
        ;;
    "validator")
        echo "Doing a mainnet validator image build for $IMAGE_ARCH"
        DOCKER_BUILD_ARGS="--build-arg BUILDER_IMAGE=${BASE_IMAGE} --build-arg RUNNER_IMAGE=${BASE_IMAGE} --build-arg REBAR_BUILD_TARGET=docker_val ${DOCKER_BUILD_ARGS}"
        BASE_DOCKER_NAME="validator"
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
        ;;
    "validator_tpm")
        echo "Doing a mainnet validator with TPM image build for $IMAGE_ARCH"
        DOCKER_BUILD_ARGS="--build-arg BUILDER_IMAGE=${BASE_IMAGE} --build-arg RUNNER_IMAGE=${BASE_IMAGE} --build-arg REBAR_BUILD_TARGET=docker_val_tpm ${DOCKER_BUILD_ARGS}"
        BASE_DOCKER_NAME="validator_tpm"
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
        ;;
    "miner")
        echo "Doing a miner image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="--build-arg EXTRA_BUILD_APK_PACKAGES=apk-tools --build-arg EXTRA_RUNNER_APK_PACKAGES=apk-tools --build-arg BUILDER_IMAGE=${BASE_IMAGE} --build-arg RUNNER_IMAGE=${BASE_IMAGE} --build-arg REBAR_BUILD_TARGET=docker ${DOCKER_BUILD_ARGS}"
        BASE_DOCKER_NAME=$(basename $(pwd))
        if [[ "$BUILDKITE_TAG" =~ _GA$ ]]; then
            DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}_GA"
        else
            DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
        fi

        ;;
    "miner_tpm")
        echo "Doing a miner with TPM image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="--build-arg EXTRA_BUILD_APK_PACKAGES=apk-tools --build-arg EXTRA_RUNNER_APK_PACKAGES=apk-tools --build-arg BUILDER_IMAGE=${BASE_IMAGE} --build-arg RUNNER_IMAGE=${BASE_IMAGE} --build-arg REBAR_BUILD_TARGET=docker_tpm ${DOCKER_BUILD_ARGS}"
        BASE_DOCKER_NAME="$(basename $(pwd))_tpm"
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
        ;;
    *)
        echo "I don't know how to do a build for ${BUILD_TYPE}"
        exit 1
        ;;
esac


if [[ ! $TEST_BUILD ]]; then
    docker login -u="team-helium+buildkite" -p="${QUAY_BUILDKITE_PASSWORD}" ${REGISTRY_HOST}
fi

# update latest tag if github tag ends in `_GA`
# and don't do the rest of a build if non-miner build type
if [[ "$BUILD_TYPE" != "miner" && "$BUILDKITE_TAG" =~ _GA$ ]]; then

    echo "non-miner GA release detected: Updating latest tag on ${REGISTRY_HOST} for ${BUILD_TYPE}"

    docker tag helium:$DOCKER_NAME "$MINER_REGISTRY_NAME:$LATEST_TAG"
    docker push "$MINER_REGISTRY_NAME:$LATEST_TAG"

    exit $?
fi

docker build $DOCKER_BUILD_ARGS -t "helium:${DOCKER_NAME}" .
docker tag "helium:$DOCKER_NAME" "$MINER_REGISTRY_NAME:$DOCKER_NAME"
docker push "$MINER_REGISTRY_NAME:$DOCKER_NAME"

# if we're building miner and on a GA tag, push "latest" image tag too.
if [[ "$BUILDKITE_TAG" =~ _GA$ ]]; then

    echo "GA release detected: Pushing latest on ${REGISTRY_HOST} for $IMAGE_ARCH"

    docker tag helium:$DOCKER_NAME "$MINER_REGISTRY_NAME:$LATEST_TAG"
    docker push "$MINER_REGISTRY_NAME:$LATEST_TAG"

fi
