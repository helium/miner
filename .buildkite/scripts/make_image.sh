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

RUN_IMAGE="alpine:3.16"

if [[ "$IMAGE_ARCH" == "arm64" ]]; then
    BUILD_IMAGE="arm64v8/$BUILD_IMAGE"
    RUN_IMAGE="arm64v8/$RUN_IMAGE"
fi

VERSION=$(echo $VERSION_TAG | sed "s/^${BUILD_NET}_//" | sed "s/^${BUILD_TYPE}//")
DOCKER_BUILD_ARGS="--build-arg BUILDER_IMAGE=$BUILD_IMAGE --build-arg RUNNER_IMAGE=$RUN_IMAGE --build-arg VERSION=$VERSION --build-arg BUILD_NET=$BUILD_NET"

if [[ ! $TEST_BUILD -eq "0" ]]; then
    REGISTRY_NAME="test-builds"
    DOCKER_BUILD_ARGS="--build-arg REBAR_DIAGNOSTIC=1 $DOCKER_BUILD_ARGS"
fi
FULL_REGISTRY_NAME="$REGISTRY_HOST/$REGISTRY_ORG/$REGISTRY_NAME"

case "${BUILD_TYPE}-$BUILD_NET" in
    "validator-mainnet")
        echo "Doing a mainnet validator image build for $IMAGE_ARCH"
        DOCKER_BUILD_ARGS="-f Dockerfile-ubuntu --build-arg REBAR_BUILD_TARGET=docker_val $DOCKER_BUILD_ARGS"
        BASE_DOCKER_NAME="validator"
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
        ;;
    "validator-testnet")
        echo "Doing a testnet validator image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="-f Dockerfile-ubuntu --build-arg REBAR_BUILD_TARGET=docker_testval $DOCKER_BUILD_ARGS"
        BASE_DOCKER_NAME="validator"
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
        ;;
    "validator-devnet")
        echo "Doing a devnet validator image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="-f Dockerfile-ubuntu --build-arg REBAR_BUILD_TARGET=docker_testval $DOCKER_BUILD_ARGS"
        BASE_DOCKER_NAME="validator"
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
        ;;
    "miner-mainnet")
        echo "Doing a miner image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="--build-arg EXTRA_BUILD_APK_PACKAGES=apk-tools --build-arg EXTRA_RUNNER_APK_PACKAGES=apk-tools --build-arg REBAR_BUILD_TARGET=docker $DOCKER_BUILD_ARGS"
        BASE_DOCKER_NAME=$(basename $(pwd))
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
        ;;
    "miner-testnet")
        echo "Doing a testnet miner image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="--build-arg EXTRA_BUILD_APK_PACKAGES=apk-tools --build-arg EXTRA_RUNNER_APK_PACKAGES=apk-tools --build-arg REBAR_BUILD_TARGET=docker_testminer $DOCKER_BUILD_ARGS"
        BASE_DOCKER_NAME=$(basename $(pwd))
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
        ;;
    "miner-devnet")
        echo "Doing a devnet miner image build for ${IMAGE_ARCH}"
        DOCKER_BUILD_ARGS="--build-arg EXTRA_BUILD_APK_PACKAGES=apk-tools --build-arg EXTRA_RUNNER_APK_PACKAGES=apk-tools --build-arg REBAR_BUILD_TARGET=docker_testminer $DOCKER_BUILD_ARGS"
        BASE_DOCKER_NAME=$(basename $(pwd))
        DOCKER_NAME="${BASE_DOCKER_NAME}-${IMAGE_ARCH}_${VERSION}"
        ;;
    *)
        echo "I don't know how to build ${BUILD_TYPE}-$BUILD_NET"
        exit 1
        ;;
esac

if [[ ! $TEST_BUILD ]]; then
    docker login -u="${REGISTRY_ORG}+buildkite" -p="${QUAY_BUILDKITE_PASSWORD}" ${REGISTRY_HOST}
fi

if [[ "$BUILD_TYPE" == "miner" ]]; then
    UPDATE_TAG="none"
    # only update tag if github tag ends in `_GA|alpha|beta` and don't do the rest of a build
    # This syntax uses bash's built in regex matching evaluation stuff...
    if [[ "$VERSION_TAG" =~ _GA$ ]]; then
        UPDATE_TAG="latest"
    elif [[ "$VERSION_TAG" =~ _alpha$ ]]; then
        UPDATE_TAG="alpha"
    elif [[ "$VERSION_TAG" =~ _beta$ ]]; then
        UPDATE_TAG="beta"
    fi

    if [[ "$UPDATE_TAG" != "none" ]]; then
        echo "Miner tag update detected; Updating ${UPDATE_TAG} on ${REGISTRY_HOST}..."

        UPDATE_TAG="${UPDATE_TAG}-${IMAGE_ARCH}"
        SEMVER_TAG=$(echo "$DOCKER_NAME" | sed -e 's/_GA//' -e 's/_alpha//' -e 's/_beta//')

        docker pull "$FULL_REGISTRY_NAME:$SEMVER_TAG"
        docker tag "$FULL_REGISTRY_NAME:$SEMVER_TAG" "$FULL_REGISTRY_NAME:$UPDATE_TAG"
        docker push "$FULL_REGISTRY_NAME:$UPDATE_TAG"

        if [[ "$VERSION_TAG" =~ _GA$ ]]; then
            docker tag "$FULL_REGISTRY_NAME:$SEMVER_TAG" "$FULL_REGISTRY_NAME:$DOCKER_NAME"
            docker push "$FULL_REGISTRY_NAME:$DOCKER_NAME"
        fi

        exit $?
    fi
fi

docker build $DOCKER_BUILD_ARGS -t "helium:${DOCKER_NAME}" .
docker tag "helium:$DOCKER_NAME" "$FULL_REGISTRY_NAME:$DOCKER_NAME"
docker push "$FULL_REGISTRY_NAME:$DOCKER_NAME"

if [[ "$BUILD_NET" =~ (testnet|devnet) ]]; then
    LATEST_TAG="latest-$IMAGE_ARCH"
    docker tag "$FULL_REGISTRY_NAME:$DOCKER_NAME" "$FULL_REGISTRY_NAME:$LATEST_TAG"
    docker push "$FULL_REGISTRY_NAME:$LATEST_TAG"
fi
