# Collects Azure CNI, containerd CNI, and HNS diagnostics from a Windows node.
# Runs through kubectl exec in a HostProcess container, so it does not depend on pod networking.
# The last line is a machine-readable summary used by run-capz-e2e.sh.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Write-Section {
    param([string]$Title, [scriptblock]$Body)
    Write-Output ''
    Write-Output "===== $Title ====="
    try {
        & $Body 2>&1 | Out-String -Width 4096 | Write-Output
    } catch {
        Write-Output "ERROR: $_"
    }
}

function Get-RegularFile {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and -not $item.LinkType) {
        return $item
    }
    return $null
}

$installInfoPath = 'C:\k\azurecni\install-info.json'
$installInfo = $null
if (Test-Path -LiteralPath $installInfoPath) {
    $installInfo = Get-Content -Raw -LiteralPath $installInfoPath | ConvertFrom-Json
}
$binDir = if ($installInfo) { $installInfo.binDir } else { 'C:\opt\cni\bin' }
$confDir = if ($installInfo) { $installInfo.confDir } else { 'C:\etc\cni\net.d' }
$containerdConfig = Join-Path $env:ProgramFiles 'containerd\config.toml'
# Azure CNI writes logs and state relative to containerd's working directory (System32 for a
# Windows service); the installer links the logs into C:\k.
$cniFileDirectories = @('C:\k', (Join-Path $env:SystemRoot 'System32'))

Write-Section 'node' { $env:COMPUTERNAME; Get-Date -Format o; [Environment]::OSVersion.VersionString }
Write-Section 'Azure CNI install info' { if ($installInfo) { Get-Content -Raw -LiteralPath $installInfoPath } else { "missing: $installInfoPath" } }
Write-Section 'containerd version' { & (Join-Path $env:ProgramFiles 'containerd\containerd.exe') --version }
Write-Section "containerd config ($containerdConfig)" { Get-Content -Raw -LiteralPath $containerdConfig }
Write-Section "CNI binaries ($binDir)" {
    Get-ChildItem -LiteralPath $binDir -Force | Select-Object Name, Length, LastWriteTime, @{ Name = 'SHA256'; Expression = { if (-not $_.PSIsContainer) { (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash } } } | Format-Table -AutoSize
    $azureVnet = Join-Path $binDir 'azure-vnet.exe'
    if (Test-Path -LiteralPath $azureVnet) { & $azureVnet -v }
}
Write-Section "CNI configuration ($confDir)" {
    Get-ChildItem -LiteralPath $confDir -Force | ForEach-Object {
        "--- $($_.FullName)"
        Get-Content -Raw -LiteralPath $_.FullName
    }
}
Write-Section 'HNS registry state' { Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\hns\State' }
Write-Section 'Get-HnsNetwork' { Get-HnsNetwork | ConvertTo-Json -Depth 20 }
Write-Section 'Get-HnsEndpoint' { Get-HnsEndpoint | ConvertTo-Json -Depth 20 }
Write-Section 'Get-HnsPolicyList' { Get-HnsPolicyList | ConvertTo-Json -Depth 20 }
Write-Section 'network adapters and IPv4 addresses' {
    Get-NetAdapter | Format-Table -AutoSize Name, InterfaceDescription, ifIndex, Status, MacAddress
    Get-NetIPAddress -AddressFamily IPv4 | Format-Table -AutoSize InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin
    route.exe print -4
}
foreach ($directory in $cniFileDirectories) {
    foreach ($name in @('azure-vnet.json', 'azure-vnet-ipam.json')) {
        $file = Get-RegularFile (Join-Path $directory $name)
        if ($file) { Write-Section "Azure CNI state $($file.FullName)" { Get-Content -Raw -LiteralPath $file.FullName } }
    }
    foreach ($name in @('azure-vnet.log', 'azure-vnet-ipam.log', 'azure-vnet-telemetry.log')) {
        $file = Get-RegularFile (Join-Path $directory $name)
        if ($file) { Write-Section "Azure CNI log $($file.FullName) (last 5000 lines)" { Get-Content -LiteralPath $file.FullName -Tail 5000 } }
    }
}
Write-Section 'containerd CNI and sandbox log lines (last 500)' {
    $log = 'C:\var\log\containerd\containerd.log'
    if (Test-Path -LiteralPath $log) { Select-String -LiteralPath $log -Pattern 'cni|network|sandbox' | Select-Object -Last 500 | ForEach-Object { $_.Line } } else { "missing: $log" }
}
foreach ($logName in @('Microsoft-Windows-Host-Network-Service-Admin', 'Microsoft-Windows-Host-Network-Service-Operational', 'Microsoft-Windows-Hyper-V-VmSwitch-Operational')) {
    Write-Section "event log $logName (last 200)" {
        Get-WinEvent -LogName $logName -MaxEvents 200 -ErrorAction Stop | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap -AutoSize
    }
}

$networks = @(Get-HnsNetwork -ErrorAction SilentlyContinue)
$endpoints = @(Get-HnsEndpoint -ErrorAction SilentlyContinue)
function Get-LogErrorCount {
    param([string]$Name)
    $count = 0
    foreach ($directory in $cniFileDirectories) {
        $file = Get-RegularFile (Join-Path $directory $Name)
        if ($file) { $count += @(Select-String -LiteralPath $file.FullName -Pattern '"level":"error"|\[error\]|failed' -ErrorAction SilentlyContinue).Count }
    }
    return $count
}
$summary = [ordered]@{
    node                = $env:COMPUTERNAME
    azureCniVersion     = if ($installInfo) { $installInfo.version } else { $null }
    binariesPresent     = -not (@('azure-vnet.exe', 'azure-vnet-ipam.exe', 'azure-vnet-telemetry.exe') | Where-Object { -not (Test-Path -LiteralPath (Join-Path $binDir $_)) })
    conflistPresent     = Test-Path -LiteralPath (Join-Path $confDir '10-azure.conflist')
    sdnRemoteArpMac     = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\hns\State' -ErrorAction SilentlyContinue).SDNRemoteArpMacAddress
    hnsNetworks         = @($networks | ForEach-Object { "$($_.Name):$($_.Type)" })
    azureNetworkCreated = [bool]($networks | Where-Object { $_.Name -eq 'azure' })
    localEndpoints      = @($endpoints | Where-Object { -not $_.IsRemoteEndpoint }).Count
    remoteEndpoints     = @($endpoints | Where-Object { $_.IsRemoteEndpoint }).Count
    policyLists         = @(Get-HnsPolicyList -ErrorAction SilentlyContinue).Count
    vnetLogErrors       = Get-LogErrorCount 'azure-vnet.log'
    ipamLogErrors       = Get-LogErrorCount 'azure-vnet-ipam.log'
}
Write-Output ''
Write-Output ('AZURE_CNI_NODE_SUMMARY ' + ($summary | ConvertTo-Json -Compress -Depth 5))
