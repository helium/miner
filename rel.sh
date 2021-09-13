#!/bin/bash

usage() {
    echo "Usage: $0 [-h] <start SHA> <end SHA>"
}

all=false

while getopts ":ha" opt; do
    case ${opt} in
        a )
            all=true
            ;;
        h )
            usage
            exit 0
            ;;
        \? )
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

if [ $# -ne 2 ]; then
    usage
    exit 1
fi

if [ $all = false ]; then
    git_merges="--merges"
    git_format=""
else
    git_merges=""
    git_format="%H "
fi

start=$1
end=$2

base=$(pwd)
if [ ! -d .repos ]; then
    mkdir .repos
fi

cd .repos

echo -n "updating repos... "
for repo in blockchain libp2p sibyl ecc508 relcast dkg hbbft helium_proto; do
    case $repo in
        "helium_proto")
            realname="proto"
            ;;
        "blockchain")
            realname="blockchain-core"
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
        cd $repo
        git fetch -q origin
        cd ..
    fi
done
cd ..

echo done
echo

## grab commit hashes and headlines
echo "miner changes:"
git log $git_merges --pretty=format:"${git_format}%s" ${start}...${end}
echo

from=$(git rev-list -n 1 ${start})
to=$(git rev-list -n 1 ${end})

## if a commit just bumps a dep like miner or gateway config, ignore
## the actual message and replace it with the same sort of thing from
## the dep
for subdep in blockchain libp2p sibyl ecc508 relcast dkg hbbft helium_proto; do
    subfrom=$(git diff ${from} ${to} rebar.lock | grep -A4 "\"$subdep\"" | grep "^\- " | \
                  grep "{ref," | sed -e "s/.*\"\(.*\)\".*/\1/" )
    subto=$(git diff ${from} ${to} rebar.lock | grep -A4 "\"$subdep\"" | grep "^\+ " | \
                grep "{ref," | sed -e "s/.*\"\(.*\)\".*/\1/" )
    if [ -z "${subfrom}" ]; then
        no_changes="$no_changes $subdep"
    else
        echo $subdep from $subfrom to $subto
        subhere=$(pwd)
        cd $base/.repos/$subdep/;
        git log $git_merges --pretty=format:"${git_format}%s" ${subfrom}...${subto};
        echo
        cd $subhere
    fi
done

echo "no changes for:$no_changes"
