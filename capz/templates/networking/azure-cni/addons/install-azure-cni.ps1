# Installs classic Azure CNI on a Windows node from the pinned azure-cni image.
# Runs in a HostProcess init container and exits non-zero on any failure so the
# DaemonSet pod never becomes Ready with a partial installation.
#
# The functions can be dot-sourced for testing without running the installer.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:AzureCniBinaries = @('azure-vnet.exe', 'azure-vnet-ipam.exe', 'azure-vnet-telemetry.exe')
$script:AzureCniConflistName = '10-azure.conflist'
$script:AzureWireServer = '168.63.129.16'

function Write-Log {
    param([string]$Message)
    Write-Host "$(Get-Date -Format o) $Message"
}

function Get-RequiredEnv {
    param([Parameter(Mandatory)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable $Name is not set"
    }
    return $value.Trim()
}

function ConvertFrom-TomlString {
    param([Parameter(Mandatory)][string]$Value)
    $inner = $Value.Substring(1, $Value.Length - 2)
    if ($Value.StartsWith("'")) {
        return $inner
    }
    return $inner.Replace('\\', '\')
}

# Returns the CNI binary and configuration directories that containerd's CRI plugin uses.
# Supports config v2 (containerd 1.x, bin_dir) and v3 (containerd 2.x, bin_dir or bin_dirs).
function Get-ContainerdCniDirectories {
    param([Parameter(Mandatory)][string]$ConfigContent)

    $sectionPattern = '(?ms)^[ \t]*\[plugins\.(?:"io\.containerd\.cri\.v1\.runtime"|''io\.containerd\.cri\.v1\.runtime''|"io\.containerd\.grpc\.v1\.cri"|''io\.containerd\.grpc\.v1\.cri'')\.cni\][ \t]*(?:#[^\r\n]*)?\r?\n(.*?)(?=^[ \t]*\[|\z)'
    $section = [regex]::Match($ConfigContent, $sectionPattern)
    if (-not $section.Success) {
        throw 'Could not locate the containerd CRI CNI section in config.toml'
    }
    $body = $section.Groups[1].Value
    $quoted = '("[^"\r\n]*"|''[^''\r\n]*'')'

    $binDir = $null
    $binDirs = [regex]::Match($body, "(?m)^[ \t]*bin_dirs[ \t]*=[ \t]*\[\s*$quoted")
    if ($binDirs.Success) {
        $binDir = ConvertFrom-TomlString $binDirs.Groups[1].Value
    } else {
        $singleBinDir = [regex]::Match($body, "(?m)^[ \t]*bin_dir[ \t]*=[ \t]*$quoted")
        if ($singleBinDir.Success) {
            $binDir = ConvertFrom-TomlString $singleBinDir.Groups[1].Value
        }
    }
    if ([string]::IsNullOrWhiteSpace($binDir)) {
        throw 'containerd config.toml does not set bin_dir or bin_dirs for the CRI CNI plugin'
    }

    $confDirMatch = [regex]::Match($body, "(?m)^[ \t]*conf_dir[ \t]*=[ \t]*$quoted")
    if (-not $confDirMatch.Success) {
        throw 'containerd config.toml does not set conf_dir for the CRI CNI plugin'
    }
    $confDir = ConvertFrom-TomlString $confDirMatch.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($confDir)) {
        throw 'containerd config.toml sets an empty conf_dir for the CRI CNI plugin'
    }

    return [pscustomobject]@{
        BinDir  = $binDir
        ConfDir = $confDir
    }
}

function New-EndpointPolicy {
    param([Parameter(Mandatory)][hashtable]$Value)
    return [pscustomobject]@{
        Name  = 'EndpointPolicy'
        Value = [pscustomobject]$Value
    }
}

# Renders the conflist shipped in the Azure CNI image the same way AKS configures
# classic Azure CNI on Windows (staging/cse/windows/azurecnifunc.ps1 in AgentBaker).
function New-AzureCniConflist {
    param(
        [Parameter(Mandatory)][string]$TemplateJson,
        [Parameter(Mandatory)][string]$DnsServiceIP,
        [Parameter(Mandatory)][string]$DnsSearch,
        [Parameter(Mandatory)][string[]]$OutboundNatExceptions,
        [Parameter(Mandatory)][string]$ServiceCidr,
        [Parameter(Mandatory)][bool]$EnableDsr
    )

    $config = $TemplateJson | ConvertFrom-Json
    $plugin = @($config.plugins)[0]
    if ($plugin.type -ne 'azure-vnet') {
        throw "Unexpected first CNI plugin type '$($plugin.type)' in the Azure CNI conflist template"
    }

    $plugin.dns.Nameservers = @($DnsServiceIP, $script:AzureWireServer)
    $plugin.dns.Search = @($DnsSearch)

    $policies = New-Object System.Collections.ArrayList
    [void]$policies.Add((New-EndpointPolicy @{ Type = 'OutBoundNAT'; ExceptionList = @($OutboundNatExceptions) }))
    if ($EnableDsr) {
        # kube-proxy runs with --enable-dsr, which replaces the service ROUTE policy with loopback DSR.
        $plugin | Add-Member -NotePropertyName windowsSettings -NotePropertyValue ([pscustomobject]@{ enableLoopbackDSR = $true }) -Force
    } else {
        [void]$policies.Add((New-EndpointPolicy @{ Type = 'ROUTE'; DestinationPrefix = $ServiceCidr; NeedEncap = $true }))
    }
    # Block pod access to the Azure WireServer endpoints, then allow all other traffic.
    foreach ($port in @('80', '32526')) {
        [void]$policies.Add((New-EndpointPolicy @{
                    Type            = 'ACL'
                    Protocols       = '6'
                    Action          = 'Block'
                    Direction       = 'Out'
                    RemoteAddresses = "$($script:AzureWireServer)/32"
                    RemotePorts     = $port
                    Priority        = 200
                    RuleType        = 'Switch'
                }))
    }
    foreach ($direction in @('In', 'Out')) {
        [void]$policies.Add((New-EndpointPolicy @{ Type = 'ACL'; Action = 'Allow'; Direction = $direction; Priority = 65500 }))
    }
    $plugin.AdditionalArgs = $policies.ToArray()

    return ($config | ConvertTo-Json -Depth 20)
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

function Write-FileAtomically {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    # containerd only loads .conf, .conflist, and .json files, so the temporary file is ignored.
    $temporaryPath = "$Path.tmp"
    [IO.File]::WriteAllText($temporaryPath, $Content, (New-Object Text.UTF8Encoding $false))
    Move-Item -Path $temporaryPath -Destination $Path -Force
}

function Add-AzureCniDefenderExclusions {
    param([Parameter(Mandatory)][string[]]$Processes)
    $defender = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
    if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue) -or -not $defender -or $defender.Status -ne 'Running') {
        Write-Log 'Microsoft Defender is not running; skipping Azure CNI process exclusions'
        return
    }
    Add-MpPreference -ExclusionProcess $Processes
    Write-Log "Added Microsoft Defender process exclusions: $($Processes -join ', ')"
}

