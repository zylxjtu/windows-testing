# Azure CNI for CAPZ Windows Clusters

## Azure CNI Options Comparison

There is no formal "v1" vs "v2" naming from Microsoft. "v1" in the CAPZ codebase refers to the original/legacy Azure CNI (Node Subnet mode).

| | Azure CNI v1 (Node Subnet) | Azure CNI Overlay | Azure CNI Powered by Cilium |
|---|---|---|---|
| **IPAM** | Node Subnet - pods get IPs directly from the VNet subnet | Overlay - pods get IPs from a private CIDR separate from VNet | Either Node Subnet or Overlay |
| **Pod IPs** | VNet-routable (each pod gets a real VNet IP) | Private, NOT VNet-routable | Depends on IPAM mode chosen |
| **IP Planning** | Must pre-allocate IPs per node (`privateIPConfigs`) | Much more efficient - /24 per node from private CIDR | Efficient |
| **Scale** | Limited by subnet size | Up to 250 pods/node, reuse pod CIDR across clusters | Best scaling with eBPF |
| **Dataplane** | iptables/HNS | iptables/HNS | eBPF (Cilium) - most performant |
| **Network Policy** | Azure Network Policy or Calico | Azure Network Policy or Calico | Cilium (eBPF-based) |
| **Windows Support** | AKS only (not CAPZ) | AKS only | AKS only (Linux eBPF, Windows fallback) |
| **CAPZ Support** | Linux only ([CAPZ#3650](https://github.com/kubernetes-sigs/cluster-api-provider-azure/issues/3650) open for Windows) | Not supported | Not supported |

**Key differences:**
- **Azure CNI v1 (Node Subnet)**: Every pod consumes a real VNet IP. Must pre-reserve IPs on each NIC (`privateIPConfigs: 110`). IP exhaustion is the main problem at scale.
- **Azure CNI Overlay**: Solves the IP exhaustion problem. Pods use a private CIDR (e.g., `10.244.0.0/16`) instead of VNet IPs. Recommended for most new AKS clusters.
- **Azure CNI Powered by Cilium**: Uses eBPF instead of iptables for the dataplane. Better performance and scalability. Can use either Node Subnet or Overlay for IPAM.

References:
- [Azure CNI Networking Overview](https://learn.microsoft.com/en-us/azure/aks/concepts-network-cni-overview)
- [Azure CNI Overlay](https://learn.microsoft.com/en-us/azure/aks/azure-cni-overlay)
- [Azure CNI Powered by Cilium](https://learn.microsoft.com/en-us/azure/aks/azure-cni-powered-by-cilium)

## Current Status

**Azure CNI v1 for Windows on CAPZ is not currently supported.**

- Open issue: [kubernetes-sigs/cluster-api-provider-azure#3650](https://github.com/kubernetes-sigs/cluster-api-provider-azure/issues/3650) - stale since 2024, no implementation.
- CAPZ has an `azure-cni-v1` flavor, but it is **Linux-only**.
- The Azure CNI installer DaemonSet targets only `kubernetes.io/os: linux` nodes.
- There is no Windows counterpart for the CNI installer.
- [CAPZ Addons documentation](https://capz.sigs.k8s.io/self-managed/addons) explicitly states: "Azure CNI v1 is only supported for Linux nodes".

## Existing CAPZ Azure CNI v1 Flavor (Linux-Only)

CAPZ already has a dedicated `azure-cni-v1` flavor for Linux clusters:

- Generated template: `templates/cluster-template-azure-cni-v1.yaml`
- Flavor directory: `templates/flavors/azure-cni-v1/` (kustomize overlay on `../default`)
- Addon manifest: `templates/addons/azure-cni-v1.yaml` (DaemonSet deploying Azure CNI binaries)
- CI test template: `templates/test/ci/cluster-template-prow-azure-cni-v1.yaml`

The Azure CNI DaemonSet installs binaries from:
```
mcr.microsoft.com/containernetworking/azure-cni:v1.5.16
```

It deploys `azure-vnet`, `azure-vnet-ipam`, `azure-vnet-telemetry` to `/opt/cni/bin/` and `10-azure.conflist` to `/etc/cni/net.d/`.

## Steps Required to Enable Azure CNI on Windows (Experimental)

### 1. AzureMachineTemplate - Add privateIPConfigs

Add `networkInterfaces` with `privateIPConfigs` to pre-allocate Azure VNet IPs for pods:

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureMachineTemplate
metadata:
  name: ${CLUSTER_NAME}-md-win
spec:
  template:
    spec:
      networkInterfaces:
      - subnetName: node-subnet
        privateIPConfigs: 110  # must match max-pods
```

### 2. KubeadmConfigTemplate - Set max-pods

```yaml
kubeletExtraArgs:
  max-pods: "110"
```

The `max-pods` value must match `privateIPConfigs`.

### 3. Windows Azure CNI Installer

A HostProcess container or script is needed to install:
- `azure-vnet.exe`
- `azure-vnet-ipam.exe`
- `10-azure.conflist` configuration

**This does not exist publicly.** AKS handles it internally through its own node provisioning process, not via a DaemonSet.

### 4. Remove Calico Configuration

- Remove `defender-exclude-calico.ps1` from templates
- Remove Calico Helm chart installation from `run-capz-e2e.sh`
- Remove IPAM strict affinity patch (`kubectl patch ipamconfigs default --type merge --patch='{"spec": {"strictAffinity": true}}'`)
- Remove kube-proxy-windows deployment
- Remove `CALICO_VERSION` from `env.sh`
- Remove or repurpose `templates/calico/values.yaml`

### 5. Keep Existing Settings

- `allocate-node-cidrs: "false"` in controller manager (already set) - correct because Azure CNI handles IP allocation
- `cloud-provider: external` (already set)

## Current Setup (for reference)

| Setting | Value |
|---------|-------|
| CNI | Calico v3.31.0 (Tigera Operator) |
| Pod CIDR | 192.168.0.0/16 |
| Encapsulation | VXLAN |
| Windows Dataplane | HNS |
| MTU | 1350 |
| Management Cluster CNI | Azure CNI (`--network-plugin azure`) |

### Key files

- `capz/env.sh` - `CALICO_VERSION` environment variable
- `capz/templates/calico/values.yaml` - Calico Helm values
- `capz/templates/windows-base.yaml` - Base Windows node template
- `capz/run-capz-e2e.sh` - Calico installation logic

## Known Limitations

- Only one subnet per control-plane node ([CAPZ#3506](https://github.com/kubernetes-sigs/cluster-api-provider-azure/issues/3506))
- Only one network interface per worker node ([azure-container-networking#1945](https://github.com/Azure/azure-container-networking/issues/1945)) - multi-NIC causes "Failed to find the master interface" errors

## Related Issues and PRs

- [CAPZ#3650](https://github.com/kubernetes-sigs/cluster-api-provider-azure/issues/3650) - Enable Azure CNI v1 for Windows node (open, stale)
- [CAPZ#3651](https://github.com/kubernetes-sigs/cluster-api-provider-azure/issues/3651) - Add azure cni specific network policies to azure cni e2e tests (open)
- [CAPZ#4522](https://github.com/kubernetes-sigs/cluster-api-provider-azure/pull/4522) - Add support for Azure CNI Powered by Cilium (AKS managed clusters only)
- [CAPZ#3508](https://github.com/kubernetes-sigs/cluster-api-provider-azure/pull/3508) - Add azure cni e2e tests with one NIC per linux node

## Reference: How AKS Sets Up Azure CNI on Windows (AgentBaker)

Source: [Azure/AgentBaker](https://github.com/Azure/AgentBaker)

AKS uses a **two-phase approach** for Windows Azure CNI setup:

### Phase 1: VHD Build Time (Packer)

Azure CNI zip packages are **pre-cached** on the Windows VHD at `c:\akse-cache\win-vnet-cni\`.

- Defined in `parts/common/components.json` with multiple versions (e.g., v1.5.38, v1.6.21)
- Download URL: `https://packages.aks.azure.com/azure-cni/v${version}/binaries/azure-vnet-cni-windows-amd64-v${version}.zip`
- Fallback URL: `https://acs-mirror.azureedge.net/azure-cni/v${version}/binaries/...`

### Phase 2: Node Provisioning (Custom Script Extension)

The CSE runs `kuberneteswindowssetup.ps1` which performs two stages:

#### BasePrep: Install containerd with CNI paths

Containerd config (`staging/cse/windows/containerdtemplate.toml`) is configured with:
```toml
[plugins.cri.cni]
  bin_dir = "c:/k/azurecni/bin"
  conf_dir = "c:/k/azurecni/netconf"
```

Path selection logic (`kuberneteswindowssetup.ps1`):
```powershell
$cniBinPath = $global:AzureCNIBinDir       # c:\k\azurecni\bin (for "azure" plugin)
$cniConfigPath = $global:AzureCNIConfDir    # c:\k\azurecni\netconf
if ($global:NetworkPlugin -eq "kubenet") {
    $cniBinPath = $global:CNIPath           # c:\k\cni
    $cniConfigPath = $global:CNIConfigPath  # c:\k\cni\config
}
```

#### NodePrep: Install and configure CNI

**Step 1 - `Install-VnetPlugins`** (`staging/cse/windows/azurecnifunc.ps1`):
```powershell
function Install-VnetPlugins {
    # Create directories: c:\k\azurecni\bin and c:\k\azurecni\netconf
    Create-Directory -FullPath $AzureCNIBinDir
    Create-Directory -FullPath $AzureCNIConfDir

    # Download from VHD cache (or network fallback)
    $zipfile = [Io.path]::Combine("$AzureCNIDir", "azure-vnet.zip")
    DownloadFileOverHttp -Url $VNetCNIPluginsURL -DestinationPath $zipfile
    AKS-Expand-Archive -path $zipfile -DestinationPath $AzureCNIBinDir
    del $zipfile

    # Move conflist from bin to netconf directory
    move $AzureCNIBinDir/*.conflist $AzureCNIConfDir
}
```

Installed binaries:
- `c:\k\azurecni\bin\azure-vnet.exe`
- `c:\k\azurecni\bin\azure-vnet-ipam.exe`
- `c:\k\azurecni\bin\azure-vnet-telemetry.exe`
- `c:\k\azurecni\bin\azure-cns.exe`
- `c:\k\azurecni\bin\AzureNetworkContainer.exe`

**Step 2 - `Set-AzureCNIConfig`** (`staging/cse/windows/azurecnifunc.ps1`):

Loads `c:\k\azurecni\netconf\10-azure.conflist` and patches it in-place:
- DNS nameserver and search path
- OutBoundNAT exception lists (pod CIDR, VNet CIDR)
- WinDSR support (if enabled)
- IMDS restriction ACLs (block 169.254.169.254:80)
- Wire Server ACLs (block 168.63.129.16 on ports 80, 32526)
- Cilium/overlay mode (`azure-cns` IPAM type, if enabled)

Also sets HNS registry key and restarts HNS:
```powershell
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\hns\State" `
    -Name SDNRemoteArpMacAddress -Value "12-34-56-78-9a-bc"
```

**Step 3 - `New-ExternalHnsNetwork`**:
```powershell
New-HNSNetwork -Type $global:NetworkMode -AddressPrefix "192.168.255.0/30" `
    -Gateway "192.168.255.1" -AdapterName $adapterName -Name "ext"
```

**Step 4 - Disable firewall**:
```powershell
netsh advfirewall set allprofiles state off
```

### On Node Restart

A scheduled task runs `cleanupnetwork.ps1` which:
```powershell
# Kill stale CNI processes
taskkill /IM azure-vnet.exe /f
taskkill /IM azure-vnet-ipam.exe /f

# Remove stale state files
$filesToRemove = @(
    "c:\k\azure-vnet.json",
    "c:\k\azure-vnet.json.lock",
    "c:\k\azure-vnet-ipam.json",
    "c:\k\azure-vnet-ipam.json.lock",
    "c:\windows\system32\azure-vnet.json",        # containerd bug workaround
    "c:\windows\system32\azure-vnet-ipam.json",
    # ... plus ipv6 variants
)
```

Then recreates the HNS network and starts kubelet.

### Windows Defender Exclusions

```powershell
Add-MpPreference -ExclusionProcess "C:\k\azurecni\bin\azure-cns.exe"
Add-MpPreference -ExclusionProcess "C:\k\azurecni\bin\azure-vnet-ipam.exe"
Add-MpPreference -ExclusionProcess "C:\k\azurecni\bin\azure-vnet-ipamv6.exe"
Add-MpPreference -ExclusionProcess "C:\k\azurecni\bin\azure-vnet-telemetry.exe"
Add-MpPreference -ExclusionProcess "C:\k\azurecni\bin\azure-vnet.exe"
Add-MpPreference -ExclusionProcess "C:\k\azurecni\bin\AzureNetworkContainer.exe"
Add-MpPreference -ExclusionProcess "C:\k\azurecni\bin\CnsWrapperService.exe"
```

### Key AgentBaker Files

| File | Purpose |
|------|---------|
| `parts/common/components.json` | Defines CNI versions and download URLs |
| `parts/windows/kuberneteswindowssetup.ps1` | Main bootstrapping script (Go template) |
| `staging/cse/windows/azurecnifunc.ps1` | `Install-VnetPlugins`, `Set-AzureCNIConfig`, `New-ExternalHnsNetwork` |
| `staging/cse/windows/containerdtemplate.toml` | Containerd config with CNI path placeholders |
| `staging/cse/windows/containerdfunc.ps1` | Replaces CNI path placeholders in containerd config |
| `staging/cse/windows/provisioningscripts/cleanupnetwork.ps1` | Node restart CNI cleanup |
| `staging/cse/windows/kubernetesfunc.ps1` | Defender exclusions (`Update-DefenderPreferences`) |
| `parts/windows/windowscsehelper.ps1` | `DownloadFileOverHttp` with VHD cache check |
| `vhdbuilder/packer/windows/configure-windows-vhd.ps1` | VHD build-time package caching |

### Directory Layout on Windows Node

```
c:\k\azurecni\
  bin\
    azure-vnet.exe
    azure-vnet-ipam.exe
    azure-vnet-telemetry.exe
    azure-cns.exe
    AzureNetworkContainer.exe
    CnsWrapperService.exe
  netconf\
    10-azure.conflist

c:\akse-cache\win-vnet-cni\          (VHD cache, multiple versions)
  azure-vnet-cni-windows-amd64-v1.5.38.zip
  azure-vnet-cni-windows-amd64-v1.6.21.zip
```

## Alternatives

1. **Use AKS** - Azure CNI on Windows is natively supported in AKS managed clusters.
2. **Custom HostProcess container** - Build a Windows HostProcess container to install Azure CNI binaries (experimental, unsupported).
3. **Stay with Calico** - Officially supported CNI for Windows on CAPZ.
