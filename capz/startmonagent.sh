#!/bin/bash

# This shell script demonstrates how to start monagnet on custoerm's cluster inside a hpc pod
#

source env.sh

hostprocessdaemonset=hpc
# Need to login first
#az login
#az account set --subscription $subscription

# Retrieve the credentials of existing cluster
#az aks get-credentials --resource-group $resourcegroup --name $clustername --overwrite-existing

# Deploy the monagent hpc container and start the monagnet process
#az aks update -n ${clustername} -g $resourcegroup --attach-acr $registryname

sed -e "s,\$managedidentityresourceid,$MANAGEDIDENTITY_RESOURCE_ID," \
    -e "s/\$subscription/$AZURE_SUBSCRIPTION_ID/" \
    -e "s/\$resourcegroup/$RESOURCE_GROUP/" \
    -e "s/\$clustername/$CLUSTER_NAME/" \
    -e 's/\r//g' \
    ./${hostprocessdaemonset}.yaml.template > ${hostprocessdaemonset}.yaml

#kubectl apply -f ./${hostprocessdaemonset}.yaml --wait

#kubectl wait --for=condition=Ready --all --timeout -1s daemonsets

#kubectl get daemonsets -o wide