# Azure CNI writes its logs relative to the plugin's working directory. containerd runs as a
# Windows service on CAPZ nodes, so the plugin inherits System32 as its working directory.
function Publish-AzureCniLogs {
    param([Parameter(Mandatory)][string]$LogDirectory)
    $pluginWorkingDirectory = Join-Path $env:SystemRoot 'System32'
    foreach ($name in @('azure-vnet.log', 'azure-vnet-ipam.log')) {
        $link = Join-Path $LogDirectory $name
        $target = Join-Path $pluginWorkingDirectory $name
        if (Test-Path -LiteralPath $link) {
            Write-Log "$link already exists; leaving it unchanged"
            continue
        }
        $output = cmd.exe /c mklink "$link" "$target" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to link $link to $($target): $output"
        }
        Write-Log "Linked $link to $target"
    }
}

function Invoke-AzureCniInstall {
    $sandbox = Get-RequiredEnv 'CONTAINER_SANDBOX_MOUNT_POINT'
    $image = Get-RequiredEnv 'AZURE_CNI_IMAGE'
    $dnsServiceIP = Get-RequiredEnv 'AZURE_CNI_DNS_SERVICE_IP'
    $dnsSearch = Get-RequiredEnv 'AZURE_CNI_DNS_SEARCH'
    $serviceCidr = Get-RequiredEnv 'AZURE_CNI_SERVICE_CIDR'
    $enableDsr = [bool]::Parse((Get-RequiredEnv 'AZURE_CNI_ENABLE_DSR'))
    $exceptions = @((Get-RequiredEnv 'AZURE_CNI_OUTBOUNDNAT_EXCEPTIONS') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($exceptions.Count -eq 0) {
        throw 'AZURE_CNI_OUTBOUNDNAT_EXCEPTIONS does not contain any CIDR'
    }

    $dropgz = Join-Path $sandbox 'dropgz.exe'
    if (-not (Test-Path -LiteralPath $dropgz)) {
        throw "dropgz.exe was not found in the Azure CNI image at $dropgz"
    }

    $containerdConfig = Join-Path $env:ProgramFiles 'containerd\config.toml'
    if (-not (Test-Path -LiteralPath $containerdConfig)) {
        throw "containerd configuration was not found at $containerdConfig"
    }
    $directories = Get-ContainerdCniDirectories ([IO.File]::ReadAllText($containerdConfig))
    $binDir = [IO.Path]::GetFullPath($directories.BinDir)
    $confDir = [IO.Path]::GetFullPath($directories.ConfDir)
    $logDir = Join-Path $env:SystemDrive 'k'
    $stateDir = Join-Path $logDir 'azurecni'
    Write-Log "Installing $image"
    Write-Log "containerd CNI bin dir: $binDir; conf dir: $confDir"
    New-Item -ItemType Directory -Force -Path $binDir, $confDir, $stateDir | Out-Null

    $otherConfigs = @(Get-ChildItem -LiteralPath $confDir -File | Where-Object { $_.Extension -in @('.conf', '.conflist', '.json') -and $_.Name -ne $script:AzureCniConflistName })
    if ($otherConfigs.Count -gt 0) {
        throw "Found other CNI configuration in $($confDir): $(($otherConfigs | ForEach-Object { $_.Name }) -join ', ')"
    }

    # Stop the telemetry service so its binary can be replaced, as the upstream installer does.
    Get-Process -Name 'azure-vnet-telemetry' -ErrorAction SilentlyContinue | Stop-Process -Force

    $template = Join-Path $stateDir 'azure.conflist.template'
    $deployments = [ordered]@{
        'azure-vnet'                  = Join-Path $binDir 'azure-vnet.exe'
        'azure-vnet-ipam'             = Join-Path $binDir 'azure-vnet-ipam.exe'
        'azure-vnet-telemetry'        = Join-Path $binDir 'azure-vnet-telemetry.exe'
        'azure-vnet-telemetry.config' = Join-Path $binDir 'azure-vnet-telemetry.config'
        'azure.conflist'              = $template
    }
    $deployArgs = @('deploy')
    foreach ($payload in $deployments.Keys) {
        $deployArgs += @($payload, '-o', $deployments[$payload])
    }
    # dropgz verifies every written file against the checksums embedded in the image.
    & $dropgz @deployArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dropgz deploy failed with exit code $LASTEXITCODE"
    }

    foreach ($path in $deployments.Values) {
        if (-not (Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -eq 0) {
            throw "Required Azure CNI file is missing or empty: $path"
        }
    }

    $version = (& (Join-Path $binDir 'azure-vnet.exe') -v | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($version)) {
        throw "Failed to query the azure-vnet version (exit code $LASTEXITCODE)"
    }
    Write-Log $version

    $conflist = New-AzureCniConflist -TemplateJson ([IO.File]::ReadAllText($template)) -DnsServiceIP $dnsServiceIP -DnsSearch $dnsSearch -OutboundNatExceptions $exceptions -ServiceCidr $serviceCidr -EnableDsr $enableDsr
    $conflistPath = Join-Path $confDir $script:AzureCniConflistName
    Write-FileAtomically -Path $conflistPath -Content $conflist
    $null = [IO.File]::ReadAllText($conflistPath) | ConvertFrom-Json
    Write-Log "Wrote $conflistPath"
    Write-Host $conflist

    Add-AzureCniDefenderExclusions -Processes @($script:AzureCniBinaries | ForEach-Object { Join-Path $binDir $_ })
    Publish-AzureCniLogs -LogDirectory $logDir

    $files = [ordered]@{}
    foreach ($path in @($deployments.Values) + $conflistPath) {
        $files[$path] = Get-FileSha256 $path
    }
    $installInfo = [ordered]@{
        image       = $image
        version     = $version
        binDir      = $binDir
        confDir     = $confDir
        enableDsr   = $enableDsr
        files       = $files
        installedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 5
    Write-FileAtomically -Path (Join-Path $stateDir 'install-info.json') -Content $installInfo
    Write-Host $installInfo
    Write-Log 'Azure CNI installation complete'
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-AzureCniInstall
        exit 0
    } catch {
        Write-Host "ERROR: Azure CNI installation failed: $_"
        Write-Host $_.ScriptStackTrace
        exit 1
    }
}
