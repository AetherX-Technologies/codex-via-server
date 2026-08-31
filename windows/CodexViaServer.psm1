Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ClientVersion = "0.2.0-dev.1"
$script:ModuleRoot = $PSScriptRoot

function Invoke-CvsSshKeygen {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Arguments)
    $executable = if ($env:CODEX_VIA_SERVER_SSH_KEYGEN) { $env:CODEX_VIA_SERVER_SSH_KEYGEN } else { "ssh-keygen.exe" }
    & $executable @Arguments
}

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

function Get-CvsConnectionProfile {
    $path = if ($env:CODEX_VIA_SERVER_CONNECTION_PROFILE) { $env:CODEX_VIA_SERVER_CONNECTION_PROFILE } else { Join-Path (Get-CvsConfigDirectory) "connection-profile.json" }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.LinkType -or $item.PSIsContainer) { throw "Connection profile is unsafe" }
    $profile = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-CvsConnectionProfile $profile
    return $profile
}

function Get-CvsExecutable {
    param([Parameter(Mandatory)][string]$EnvironmentName, [Parameter(Mandatory)][string]$DefaultName)
    $configured = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if ($configured) { return $configured }
    return (Get-Command $DefaultName -ErrorAction Stop).Source
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
        Invoke-CvsSshKeygen -Arguments @("-q", "-t", "ed25519", "-N", "", "-C", $DeviceId, "-f", $privateKey)
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
    $fingerprintOutput = Invoke-CvsSshKeygen -Arguments @("-lf", $publicKey, "-E", "sha256")
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

function Get-CvsVerifiedKnownHosts {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$RuntimeDirectory)
    $keyscan = Get-CvsExecutable "CODEX_VIA_SERVER_SSH_KEYSCAN" "ssh-keyscan.exe"
    $keygen = Get-CvsExecutable "CODEX_VIA_SERVER_SSH_KEYGEN" "ssh-keygen.exe"
    $scanned = Join-Path $RuntimeDirectory "known_hosts.scanned"
    $verified = Join-Path $RuntimeDirectory "known_hosts"
    & $keyscan -T 5 -p ([string]$Profile.server.ssh_port) ([string]$Profile.server.host) 2>$null | Set-Content -LiteralPath $scanned -Encoding utf8NoBOM
    if ($LASTEXITCODE -ne 0) { throw "Cannot read server SSH host keys" }
    foreach ($line in Get-Content -LiteralPath $scanned) {
        if (-not $line -or $line.StartsWith("#")) { continue }
        $candidate = Join-Path $RuntimeDirectory "candidate-key"
        Set-Content -LiteralPath $candidate -Value $line -Encoding utf8NoBOM
        $fingerprintOutput = & $keygen -lf $candidate -E sha256 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $fingerprint = ($fingerprintOutput -split '\s+')[1]
        if ($Profile.server.host_fingerprints -contains $fingerprint) { Add-Content -LiteralPath $verified -Value $line -Encoding utf8NoBOM }
    }
    if (-not (Test-Path $verified)) { throw "Server SSH fingerprint changed" }
    return $verified
}

function Test-CvsTailscaleReachability {
    param([Parameter(Mandatory)][string]$HostName)
    $tailscale = Get-CvsExecutable "CODEX_VIA_SERVER_TAILSCALE" "tailscale.exe"
    & $tailscale ping --timeout=5s $HostName *> $null
    if ($LASTEXITCODE -ne 0) { throw "Tailscale cannot reach the server" }
}

function Test-CvsLocalPortAvailable {
    param([Parameter(Mandatory)][int]$Port)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try { $listener.Start() } catch { throw "Local port $Port is already in use" } finally { $listener.Stop() }
}

