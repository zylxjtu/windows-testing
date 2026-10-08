#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o functrace

SCRIPT_PATH=$(realpath "${BASH_SOURCE[0]}")
SCRIPT_ROOT=$(dirname "${SCRIPT_PATH}")
export MANAGEMENT_KUBECONFIG="${SCRIPT_ROOT}/management.kubeconfig"
export CAPZ_DIR="${CAPZ_DIR:-"${GOPATH}/src/sigs.k8s.io/cluster-api-provider-azure"}"
: "${CAPZ_DIR:?Environment variable empty or not defined.}"
if [[ ! -d $CAPZ_DIR ]]; then
    echo "Must have capz repo present"
fi
export AZURE_CLOUD_PROVIDER_ROOT="${AZURE_CLOUD_PROVIDER_ROOT:-"${GOPATH}/src/sigs.k8s.io/cloud-provider-azure"}"
: "${AZURE_CLOUD_PROVIDER_ROOT:?Environment variable empty or not defined.}"
if [[ ! -d $AZURE_CLOUD_PROVIDER_ROOT ]]; then
    echo "Must have azure cloud provider repo present"
fi

main() {
    local -a post_command=("$@")

    export NETWORK_PLUGIN="${NETWORK_PLUGIN:-"calico"}"
    case "${NETWORK_PLUGIN}" in
        calico|azure-cni) ;;
        *) fail_validation "unsupported NETWORK_PLUGIN=${NETWORK_PLUGIN}; supported values are calico and azure-cni" ;;
    esac
    local template_override="${TEMPLATE:-}"
    if [[ "${NETWORK_PLUGIN}" == "azure-cni" ]]; then
        # Azure CNI is validated on Windows Server 2022 first.
        export WINDOWS_SERVER_VERSION="${WINDOWS_SERVER_VERSION:-"windows-2022"}"
    fi

    # defaults
    export KUBERNETES_VERSION="${KUBERNETES_VERSION:-"latest"}"
    export CONTROL_PLANE_MACHINE_COUNT="${AZURE_CONTROL_PLANE_MACHINE_COUNT:-"1"}"
    export WINDOWS_WORKER_MACHINE_COUNT="${WINDOWS_WORKER_MACHINE_COUNT:-"2"}"
    export WINDOWS_SERVER_VERSION="${WINDOWS_SERVER_VERSION:-"windows-2019"}"
    export WINDOWS_CONTAINERD_URL="${WINDOWS_CONTAINERD_URL:-"https://github.com/containerd/containerd/releases/download/v2.3.5/containerd-2.3.5-windows-amd64.tar.gz"}"
    export GMSA="${GMSA:-""}" 
    export HYPERV="${HYPERV:-""}"
    # Override kubelet maxPods (e.g. Hyper-V Prow jobs set MAX_PODS=20).
    export MAX_PODS="${MAX_PODS:-}"

    export KPNG="${WINDOWS_KPNG:-""}"
    export CALICO_VERSION="${CALICO_VERSION:-"v3.31.0"}"
    export TEMPLATE="${TEMPLATE:-"windows-ci.yaml"}"
    export CAPI_VERSION="${CAPI_VERSION:-"v1.12.2"}"
    export HELM_VERSION=v3.15.2
    export TOOLS_BIN_DIR="${TOOLS_BIN_DIR:-$SCRIPT_ROOT/tools/bin}"
    export CONTAINERD_LOGGER="${CONTAINERD_LOGGER:-""}"

    # other config
    export ARTIFACTS="${ARTIFACTS:-${PWD}/_artifacts}"
    export CLUSTER_NAME="${CLUSTER_NAME:-capz-conf-$(head /dev/urandom | LC_ALL=C tr -dc a-z0-9 | head -c 6 ; echo '')}"
    export IMAGE_SKU="${IMAGE_SKU:-"${WINDOWS_SERVER_VERSION:=windows-2019}-containerd-gen1"}"
    export GALLERY_IMAGE_NAME="${GALLERY_IMAGE_NAME:-"${WINDOWS_SERVER_VERSION//windows/capi-win}-containerd"}"
    
    # CI is an environment variable set by a prow job: https://github.com/kubernetes/test-infra/blob/master/prow/jobs.md#job-environment-variables
    export CI="${CI:-""}"

    if [[ "${NETWORK_PLUGIN}" == "azure-cni" ]]; then
        set_azure_cni_defaults
        validate_azure_cni_configuration "${template_override}"
    fi

    set_azure_envs

    mkdir -p "${ARTIFACTS}"
    set_ci_version
    IS_PRESUBMIT="$(capz::util::should_build_kubernetes)"
    echo "IS_PRESUBMIT=$IS_PRESUBMIT"
    if [[ "${IS_PRESUBMIT}" == "true" ]]; then
        "${CAPZ_DIR}/scripts/ci-build-kubernetes.sh";
        trap run_capz_e2e_cleanup EXIT # reset the EXIT trap since ci-build-kubernetes.sh also sets it.
    fi
    if [[ "${GMSA}" == "true" ]]; then create_gmsa_domain; fi

    install_tools
    prepare_cloud_provider_azure
    create_cluster
    export_workload_cluster_resource_group
    apply_workload_configuration
    apply_cloud_provider_azure
    wait_for_nodes
    if [[ "${NETWORK_PLUGIN}" == "azure-cni" ]]; then
        # Nodes become Ready only after the CNI conflist exists, so the installers have run by now.
        wait_for_azure_cni_installers
        apply_windows_kube_proxy
    fi
    ensure_cloud_provider_taint_on_windows_nodes
    wait_for_windows_machinedeployment
    if [[ "${NETWORK_PLUGIN}" == "azure-cni" ]]; then validate_azure_cni_smoke; fi
    if [[ ${#post_command[@]} -gt 0 ]]; then
        local exit_code
        log "post command detected; skipping default e2e tests"
        run_post_command "${post_command[@]}"
        exit_code=$?
        return ${exit_code}
    fi

    apply_hpc_webhook
    if [[ "${HYPERV}" == "true" ]]; then apply_hyperv_configuration; fi
    run_e2e_test
}

install_tools(){
    CURL_RETRIES=3
    mkdir -p "$TOOLS_BIN_DIR"
    if [[ -z "$(command -v "$TOOLS_BIN_DIR"/helm)" ]]; then
        log "install helm"
        curl --retry "$CURL_RETRIES" -L https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$TOOLS_BIN_DIR"/get_helm.sh
        chmod +x "$TOOLS_BIN_DIR"/get_helm.sh
        PATH="$PATH:$TOOLS_BIN_DIR"
        USE_SUDO=false HELM_INSTALL_DIR="$TOOLS_BIN_DIR" DESIRED_VERSION="$HELM_VERSION" BINARY_NAME=helm "$TOOLS_BIN_DIR"/get_helm.sh
    fi

    if [[ -z "$(command -v "$TOOLS_BIN_DIR"/clusterctl)" ]]; then
        log "install clusterctl"
        curl --retry "$CURL_RETRIES" -L https://github.com/kubernetes-sigs/cluster-api/releases/download/"$CAPI_VERSION"/clusterctl-linux-amd64 -o "$TOOLS_BIN_DIR"/clusterctl
        chmod +x "$TOOLS_BIN_DIR"/clusterctl
    fi
}

create_gmsa_domain(){
    log "running gmsa setup"

    export CI_RG="${CI_RG:-capz-ci}"
    export GMSA_ID="${RANDOM}"
    export GMSA_NODE_RG="gmsa-dc-${GMSA_ID}"
    export GMSA_KEYVAULT_URL="https://${GMSA_KEYVAULT:-$CI_RG-gmsa-community}.vault.azure.net"

    log "setting up domain vm in $GMSA_NODE_RG with keyvault $CI_RG-gmsa-community"
    "${SCRIPT_ROOT}/gmsa/ci-gmsa.sh"

    # export the ip Address so it can be used in e2e test
    vmname="dc-${GMSA_ID}"
    vmip=$(az vm list-ip-addresses -n ${vmname} -g $GMSA_NODE_RG --query "[?virtualMachine.name=='$vmname'].virtualMachine.network.privateIpAddresses" -o tsv)
    export GMSA_DNS_IP=$vmip
}

run_capz_e2e_cleanup() {
    log "cleaning up"

    
    if command -v capz::ci-build-azure-ccm::cleanup &> /dev/null; then
        capz::ci-build-azure-ccm::cleanup || true
    fi

    if [[ "$(capz::util::should_build_kubernetes)" == "true" ]]; then
        capz::ci-build-kubernetes::cleanup || true
    fi

    if [[ "${NETWORK_PLUGIN:-}" == "azure-cni" && ! "${SKIP_LOG_COLLECTION:-"false"}" == "true" ]]; then
        collect_azure_cni_diagnostics || true
    fi

    kubectl get nodes -owide

    # currently KUBECONFIG is set to the workload cluster so reset to the management cluster
    unset KUBECONFIG
    if [[ -f "${MANAGEMENT_KUBECONFIG}" ]]; then
        export KUBECONFIG="${MANAGEMENT_KUBECONFIG}"
    fi

    SKIP_LOG_COLLECTION="${SKIP_LOG_COLLECTION:-"false"}"
    if [[ ! "$SKIP_LOG_COLLECTION" == "true" ]]; then
        log "collecting logs"
        pushd "${CAPZ_DIR}"

        # there is an issue in ci with the go client conflicting with the kubectl client failing to get logs for 
        # control plane node.  This is a mitigation being tried 
        rm -rf "$HOME/.kube/cache/"
        # don't stop on errors here, so we always cleanup
        go run -tags e2e "${CAPZ_DIR}/test/logger.go" --name "${CLUSTER_NAME}" --namespace default --artifacts-folder "${ARTIFACTS}" || true
        popd

        "${CAPZ_DIR}/hack/log/redact.sh" || true
    else
        log "skipping log collection"
    fi

    SKIP_CLEANUP="${SKIP_CLEANUP:-"false"}"
    if [[ ! "$SKIP_CLEANUP" == "true" ]]; then
        log "removing role assignment if the RG is not locked"
        if ! az lock list --resource-group "$CLUSTER_NAME" --output json | jq -e '.[] | select(.level == "CanNotDelete")' > /dev/null; then
            az role assignment delete --ids "$assignmentId" || true
        fi

        log "deleting cluster"
        az group delete --name "$CLUSTER_NAME" --no-wait -y --force-deletion-types=Microsoft.Compute/virtualMachines --force-deletion-types=Microsoft.Compute/virtualMachineScaleSets || true

        # clean up GMSA NODE RG
        if [[ -n ${GMSA:-} ]]; then
            echo "Cleaning up gMSA resources $GMSA_NODE_RG with keyvault $GMSA_KEYVAULT_URL"
            az keyvault secret list --vault-name "${GMSA_KEYVAULT:-$CI_RG-gmsa-community}" --query "[? contains(name, '${GMSA_ID}')].name" -o tsv | while read -r secret ; do
                az keyvault secret delete -n "$secret" --vault-name "${GMSA_KEYVAULT:-$CI_RG-gmsa-community}"
            done

            az group delete --name "$GMSA_NODE_RG" --no-wait -y --force-deletion-types=Microsoft.Compute/virtualMachines --force-deletion-types=Microsoft.Compute/virtualMachineScaleSets || true
        fi
    else
        log "skipping clean up"
    fi
}

create_cluster(){
    export SKIP_CREATE="${SKIP_CREATE:-"false"}"
    if [[ ! "$SKIP_CREATE" == "true" ]]; then
        # create cluster
        log "starting to create cluster"

        # TODO remove once 1.29 is EOL
        if [[ "${KUBERNETES_VERSION}" =~ ^v1\.29 ]]; then
            template_root="$SCRIPT_ROOT"/templates/1.29
        else
            template_root="$SCRIPT_ROOT"/templates
        fi
       
        # select correct template
        template="$template_root"/"$TEMPLATE"
        if [[ "${NETWORK_PLUGIN}" == "azure-cni" ]]; then
            if [[ "${IS_PRESUBMIT}" == "true" ]]; then
                template="$SCRIPT_ROOT"/templates/windows-azure-cni-pr.yaml
            else
                template="$SCRIPT_ROOT"/templates/windows-azure-cni-ci.yaml
            fi
        elif [[ "${IS_PRESUBMIT}" == "true" ]]; then
            template="$template_root"/windows-pr.yaml;
        fi
        if [[ "${GMSA}" == "true" ]]; then
            if [[ "${IS_PRESUBMIT}" == "true" ]]; then
                template="$SCRIPT_ROOT"/templates/gmsa-pr.yaml;
            else
                template="$SCRIPT_ROOT"/templates/gmsa-ci.yaml
            fi
        fi
        echo "Using $template"

        # Resolve the AKS management cluster Kubernetes version.
        # Hard-pinning this (previously --kubernetes-version 1.33.5) breaks CI every
        # time AKS retires an old minor version. Set MGMT_K8S_VERSION to pin explicitly,
        # otherwise use the region's current default GA version, falling back to the
        # highest available version.
        if [[ -z "${MGMT_K8S_VERSION:-}" ]]; then
            MGMT_K8S_VERSION=$(az aks get-versions --location "$AZURE_LOCATION" --query "values[?isDefault].version | [0]" --output tsv 2>/dev/null || true)
            if [[ -z "${MGMT_K8S_VERSION}" || "${MGMT_K8S_VERSION}" == "None" ]]; then
                MGMT_K8S_VERSION=$(az aks get-versions --location "$AZURE_LOCATION" --query "values[].version | sort(@) | [-1]" --output tsv 2>/dev/null || true)
            fi
        fi
        # az CLI may emit the literal "None" for a null result; normalize it so the guard below catches it
        if [[ "${MGMT_K8S_VERSION:-}" == "None" ]]; then
            MGMT_K8S_VERSION=""
        fi
        : "${MGMT_K8S_VERSION:?Unable to resolve an AKS management cluster Kubernetes version}"
        export MGMT_K8S_VERSION
        log "using AKS management cluster Kubernetes version: ${MGMT_K8S_VERSION}"

        log "create resource group and management cluster"
        if [[ "$(az group exists --name "${CLUSTER_NAME}" --output tsv)" == "false" ]]; then
            az group create --name "${CLUSTER_NAME}" --location "$AZURE_LOCATION" --tags creationTimestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            output=$(az aks create \
                --resource-group "${CLUSTER_NAME}" \
                --name "${CLUSTER_NAME}" \
                --node-count 1 \
                --generate-ssh-keys \
                --vm-set-type VirtualMachineScaleSets \
                --kubernetes-version "${MGMT_K8S_VERSION}" \
                --network-plugin azure \
                --tags creationTimestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')")
            
            if [[ $output == *"AKSCapacityError"* ]]; then
                log "AKS Capacity Error, retrying"
                az group delete --name "${CLUSTER_NAME}" --no-wait -y || true
                # reset location and name
                export AZURE_LOCATION="${AZURE_LOCATION:-$(get_random_region)}"
                export CLUSTER_NAME="${CLUSTER_NAME:-capz-conf-$(head /dev/urandom | LC_ALL=C tr -dc a-z0-9 | head -c 6 ; echo '')}"
                az group create --name "${CLUSTER_NAME}" --location "$AZURE_LOCATION" --tags creationTimestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
                output=$(az aks create \
                    --resource-group "${CLUSTER_NAME}" \
                    --name "${CLUSTER_NAME}" \
                    --node-count 1 \
                    --generate-ssh-keys \
                    --vm-set-type VirtualMachineScaleSets \
                    --kubernetes-version "${MGMT_K8S_VERSION}" \
                    --network-plugin azure \
                    --tags creationTimestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')")
            fi
        else
            log "resource group ${CLUSTER_NAME} already exists, use the location of the existing resource group"
            # Use the location same as the existing resource group
            AZURE_LOCATION=$(az group show --name "${CLUSTER_NAME}" --query location -o tsv)
            export AZURE_LOCATION
        fi

        az aks get-credentials --resource-group "${CLUSTER_NAME}" --name "${CLUSTER_NAME}" -f "${MANAGEMENT_KUBECONFIG}" --overwrite-existing
        export KUBECONFIG="${MANAGEMENT_KUBECONFIG}"

        # some scenarios require knowing the vnet configuration of the management cluster in order to work in a restricted networking environment
        aks_infra_rg_name=$(az aks show -g "${CLUSTER_NAME}" --name "${CLUSTER_NAME}" --query nodeResourceGroup --output tsv)
        ask_vnet=$(az network vnet list -g "$aks_infra_rg_name" --query "[?starts_with(name, 'aks-vnet-')].name | [0]" --output tsv)
        export AKS_INFRA_RG_NAME="${aks_infra_rg_name}"
        export AKS_VNET_NAME="${ask_vnet}"

        # In a prod set up we probably would want a separate identity for this operation but for ease of use we are re-using the one created by AKS for kubelet
        log "applying role assignment to management cluster identity to have permissions to create workload cluster"
        MANAGEMENT_IDENTITY=$(az aks show -n "${CLUSTER_NAME}" -g "${CLUSTER_NAME}" --output json | jq -r '.identityProfile.kubeletidentity.clientId')
        export MANAGEMENT_IDENTITY
        # For simplicity we will use the kubelet identity as the identity for the workload cluster as well
        USER_IDENTITY=$(az aks show -n "${CLUSTER_NAME}" -g "${CLUSTER_NAME}" --output json | jq -r '.identityProfile.kubeletidentity.resourceId')
        export USER_IDENTITY
        
        objectId=$(az aks show -n "${CLUSTER_NAME}" -g "${CLUSTER_NAME}" --output json | jq -r '.identityProfile.kubeletidentity.objectId')
        until assignmentId=$(az role assignment create --assignee-object-id "${objectId}" --role "Contributor" --scope "/subscriptions/${AZURE_SUBSCRIPTION_ID}" --assignee-principal-type ServicePrincipal --output json |jq -r .id); do
            sleep 5
        done
        export assignmentId # used in cleanup

        log "Install cluster api azure onto management cluster"
        "$TOOLS_BIN_DIR"/clusterctl init --infrastructure azure
        log "wait for core CRDs to be installed"
        kubectl wait --for=condition=ready pod --all -n capz-system --timeout=300s
        # Wait for the core CRD resources to be "installed" onto the mgmt cluster before returning control
        timeout --foreground 300 bash -c "until kubectl get clusters -A > /dev/null 2>&1; do sleep 3; done"
        timeout --foreground 300 bash -c "until kubectl get azureclusters -A > /dev/null 2>&1; do sleep 3; done"
        timeout --foreground 300 bash -c "until kubectl get kubeadmcontrolplanes -A > /dev/null 2>&1; do sleep 3; done"

        log "Provision workload cluster"
        "$TOOLS_BIN_DIR"/clusterctl generate cluster "${CLUSTER_NAME}" --kubernetes-version "$KUBERNETES_VERSION" --from "$template" > "$SCRIPT_ROOT"/"${CLUSTER_NAME}-template.yaml"
        kubectl apply -f "$SCRIPT_ROOT"/"${CLUSTER_NAME}-template.yaml"

        log "wait for workload cluster config"
        timeout --foreground 300 bash -c "until $TOOLS_BIN_DIR/clusterctl get kubeconfig ${CLUSTER_NAME} > ${CLUSTER_NAME}.kubeconfig 2>/dev/null; do sleep 3; done"

        # copy generated template to logs
        mkdir -p "${ARTIFACTS}"/clusters/bootstrap
        cp "$SCRIPT_ROOT"/"${CLUSTER_NAME}-template.yaml" "${ARTIFACTS}"/clusters/bootstrap || true
        log "cluster creation complete"
    fi

    log "wait for \"${CLUSTER_NAME}\" cluster to stabilize"
    timeout --foreground 300 bash -c "until kubectl get --raw /version --request-timeout 5s > /dev/null 2>&1; do sleep 3; done"

    CLUSTER_JSON=$(kubectl get cluster "${CLUSTER_NAME}" -n default -o json || true)
    if [[ -z "${CLUSTER_JSON}" ]]; then
        log "ERROR: failed to get cluster \"${CLUSTER_NAME}\" in namespace default"
        exit 1
    fi
    BASTION_ADDRESS=$(echo "${CLUSTER_JSON}" | jq -r '.spec.controlPlaneEndpoint.host // empty')
    if [[ -z "${BASTION_ADDRESS}" ]]; then
        log "ERROR: bastion address lookup failed for cluster"
        echo "${CLUSTER_JSON}"
        exit 1
    fi
    # set the SSH bastion that can be used to SSH into nodes
    export KUBE_SSH_BASTION="${BASTION_ADDRESS}:22"
    KUBE_SSH_USER=capi
    export KUBE_SSH_USER
    log "bastion info: $KUBE_SSH_USER@$KUBE_SSH_BASTION"

    # set the kube config to the workload cluster
    # the kubeconfig is dropped to the current folder but move it to a location that is well known to avoid issues if end up in wrong folder due to other scripts.
    local workload_kubeconfig_path="$PWD/${CLUSTER_NAME}.kubeconfig"
    if [[ "$PWD" != "$SCRIPT_ROOT" ]]; then
        cp "$workload_kubeconfig_path" "$SCRIPT_ROOT/${CLUSTER_NAME}.kubeconfig"
        workload_kubeconfig_path="$SCRIPT_ROOT/${CLUSTER_NAME}.kubeconfig"
    fi
    export KUBECONFIG="$workload_kubeconfig_path"

    log "create_cluster complete"
}

export_workload_cluster_resource_group() {
    local workload_resource_group=""

    workload_resource_group=$(kubectl --kubeconfig "${MANAGEMENT_KUBECONFIG}" get azurecluster "${CLUSTER_NAME}" -n default -o jsonpath='{.spec.resourceGroup}' 2>/dev/null || true)
    if [[ -z "${workload_resource_group}" ]]; then
        workload_resource_group="${CLUSTER_NAME}"
        log "AzureCluster resource group lookup unavailable or empty; falling back to ${workload_resource_group}"
    else
        log "discovered workload cluster Azure resource group: ${workload_resource_group}"
    fi

    if [[ -n "${AZURE_RESOURCE_GROUP:-}" ]]; then
        if [[ "${AZURE_RESOURCE_GROUP}" == "${workload_resource_group}" ]]; then
            export AZURE_RESOURCE_GROUP
            log "AZURE_RESOURCE_GROUP already matches workload cluster resource group; exporting AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}"
            return
        fi
        log "WARNING: AZURE_RESOURCE_GROUP was set to ${AZURE_RESOURCE_GROUP}; exporting workload cluster resource group ${workload_resource_group} for this CAPZ e2e run"
    fi

    export AZURE_RESOURCE_GROUP="${workload_resource_group}"
    log "exporting AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}"
}

wait_for_windows_machinedeployment() {
    local md_name="${CLUSTER_NAME}-md-win"
    local kubeconfig="${MANAGEMENT_KUBECONFIG}"

    log "entering wait_for_windows_machinedeployment for ${md_name}"

    if [[ ! -f "${kubeconfig}" ]]; then
        log "management kubeconfig ${kubeconfig} not found; skipping MachineDeployment wait"
        return
    fi

    log "waiting for MachineDeployment ${md_name} to exist on management cluster"
    timeout --foreground 900 bash -c "until kubectl --kubeconfig \"${kubeconfig}\" get machinedeployment ${md_name} -n default > /dev/null 2>&1; do sleep 5; done"

    log "waiting for MachineDeployment ${md_name} to become Available"
    kubectl --kubeconfig "${kubeconfig}" wait --for=condition=Available --timeout=20m "machinedeployment/${md_name}" -n default
}

ensure_cloud_provider_taint_on_windows_nodes() {
    log "tainting Windows nodes with node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule"
    
    local windows_nodes
    windows_nodes=$(kubectl get nodes -l kubernetes.io/os=windows -o name 2>/dev/null || true)
    
    if [[ -z "${windows_nodes}" ]]; then
        log "no Windows nodes found to taint"
        return
    fi
    
    # Taint all Windows nodes
    echo "${windows_nodes}" | while read -r node; do
        [[ -z "${node}" ]] && continue
        local node_name="${node#node/}"
        log "tainting node ${node_name}"
        kubectl taint nodes "${node_name}" node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule --overwrite
    done
    
    local count
    count=$(echo "${windows_nodes}" | wc -l)
    log "tainted ${count} Windows node(s)"
}

apply_workload_configuration(){
    log "entering apply_workload_configuration"
    log "wait for cluster to stabilize"
    timeout --foreground 300 bash -c "until kubectl get --raw /version --request-timeout 5s > /dev/null 2>&1; do sleep 3; done"

    case "${NETWORK_PLUGIN}" in
        calico)
            apply_calico
            apply_windows_kube_proxy
            ;;
        azure-cni)
            # Windows kube-proxy is applied after the nodes are Ready; see main.
            apply_azure_cni
            ;;
    esac
    apply_common_addons
}

apply_calico(){
    log "installing calico"
    "$TOOLS_BIN_DIR"/helm repo add projectcalico https://docs.tigera.io/calico/charts
    kubectl create ns calico-system

    if [[ "${IS_PRESUBMIT}" == "true" ]]; then
        sleep 30s
    fi
    "$TOOLS_BIN_DIR"/helm upgrade calico projectcalico/tigera-operator --version "$CALICO_VERSION" --namespace tigera-operator -f "$SCRIPT_ROOT"/templates/calico/values.yaml  --create-namespace  --install --debug
    timeout --foreground 300 bash -c "until kubectl get ipamconfigs default -n default > /dev/null 2>&1; do sleep 3; done"

    #required for windows no way to do it via operator https://github.com/tigera/operator/issues/3113
    kubectl patch ipamconfigs default --type merge --patch='{"spec": {"strictAffinity": true}}'

    # get the info for the API server
    servername=$(kubectl config view -o json | jq -r '.clusters[0].cluster.server | sub("https://"; "") | split(":") | .[0]')
    port=$(kubectl config view -o json | jq -r '.clusters[0].cluster.server | sub("https://"; "") | split(":") | .[1]')

    kubectl apply -f - << EOF
kind: ConfigMap
apiVersion: v1
metadata:
  name: kubernetes-services-endpoint
  namespace: tigera-operator
data:
  KUBERNETES_SERVICE_HOST: "${servername}"
  KUBERNETES_SERVICE_PORT: "${port}"
EOF
}

apply_windows_kube_proxy(){
    # Only patch up kube-proxy if $WINDOWS_KPNG is unset
    if [[ -n "$KPNG" ]]; then
        return
    fi
    log "installing kube-proxy for windows"
    case "${NETWORK_PLUGIN}" in
        calico)
            # apply kube-proxy for windows with a version (it doesn't matter what version it is replaced with the patch below)
            KUBERNETES_VERSION=v1.30.1 "$TOOLS_BIN_DIR"/clusterctl generate yaml --from "${CAPZ_DIR}"/templates/addons/windows/calico/kube-proxy-windows.yaml | kubectl apply -f -

            # A patch is needed to tell kube-proxy to use CI binaries.  This could go away once we have build scripts for kubeproxy HostProcess image.
            kubectl apply -f "${CAPZ_DIR}"/templates/test/ci/patches/windows-kubeproxy-ci.yaml
            kubectl rollout restart ds -n kube-system kube-proxy-windows
            ;;
        azure-cni)
            # Create the CI binary override first so the initial pods already use it.
            kubectl apply -f "${CAPZ_DIR}"/templates/test/ci/patches/windows-kubeproxy-ci.yaml
            "$TOOLS_BIN_DIR"/clusterctl generate yaml --from "${AZURE_CNI_TEMPLATE_DIR}"/addons/windows-kube-proxy.yaml | kubectl apply -f -
            kubectl -n kube-system rollout status daemonset/kube-proxy-windows --timeout=10m
            ;;
    esac
}

apply_common_addons(){
    # apply additional helper manifests (logger etc)
    if [[ -n "$CONTAINERD_LOGGER" ]]; then
        kubectl apply -f "${CAPZ_DIR}"/templates/addons/windows/containerd-logging/containerd-logger.yaml
    fi
    kubectl apply -f "${CAPZ_DIR}"/templates/addons/windows/csi-proxy/csi-proxy.yaml
    kubectl apply -f "${CAPZ_DIR}"/templates/addons/metrics-server/metrics-server.yaml
}

set_azure_cni_defaults(){
    export AZURE_CNI_TEMPLATE_DIR="${SCRIPT_ROOT}/templates/networking/azure-cni"
    # One multi-arch image provides the verified Linux and Windows payloads for a single release.
    export AZURE_CNI_IMAGE="${AZURE_CNI_IMAGE:-"mcr.microsoft.com/containernetworking/azure-cni:v1.6.35-0@sha256:6af0917268f36b92c08925ddd16759984ad15b4d2e20349ce6cfe51d8a1a0067"}"
    export AZURE_CNI_WINDOWS_IMAGE="${AZURE_CNI_WINDOWS_IMAGE:-"${AZURE_CNI_IMAGE}"}"
    export AZURE_CNI_MAX_PODS="${AZURE_CNI_MAX_PODS:-"110"}"
    if [[ -z "${AZURE_CNI_PRIVATE_IP_CONFIGS:-}" && "${AZURE_CNI_MAX_PODS}" =~ ^[0-9]+$ ]]; then
        # CAPZ counts the primary IP configuration, and Azure CNI assigns only the secondary IPs to pods.
        AZURE_CNI_PRIVATE_IP_CONFIGS="$((10#${AZURE_CNI_MAX_PODS} + 1))"
    fi
    export AZURE_CNI_PRIVATE_IP_CONFIGS="${AZURE_CNI_PRIVATE_IP_CONFIGS:-}"
    export AZURE_CNI_VNET_CIDR="${AZURE_CNI_VNET_CIDR:-"10.0.0.0/8"}"
    export AZURE_CNI_CONTROL_PLANE_SUBNET_CIDR="${AZURE_CNI_CONTROL_PLANE_SUBNET_CIDR:-"10.0.0.0/16"}"
    export AZURE_CNI_NODE_SUBNET_CIDR="${AZURE_CNI_NODE_SUBNET_CIDR:-"10.1.0.0/16"}"
    export AZURE_CNI_DNS_SEARCH="${AZURE_CNI_DNS_SEARCH:-"svc.cluster.local"}"
    # Azure CNI names its HNS network after the conflist network name.
    export WINDOWS_HNS_NETWORK_NAME="${WINDOWS_HNS_NETWORK_NAME:-"azure"}"
    export WINDOWS_ENABLE_DSR="${WINDOWS_ENABLE_DSR:-"true"}"
    # CI and presubmit jobs run kube-proxy.exe from KUBEPROXY_PATH; the image provides start.ps1.
    export WINDOWS_KUBEPROXY_IMAGE="${WINDOWS_KUBEPROXY_IMAGE:-"docker.io/sigwindowstools/kube-proxy:v1.35.0-hostprocess"}"
    export AZURE_CNI_SMOKE_IMAGE="${AZURE_CNI_SMOKE_IMAGE:-"registry.k8s.io/e2e-test-images/agnhost:2.57@sha256:80658cfc42bff7977efaa188e661631202fdbe810c4e17b2fcc84e2a3ac79298"}"
}

validate_azure_cni_configuration(){
    local template_override=$1

    # Fail explicitly for combinations that have not been validated with Azure CNI yet.
    if [[ "${GMSA}" == "true" ]]; then fail_validation "NETWORK_PLUGIN=azure-cni has not been validated with GMSA"; fi
    if [[ -n "${KPNG}" ]]; then fail_validation "NETWORK_PLUGIN=azure-cni has not been validated with WINDOWS_KPNG"; fi
    if [[ "${HYPERV}" == "true" ]]; then fail_validation "NETWORK_PLUGIN=azure-cni has not been validated with HYPERV"; fi
    if [[ -n "${MAX_PODS}" ]]; then fail_validation "MAX_PODS is not supported with NETWORK_PLUGIN=azure-cni; set AZURE_CNI_MAX_PODS instead"; fi
    if [[ -n "${template_override}" ]]; then fail_validation "TEMPLATE is not supported with NETWORK_PLUGIN=azure-cni; the Azure CNI CI or PR template is selected automatically"; fi
    if [[ "${WINDOWS_SERVER_VERSION}" != "windows-2022" ]]; then fail_validation "NETWORK_PLUGIN=azure-cni has only been validated with WINDOWS_SERVER_VERSION=windows-2022"; fi
    if [[ "${KUBERNETES_VERSION}" =~ ^(v|latest-)?1\.29(\.|$) ]]; then fail_validation "NETWORK_PLUGIN=azure-cni does not support Kubernetes v1.29 templates"; fi
    if [[ "${WINDOWS_ENABLE_DSR}" != "true" && "${WINDOWS_ENABLE_DSR}" != "false" ]]; then fail_validation "WINDOWS_ENABLE_DSR must be true or false"; fi

    local entry
    for entry in "AZURE_CNI_MAX_PODS=${AZURE_CNI_MAX_PODS}" "AZURE_CNI_PRIVATE_IP_CONFIGS=${AZURE_CNI_PRIVATE_IP_CONFIGS}" "CONTROL_PLANE_MACHINE_COUNT=${CONTROL_PLANE_MACHINE_COUNT}" "WINDOWS_WORKER_MACHINE_COUNT=${WINDOWS_WORKER_MACHINE_COUNT}"; do
        if [[ ! "${entry#*=}" =~ ^[1-9][0-9]*$ ]]; then fail_validation "${entry%%=*} must be a positive integer, got '${entry#*=}'"; fi
    done
    if (( AZURE_CNI_PRIVATE_IP_CONFIGS < AZURE_CNI_MAX_PODS + 1 )); then
        fail_validation "AZURE_CNI_PRIVATE_IP_CONFIGS (${AZURE_CNI_PRIVATE_IP_CONFIGS}) must be at least AZURE_CNI_MAX_PODS + 1 ($((AZURE_CNI_MAX_PODS + 1))) because CAPZ counts the primary IP configuration"
    fi
    # Azure allows at most 256 IP configurations per network interface on every VM size.
    if (( AZURE_CNI_PRIVATE_IP_CONFIGS > 256 )); then
        fail_validation "AZURE_CNI_PRIVATE_IP_CONFIGS (${AZURE_CNI_PRIVATE_IP_CONFIGS}) exceeds the Azure limit of 256 IP configurations per network interface"
    fi

    local cidr
    for cidr in "${AZURE_CNI_VNET_CIDR}" "${AZURE_CNI_CONTROL_PLANE_SUBNET_CIDR}" "${AZURE_CNI_NODE_SUBNET_CIDR}"; do
        if ! is_ipv4_cidr "${cidr}"; then fail_validation "invalid IPv4 CIDR '${cidr}'"; fi
    done
    if cidr_within "${AZURE_CNI_CONTROL_PLANE_SUBNET_CIDR}" "${AZURE_CNI_NODE_SUBNET_CIDR}" || cidr_within "${AZURE_CNI_NODE_SUBNET_CIDR}" "${AZURE_CNI_CONTROL_PLANE_SUBNET_CIDR}"; then
        fail_validation "AZURE_CNI_CONTROL_PLANE_SUBNET_CIDR and AZURE_CNI_NODE_SUBNET_CIDR overlap"
    fi

    local subnet machines usable required
    for entry in "control-plane-subnet ${AZURE_CNI_CONTROL_PLANE_SUBNET_CIDR} ${CONTROL_PLANE_MACHINE_COUNT}" "node-subnet ${AZURE_CNI_NODE_SUBNET_CIDR} ${WINDOWS_WORKER_MACHINE_COUNT}"; do
        read -r subnet cidr machines <<< "${entry}"
        if ! cidr_within "${cidr}" "${AZURE_CNI_VNET_CIDR}"; then
            fail_validation "${subnet} ${cidr} is not inside AZURE_CNI_VNET_CIDR ${AZURE_CNI_VNET_CIDR}"
        fi
        # Azure reserves five addresses per subnet; one extra machine covers a rolling upgrade surge.
        usable=$(( (1 << (32 - 10#${cidr#*/})) - 5 ))
        required=$(( (machines + 1) * AZURE_CNI_PRIVATE_IP_CONFIGS ))
        if (( required > usable )); then
            fail_validation "${subnet} ${cidr} has ${usable} usable addresses but ${required} are required for $((machines + 1)) machines with ${AZURE_CNI_PRIVATE_IP_CONFIGS} IP configurations each"
        fi
        log "${subnet} ${cidr}: ${required} of ${usable} usable addresses required"
    done
}

is_ipv4_cidr(){
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    (( 10#${BASH_REMATCH[1]} <= 255 && 10#${BASH_REMATCH[2]} <= 255 && 10#${BASH_REMATCH[3]} <= 255 && 10#${BASH_REMATCH[4]} <= 255 && 10#${BASH_REMATCH[5]} <= 32 ))
}

ipv4_to_int(){
    local IFS=. a b c d
    read -r a b c d <<< "$1"
    echo $(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))
}

cidr_contains_ip(){
    local network=${1%/*} bits=$((10#${1#*/}))
    local mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    (( ($(ipv4_to_int "$2") & mask) == ($(ipv4_to_int "${network}") & mask) ))
}

# Returns success when the first CIDR is entirely inside the second CIDR.
cidr_within(){
    (( 10#${1#*/} >= 10#${2#*/} )) && cidr_contains_ip "$2" "${1%/*}"
}

apply_azure_cni(){
    log "installing Azure CNI from ${AZURE_CNI_IMAGE}"

    # Linux uses CAPZ's Azure CNI v1 add-on, pinned to the same release as Windows.
    local linux_manifest="${CAPZ_DIR}/templates/addons/azure-cni-v1.yaml"
    local image_pattern='mcr\.microsoft\.com/containernetworking/azure-cni:[^[:space:]]+'
    if [[ "$(grep -cE "${image_pattern}" "${linux_manifest}")" != "1" ]]; then
        log "ERROR: expected exactly one Azure CNI image in ${linux_manifest}"
        exit 1
    fi
    sed -E "s#${image_pattern}#${AZURE_CNI_IMAGE}#" "${linux_manifest}" | kubectl apply -f -

    log "discovering Windows Azure CNI settings"
    timeout --foreground 300 bash -c "until kubectl -n kube-system get service kube-dns > /dev/null 2>&1; do sleep 3; done"
    AZURE_CNI_DNS_SERVICE_IP=$(kubectl -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}')
    AZURE_CNI_SERVICE_CIDR=$(kubectl -n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | awk '$1 == "serviceSubnet:" { gsub(/"/, "", $2); print $2 }')
    local vnet_cidrs
    vnet_cidrs=$(kubectl --kubeconfig "${MANAGEMENT_KUBECONFIG}" get azurecluster "${CLUSTER_NAME}" -n default -o jsonpath='{.spec.networkSpec.vnet.cidrBlocks[*]}' 2>/dev/null || true)
    if [[ -z "${vnet_cidrs}" ]]; then
        log "AzureCluster VNet CIDR lookup unavailable; using AZURE_CNI_VNET_CIDR=${AZURE_CNI_VNET_CIDR}"
        vnet_cidrs="${AZURE_CNI_VNET_CIDR}"
    fi
    # Pod and node IPs both come from the VNet, so traffic inside it must not be SNATed.
    AZURE_CNI_OUTBOUNDNAT_EXCEPTIONS="${vnet_cidrs// /,}"
    if [[ -z "${AZURE_CNI_DNS_SERVICE_IP}" || -z "${AZURE_CNI_SERVICE_CIDR}" ]]; then
        log "ERROR: could not discover the cluster DNS service IP (${AZURE_CNI_DNS_SERVICE_IP}) or service CIDR (${AZURE_CNI_SERVICE_CIDR})"
        exit 1
    fi
    export AZURE_CNI_DNS_SERVICE_IP AZURE_CNI_SERVICE_CIDR AZURE_CNI_OUTBOUNDNAT_EXCEPTIONS
    log "Windows Azure CNI: image=${AZURE_CNI_WINDOWS_IMAGE} dns=${AZURE_CNI_DNS_SERVICE_IP} serviceCIDR=${AZURE_CNI_SERVICE_CIDR} outboundNATExceptions=${AZURE_CNI_OUTBOUNDNAT_EXCEPTIONS} dsr=${WINDOWS_ENABLE_DSR}"

    kubectl -n kube-system create configmap azure-cni-windows-installer \
        --from-file=install-azure-cni.ps1="${AZURE_CNI_TEMPLATE_DIR}"/addons/install-azure-cni.ps1 \
        --dry-run=client -o yaml | kubectl apply -f -
    "$TOOLS_BIN_DIR"/clusterctl generate yaml --from "${AZURE_CNI_TEMPLATE_DIR}"/addons/azure-cni-windows.yaml | kubectl apply -f -
}

wait_for_azure_cni_installers(){
    log "waiting for the Azure CNI installers"
    local entry daemonset os expected ready
    for entry in "azure-cni linux" "azure-cni-windows windows"; do
        read -r daemonset os <<< "${entry}"
        expected=$(kubectl get nodes -l "kubernetes.io/os=${os}" -o name | wc -l)
        if kubectl -n kube-system rollout status "daemonset/${daemonset}" --timeout=10m; then
            ready=$(kubectl -n kube-system get daemonset "${daemonset}" -o jsonpath='{.status.numberReady}')
        else
            ready=""
        fi
        if [[ "${ready}" != "${expected}" ]]; then
            log "ERROR: ${daemonset} is Ready on ${ready:-an unknown number} of ${expected} ${os} node(s)"
            kubectl -n kube-system get pods -l "k8s-app=${daemonset}" -o wide || true
            kubectl -n kube-system logs -l "k8s-app=${daemonset}" --all-containers --prefix --tail=-1 || true
            exit 1
        fi
        log "${daemonset} is Ready on ${ready} ${os} node(s)"
    done
}

validate_azure_cni_smoke(){
    if [[ "${AZURE_CNI_SKIP_SMOKE:-"false"}" == "true" ]]; then
        log "skipping Azure CNI smoke validation"
        return
    fi
    log "running Azure CNI smoke validation"
    local ns="azure-cni-smoke"
    local windows_replicas=$((WINDOWS_WORKER_MACHINE_COUNT * 2))
    local failures=0

    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: win
  namespace: ${ns}
spec:
  replicas: ${windows_replicas}
  selector:
    matchLabels:
      app: win
  template:
    metadata:
      labels:
        app: win
    spec:
      nodeSelector:
        kubernetes.io/os: windows
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: win
      containers:
      - name: agnhost
        image: ${AZURE_CNI_SMOKE_IMAGE}
        args: ["netexec", "--http-port=8080"]
---
apiVersion: v1
kind: Pod
metadata:
  name: linux
  namespace: ${ns}
  labels:
    app: linux
spec:
  nodeSelector:
    kubernetes.io/os: linux
  tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  containers:
  - name: agnhost
    image: ${AZURE_CNI_SMOKE_IMAGE}
    args: ["netexec", "--http-port=8080"]
---
apiVersion: v1
kind: Service
metadata:
  name: win
  namespace: ${ns}
spec:
  type: NodePort
  selector:
    app: win
  ports:
  - port: 80
    targetPort: 8080
EOF
    # The first Windows pod triggers the first Azure CNI ADD and creates the HNS network.
    kubectl -n "${ns}" rollout status deployment/win --timeout=20m
    kubectl -n "${ns}" wait --for=condition=Ready pod/linux --timeout=10m
    kubectl -n "${ns}" get pods -o wide

    azure_cni_smoke_checks "${ns}" || failures=$((failures + 1))

    log "checking that Windows pod churn does not leak HNS endpoints"
    local before after iteration
    before=$(azure_cni_local_hns_endpoints)
    for iteration in $(seq 1 "${AZURE_CNI_SMOKE_CHURN_ITERATIONS:-3}"); do
        log "pod churn iteration ${iteration}"
        kubectl -n "${ns}" delete pods -l app=win --wait=true
        kubectl -n "${ns}" rollout status deployment/win --timeout=10m
    done
    for _ in $(seq 1 12); do
        after=$(azure_cni_local_hns_endpoints)
        if [[ "${before}" == "${after}" ]]; then break; fi
        sleep 10
    done
    if [[ "${before}" == "${after}" ]]; then
        log "PASS: local HNS endpoints per node unchanged after churn: ${after}"
    else
        log "FAIL: local HNS endpoints per node changed after churn: before=${before} after=${after}"
        failures=$((failures + 1))
    fi
    azure_cni_smoke_checks "${ns}" || failures=$((failures + 1))

    log "checking recovery after restarting Windows kube-proxy"
    kubectl -n kube-system rollout restart daemonset/kube-proxy-windows
    kubectl -n kube-system rollout status daemonset/kube-proxy-windows --timeout=10m
    azure_cni_smoke_checks "${ns}" || failures=$((failures + 1))

    if (( failures > 0 )); then
        log "ERROR: Azure CNI smoke validation failed in ${failures} phase(s)"
        kubectl -n "${ns}" get pods,svc,endpointslices -o wide || true
        exit 1
    fi
    kubectl delete namespace "${ns}" --wait=false
    log "Azure CNI smoke validation passed"
}

# Runs the connectivity checks against the current smoke pods and returns non-zero on any failure.
azure_cni_smoke_checks(){
    local ns=$1 failures=0
    local -a pods=() ips=() nodes=()
    local name ip node
    while read -r name ip node; do
        pods+=("${name}"); ips+=("${ip}"); nodes+=("${node}")
    done < <(kubectl -n "${ns}" get pods -l app=win -o json | jq -r '.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running") | "\(.metadata.name) \(.status.podIP) \(.spec.nodeName)"')
    if (( ${#pods[@]} == 0 )); then
        log "FAIL: no running Windows smoke pods"
        return 1
    fi
    local linux_ip control_plane_ip node_port
    linux_ip=$(kubectl -n "${ns}" get pod linux -o jsonpath='{.status.podIP}')
    control_plane_ip=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    node_port=$(kubectl -n "${ns}" get service win -o jsonpath='{.spec.ports[0].nodePort}')

    local i node_ip
    for i in "${!pods[@]}"; do
        node_ip=$(kubectl get node "${nodes[$i]}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
        if [[ "${ips[$i]}" != "${node_ip}" ]] && cidr_contains_ip "${AZURE_CNI_NODE_SUBNET_CIDR}" "${ips[$i]}"; then
            log "PASS: ${pods[$i]} IP ${ips[$i]} is from node subnet ${AZURE_CNI_NODE_SUBNET_CIDR}"
        else
            log "FAIL: ${pods[$i]} IP ${ips[$i]} is not a pod IP from node subnet ${AZURE_CNI_NODE_SUBNET_CIDR}"
            failures=$((failures + 1))
        fi
    done
    if cidr_contains_ip "${AZURE_CNI_CONTROL_PLANE_SUBNET_CIDR}" "${linux_ip}"; then
        log "PASS: linux pod IP ${linux_ip} is from control plane subnet ${AZURE_CNI_CONTROL_PLANE_SUBNET_CIDR}"
    else
        log "FAIL: linux pod IP ${linux_ip} is not from control plane subnet ${AZURE_CNI_CONTROL_PLANE_SUBNET_CIDR}"
        failures=$((failures + 1))
    fi

    local source=${pods[0]} same_node="" other_node="" other_node_ip=""
    for i in "${!pods[@]}"; do
        if (( i == 0 )); then continue; fi
        if [[ "${nodes[$i]}" == "${nodes[0]}" && -z "${same_node}" ]]; then same_node=${ips[$i]}; fi
        if [[ "${nodes[$i]}" != "${nodes[0]}" && -z "${other_node}" ]]; then
            other_node=${ips[$i]}
            other_node_ip=$(kubectl get node "${nodes[$i]}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
        fi
    done
    local service="win.${ns}.svc.cluster.local:80"
    local -a checks=(
        "Windows to Windows on the same node|${source}|${same_node}:8080"
        "Windows to Windows on another node|${source}|${other_node}:8080"
        "Windows to Linux|${source}|${linux_ip}:8080"
        "Linux to Windows|linux|${ips[0]}:8080"
        "Windows DNS and ClusterIP|${source}|${service}"
        "Linux DNS and ClusterIP|linux|${service}"
        "Linux to Windows NodePort|linux|$(kubectl get node "${nodes[0]}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'):${node_port}"
        "Windows to remote Windows NodePort|${source}|${other_node_ip}:${node_port}"
        "Windows VNet egress to the API server|${source}|${control_plane_ip}:6443"
        "Windows internet egress|${source}|${AZURE_CNI_SMOKE_EGRESS_TARGET:-"mcr.microsoft.com:443"}"
    )
    local check description pod target
    for check in "${checks[@]}"; do
        IFS='|' read -r description pod target <<< "${check}"
        if [[ "${target}" == :* ]]; then
            if (( WINDOWS_WORKER_MACHINE_COUNT > 1 )); then
                log "FAIL: ${description}: no Windows smoke pod was scheduled on another node"
                failures=$((failures + 1))
            else
                log "SKIP: ${description}: only one Windows node"
            fi
            continue
        fi
        azure_cni_smoke_connect "${ns}" "${description}" "${pod}" "${target}" || failures=$((failures + 1))
    done
    (( failures == 0 ))
}

azure_cni_smoke_connect(){
    local ns=$1 description=$2 pod=$3 target=$4
    for _ in $(seq 1 12); do
        if kubectl -n "${ns}" exec "${pod}" -- /agnhost connect --timeout=5s "${target}" > /dev/null 2>&1; then
            log "PASS: ${description}: ${pod} -> ${target}"
            return 0
        fi
        sleep 10
    done
    log "FAIL: ${description}: ${pod} -> ${target}"
    kubectl -n "${ns}" exec "${pod}" -- /agnhost connect --timeout=5s "${target}" || true
    return 1
}

# Prints "node=count" pairs for local (non-remote) HNS endpoints on each Windows node.
azure_cni_local_hns_endpoints(){
    local pod node count result=""
    while read -r pod node; do
        # shellcheck disable=SC2016 # $_ is a PowerShell variable.
        count=$(kubectl -n kube-system exec "${pod}" -c idle -- C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoLogo -NoProfile -NonInteractive -Command '@(Get-HnsEndpoint | Where-Object { -not $_.IsRemoteEndpoint }).Count' | tr -d '\r')
        result+="${node}=${count} "
    done < <(kubectl -n kube-system get pods -l k8s-app=azure-cni-windows -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | sort -k2)
    echo "${result% }"
}

# Best-effort collection that shows whether a failure came from Azure IP allocation, containerd
# CNI invocation, HNS network creation, or kube-proxy service routing. Called from the EXIT trap.
collect_azure_cni_diagnostics(){
    local dir="${ARTIFACTS}/azure-cni"
    local template_dir="${AZURE_CNI_TEMPLATE_DIR:-"${SCRIPT_ROOT}/templates/networking/azure-cni"}"
    local workload_kubeconfig="${SCRIPT_ROOT}/${CLUSTER_NAME:-}.kubeconfig"
    if [[ -f "${workload_kubeconfig}" ]]; then
        local -x KUBECONFIG="${workload_kubeconfig}"
    fi
    mkdir -p "${dir}"
    log "collecting Azure CNI diagnostics in ${dir}"

    local resource_group="${AZURE_RESOURCE_GROUP:-"${CLUSTER_NAME:-}"}"
    az network nic list --resource-group "${resource_group}" \
        --query "[].{NIC:name,IPConfigs:length(ipConfigurations)}" --output table > "${dir}/nic-ipconfig-counts.txt" 2>&1
    az network nic list --resource-group "${resource_group}" \
        --query "[].{nic:name,ipConfigurations:ipConfigurations[].{name:name,privateIPAddress:privateIPAddress,primary:primary,subnet:subnet.id}}" \
        --output json > "${dir}/nic-ipconfigs.json" 2>&1

    {
        kubectl get nodes -o wide
        kubectl -n kube-system get ds,pods -o wide
        kubectl get pods -A -o wide
    } > "${dir}/cluster-state.txt" 2>&1
    kubectl get events -A --sort-by=.lastTimestamp > "${dir}/events.txt" 2>&1
    kubectl -n kube-system describe daemonset azure-cni azure-cni-windows kube-proxy-windows > "${dir}/daemonsets.txt" 2>&1
    local app
    for app in azure-cni azure-cni-windows kube-proxy-windows; do
        kubectl -n kube-system logs -l "k8s-app=${app}" --all-containers --prefix --tail=-1 > "${dir}/${app}.log" 2>&1
        kubectl -n kube-system logs -l "k8s-app=${app}" --all-containers --prefix --tail=-1 --previous > "${dir}/${app}-previous.log" 2>&1
    done

    # HostProcess containers run without pod networking, so this works even when the CNI is broken.
    local encoded node candidate pod container
    encoded=$(iconv -f UTF-8 -t UTF-16LE "${template_dir}/addons/collect-azure-cni-diagnostics.ps1" | base64 -w 0)
    while read -r node; do
        [[ -z "${node}" ]] && continue
        pod=""
        for candidate in "azure-cni-windows idle" "kube-proxy-windows kube-proxy"; do
            read -r app container <<< "${candidate}"
            pod=$(kubectl -n kube-system get pods -l "k8s-app=${app}" --field-selector "spec.nodeName=${node},status.phase=Running" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            if [[ -n "${pod}" ]]; then break; fi
        done
        if [[ -z "${pod}" ]]; then
            echo "no running HostProcess pod found on ${node}; see the CAPZ node logs" > "${dir}/node-${node}.txt"
            continue
        fi
        timeout 300 kubectl -n kube-system exec "${pod}" -c "${container}" -- \
            C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "${encoded}" \
            > "${dir}/node-${node}.txt" 2>&1
    done < <(kubectl get nodes -l kubernetes.io/os=windows -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

    write_azure_cni_diagnostics_summary "${dir}"
}

write_azure_cni_diagnostics_summary(){
    local dir=$1 matches
    {
        echo "== Azure IP allocation (expected ${AZURE_CNI_PRIVATE_IP_CONFIGS:-unknown} IP configurations per NIC)"
        cat "${dir}/nic-ipconfig-counts.txt"
        echo
        echo "== containerd CNI invocation (pod sandbox and network readiness events)"
        matches=$(grep -E 'FailedCreatePodSandBox|NetworkNotReady|NetworkPluginNotReady|failed to setup network|failed to set up sandbox' "${dir}/events.txt" | tail -n 50)
        echo "${matches:-none}"
        echo
        echo "== Windows nodes (HNS network creation, conflist, IPAM log errors, endpoints)"
        matches=$(grep -h '^AZURE_CNI_NODE_SUMMARY ' "${dir}"/node-*.txt 2>/dev/null | sed 's/^AZURE_CNI_NODE_SUMMARY //')
        echo "${matches:-no node summaries collected}"
        echo
        echo "== Windows kube-proxy service routing"
        grep -E 'kube-proxy-windows' "${dir}/cluster-state.txt"
        matches=$(grep -hiE 'waiting for hns network|error|failed' "${dir}/kube-proxy-windows.log" | tail -n 50)
        echo "${matches:-no kube-proxy errors logged}"
    } > "${dir}/summary.txt" 2>&1
    log "Azure CNI diagnostics summary (${dir}/summary.txt):"
    cat "${dir}/summary.txt"
}

apply_cloud_provider_azure() {
    log "entering apply_cloud_provider_azure"
    echo "KUBERNETES_VERSION = ${KUBERNETES_VERSION}"

    prepare_cloud_provider_azure
    echo "Will use the ${IMAGE_REGISTRY}/${CCM_IMAGE_NAME}:${IMAGE_TAG_CCM} cloud-controller-manager image for external cloud-provider-cluster"
    echo "Will use the ${IMAGE_REGISTRY}/${CNM_IMAGE_NAME}:${IMAGE_TAG_CNM} cloud-node-manager image for external cloud-provider-azure cluster"

    CCM_IMG_ARGS=(--set cloudControllerManager.imageRepository="${IMAGE_REGISTRY}"
    --set cloudNodeManager.imageRepository="${IMAGE_REGISTRY}"
    --set cloudControllerManager.imageName="${CCM_IMAGE_NAME}"
    --set cloudNodeManager.imageName="${CNM_IMAGE_NAME}"
    --set-string cloudControllerManager.imageTag="${IMAGE_TAG_CCM}"
    --set-string cloudNodeManager.imageTag="${IMAGE_TAG_CNM}")

    echo "Installing cloud-provider-azure components via helm"
    "$TOOLS_BIN_DIR"/helm upgrade cloud-provider-azure --install --namespace kube-system --repo https://raw.githubusercontent.com/kubernetes-sigs/cloud-provider-azure/master/helm/repo cloud-provider-azure "${CCM_IMG_ARGS[@]}"
}

prepare_cloud_provider_azure() {
    if [[ "${CLOUD_PROVIDER_AZURE_ARTIFACTS_READY:-}" == "true" ]]; then
        return
    fi

    log "preparing cloud-provider-azure images and credential-provider artifacts"
    # shellcheck disable=SC1091
    "${CAPZ_DIR}/hack/ensure-acr-login.sh"

    local previous_dir
    previous_dir="$(pwd)"
    # shellcheck disable=SC1091
    source "${CAPZ_DIR}/scripts/ci-build-azure-ccm.sh" || false
    cd "${previous_dir}"
    trap run_capz_e2e_cleanup EXIT # reset the EXIT trap since ci-build-azure-ccm.sh also sets it.

    : "${AZURE_BLOB_CONTAINER_NAME:?Environment variable empty or not defined.}"
    : "${IMAGE_TAG_ACR_CREDENTIAL_PROVIDER:?Environment variable empty or not defined.}"
    export CLOUD_PROVIDER_AZURE_ARTIFACTS_READY="true"
}

apply_hpc_webhook(){
    log "applying configuration for HPC webhook"

    # ensure cert-manager and webhook pods land on Linux nodes
    log "untainting control-plane nodes"
    mapfile -t cp_nodes < <(kubectl get nodes | grep control-plane | awk '{print $1}')
    kubectl taint nodes "${cp_nodes[@]}" node-role.kubernetes.io/control-plane:NoSchedule- || true

    log "tainting windows nodes"
    mapfile -t windows_nodes < <(kubectl get nodes -o wide | grep Windows | awk '{print $1}')
    kubectl taint nodes "${windows_nodes[@]}" os=windows:NoSchedule

    log "installing cert-manager via helm"
    "$TOOLS_BIN_DIR"/helm install \
        --repo https://charts.jetstack.io \
        --namespace cert-manager \
        --create-namespace \
        --set crds.enabled=true \
        --wait \
        cert-manager cert-manager

    log "wait for cert-manager pods to start"
    timeout 5m kubectl wait --for=condition=ready pod --all -n cert-manager --timeout -1s

    log "installing HPC mutating webhook via helm"
    "$TOOLS_BIN_DIR"/helm install hpc-webhook "${SCRIPT_ROOT}/../helpers/helm" \
        -f "${SCRIPT_ROOT}/../helpers/helm/values-hpc.yaml" \
        --create-namespace

    log "wait for HPC webhook pods to start"
    timeout 5m kubectl wait --for=condition=ready pod --all -n hpc-webhook --timeout -1s

    log "untainting Windows agent nodes"
    kubectl taint nodes "${windows_nodes[@]}" os=windows:NoSchedule-

    log "tainting control-plane nodes again"
    kubectl taint nodes "${cp_nodes[@]}" node-role.kubernetes.io/control-plane:NoSchedule || true

    log "done configuring HPC webhook"
}

apply_hyperv_configuration(){
    log "applying configuration for testing hyperv isolated containers"

    # ensure webhook pod lands on Linux control-plane node
    log "untainting control-plane nodes"
    mapfile -t cp_nodes < <(kubectl get nodes | grep control-plane | awk '{print $1}')
    kubectl taint nodes "${cp_nodes[@]}" node-role.kubernetes.io/control-plane:NoSchedule- || true

    log "installing hyperv webhook via helm"
    "$TOOLS_BIN_DIR"/helm install hyperv-webhook "${SCRIPT_ROOT}/../helpers/helm" \
        -f "${SCRIPT_ROOT}/../helpers/helm/values-hyperv.yaml" \
        --create-namespace

    log "wait for hyperv webhook pods to start"
    timeout 5m kubectl wait --for=condition=ready pod --all -n hyperv-webhook --timeout -1s

    log "tainting control-plane nodes again"
    kubectl taint nodes "${cp_nodes[@]}" node-role.kubernetes.io/control-plane:NoSchedule || true

    log "done configuring testing for hyperv isolated containers"
}

run_post_command() {
    log "running user provided command: $*"
    set +o errexit
    "${@}"
    local exit_code=$?
    set -o errexit
    if [[ ${exit_code} -ne 0 ]]; then
        log "user provided command failed with exit code ${exit_code}"
    else
        log "user provided command completed successfully"
    fi
    return ${exit_code}
}

run_e2e_test() {
    export SKIP_TEST="${SKIP_TEST:-"false"}"
    if [[ ! "$SKIP_TEST" == "true" ]]; then
        ## get test binaries (e2e.test and ginkgo)
        ## https://github.com/kubernetes/sig-release/blob/master/release-engineering/artifacts.md#content-of-kubernetes-test-system-archtargz-on-example-of-kubernetes-test-linux-amd64targz-directories-removed-from-list
        curl -L -o /tmp/kubernetes-test-linux-amd64.tar.gz https://storage.googleapis.com/k8s-release-dev/ci/"${CI_VERSION}"/kubernetes-test-linux-amd64.tar.gz
        tar -xzvf /tmp/kubernetes-test-linux-amd64.tar.gz

        if [[ "$IS_PRESUBMIT" == "true" ]]; then
            # get e2e.test from build artifacts produced by ci-build-kubernetes.sh if running a presubmit job
            # note: KUBE_GIT_VERSION is set by ci-build-kubernetes.sh
            mkdir -p "$PWD/kubernetes/test/bin"
            export e2e_url="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/kubernetes-ci/${KUBE_GIT_VERSION}/bin/linux/amd64/e2e.test"
            log "Downloading e2e.test from $e2e_url"
            curl -L -o "$PWD"/kubernetes/test/bin/e2e.test "$e2e_url"
            chmod +x "$PWD/kubernetes/test/bin/e2e.test"
        fi

        if [[ ! "${RUN_SERIAL_TESTS:-}" == "true" ]]; then
            # Default GINKGO settings for non-serial jobs
            export GINKGO_FOCUS=${GINKGO_FOCUS:-"\[Conformance\]|\[NodeConformance\]|\[sig-windows\]|\[sig-apps\].CronJob|\[sig-api-machinery\].ResourceQuota|\[sig-scheduling\].SchedulerPreemption"}
            export GINKGO_SKIP=${GINKGO_SKIP:-"\[LinuxOnly\]|\[Serial\]|\[Slow\]|\[Excluded:WindowsDocker\]|\[Feature:DynamicResourceAllocation\]|Networking.Granular.Checks(.*)node-pod.communication|Guestbook.application.should.create.and.stop.a.working.application|device.plugin.for.Windows|Container.Lifecycle.Hook.when.create.a.pod.with.lifecycle.hook.should.execute(.*)http.hook.properly|\[sig-api-machinery\].Garbage.collector|\[Alpha\]|\[Beta\].\[Feature:OffByDefault\]|\[FeatureGate:HostnameOverride\]|should.run.with.an.image.specified.user.ID|should.support.memory.backed.volumes.of.specified.size"}
            export GINKGO_NODES="${GINKGO_NODES:-"4"}"
        else
            export GINKGO_FOCUS=${GINKGO_FOCUS:-"(\[sig-windows\]|\[sig-scheduling\].SchedulerPreemption|\[sig-autoscaling\].\[Feature:HPA\]|\[sig-apps\].CronJob).*(\[Serial\]|\[Slow\])|(\[Serial\]|\[Slow\]).*(\[Conformance\]|\[NodeConformance\])|\[sig-api-machinery\].Garbage.collector"}
            export GINKGO_SKIP=${GINKGO_SKIP:-"\[LinuxOnly\]|\[Excluded:WindowsDocker\]|device.plugin.for.Windows|should.be.able.to.gracefully.shutdown.pods.with.various.grace.periods|\[Alpha\]|\[Beta\].\[Feature:OffByDefault\]|\[FeatureGate:HostnameOverride\]|should.run.with.an.image.specified.user.ID|should.support.memory.backed.volumes.of.specified.size"}
            export GINKGO_NODES="${GINKGO_NODES:-"1"}"
        fi

        ADDITIONAL_E2E_ARGS=()
        if [[ "$CI" == "true" ]]; then
            # private image repository doesn't have a way to promote images: https://github.com/kubernetes/k8s.io/pull/1929
            # So we are using a custom repository for the test "Container Runtime blackbox test when running a container with a new image should be able to pull from private registry with secret [NodeConformance]"
            # Must also set label preset-windows-private-registry-cred: "true" on the job
            
            # This will not work in community cluster as this secret is not present (hence we only do it if ENV is set)
            # On the community cluster we will use credential providers to a private registry in azure see:
            # https://github.com/kubernetes-sigs/windows-testing/issues/446
            export KUBE_TEST_REPO_LIST="$SCRIPT_ROOT/../images/image-repo-list-private-registry-community"
        fi

        # K8s 1.24 and below use ginkgo v1 which has slightly different args
        ginkgo_v1="false"
        if [[ "${KUBERNETES_VERSION}" =~ 1.24 ]]; then
            ginkgo_v1="true"
        fi

        if [[ "${ginkgo_v1}" == "true" ]]; then
            ADDITIONAL_E2E_ARGS+=("--ginkgo.slowSpecThreshold=120.0")
        else
            ADDITIONAL_E2E_ARGS+=("--ginkgo.slow-spec-threshold=120s")
            ADDITIONAL_E2E_ARGS+=("--ginkgo.timeout=4h")
        fi

        log "e2e.test version:"
        "$PWD"/kubernetes/test/bin/e2e.test --version
        log "starting to run e2e tests"
        set -x
        "$PWD"/kubernetes/test/bin/ginkgo --nodes="${GINKGO_NODES}" "$PWD"/kubernetes/test/bin/e2e.test -- \
            --provider=skeleton \
            --ginkgo.noColor \
            --ginkgo.focus="$GINKGO_FOCUS" \
            --ginkgo.skip="$GINKGO_SKIP" \
            --ginkgo.flakeAttempts=2 \
            --node-os-distro="windows" \
            --disable-log-dump \
            --ginkgo.progress=true \
            --ginkgo.trace=true \
            --num-nodes="$WINDOWS_WORKER_MACHINE_COUNT" \
            --ginkgo.v=true \
            --dump-logs-on-failure=true \
            --report-dir="${ARTIFACTS}" \
            --prepull-images=true \
            --v=5 "${ADDITIONAL_E2E_ARGS[@]}"
        set +x
        log "e2e tests complete"
    fi
}

wait_for_nodes() {

    log "entering wait_for_nodes"

    log "Waiting for ${CONTROL_PLANE_MACHINE_COUNT} control plane machine(s) and ${WINDOWS_WORKER_MACHINE_COUNT} windows machine(s) to become Ready"
    kubectl get nodes -o wide
    kubectl get pods -A -o wide

    # switch KUBECONFIG to point to management cluster so we can check for provisioning status on
    # if any of the machines are in a failed state
    az aks get-credentials --resource-group "${CLUSTER_NAME}" --name "${CLUSTER_NAME}" -f "${MANAGEMENT_KUBECONFIG}" --overwrite-existing
    export KUBECONFIG="${MANAGEMENT_KUBECONFIG}"

    kubectl get AzureMachines --all-namespaces
    # Ensure that all nodes are registered with the API server before checking for readiness
    local total_nodes="$((CONTROL_PLANE_MACHINE_COUNT + WINDOWS_WORKER_MACHINE_COUNT))"
    while [[ $(kubectl get azuremachines --all-namespaces -o json | jq '[.items[] | select(.status.ready == true and .status.vmState == "Succeeded")] | length') -ne "${total_nodes}" ]]; do
        current_nodes=$(kubectl get azuremachines --all-namespaces -o json | jq '[.items[] | select(.status.ready == true and .status.vmState == "Succeeded")] | length')
        log "Current registered AzureMachine count: ${current_nodes}; expecting ${total_nodes}."

        log "Checking for AzureMachines in Failed state..."
        failed_machines=$(kubectl get AzureMachine --all-namespaces -o json | jq -r '.items[] | select(.status.vmState=="Failed") | .metadata.name')
        if [[ -n "${failed_machines}" ]]; then
            for machine in ${failed_machines}; do
                log "AzureMachine ${machine} is in Failed state. Attempting delete..."
                kubectl -n default describe  AzureMachine "${machine}"
                log "Force deleting failed AzureMachine: ${machine}"
                kubectl -n default delete AzureMachine "${machine}"
                log "Force deleting corresponding Machine: ${machine}"
                kubectl -n default delete Machine "${machine}"
            done
        else
            log "No failed AzureMachines detected."
        fi
        sleep 45
    done

    # switch kubeconfig back to workload cluster 
    export KUBECONFIG="$SCRIPT_ROOT"/"${CLUSTER_NAME}".kubeconfig

    kubectl get nodes -o wide
    kubectl get pods -A -o wide

    log "waiting for nodes to be Ready"
    kubectl wait --for=condition=Ready node --all --timeout=20m
    log "Nodes Ready"
    kubectl get nodes -owide

    if [[ "${GMSA}" == "true" ]]; then
        log "Configuring workload cluster nodes for gmsa tests"
        # require kubeconfig to be pointed at management cluster 
        unset KUBECONFIG
        if [[ -f "${MANAGEMENT_KUBECONFIG}" ]]; then
            export KUBECONFIG="${MANAGEMENT_KUBECONFIG}"
        fi

        pushd  "$SCRIPT_ROOT"/gmsa/configuration
        go run --tags e2e configure.go --name "${CLUSTER_NAME}" --namespace default
        popd
        export KUBECONFIG="$SCRIPT_ROOT"/"${CLUSTER_NAME}".kubeconfig
    fi

}

set_azure_envs() {
    # shellcheck disable=SC1091
    source "${CAPZ_DIR}/hack/ensure-tags.sh"
    if [[ -z "${AZURE_FEDERATED_TOKEN_FILE:-}" && -f "${CAPZ_DIR}/hack/parse-prow-creds.sh" ]]; then
        # older versions of capz require this to authenticate properly
        # shellcheck disable=SC1091
        source "${CAPZ_DIR}/hack/parse-prow-creds.sh"
    fi
    # shellcheck disable=SC1091
    source "${CAPZ_DIR}/hack/util.sh"
    # shellcheck disable=SC1091
    source "${CAPZ_DIR}/hack/ensure-azcli.sh"

    

    # Verify the required Environment Variables are present.
    : "${AZURE_SUBSCRIPTION_ID:?Environment variable empty or not defined.}"
    : "${AZURE_TENANT_ID:?Environment variable empty or not defined.}"

    # Generate SSH key.
    capz::util::generate_ssh_key

    # Set the Azure Location, preferred location can be set through the AZURE_LOCATION environment variable.
    AZURE_LOCATION="${AZURE_LOCATION:-$(get_random_region)}"
    export AZURE_LOCATION
    if [[ "${CI:-}" == "true" ]]; then
        # we don't provide an ssh key in ci so it is created.  
        # the ssh code in the logger and gmsa configuration
        # can't find it via relative paths so 
        # give it the absolute path
        export AZURE_SSH_PUBLIC_KEY_FILE="${PWD}"/.sshkey.pub
        export AZURE_SSH_KEY="${PWD}"/.sshkey
        # This is required as the e2e.test is run with --provider=skeleton
        export KUBE_SSH_KEY="${PWD}"/.sshkey
    fi
}

log() {
	local msg=$1
	echo "$(date -R): $msg"
}

# Fails before any Azure resources exist, so the cleanup EXIT trap is not needed.
fail_validation() {
    log "ERROR: $1"
    trap - EXIT
    exit 1
}

# all test regions must support AvailabilityZones
get_random_region() {
    # temp remove northEurope as there are capacity related issue
    local REGIONS=("australiaeast" "canadacentral" "francecentral" "germanywestcentral" "switzerlandnorth" "uksouth")
    echo "${REGIONS[${RANDOM} % ${#REGIONS[@]}]}"
}

set_ci_version() {
    # select correct windows version for tests
    if [[ "$(capz::util::should_build_kubernetes)" == "true" ]]; then
        #todo - test this
        : "${REGISTRY:?Environment variable empty or not defined.}"
        "${CAPZ_DIR}"/hack/ensure-acr-login.sh

        export E2E_ARGS="-kubetest.use-pr-artifacts"
        export KUBE_BUILD_CONFORMANCE="y"
        # shellcheck disable=SC1091
        source "${CAPZ_DIR}/scripts/ci-build-kubernetes.sh"
        # Set this AFTER ci-build-kubernetes.sh because the script will set AZURE_BLOB_CONTAINER_NAME some time in the
        # future - see https://github.com/kubernetes-sigs/cluster-api-provider-azure/pull/4172
        export AZURE_BLOB_CONTAINER_NAME="${AZURE_BLOB_CONTAINER_NAME:-${JOB_NAME}}"
    else
        if [[ "${KUBERNETES_VERSION:-}" =~ "latest" ]]; then
            CI_VERSION_URL="https://dl.k8s.io/ci/${KUBERNETES_VERSION}.txt"
        else
            CI_VERSION_URL="https://dl.k8s.io/ci/latest.txt"
        fi
        export CI_VERSION="${CI_VERSION:-$(curl -sSL "${CI_VERSION_URL}")}"
        export KUBERNETES_VERSION="${CI_VERSION}"

        log "Selected Kubernetes version:"
        log "$KUBERNETES_VERSION"

        # write metadata.json to artifacts directory
        # for testgrid to pick up the version.
        cat <<EOF >"${ARTIFACTS}/metadata.json"
{"revision":"${KUBERNETES_VERSION}"}
EOF
    fi
}

trap run_capz_e2e_cleanup EXIT
main "$@"
