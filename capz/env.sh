export AZURE_SUBSCRIPTION_ID="1c8c4edc-b188-4199-9580-3173033d75f7"
export AZURE_CLIENT_ID="aa0caef4-31da-4426-9908-f75af27075c8"
export AZURE_CLIENT_SECRET="" 
export AZURE_TENANT_ID="72f988bf-86f1-41af-91ab-2d7cd011db47"
export AZURE_LOCATION=eastus 
export AZURE_CONTROL_PLANE_MACHINE_TYPE=Standard_D2s_v3
export AZURE_NODE_MACHINE_TYPE=Standard_D2s_v3
export WINDOWS_SERVER_VERSION=windows-2022
export KUBERNETES_VERSION=latest-1.27
export CONFORMANCE_WORKER_MACHINE_COUNT=3
export WINDOWS_WORKER_MACHINE_COUNT=3
export WINDOWS=true
export AZURE_SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_rsa.pub"
export CAPZ_DIR="$HOME/cluster-api-provider-azure"
export RESOURCE_GROUP="containerrolling-capz"
export CLUSTER_NAME="containerrolling-capz"
#export SKIP_TEST=true

# Normaly, we will not clean up the cluster when scripts exists.
# The old cluster will be deleted when a new host image is available.
export SKIP_CLEANUP=true
#export SKIP_LOG_COLLECTION=true

export MI_RESOURCE_GROUP="containerRolling"
export MANAGEDIDENTITY_ID="containerRollingMI"
export MANAGEDIDENTITY_RESOURCE_ID="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourcegroups/$MI_RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$MANAGEDIDENTITY_ID"
export GALLERY_NAME="windowsservercore"
export GALLERY_IMAGE_NAME="imagedef-rs_sparc_ctr_v1"
export GALLERY_IMAGE_VERSION="25996.1000.231110"