function Start-CvsTunnel {
    [CmdletBinding()]
    param()
    $profile = Get-CvsConnectionProfile
    Test-CvsTailscaleReachability ([string]$profile.server.host)
    Test-CvsLocalPortAvailable ([int]$profile.client.local_port)
    $deviceId = [string]$profile.approved_device.device_id
    $identity = Join-Path (Get-CvsKeyDirectory) $deviceId
    if (-not (Test-Path $identity) -or (Get-Item $identity -Force).LinkType) { throw "Device SSH identity is missing or unsafe" }
    $runtime = Join-Path ([System.IO.Path]::GetTempPath()) "codex-via-server-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $runtime | Out-Null
    $process = $null
    try {
        $knownHosts = Get-CvsVerifiedKnownHosts -Profile $profile -RuntimeDirectory $runtime
        $ssh = Get-CvsExecutable "CODEX_VIA_SERVER_SSH" "ssh.exe"
        $arguments = @(
            "-F", "NUL", "-p", [string]$profile.server.ssh_port,
            "-i", $identity, "-N",
            "-L", "127.0.0.1:$($profile.client.local_port):127.0.0.1:$($profile.gateway.remote_port)",
            "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no", "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=$knownHosts", "-o", "GlobalKnownHostsFile=NUL",
            "-o", "UpdateHostKeys=no", "-o", "ProxyCommand=none", "-o", "ProxyJump=none",
            "-o", "PermitLocalCommand=no", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "LogLevel=ERROR",
            "$($profile.server.ssh_user)@$($profile.server.host)"
        )
        $process = Start-Process -FilePath $ssh -ArgumentList $arguments -PassThru -WindowStyle Hidden
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            if ($process.HasExited) { throw "Restricted SSH tunnel exited during startup" }
            try {
                $models = Invoke-RestMethod -Uri "http://127.0.0.1:$($profile.client.local_port)/v1/models" -TimeoutSec 2
                if ($models.data -isnot [array]) { throw "Gateway models response is invalid" }
                return [pscustomobject]@{Process=$process;RuntimeDirectory=$runtime;Profile=$profile}
            } catch { Start-Sleep -Milliseconds 200 }
        } while ([DateTime]::UtcNow -lt $deadline)
        throw "Gateway models check timed out"
    } catch {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
        Remove-Item -LiteralPath $runtime -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Test-CvsCodexConfiguration {
    param([Parameter(Mandatory)]$Profile)
    $codex = Get-CvsExecutable "CODEX_VIA_SERVER_CODEX" "codex.exe"
    $versionOutput = & $codex --version
    if ($LASTEXITCODE -ne 0) { throw "Codex version check failed" }
    $version = [regex]::Match(($versionOutput | Out-String), '[0-9]+\.[0-9]+\.[0-9]+(?:[-.][0-9A-Za-z.]+)?').Value
    if (-not (Test-CvsVersionAtLeast $version ([string]$Profile.client.minimum_codex_version))) { throw "Codex is too old" }
    & $codex --profile ([string]$Profile.client.codex_profile) --version *> $null
    if ($LASTEXITCODE -ne 0) { throw "Codex profile parsing failed" }
    return $version
}

function Invoke-CvsOfficialCodex {
    param([Parameter(Mandatory)][string]$ProfileName, [string[]]$Arguments)
    $codex = Get-CvsExecutable "CODEX_VIA_SERVER_CODEX" "codex.exe"
    & $codex --profile $ProfileName @Arguments
    return $LASTEXITCODE
}

function Stop-CvsTunnel {
    param([Parameter(Mandatory)]$Tunnel)
    if ($Tunnel.Process -and -not $Tunnel.Process.HasExited) { Stop-Process -Id $Tunnel.Process.Id -Force }
    if ($Tunnel.RuntimeDirectory -and (Test-Path $Tunnel.RuntimeDirectory)) { Remove-Item -LiteralPath $Tunnel.RuntimeDirectory -Recurse -Force }
}

function Test-CvsDoctor {
    [CmdletBinding()]
    param([switch]$Live, [switch]$Yes, [string]$Model)
    if ($Live -and -not $Yes) { throw "Live doctor requires -Yes" }
    if ($Live -and $Model -cnotmatch '^[A-Za-z0-9._:/-]{1,128}$') { throw "Live doctor requires a valid model" }
    $profile = Get-CvsConnectionProfile
    $version = Test-CvsCodexConfiguration $profile
    $tunnel = Start-CvsTunnel
    try {
        if ($Live) {
            $body = @{model=$Model;input="Reply only OK.";stream=$true} | ConvertTo-Json -Compress
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$($profile.client.local_port)/v1/responses" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 45
            if ($response.Content -notmatch '"type"\s*:\s*"response.completed"') { throw "Live response did not complete" }
        }
        return [pscustomobject]@{Status="pass";Codex=$version;Profile=$profile.client.codex_profile;Live=[bool]$Live}
    } finally { Stop-CvsTunnel $tunnel }
}

function Invoke-CvsCodex {
    [CmdletBinding()]
    param([string[]]$Arguments)
    $tunnel = Start-CvsTunnel
    try {
        Remove-Item Env:SERVER_CODEX_API_KEY, Env:CLIPROXY_API_KEY, Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
        return Invoke-CvsOfficialCodex -ProfileName ([string]$tunnel.Profile.client.codex_profile) -Arguments $Arguments
    } finally { Stop-CvsTunnel $tunnel }
}

function Get-CvsInstallRoot {
    if ($env:CODEX_VIA_SERVER_INSTALL_ROOT) { return $env:CODEX_VIA_SERVER_INSTALL_ROOT }
    return $script:ModuleRoot
}

function Get-CvsLatestRelease {
    $stateDirectory = Get-CvsStateDirectory
    $cachePath = Join-Path $stateDirectory "update-check.json"
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (-not $env:CODEX_VIA_SERVER_FORCE_UPDATE_CHECK -and (Test-Path $cachePath)) {
        $cached = Get-Content $cachePath -Raw | ConvertFrom-Json
        if (($now - [long]$cached.checked_at) -lt 86400) { return $cached }
    }
    $uri = if ($env:CODEX_VIA_SERVER_RELEASE_API) { $env:CODEX_VIA_SERVER_RELEASE_API } else { "https://api.github.com/repos/AetherX-Technologies/codex-via-server/releases/latest" }
    $response = Invoke-RestMethod -Uri $uri -Headers @{Accept="application/vnd.github+json"}
    $asset = @($response.assets | Where-Object name -eq "codex-via-server-windows.zip")[0]
    $checksums = @($response.assets | Where-Object name -eq "checksums.txt")[0]
    if (-not $asset -or -not $checksums) { throw "Release artifacts are missing" }
    $result = [ordered]@{checked_at=$now;tag_name=$response.tag_name;asset_url=$asset.browser_download_url;checksums_url=$checksums.browser_download_url}
    $result | ConvertTo-Json | Set-Content $cachePath -Encoding utf8NoBOM
    Set-CvsPrivateAcl $cachePath
    return [pscustomobject]$result
}

function Update-CvsClient {
    [CmdletBinding()]
    param([switch]$CheckOnly, [switch]$Force)
    if ($Force) { $env:CODEX_VIA_SERVER_FORCE_UPDATE_CHECK="1" }
    try { $release = Get-CvsLatestRelease } finally { Remove-Item Env:CODEX_VIA_SERVER_FORCE_UPDATE_CHECK -ErrorAction SilentlyContinue }
    $latest = ([string]$release.tag_name).TrimStart('v')
    if ($latest -cnotmatch '^\d+\.\d+\.\d+$') { throw "Invalid release version" }
    $installRoot = Get-CvsInstallRoot
    $versionPath = Join-Path $installRoot "VERSION"
    $installed = if (Test-Path $versionPath) { (Get-Content $versionPath -Raw).Trim() } else { "0.0.0" }
    if ($CheckOnly) { return [pscustomobject]@{Installed=$installed;Latest=$latest} }
    if (Test-CvsVersionAtLeast $installed $latest) { return [pscustomobject]@{Status="current";Version=$installed} }

    $stateDirectory = Get-CvsStateDirectory
    $runtime = Join-Path ([System.IO.Path]::GetTempPath()) "codex-update-$([guid]::NewGuid().ToString('N'))"
    $backup = Join-Path $stateDirectory "backups/$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$PID"
    New-Item -ItemType Directory -Force -Path $runtime,$backup | Out-Null
    $archive = Join-Path $runtime "codex-via-server-windows.zip"
    $checksums = Join-Path $runtime "checksums.txt"
    $committed = $false
    try {
        Invoke-WebRequest -Uri $release.asset_url -OutFile $archive
        Invoke-WebRequest -Uri $release.checksums_url -OutFile $checksums
        $expected = ((Get-Content $checksums | Where-Object {$_ -match 'codex-via-server-windows\.zip$'} | Select-Object -First 1) -split '\s+')[0]
        if ($expected -cnotmatch '^[a-f0-9]{64}$') { throw "Release checksum is missing" }
        if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected) { throw "Release checksum mismatch" }
        Expand-Archive -LiteralPath $archive -DestinationPath $runtime
        $packageRoot = Join-Path $runtime "codex-via-server-windows"
        foreach ($file in @("codex-via-server.ps1","CodexViaServer.psm1","VERSION")) {
            $candidate = Join-Path $packageRoot $file
            if (-not (Test-Path $candidate) -or (Get-Item $candidate -Force).LinkType) { throw "Candidate file is missing or unsafe: $file" }
        }
        if ((Get-Content (Join-Path $packageRoot "VERSION") -Raw).Trim() -cne $latest) { throw "Package version mismatch" }
        foreach ($scriptFile in @("codex-via-server.ps1","CodexViaServer.psm1")) {
            $tokens=$null;$errors=$null
            [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $packageRoot $scriptFile),[ref]$tokens,[ref]$errors)|Out-Null
            if ($errors.Count -gt 0) { throw "Candidate PowerShell parse failed" }
        }
        if (Test-Path $installRoot) { Copy-Item $installRoot (Join-Path $backup "install") -Recurse -Force } else { New-Item -ItemType File (Join-Path $backup "install.absent") | Out-Null }
        New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
        Copy-Item (Join-Path $packageRoot "*") $installRoot -Recurse -Force
        if ($env:CODEX_VIA_SERVER_TEST_FAIL_STAGE -eq "after-copy") { throw "Injected update failure" }
        $committed=$true
        return [pscustomobject]@{Status="updated";Version=$latest;Backup=$backup}
    } finally {
        if (-not $committed) {
            if (Test-Path (Join-Path $backup "install")) {
                if (Test-Path $installRoot) { Remove-Item $installRoot -Recurse -Force }
                Copy-Item (Join-Path $backup "install") $installRoot -Recurse -Force
            } elseif (Test-Path (Join-Path $backup "install.absent")) {
                Remove-Item $installRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item $runtime -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-CvsClient {
    [CmdletBinding()]
    param([switch]$RemoveDeviceKey, [switch]$Yes)
    if ($RemoveDeviceKey -and -not $Yes) { throw "Removing the device key requires -Yes" }
    $root = Get-CvsRoot
    $config = Join-Path (Get-CvsConfigDirectory) "connection-profile.json"
    $deviceId=$null;$profileName="codex-via-server"
    if (Test-Path $config) { $profile=Get-Content $config -Raw|ConvertFrom-Json;$deviceId=$profile.approved_device.device_id;$profileName=$profile.client.codex_profile }
    if ($profileName -cnotmatch '^[A-Za-z0-9_-]{3,64}$') { throw "Unsafe profile name" }
    $codexHome=if($env:CODEX_HOME){$env:CODEX_HOME}else{Join-Path $root ".codex"}
    $targets=@((Get-CvsInstallRoot),$config,(Join-Path $codexHome "$profileName.config.toml"))
    $backup=Join-Path (Get-CvsStateDirectory) "uninstall-backups/$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$PID"
    New-Item -ItemType Directory -Force -Path $backup|Out-Null
    foreach($target in $targets){if(Test-Path $target){$item=Get-Item $target -Force;if($item.LinkType){throw "Refusing symbolic link"};Copy-Item $target (Join-Path $backup ([guid]::NewGuid().ToString('N'))) -Recurse -Force;Remove-Item $target -Recurse -Force}}
    if($RemoveDeviceKey -and $deviceId){foreach($key in @((Join-Path (Get-CvsKeyDirectory) $deviceId),(Join-Path (Get-CvsKeyDirectory) "$deviceId.pub"))){if(Test-Path $key){Remove-Item $key -Force}}}
    return [pscustomobject]@{Status="uninstalled";Backup=$backup;DeviceKeyRemoved=[bool]$RemoveDeviceKey}
}

Export-ModuleMember -Function Initialize-CvsDevice, Import-CvsConnectionProfile, Test-CvsVersionAtLeast, Start-CvsTunnel, Stop-CvsTunnel, Test-CvsDoctor, Invoke-CvsCodex, Update-CvsClient, Uninstall-CvsClient
