export KEYVAULT_NAME="containerrollingKV"
export CAPZ_STORAGE_URL_NAME="capzstoragesasurl"
export AZURE_SSH_PUBLIC_KEY_NAME="sshpublickey"
export AZURE_SSH_PRIVATE_KEY_NAME="sshprivatekey"
export AZURE_CLIENT_SECRET_NAME="aadappkey"

export AZURE_SUBSCRIPTION_ID="1c8c4edc-b188-4199-9580-3173033d75f7"
export AZURE_CLIENT_ID="aa0caef4-31da-4426-9908-f75af27075c8"
export AZURE_TENANT_ID="72f988bf-86f1-41af-91ab-2d7cd011db47"
export AZURE_LOCATION=eastus 
export AZURE_CONTROL_PLANE_MACHINE_TYPE=Standard_D2s_v3
export AZURE_NODE_MACHINE_TYPE=Standard_D2s_v3
export WINDOWS_SERVER_VERSION=windows-2022
export KUBERNETES_VERSION=latest-1.29
export CONFORMANCE_WORKER_MACHINE_COUNT=3
export WINDOWS_WORKER_MACHINE_COUNT=3
export WINDOWS=true
export AZURE_SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_rsa.pub"
export AZURE_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_rsa"
export CAPZ_DIR="$HOME/cluster-api-provider-azure"
export CAPZ_RESOURCE_GROUP="containerrolling-capz"
export CLUSTER_NAME="containerrolling-capz"
#export SKIP_TEST=true

# Normaly, we will not clean up the cluster when scripts exists.
# The old cluster will be deleted when a new host image is available.
export SKIP_CLEANUP=true
export SKIP_LOG_COLLECTION=true

export RESOURCE_GROUP="wcct-agentbaker-test"
export MANAGEDIDENTITY_ID="wcct-agentbaker-identity"
export MANAGEDIDENTITY_RESOURCE_ID="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$MANAGEDIDENTITY_ID"
export GALLERY_NAME="aks"
export GALLERY_IMAGE_NAME="windows-2025-containerd"
export GALLERY_IMAGE_VERSION=26003.1000.231121


