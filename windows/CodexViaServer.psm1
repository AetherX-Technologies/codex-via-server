Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ClientVersion = "0.2.0-dev.1"

function Test-CvsDeviceId {
    param([Parameter(Mandatory)][string]$DeviceId)
    return $DeviceId -cmatch '^[a-z0-9][a-z0-9._-]{1,62}[a-z0-9]$'
}

function Test-CvsVersionAtLeast {
    param([Parameter(Mandatory)][string]$Current, [Parameter(Mandatory)][string]$Minimum)
    $currentCore = ($Current -split '-', 2)[0]
    $minimumCore = ($Minimum -split '-', 2)[0]
    return ([version]$currentCore -ge [version]$minimumCore)
}

function Get-CvsRoot {
    if ($env:CODEX_VIA_SERVER_HOME) { return $env:CODEX_VIA_SERVER_HOME }
    return Join-Path $HOME ".codex-via-server"
}

function Get-CvsKeyDirectory {
    if ($env:CODEX_VIA_SERVER_KEY_DIR) { return $env:CODEX_VIA_SERVER_KEY_DIR }
    return Join-Path (Get-CvsRoot) "keys"
}

function Get-CvsConfigDirectory {
    return Join-Path (Get-CvsRoot) "config"
}

function Get-CvsStateDirectory {
    return Join-Path (Get-CvsRoot) "state"
}

function Set-CvsPrivateAcl {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsWindows) { return }
    & icacls.exe $Path /inheritance:r /grant:r "${env:USERNAME}:(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to restrict ACL: $Path" }
}

function Assert-CvsSafeOutputPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [System.IO.Path]::IsPathFullyQualified($Path)) { throw "Output path must be absolute" }
    if (Test-Path $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.LinkType) { throw "Output path must not be a symbolic link" }
        if ($item.PSIsContainer) { throw "Output path must be a file" }
    }
}

function Initialize-CvsDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DeviceId,
        [Parameter(Mandatory)][string]$OutputPath
    )
    if (-not (Test-CvsDeviceId $DeviceId)) { throw "Invalid device id" }
    Assert-CvsSafeOutputPath $OutputPath

    $keyDirectory = Get-CvsKeyDirectory
    New-Item -ItemType Directory -Force -Path $keyDirectory | Out-Null
    $privateKey = Join-Path $keyDirectory $DeviceId
    $publicKey = "${privateKey}.pub"
    if ((Test-Path $privateKey) -xor (Test-Path $publicKey)) { throw "Existing key pair is incomplete" }
    foreach ($keyPath in @($privateKey, $publicKey)) {
        if (Test-Path $keyPath) {
            $keyItem = Get-Item -LiteralPath $keyPath -Force
            if ($keyItem.LinkType) { throw "Key path must not be a symbolic link" }
        }
    }
    if (-not (Test-Path $privateKey)) {
        & ssh-keygen.exe -q -t ed25519 -N "" -C $DeviceId -f $privateKey
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed" }
    }
    Set-CvsPrivateAcl $privateKey

    $publicKeyText = (Get-Content -LiteralPath $publicKey -Raw).Trim()
    if ($publicKeyText -cnotmatch "^ssh-ed25519 [A-Za-z0-9+/]+=* $([regex]::Escape($DeviceId))$") {
        throw "Public key has an unexpected shape"
    }
    $outputDirectory = Split-Path -Parent $OutputPath
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    $request = [ordered]@{
        schema_version = 1
        device_id = $DeviceId
        platform = "windows"
        public_key = $publicKeyText
        requested_at = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    $request | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
    Set-CvsPrivateAcl $OutputPath
    return $OutputPath
}

