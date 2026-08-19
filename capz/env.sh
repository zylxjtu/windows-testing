    export KUBERNETES_VERSION="latest-1.35"
    export CONTROL_PLANE_MACHINE_COUNT="1"
    export WINDOWS_WORKER_MACHINE_COUNT="2"
    export WINDOWS_SERVER_VERSION="windows-2025"
    export WINDOWS_CONTAINERD_URL="https://wcctagentbakerstorage.blob.core.windows.net/arm64/containerd-2.3.3-windows-arm64.tar.gz"
    export WINDOWS_HPC_ARCH="arm64"
    export WINDOWS_HPC_BASE_IMAGE="wcctpublic.azurecr.io/windows-host-process-containers-base-image:v2.0.0-arm64"
    export GMSA="" 
    export HYPERV=""
    export KPNG=""
    export CALICO_VERSION="v3.31.0"
    export TEMPLATE="windows-ci.yaml"
    export CAPI_VERSION="v1.12.2"
    export HELM_VERSION=v3.15.2
    export TOOLS_BIN_DIR="${SCRIPT_ROOT}/tools/bin"

    # other config
    export ARTIFACTS="${PWD}/_artifacts"
    export CLUSTER_NAME="wcct-capz2026"
    export IMAGE_SKU="${WINDOWS_SERVER_VERSION:=windows-2025}-containerd-gen1"

    export AZURE_SUBSCRIPTION_ID="1c8c4edc-b188-4199-9580-3173033d75f7"
    # client id will be used by https://github.com/kubernetes-sigs/cloud-provider-azure/blob/c86a3cb7a4f4b96af235486ef22449470c6a933c/hack/deploy-workload-cluster.sh#L29
    export AZURE_CLIENT_ID="aa0caef4-31da-4426-9908-f75af27075c8"
    export AZURE_TENANT_ID="72f988bf-86f1-41af-91ab-2d7cd011db47"
    export AZURE_LOCATION="uksouth"

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



