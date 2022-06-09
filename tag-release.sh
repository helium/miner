#!/bin/bash

set -e

usage() {
    echo "Usage: $0 [-h] [-n <NAMED_TAG>] <SHA>"
}

dep_hash() {
    local MINER=$1
    local DEP=$2

    git show "${MINER}:rebar.lock" | grep -A2 "${DEP}" | sed -e "s/.*\"\(.*\)\".*/\1/" | tr '\n' ' ' | awk '{print $3}'
}

strip_zeros() {
    local VZN=$(echo $1 | sed -e 's/0//g')

    if [[ $VZN == "" ]]; then
        echo "0"
    else
        echo $VZN
    fi
}

val_tag() {
    local VAL_VERSION
    local MAJ
    local MIN
    local PATCH

    VAL_VERSION=$(sed -n "/^version() ->$/,/\.$/p" src/miner.erl | grep -o -E '[0-9]{10}')
    MAJ=$(echo $VAL_VERSION | awk '{print substr( $0, 1, 3 )}')
    MIN=$(echo $VAL_VERSION | awk '{print substr( $0, 4, 3 )}')
    PATCH=$(echo $VAL_VERSION | awk '{print substr( $0, 7, 4 )}')

    echo "validator$(strip_zeros $MAJ).$(strip_zeros $MIN).$(strip_zeros $PATCH)"
}

declare -r repos="blockchain libp2p sibyl ecc508 relcast dkg hbbft helium_proto"
declare NAMED_TAG

TAG_NAME=$(date +%Y.%m.%d)
TAG_NUMBER=0

while getopts ":hn:" opt; do
    case ${opt} in
        h )
            usage
            exit 0
            ;;
        n )
            NAMED_TAG=$OPTARG
            ;;
        \? )
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

if [ $# -ne 1 ]; then
    usage
    exit 1
fi

MINER_HASH=$1

if [[ ! -z $NAMED_TAG ]]; then
    VAL_VERSION_TO_TAG=$(val_tag)
    if [[ ! $VAL_VERSION_TO_TAG == $NAMED_TAG ]]; then
        echo "tag doesnt match committed version; should be ${VAL_VERSION_TO_TAG} per miner.erl!"
        exit 1
    fi
    RELEASE_TAG=$NAMED_TAG
else
    while git tag -l | grep -q "${TAG_NAME}.${TAG_NUMBER}"; do
        TAG_NUMBER=`expr $TAG_NUMBER + 1`
    done
    RELEASE_TAG=${TAG_NAME}.${TAG_NUMBER}
fi

if [ ! -d .repos ]; then
    mkdir .repos
fi

cd .repos

echo "updating repos"
for repo in $repos; do
    case $repo in
        "blockchain")
            realname="blockchain-core"
            ;;
        "helium_proto")
            realname="proto"
            ;;
        "libp2p")
            realname="erlang-libp2p"
            ;;
        "hbbft")
            realname="erlang-hbbft"
            ;;
        "dkg")
            realname="erlang-dkg"
            ;;
        *)
            realname=$repo
            ;;
    esac
    if [ ! -d $repo ]; then
        git clone -q git@github.com:helium/$realname.git $repo
    else
        $(cd $repo && git fetch -q origin)
    fi
done
cd ..
echo -e "done\n"

echo -e "publishing ${RELEASE_TAG} tag\n"
git tag -a ${RELEASE_TAG} ${MINER_HASH} -m "${RELEASE_TAG} release"
git push origin "${RELEASE_TAG}"

for repo in $repos; do
    REPO_HASH=$(dep_hash $MINER_HASH $repo)

    cd .repos/$repo
    TAG_REF=$(git show-ref ${RELEASE_TAG} | awk '{print $1}')
    if [[ -z $TAG_REF ]]; then
        echo -e "tagging ${repo} ${REPO_HASH}\n"
        git tag -a ${RELEASE_TAG} ${REPO_HASH} -m "${RELEASE_TAG} miner release"
        git push origin "${RELEASE_TAG}"
    elif [[ $TAG_REF == $REPO_HASH ]]; then
        echo -e "tag already present on ${repo} at desired hash ${REPO_HASH}\n"
    else
        echo -e "tag already present on ${repo} at another hash ${TAG_REF}; skipping"
    fi
    cd ../../
done
