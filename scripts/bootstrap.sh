#!/bin/bash
aws sts get-caller-identity &&
curl -o kubectl https://amazon-eks.s3.us-west-2.amazonaws.com/1.16.8/2020-04-16/bin/linux/amd64/kubectl &&
chmod +x ./kubectl &&
mkdir -p $HOME/bin && cp ./kubectl $HOME/bin/kubectl && export PATH=$PATH:$HOME/bin &&
kubectl version --short --client &&
IP_ADDRESS=$(kubectl get pod vault-0 -o=jsonpath={.status.podIP}) &&
SECRETS=$(kubectl exec vault-0 -- "vault operator init")

now join all the nodes
RESULT=$(kubectl exec vault-1 -- "vault operator raft join")

sleep 10
