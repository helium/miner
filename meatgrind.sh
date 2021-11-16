#!/bin/bash
N=8
N2=$(( $N * 2))
while true; do
    #RAND=`date +%N|sed s/...$//`
    RAND=$RANDOM
    ## sleep up to 20 seconds
    sleep "$(( $RAND % 20))"
    export I=$(expr $RAND % $N2 + 1)
    ## 50 percent chance of stopping
    ## 50 percent chance of kill -9
    if [ $I -lt 9 ]; then
        ./cmd.sh $I stop
    else
        export I=$(( $I - $N))
        if [ "$(./cmd.sh $I ping)" = "pong" ]; then
            MURDERPID=$(./cmd.sh $I eval 'list_to_integer(os:getpid()).')
            kill -9 $MURDERPID
        fi
    fi
    while [ "$(./cmd.sh $I ping)" = "pong" ]; do
        sleep 1
    done
    ## 80% chance of restarting things
    if [ $(expr $RAND % 5) -ne 0 ]; then
        ./cmd.sh $I start
    fi
done
