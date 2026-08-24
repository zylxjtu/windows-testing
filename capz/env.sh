    export KUBERNETES_VERSION="latest-1.35"
    export CONTROL_PLANE_MACHINE_COUNT="1"
    export WINDOWS_WORKER_MACHINE_COUNT="2"
    export WINDOWS_SERVER_VERSION="windows-2025"
    export WINDOWS_CONTAINERD_URL="https://wcctagentbakerstorage.blob.core.windows.net/arm64/containerd-2.3.3-windows-arm64.tar.gz"
    export WINDOWS_HPC_ARCH="arm64"
    export WINDOWS_HPC_BASE_IMAGE="wcctpublic.azurecr.io/windows-host-process-containers-base-image:v2.0.0-arm64"
    # Publish kubeadm.exe, kubectl.exe, kubelet.exe, and kube-proxy.exe for the
    # selected Kubernetes version to this directory before running the test.
    export WINDOWS_KUBERNETES_BIN_URL="https://wcctagentbakerstorage.blob.core.windows.net/arm64"
    export WINDOWS_KUBE_PROXY_IMAGE="wcctpublic.azurecr.io/kube-proxy:windows-arm64"
    export WINDOWS_GALLERY_SUBSCRIPTION_ID="1c8c4edc-b188-4199-9580-3173033d75f7"
    export WINDOWS_GALLERY_RESOURCE_GROUP="yuanliang_Arm64_scus"
    export WINDOWS_GALLERY_NAME="Arm64ImageGallery_private"
    export WINDOWS_GALLERY_IMAGE_NAME="yuanliangtest"
    export WINDOWS_GALLERY_IMAGE_VERSION="0.3.1787349176"

    # the following are the base ARM image used to create the capz image
    # export WINDOWS_GALLERY_RESOURCE_GROUP="yuanliangARM64"
    # export WINDOWS_GALLERY_NAME="yuanliangARM64Gallery"
    # export WINDOWS_GALLERY_IMAGE_NAME="Windows2025Arm64"
    # export WINDOWS_GALLERY_IMAGE_VERSION="1.0.0"
    
    export AZURE_NODE_MACHINE_TYPE="Standard_D4ps_v6"
    export GMSA="" 
    export HYPERV=""
    export KPNG=""
    export CALICO_VERSION="v3.31.0"
    export CALICO_WINDOWS_NODE_IMAGE="${CALICO_WINDOWS_NODE_IMAGE:-wcctpublic.azurecr.io/calico/node-windows:v0.0.0-arm64-test}"
    export CALICO_WINDOWS_CNI_IMAGE="${CALICO_WINDOWS_CNI_IMAGE:-wcctpublic.azurecr.io/calico/cni-windows:v0.0.0-arm64-test}"
    export TEMPLATE="windows-ci.yaml"
    export CAPI_VERSION="v1.12.2"
    export HELM_VERSION=v3.15.2
    export TOOLS_BIN_DIR="${SCRIPT_ROOT}/tools/bin"

    # other config
    export ARTIFACTS="${PWD}/_artifacts"
    export CLUSTER_NAME="wcct2-arm64"
    export IMAGE_SKU="${WINDOWS_SERVER_VERSION:=windows-2025}-containerd-gen1"

    export AZURE_SUBSCRIPTION_ID="1c8c4edc-b188-4199-9580-3173033d75f7"
    # client id will be used by https://github.com/kubernetes-sigs/cloud-provider-azure/blob/c86a3cb7a4f4b96af235486ef22449470c6a933c/hack/deploy-workload-cluster.sh#L29
    export AZURE_CLIENT_ID="aa0caef4-31da-4426-9908-f75af27075c8"
    export AZURE_TENANT_ID="72f988bf-86f1-41af-91ab-2d7cd011db47"
    export AZURE_LOCATION="westus2"

    # worth to sync to latest if local creation of cluster is failing
    export AZURE_CLOUD_PROVIDER_ROOT="${HOME}/git/cloud-provider-azure"
    export CAPZ_DIR="${HOME}/git/cluster-api-provider-azure"

    export SKIP_CREATE=false
    export SKIP_TEST=false
    export SKIP_CLEANUP=true
    export SKIP_LOG_COLLECTION=true

    # use by CAPZ
    export AZURE_STORAGE_ACCOUNT="wcctagentbakerstorage"
    export REGISTRY="wcctpublic.azurecr.io"

    export NODE_FEATURE_GATES="WindowsGracefulNodeShutdown=true"


    export AKS_NODE_VM_SIZE="Standard_D2s_v5"



