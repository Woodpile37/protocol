#!/usr/bin/env bash

# The type of oracle system to set up contracts for, for example "beacon-l1" or "beacon-l2". Default is "dvm".
ORACLE_TYPE=$1
if [ ! "$ORACLE_TYPE" ]; 
then 
    echo "Must specify the type of oracle system to set up, like 'beacon-l1'"
    exit 1
fi
NETWORK_NAME=$2
if [ ! "$NETWORK_NAME" ]; 
then 
    echo "Must specify network name"
    exit 1
fi

if [ "$ORACLE_TYPE" == "beacon-l2" ]
then 
    yarn hardhat setup-finder --registry --bridge --generichandler --network $NETWORK_NAME
elif [ "$ORACLE_TYPE" == "beacon-l1" ]
then
    yarn hardhat setup-finder --registry --bridge --generichandler --identifierwhitelist --mockoracle --network $NETWORK_NAME
else
    echo "unimplemented"
fi