function Assert-CvsConnectionProfile {
    param([Parameter(Mandatory)]$Profile)
    $topFields = @($Profile.PSObject.Properties.Name | Sort-Object)
    $expected = @("approved_device", "client", "gateway", "issued_at", "profile_id", "schema_version", "server")
    if (Compare-Object $topFields $expected) { throw "Connection profile fields are invalid" }
    if (Compare-Object @($Profile.server.PSObject.Properties.Name | Sort-Object) @("host", "host_fingerprints", "ssh_port", "ssh_user")) { throw "Server fields are invalid" }
    if (Compare-Object @($Profile.gateway.PSObject.Properties.Name | Sort-Object) @("remote_host", "remote_port")) { throw "Gateway fields are invalid" }
    if (Compare-Object @($Profile.client.PSObject.Properties.Name | Sort-Object) @("codex_profile", "local_port", "minimum_client_version", "minimum_codex_version")) { throw "Client fields are invalid" }
    if (Compare-Object @($Profile.approved_device.PSObject.Properties.Name | Sort-Object) @("device_id", "public_key_fingerprint")) { throw "Approved device fields are invalid" }
    if ($Profile.schema_version -ne 1) { throw "Unsupported connection profile schema" }
    if (-not (Test-CvsDeviceId ([string]$Profile.approved_device.device_id))) { throw "Invalid approved device id" }
    if ($Profile.server.ssh_user -cne "codex-tunnel") { throw "Invalid tunnel user" }
    if ([int]$Profile.server.ssh_port -lt 1 -or [int]$Profile.server.ssh_port -gt 65535) { throw "Invalid SSH port" }
    if ($Profile.gateway.remote_host -cne "127.0.0.1") { throw "Invalid gateway host" }
    if ([int]$Profile.gateway.remote_port -lt 1024 -or [int]$Profile.gateway.remote_port -gt 65535) { throw "Invalid gateway port" }
    if ([int]$Profile.client.local_port -lt 1024 -or [int]$Profile.client.local_port -gt 65535) { throw "Invalid local port" }
    if ($Profile.server.host -cnotmatch '^(100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}|[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?){1,6})$') { throw "Invalid server host" }
    if ($Profile.client.codex_profile -cnotmatch '^[A-Za-z0-9_-]{3,64}$') { throw "Invalid Codex profile" }
    if (-not (Test-CvsVersionAtLeast $script:ClientVersion ([string]$Profile.client.minimum_client_version))) { throw "Client is too old" }
    foreach ($fingerprint in $Profile.server.host_fingerprints) {
        if ($fingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$') { throw "Invalid host fingerprint" }
    }
    if ([string]$Profile.approved_device.public_key_fingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$') { throw "Invalid device fingerprint" }
}

function Import-CvsConnectionProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType -or $item.PSIsContainer) { throw "Profile must be a regular file" }
    $profile = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    Assert-CvsConnectionProfile $profile

    $deviceId = [string]$profile.approved_device.device_id
    $keyDirectory = Get-CvsKeyDirectory
    $privateKey = Join-Path $keyDirectory $deviceId
    $publicKey = "${privateKey}.pub"
    if (-not (Test-Path $privateKey) -or -not (Test-Path $publicKey)) { throw "Approved device key pair is missing" }
    $fingerprintOutput = & ssh-keygen.exe -lf $publicKey -E sha256
    if ($LASTEXITCODE -ne 0) { throw "Cannot fingerprint device key" }
    $actualFingerprint = ($fingerprintOutput -split '\s+')[1]
    if ($actualFingerprint -cne [string]$profile.approved_device.public_key_fingerprint) { throw "Approved device fingerprint does not match" }

    $configDirectory = Get-CvsConfigDirectory
    New-Item -ItemType Directory -Force -Path $configDirectory | Out-Null
    $connectionTarget = Join-Path $configDirectory "connection-profile.json"
    Copy-Item -LiteralPath $Path -Destination $connectionTarget -Force
    Set-CvsPrivateAcl $connectionTarget

    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path (Get-CvsRoot) ".codex" }
    New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
    $codexTarget = Join-Path $codexHome "$($profile.client.codex_profile).config.toml"
    $toml = @"
model_provider = "server_cliproxy"

[model_providers.server_cliproxy]
name = "CLIProxyAPI through a restricted SSH tunnel"
base_url = "http://127.0.0.1:$($profile.client.local_port)/v1"
wire_api = "responses"
supports_websockets = false
request_max_retries = 2
stream_max_retries = 4
stream_idle_timeout_ms = 300000
"@
    Set-Content -LiteralPath $codexTarget -Value $toml -Encoding utf8NoBOM
    Set-CvsPrivateAcl $codexTarget
    return $connectionTarget
}

Export-ModuleMember -Function Initialize-CvsDevice, Import-CvsConnectionProfile, Test-CvsVersionAtLeast
