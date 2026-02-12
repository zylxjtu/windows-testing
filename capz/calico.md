# Calico CNI Deployment in CAPZ Windows Testing

## Overview

Calico is deployed via the [Tigera Operator](https://docs.tigera.io/calico/charts) Helm chart during the CAPZ e2e test setup. It is the officially supported CNI for Windows on CAPZ.

## Configuration

### Environment Variable

`capz/env.sh`:
```bash
export CALICO_VERSION="v3.31.0"
```

### Helm Values (`capz/templates/calico/values.yaml`)

| Setting | Value |
|---------|-------|
| CNI type | Calico |
| BGP | Disabled |
| MTU | 1350 (VXLAN-optimized) |
| Windows Dataplane | HNS |
| IP Pool | 192.168.0.0/16 with VXLAN encapsulation |
| Service CIDR | 10.96.0.0/12 |
| Operator registry | capzcicommunity.azurecr.io |

Full values:
```yaml
installation:
  cni:
    type: Calico
  calicoNetwork:
    bgp: Disabled
    mtu: 1350
    windowsDataplane: HNS
    ipPools:
    - cidr: 192.168.0.0/16
      encapsulation: VXLAN
  serviceCIDRs:
    - 10.96.0.0/12
tigeraOperator:
  image: tigera/operator
  registry: capzcicommunity.azurecr.io
calicoctl:
  image: capzcicommunity.azurecr.io/calico/ctl
dnsConfig:
  nameservers:
    - 127.0.0.53
  options:
    - name: edns0
    - name: trust-ad
```

## Deployment Flow

The function `apply_workload_configuration()` in `capz/run-capz-e2e.sh` handles the full deployment:

### Step 1: Install Calico via Helm

```bash
helm repo add projectcalico https://docs.tigera.io/calico/charts
kubectl create ns calico-system
helm upgrade calico projectcalico/tigera-operator \
  --version "$CALICO_VERSION" \
  --namespace tigera-operator \
  -f templates/calico/values.yaml \
  --create-namespace --install
```

### Step 2: Patch IPAM for Windows (strict affinity)

```bash
kubectl patch ipamconfigs default --type merge \
  --patch='{"spec": {"strictAffinity": true}}'
```

This is required for Windows nodes. There is no way to set it via the operator - see [tigera/operator#3113](https://github.com/tigera/operator/issues/3113).

### Step 3: Create API Server Endpoint ConfigMap

A `kubernetes-services-endpoint` ConfigMap is created in the `tigera-operator` namespace with the API server host and port. This helps Calico components discover the API server.

```yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: kubernetes-services-endpoint
  namespace: tigera-operator
data:
  KUBERNETES_SERVICE_HOST: "<api-server-host>"
  KUBERNETES_SERVICE_PORT: "<api-server-port>"
```

### Step 4: Install kube-proxy for Windows

```bash
# Generate and apply kube-proxy DaemonSet
clusterctl generate yaml \
  --from templates/addons/windows/calico/kube-proxy-windows.yaml | kubectl apply -f -

# Patch to use CI binaries
kubectl apply -f templates/test/ci/patches/windows-kubeproxy-ci.yaml
kubectl rollout restart ds -n kube-system kube-proxy-windows
```

This step is skipped if `$KPNG` is set (alternative kube-proxy implementation).

### Step 5: Install additional components

```bash
# CSI proxy for Windows
kubectl apply -f templates/addons/windows/csi-proxy/csi-proxy.yaml

# Metrics server
kubectl apply -f templates/addons/metrics-server/metrics-server.yaml

# Containerd logger (if enabled)
kubectl apply -f templates/addons/windows/containerd-logging/containerd-logger.yaml
```

## Windows Node Template Integration

### Defender Exclusions

In `capz/templates/windows-base.yaml`, a PowerShell script adds Defender exclusions for Calico binaries:

```powershell
Add-MpPreference -ExclusionProcess C:/opt/cni/bin/calico.exe
Add-MpPreference -ExclusionProcess C:/opt/cni/bin/calico-ipam.exe
```

This is saved as `C:/defender-exclude-calico.ps1` and runs as a `postKubeadmCommand`:
```yaml
postKubeadmCommands:
- powershell C:/defender-exclude-calico.ps1
```

### Cluster Labels

The Cluster resource includes a CNI label:
```yaml
labels:
  cni: ${CLUSTER_NAME}-calico
```

### Controller Manager

The controller manager has `allocate-node-cidrs: "false"` because Calico handles node CIDR allocation via its own IPAM.

## Call Chain

```
main()
  → apply_workload_configuration()
      1. helm install calico (tigera-operator v3.31.0)
      2. patch ipamconfigs (strictAffinity for Windows)
      3. create kubernetes-services-endpoint ConfigMap
      4. install kube-proxy-windows DaemonSet
      5. install csi-proxy
      6. install metrics-server
      7. install containerd-logger (if enabled)
```

## Key Files

| File | Purpose |
|------|---------|
| `capz/env.sh` | `CALICO_VERSION` environment variable |
| `capz/templates/calico/values.yaml` | Calico Helm values |
| `capz/run-capz-e2e.sh` | `apply_workload_configuration()` function |
| `capz/templates/windows-base.yaml` | Defender exclusions for Calico, postKubeadmCommands |
| `capz/templates/addons/windows/calico/kube-proxy-windows.yaml` | Windows kube-proxy DaemonSet |
| `capz/templates/test/ci/patches/windows-kubeproxy-ci.yaml` | CI patch for kube-proxy |

## Building Calico for Windows ARM64

### Current Status

Calico does **not** publish Windows ARM64 container images. All Windows images are `windows/amd64` only.
However, all Calico Windows components are written in **pure Go** with `CGO_ENABLED=0`, making cross-compilation straightforward.

There are **zero** open issues or PRs in the Calico repo requesting Windows ARM64 support.

### Prerequisites

- Windows ARM64 host OS image (for CAPZ nodes)
- Windows ARM64 container base image (e.g., nanoserver ARM64)
- Go 1.25+ (supports `GOOS=windows GOARCH=arm64`)
- Docker with buildx for multi-platform image builds

### Source Repo

All work is done in the Calico monorepo: [github.com/projectcalico/calico](https://github.com/projectcalico/calico)

### Components to Build

Only the Windows node components need ARM64 builds. Linux control plane components (operator, typha, kube-controllers, BIRD) are unaffected.

| Image | Binaries | Source Directory |
|-------|----------|-----------------|
| `calico/node-windows` | `calico-node.exe` | `node/` |
| `calico/cni-windows` | `calico.exe`, `calico-ipam.exe`, `install.exe` | `cni-plugin/` |

### Step-by-Step Build Guide

#### 1. Fork and clone the Calico repo

```bash
git clone https://github.com/projectcalico/calico.git
cd calico
git checkout v3.31.0  # match the version used in env.sh
```

#### 2. Modify the build system

Edit `lib.Makefile` to parameterize `GOARCH` in `build_windows_binary`:

```makefile
# Before (hardcoded amd64):
define build_windows_binary
    $(DOCKER_RUN) \
        -e CGO_ENABLED=0 \
        -e GOARCH=amd64 \
        -e GOOS=windows \
        ...
endef

# After (parameterized):
define build_windows_binary
    $(DOCKER_RUN) \
        -e CGO_ENABLED=0 \
        -e GOARCH=$(ARCH) \
        -e GOOS=windows \
        ...
endef
```

#### 3. Cross-compile binaries for windows/arm64

```bash
# calico-node
cd node/
CGO_ENABLED=0 GOOS=windows GOARCH=arm64 go build -o bin/windows-arm64/calico-node.exe ./cmd/calico-node

# CNI plugins
cd ../cni-plugin/
CGO_ENABLED=0 GOOS=windows GOARCH=arm64 go build -o bin/windows-arm64/calico.exe ./cmd/calico
CGO_ENABLED=0 GOOS=windows GOARCH=arm64 go build -o bin/windows-arm64/calico-ipam.exe ./cmd/calico-ipam
CGO_ENABLED=0 GOOS=windows GOARCH=arm64 go build -o bin/windows-arm64/install.exe ./cmd/install
```

#### 4. Verify binaries

```bash
file bin/windows-arm64/calico-node.exe
# Should show: PE32+ executable (console) Aarch64
```

#### 5. Update Dockerfiles for ARM64

Edit `node/Dockerfile-windows`:
- Change base image to your ARM64 nanoserver base
- Update `COPY` paths to use `bin/windows-arm64/` for ARM64 builds
- Add `--platform=windows/arm64` build arg

Edit `cni-plugin/Dockerfile-windows` with the same changes.

PowerShell scripts in `node/windows-packaging/` are architecture-independent (no changes needed):
- `host-process-install.ps1`
- `install-calico-windows.ps1`
- `felix-service.ps1`
- `node-service.ps1`

#### 6. Build container images

```bash
# calico/node-windows ARM64
docker buildx build --platform windows/arm64 \
  -f node/Dockerfile-windows \
  -t your-registry/calico/node-windows:v3.31.0-arm64 \
  --build-arg WINDOWS_VERSION=ltsc2025 .

# calico/cni-windows ARM64
docker buildx build --platform windows/arm64 \
  -f cni-plugin/Dockerfile-windows \
  -t your-registry/calico/cni-windows:v3.31.0-arm64 \
  --build-arg WINDOWS_VERSION=ltsc2025 .
```

#### 7. Push to your registry

```bash
docker push your-registry/calico/node-windows:v3.31.0-arm64
docker push your-registry/calico/cni-windows:v3.31.0-arm64
```

#### 8. Deploy with custom images

Update `capz/templates/calico/values.yaml` to reference your ARM64 images, or override via Helm `--set` values during installation.

### Key Source Files in Calico Repo

| File | Purpose |
|------|---------|
| `lib.Makefile` | `build_windows_binary` function (hardcodes `GOARCH=amd64`) |
| `node/Makefile` | `image-windows` target for calico-node-windows |
| `cni-plugin/Makefile` | `image-windows` target for calico-cni-windows |
| `node/Dockerfile-windows` | Dockerfile for calico/node-windows (nanoserver base) |
| `cni-plugin/Dockerfile-windows` | Dockerfile for calico/cni-windows |
| `felix/dataplane/windows/` | Felix Windows dataplane (HNS/HCN API bindings, pure Go) |
| `node/windows-packaging/` | PowerShell scripts for HostProcess container deployment |

### Deployment Model

This repo uses the **Tigera Operator + HostProcess containers** model:
- Calico runs as HostProcess DaemonSet pods managed by Kubernetes
- The container runtime (containerd) manages the lifecycle
- No `nssm.exe` or native Windows service manager is needed
- `nssm.exe` is only used in the legacy ZIP-based manual installation path

### Testing Checklist

- [ ] Calico node agent starts and registers with the API server
- [ ] Felix Windows dataplane initializes (HNS/HCN APIs work on ARM64)
- [ ] CNI plugin is invoked correctly by containerd
- [ ] Pods get IP addresses from Calico IPAM
- [ ] Pod-to-pod connectivity works (VXLAN overlay)
- [ ] Network policies are enforced via HNS ACLs
- [ ] Node restart recovery works correctly
