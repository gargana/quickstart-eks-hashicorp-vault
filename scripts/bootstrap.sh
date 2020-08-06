#!/bin/bash
VAULT_NUMBER_OF_KEYS_FOR_UNSEAL=3
VAULT_NUMBER_OF_KEYS=5
SLEEP_SECONDS=90

get_secret () {
    local value=$(aws secretsmanager --region ${AWS_REGION} get-secret-value --secret-id "$1" | jq --raw-output .SecretString)
    echo $value
}

# Install JQ as we use it later on
yum install -y jq >&1 >/dev/null

# Give the Helm chart a chance to get started
echo "Sleeping for ${SLEEP_SECONDS} seconds"
sleep ${SLEEP_SECONDS} # Allow helm chart some time 

# Test that we can auth as expected
aws sts get-caller-identity

# Install Kubernetes cli
curl -o kubectl https://amazon-eks.s3.us-west-2.amazonaws.com/1.16.8/2020-04-16/bin/linux/amd64/kubectl
chmod +x ./kubectl
mkdir -p $HOME/bin && cp ./kubectl $HOME/bin/kubectl && export PATH=$PATH:$HOME/bin
kubectl version --short --client 

while true; do
  IP_ADDRESS=$(kubectl get pods vault-${RELEASE_NAME}-0 -o jsonpath={.status.podIP})
  if [ "${IP_ADDRESS}X" == "X" ]
  then
    sleep 1
  else
    break
  fi
done

until curl -fs -o /dev/null ${IP_ADDRESS}:8200/v1/sys/init; do
    echo "Waiting for Vault to start..."
    sleep 1
done

# See if vault is initialized
init=$(kubectl exec -t vault-${RELEASE_NAME}-0 -- vault operator init -status)

echo "Is vault initialized: '${init}'"

if [ "$init" != "Vault is initialized" ]; then
    echo "Initializing Vault"
    SECRET_VALUE=$(kubectl exec vault-${RELEASE_NAME}-0 -- vault operator init -recovery-shares=${VAULT_NUMBER_OF_KEYS} -recovery-threshold=${VAULT_NUMBER_OF_KEYS_FOR_UNSEAL})
    echo "storing vault init values in secrets manager"
    aws secretsmanager put-secret-value --region ${AWS_REGION} --secret-id ${VAULT_SECRET} --secret-string "${SECRET_VALUE}"
else
    echo "Vault is already initialized"
fi

sealed=$(curl -fs ${IP_ADDRESS}:8200/v1/sys/seal-status | jq -r .sealed)

# Should Auto unseal using KMS but this is for demonstration for manual unseal
if [ "$sealed" == "true" ]; then
    VAULT_SECRET_VALUE=$(get_secret ${VAULT_SECRET})
    root_token=$(echo ${VAULT_SECRET_VALUE} | awk '{ if (match($0,/Initial Root Token: (.*)/,m)) print m[1] }' | cut -d " " -f 1)
    for UNSEAL_KEY_INDEX in {1..${VAULT_NUMBER_OF_KEYS_FOR_UNSEAL}}
    do
            unseal_key+=($(echo ${VAULT_SECRET_VALUE} | awk '{ if (match($0,/Recovery Key '${UNSEAL_KEY_INDEX}': (.*)/,m)) print m[1] }'| cut -d " " -f 1))
    done

    echo "Unsealing Vault"
    # Handle variable number of unseal keys
    for UNSEAL_KEY_INDEX in {1..${VAULT_NUMBER_OF_KEYS_FOR_UNSEAL}}
    do
        kubectl exec vault-${RELEASE_NAME}-0 -- vault operator unseal $unseal_key[${UNSEAL_KEY_INDEX}]
    done
else
    echo "Vault is already unsealed"
fi

VAULT_SECRET_VALUE=$(get_secret ${VAULT_SECRET})
root_token=$(echo ${VAULT_SECRET_VALUE} | awk '{ if (match($0,/Initial Root Token: (.*)/,m)) print m[1] }' | cut -d " " -f 1)

# Show who we have joined
kubectl exec vault-${RELEASE_NAME}-0 -- vault login token=$root_token 2>&1 > /dev/null  # Hide this output from the console

# Join other pods to the raft cluster
kubectl exec -t vault-${RELEASE_NAME}-1 -- vault operator raft join http://vault-${RELEASE_NAME}-0.vault-${RELEASE_NAME}-internal:8200

kubectl exec -t vault-${RELEASE_NAME}-2 -- vault operator raft join http://vault-${RELEASE_NAME}-0.vault-${RELEASE_NAME}-internal:8200

# Show who we have joined
kubectl exec -t vault-${RELEASE_NAME}-0 -- vault operator raft list-peers
# If we see 3 raft peers we have succeeded.