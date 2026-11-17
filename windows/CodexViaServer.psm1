Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ClientVersion = "0.2.0-dev.1"
$script:ModuleRoot = $PSScriptRoot
$script:DesktopProviderName = "codex_via_server_desktop"
$script:DesktopRootBegin = "# BEGIN CODEX VIA SERVER DESKTOP ROOT"
$script:DesktopRootEnd = "# END CODEX VIA SERVER DESKTOP ROOT"
$script:DesktopProviderBegin = "# BEGIN CODEX VIA SERVER DESKTOP PROVIDER"
$script:DesktopProviderEnd = "# END CODEX VIA SERVER DESKTOP PROVIDER"
$script:LastTunnelSuccess = $null

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

function Get-CvsCodexHome {
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    return Join-Path $HOME ".codex"
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

function Protect-CvsClientDirectories {
    foreach ($directory in @((Get-CvsRoot), (Get-CvsConfigDirectory), (Get-CvsKeyDirectory), (Get-CvsStateDirectory))) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        Set-CvsPrivateAcl $directory
    }
}

function Protect-CvsApprovedDeviceFiles {
    param([Parameter(Mandatory)]$Profile)
    $identity = Join-Path (Get-CvsKeyDirectory) ([string]$Profile.approved_device.device_id)
    foreach ($keyPath in @($identity, "${identity}.pub")) {
        if (-not (Test-Path -LiteralPath $keyPath)) { continue }
        $item = Get-Item -LiteralPath $keyPath -Force
        if ($item.LinkType -or $item.PSIsContainer) { throw "Device SSH identity is unsafe" }
        Set-CvsPrivateAcl $keyPath
    }
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
    $item = Get-Item -LiteralPath $Path -Force
    if($item.LinkType){throw 'unsafe_private_path'}
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in @($acl.Access)) { [void]$acl.PurgeAccessRules($existingRule.IdentityReference) }
    $inheritance = if ($item.PSIsContainer) { [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit } else { [System.Security.AccessControl.InheritanceFlags]::None }
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($identity, [System.Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
    [void]$acl.AddAccessRule($rule)
    [System.IO.FileSystemAclExtensions]::SetAccessControl($item, $acl)
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

    Protect-CvsClientDirectories
    Protect-CvsApprovedDeviceFiles -Profile $profile
    $configDirectory = Get-CvsConfigDirectory
    $connectionTarget = Join-Path $configDirectory "connection-profile.json"
    Copy-Item -LiteralPath $Path -Destination $connectionTarget -Force
    Set-CvsPrivateAcl $connectionTarget

    $codexHome = Get-CvsCodexHome
    New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
    $codexTarget = Join-Path $codexHome "$($profile.client.codex_profile).config.toml"
    $toml = @"
model_provider = "server_cliproxy"

[model_providers.server_cliproxy]
name = "CLIProxyAPI through a restricted SSH tunnel"
base_url = "http://127.0.0.1:$($profile.client.local_port)/v1"
wire_api = "responses"
supports_websockets = false
requires_openai_auth = false
request_max_retries = 2
stream_max_retries = 4
stream_idle_timeout_ms = 300000
"@
    Set-Content -LiteralPath $codexTarget -Value $toml -Encoding utf8NoBOM
    Set-CvsPrivateAcl $codexTarget
    return $connectionTarget
}

function Invoke-CvsBoundedNative {
    param([string]$Executable, [string[]]$Arguments, [ValidateRange(1,120)][int]$TimeoutSec)
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$Executable; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach($argument in $Arguments){$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$info
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutSec*1000)){ $process.Kill(); throw 'native_timeout' }
        if($process.ExitCode -ne 0){throw 'native_failed'}
        return $stdout.GetAwaiter().GetResult()
    } finally { $process.Dispose() }
}

function Get-CvsVerifiedKnownHosts {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$RuntimeDirectory, [ValidateRange(1,120)][int]$TimeoutSec=15)
    $keyscan = Get-CvsExecutable "CODEX_VIA_SERVER_SSH_KEYSCAN" "ssh-keyscan.exe"
    $keygen = Get-CvsExecutable "CODEX_VIA_SERVER_SSH_KEYGEN" "ssh-keygen.exe"
    $scanned = Join-Path $RuntimeDirectory "known_hosts.scanned"
    $verified = Join-Path $RuntimeDirectory "known_hosts"
    $scanTimer=[Diagnostics.Stopwatch]::StartNew()
    try { Invoke-CvsBoundedNative -Executable $keyscan -Arguments @('-T','5','-p',[string]$Profile.server.ssh_port,[string]$Profile.server.host) -TimeoutSec $TimeoutSec |
        Set-Content -LiteralPath $scanned -Encoding utf8NoBOM } catch {throw 'ssh_host_key_unavailable'}
    foreach ($line in Get-Content -LiteralPath $scanned) {
        if (-not $line -or $line.StartsWith("#")) { continue }
        $candidate = Join-Path $RuntimeDirectory "candidate-key"
        Set-Content -LiteralPath $candidate -Value $line -Encoding utf8NoBOM
        $remaining=[int][math]::Floor($TimeoutSec-$scanTimer.Elapsed.TotalSeconds)
        if($remaining -lt 1){throw 'ssh_host_key_unavailable'}
        try { $fingerprintOutput = Invoke-CvsBoundedNative -Executable $keygen -Arguments @('-lf',$candidate,'-E','sha256') -TimeoutSec $remaining } catch {continue}
        $fingerprint = ($fingerprintOutput -split '\s+')[1]
        if ($Profile.server.host_fingerprints -contains $fingerprint) { Add-Content -LiteralPath $verified -Value $line -Encoding utf8NoBOM }
    }
    if (-not (Test-Path $verified)) { throw 'ssh_host_key_unavailable' }
    return $verified
}

function Test-CvsTailscaleReachability {
    param([Parameter(Mandatory)][string]$HostName, [ValidateRange(1,120)][int]$TimeoutSec=10)
    $tailscale = Get-CvsExecutable "CODEX_VIA_SERVER_TAILSCALE" "tailscale.exe"
    Invoke-CvsBoundedNative -Executable $tailscale -Arguments @('ping','--timeout=5s','--c=1','--until-direct=false',$HostName) -TimeoutSec $TimeoutSec | Out-Null
}

function Test-CvsGatewayModels {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Port, [ValidateRange(5,60)][int]$TimeoutSec = 45)
    try {
        $models = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -NoProxy -TimeoutSec $TimeoutSec -MaximumRedirection 0
        return ($models.data -is [array])
    } catch {
        return $false
    }
}

function Get-CvsTunnelPolicy {
    $policy = [ordered]@{
        HealthTimeoutSec=8; HealthIntervalSec=10; ConsecutiveFailureThreshold=3
        MinUnhealthyDurationSec=45; ActiveSessionGraceSec=90; RestartCooldownSec=60
        ReconnectBackoffSec=@(5,10,20,40,60); StartupBudgetSec=30; PortReleaseTimeoutSec=10
    }
    $path = Join-Path (Get-CvsConfigDirectory) 'runtime-policy.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $item = Get-Item -LiteralPath $path -Force
            if ($item.LinkType -or $item.PSIsContainer) { throw 'unsafe policy' }
            $overrides = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
            if ($overrides -isnot [System.Collections.IDictionary]) { throw 'policy must be an object' }
            foreach ($key in $overrides.Keys) {
                if (-not $policy.Contains($key)) { throw 'unknown policy key' }
                $policy[$key] = $overrides[$key]
            }
        } catch { throw 'invalid_runtime_policy' }
    }
    $ranges = @{
        HealthTimeoutSec=@(1,60); HealthIntervalSec=@(1,300); ConsecutiveFailureThreshold=@(2,20)
        MinUnhealthyDurationSec=@(10,600); ActiveSessionGraceSec=@(45,1800)
        RestartCooldownSec=@(10,600); StartupBudgetSec=@(5,120); PortReleaseTimeoutSec=@(1,30)
    }
    foreach ($key in $ranges.Keys) {
        $value = $policy[$key]
        if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt $ranges[$key][0] -or $value -gt $ranges[$key][1]) { throw 'invalid_runtime_policy' }
    }
    $steps = $policy.ReconnectBackoffSec
    if ($steps -isnot [array] -or $steps.Count -lt 1 -or $steps.Count -gt 10) { throw 'invalid_runtime_policy' }
    $previous = 0
    foreach ($step in $steps) {
        if (($step -isnot [int] -and $step -isnot [long]) -or $step -lt 1 -or $step -gt 300 -or $step -lt $previous) { throw 'invalid_runtime_policy' }
        $previous = $step
    }
    if ($policy.HealthTimeoutSec -gt $policy.StartupBudgetSec) { throw 'invalid_runtime_policy' }
    return [pscustomobject]$policy
}

function Get-CvsPortListeners {
    param([Parameter(Mandatory)][int]$Port)
    return @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -in @('127.0.0.1','0.0.0.0','::','::1') })
}

function Test-CvsGatewayHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Port, [ValidateRange(1,60)][int]$TimeoutSec=8, [switch]$Detailed, $Profile=(Get-CvsConnectionProfile))
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = [ordered]@{Success=$false;Code='managed_listener_missing';DurationMs=0;HttpStatus=0}
    # An arbitrary HTTP service occupying the approved port is not our tunnel.
    $managed = Get-CvsManagedTunnelProcess -Profile $Profile
    if ($Port -ne [int]$Profile.client.local_port -or -not $managed) {
        if (@(Get-CvsPortListeners -Port $Port).Count) {
            # SSH can bind between snapshots; validate the observed owner again.
            if ($Port -eq [int]$Profile.client.local_port) { $managed=Get-CvsManagedTunnelProcess -Profile $Profile }
            if ($Port -ne [int]$Profile.client.local_port -or -not $managed) { $result.Code='unmanaged_listener' }
        }
    }
    if ($Port -eq [int]$Profile.client.local_port -and $managed) {
        $probeLock=New-CvsMutex -Kind Health
        $locked=$false
        try {
            try {$locked=$probeLock.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
            if(-not $locked){
                $result.Code='health_probe_busy'
                if($Detailed){return [pscustomobject]$result}; return $false
            }
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/healthz" -NoProxy -TimeoutSec $TimeoutSec -MaximumRedirection 0 -SkipHttpErrorCheck
            $result.HttpStatus = [int]$response.StatusCode
            $result.Success = ($result.HttpStatus -eq 204 -and $response.Content.Length -eq 0)
            $result.Code = if ($result.Success) { 'healthy' } else { 'gateway_bad_status' }
        } catch {
            $errorObject = $_.Exception
            $isTimeout = $false
            while ($null -ne $errorObject) {
                if ($errorObject -is [TimeoutException] -or $errorObject -is [OperationCanceledException] -or
                    ($errorObject -is [System.Net.WebException] -and $errorObject.Status -eq 'Timeout')) { $isTimeout=$true }
                $errorObject = $errorObject.InnerException
            }
            $result.Code = if ($isTimeout) { 'gateway_timeout' } else { 'gateway_connection_failed' }
        } finally { if($locked){$probeLock.ReleaseMutex()}; $probeLock.Dispose() }
    }
    $result.DurationMs = $timer.ElapsedMilliseconds
    if ($Detailed) { return [pscustomobject]$result }
    return [bool]$result.Success
}

function New-CvsMutex {
    param([ValidateSet('Health','Control')][string]$Kind)
    $bytes=[Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath((Get-CvsRoot)).ToLowerInvariant())
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    return [Threading.Mutex]::new($false,"Local\CodexViaServer-$Kind-$hash")
}

function New-CvsSshArguments {
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][string]$KnownHosts
    )
    return @(
        "-F", "NUL", "-p", [string]$Profile.server.ssh_port,
        "-i", $Identity, "-N", "-T", "-C",
        "-L", "127.0.0.1:$($Profile.client.local_port):127.0.0.1:$($Profile.gateway.remote_port)",
        "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "PasswordAuthentication=no",
        "-o", "KbdInteractiveAuthentication=no", "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=$KnownHosts", "-o", "GlobalKnownHostsFile=NUL",
        "-o", "UpdateHostKeys=no", "-o", "ProxyCommand=none", "-o", "ProxyJump=none",
        "-o", "PermitLocalCommand=no", "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "TCPKeepAlive=yes", "-o", "LogLevel=INFO",
        "$($Profile.server.ssh_user)@$($Profile.server.host)"
    )
}

function ConvertTo-CvsWindowsProcessArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Argument)
    if ($Argument -notmatch '[\s"]') { return $Argument }
    if ($Argument.Contains('"')) { throw "SSH argument contains an unsafe quote" }
    return '"' + $Argument + '"'
}

function ConvertFrom-CvsWindowsCommandLine {
    param([Parameter(Mandatory)][string]$CommandLine)
    $arguments = [System.Collections.Generic.List[string]]::new()
    $length = $CommandLine.Length
    $index = 0
    while ($index -lt $length) {
        while ($index -lt $length -and [char]::IsWhiteSpace($CommandLine[$index])) { $index++ }
        if ($index -ge $length) { break }
        $builder = [System.Text.StringBuilder]::new()
        $quoted = $false
        while ($index -lt $length) {
            $slashes = 0
            while ($index -lt $length -and $CommandLine[$index] -eq '\') { $slashes++; $index++ }
            if ($index -lt $length -and $CommandLine[$index] -eq '"') {
                [void]$builder.Append(('\' * [Math]::Floor($slashes / 2)))
                if (($slashes % 2) -eq 0) { $quoted = -not $quoted } else { [void]$builder.Append('"') }
                $index++
                continue
            }
            [void]$builder.Append(('\' * $slashes))
            if ($index -ge $length -or (-not $quoted -and [char]::IsWhiteSpace($CommandLine[$index]))) { break }
            [void]$builder.Append($CommandLine[$index])
            $index++
        }
        $arguments.Add($builder.ToString())
    }
    return $arguments.ToArray()
}

function Test-CvsManagedSshCommandLine {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$CommandLine)
    $tokens = @(ConvertFrom-CvsWindowsCommandLine $CommandLine)
    if ($tokens.Count -lt 2 -or [System.IO.Path]::GetFileName($tokens[0]) -ine "ssh.exe") { return $false }

    $identity = [System.IO.Path]::GetFullPath((Join-Path (Get-CvsKeyDirectory) ([string]$Profile.approved_device.device_id)))
    $knownHostsIndex = -1
    $template = @(New-CvsSshArguments -Profile $Profile -Identity $identity -KnownHosts "__KNOWN_HOSTS__")
    for ($i = 0; $i -lt $template.Count; $i++) {
        if ($template[$i] -eq "UserKnownHostsFile=__KNOWN_HOSTS__") { $knownHostsIndex = $i; break }
    }
    if ($knownHostsIndex -lt 0) { return $false }
    $actual = @($tokens[1..($tokens.Count - 1)])
    # Retain exact ownership of pre-compression connections during an upgrade.
    if ($actual.Count -eq $template.Count - 1 -and $actual -cnotcontains '-C') {
        $actual = @($actual[0..7]) + @('-C') + @($actual[8..($actual.Count - 1)])
    }
    if ($actual.Count -ne $template.Count) { return $false }

    for ($i = 0; $i -lt $template.Count; $i++) {
        if ($i -eq $knownHostsIndex) { continue }
        if ($i -eq 5) {
            try {
                if ([System.IO.Path]::GetFullPath($actual[$i]) -ine $template[$i]) { return $false }
            } catch { return $false }
        } elseif ($template[$i] -ceq 'LogLevel=INFO' -and $actual[$i] -ceq 'LogLevel=ERROR') {
            # Retain the previous restricted connection when upgrading diagnostics.
            continue
        } elseif ($actual[$i] -cne $template[$i]) {
            return $false
        }
    }

    $knownHostsValue = $actual[$knownHostsIndex]
    if (-not $knownHostsValue.StartsWith("UserKnownHostsFile=", [System.StringComparison]::Ordinal)) { return $false }
    try {
        $knownHostsPath = [System.IO.Path]::GetFullPath($knownHostsValue.Substring("UserKnownHostsFile=".Length))
        $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
        $runtimeDirectory = Split-Path -Parent $knownHostsPath
        if ((Split-Path -Leaf $knownHostsPath) -cne "known_hosts") { return $false }
        if ((Split-Path -Parent $runtimeDirectory).TrimEnd('\','/') -ine $temporaryRoot -or
            (Split-Path -Leaf $runtimeDirectory) -cnotmatch '^codex-via-server-[0-9a-f]{32}$') { return $false }
    } catch { return $false }
    return $true
}

function Get-CvsManagedTunnelProcess {
    [CmdletBinding()]
    param($Profile = (Get-CvsConnectionProfile), [switch]$IncludeStarting)
    $listeners = @(Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort ([int]$Profile.client.local_port) -State Listen -ErrorAction SilentlyContinue)
    $processIds = @($listeners | Where-Object { $null -ne $_ } | ForEach-Object { $_.OwningProcess } | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($processId in $processIds) {
        $processRecord = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
        if (-not $processRecord) { continue }
        $executableName = if ($processRecord.ExecutablePath) { [System.IO.Path]::GetFileName([string]$processRecord.ExecutablePath) } else { [string]$processRecord.Name }
        if ($executableName -ine "ssh.exe") { continue }
        if (-not (Test-CvsManagedSshCommandLine -Profile $Profile -CommandLine ([string]$processRecord.CommandLine))) { continue }
        return Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue
    }
    if ($IncludeStarting -and $processIds.Count -eq 0) {
        # Stopping a task can orphan SSH before it binds the forwarded port.
        foreach ($record in @(Get-CimInstance Win32_Process -Filter "Name = 'ssh.exe'" -ErrorAction SilentlyContinue)) {
            if (-not $record -or [IO.Path]::GetFileName([string]$record.ExecutablePath) -ine 'ssh.exe') { continue }
            if (Test-CvsManagedSshCommandLine -Profile $Profile -CommandLine ([string]$record.CommandLine)) {
                return Get-Process -Id ([int]$record.ProcessId) -ErrorAction SilentlyContinue
            }
        }
    }
    return $null
}

function Test-CvsLocalPortAvailable {
    param([Parameter(Mandatory)][int]$Port)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try { $listener.Start() } catch { throw "Local port $Port is already in use" } finally { $listener.Stop() }
}

function Start-CvsSshProcess {
    param([string]$Executable, [string[]]$Arguments)
    if(-not ('CvsSshProcess' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class CvsSshProcess : IDisposable {
    public Process Process { get; private set; }
    private Task drain;
    private string errorCode = "none";
    public static CvsSshProcess Start(string executable, string[] arguments) {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        var result = new CvsSshProcess();
        result.Process = Process.Start(info);
        result.drain = result.Drain();
        return result;
    }
    private void Classify(string line) {
        string code = null;
        if (line.Contains("not responding", StringComparison.OrdinalIgnoreCase)) code = "server_not_responding";
        else if (line.Contains("Connection reset", StringComparison.OrdinalIgnoreCase) || line.Contains("forcibly closed", StringComparison.OrdinalIgnoreCase)) code = "connection_reset";
        else if (line.Contains("Connection refused", StringComparison.OrdinalIgnoreCase)) code = "connection_refused";
        else if (line.Contains("timed out", StringComparison.OrdinalIgnoreCase)) code = "connection_timeout";
        else if (line.Contains("Connection closed", StringComparison.OrdinalIgnoreCase) || line.Contains("closed by remote host", StringComparison.OrdinalIgnoreCase)) code = "connection_closed";
        else if (line.Contains("Host key verification failed", StringComparison.OrdinalIgnoreCase) || line.Contains("REMOTE HOST IDENTIFICATION HAS CHANGED", StringComparison.OrdinalIgnoreCase)) code = "host_key_rejected";
        else if (line.Contains("Permission denied", StringComparison.OrdinalIgnoreCase)) code = "authentication_failed";
        if (code != null) Volatile.Write(ref errorCode, code);
        else if (errorCode == "none" && line.Length > 0) Volatile.Write(ref errorCode, "unclassified");
    }
    private async Task Drain() {
        // Bound memory even when stderr has no newline; raw diagnostics never reach disk.
        var buffer = new char[512];
        var line = new StringBuilder(2048);
        try {
            int count;
            while ((count = await Process.StandardError.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0) {
                for (int i = 0; i < count; i++) {
                    if (buffer[i] == '\n') { Classify(line.ToString()); line.Clear(); }
                    else if (line.Length < 2048) line.Append(buffer[i]);
                }
            }
            if (line.Length > 0) Classify(line.ToString());
        } catch { if (errorCode == "none") Volatile.Write(ref errorCode, "unavailable"); }
    }
    public string GetErrorCode() {
        if (Process.HasExited) drain.Wait(1000);
        return Volatile.Read(ref errorCode);
    }
    public void Dispose() { Process.Dispose(); }
}
'@
    }
    return [CvsSshProcess]::Start($Executable,$Arguments)
}

function Start-CvsTunnel {
    [CmdletBinding()]
    param([switch]$Persistent, $Policy=(Get-CvsTunnelPolicy), $Profile=(Get-CvsConnectionProfile), [switch]$VerifyModels)
    $startup=[Diagnostics.Stopwatch]::StartNew()
    $managedProcess = Get-CvsManagedTunnelProcess -Profile $profile -IncludeStarting
    if ($managedProcess) {
        # The supervisor must retain the reused handle even when it is stalled.
        if (-not $Persistent) {
            $ready=if($VerifyModels){Test-CvsGatewayModels -Port ([int]$profile.client.local_port)}else{Test-CvsGatewayHealth -Port ([int]$profile.client.local_port) -Profile $profile -TimeoutSec $Policy.HealthTimeoutSec}
            if(-not $ready){throw 'gateway_timeout'}
        }
        return [pscustomobject]@{Process=$null;ManagedProcess=$managedProcess;RuntimeDirectory=$null;Profile=$profile;Reused=$true}
    }
    if(@(Get-CvsPortListeners -Port ([int]$profile.client.local_port)).Count){throw 'unmanaged_listener'}
    # A failed Tailscale ping cannot establish that the SSH service is unreachable.
    try { Test-CvsLocalPortAvailable ([int]$profile.client.local_port) } catch {throw 'unmanaged_listener'}
    $deviceId = [string]$profile.approved_device.device_id
    $identity = Join-Path (Get-CvsKeyDirectory) $deviceId
    if (-not (Test-Path $identity) -or (Get-Item $identity -Force).LinkType) { throw "Device SSH identity is missing or unsafe" }
    $runtime = Join-Path ([System.IO.Path]::GetTempPath()) "codex-via-server-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $runtime | Out-Null
    Set-CvsPrivateAcl $runtime
    $process = $null; $diagnostics=$null
    try {
        $remaining=[int][math]::Floor($Policy.StartupBudgetSec-$startup.Elapsed.TotalSeconds)
        if($remaining -lt 1){throw 'ssh_auth_or_start_failed'}
        $knownHosts = Get-CvsVerifiedKnownHosts -Profile $profile -RuntimeDirectory $runtime -TimeoutSec $remaining
        $ssh = Get-CvsExecutable "CODEX_VIA_SERVER_SSH" "ssh.exe"
        $arguments = New-CvsSshArguments -Profile $profile -Identity $identity -KnownHosts $knownHosts
        try {$diagnostics=Start-CvsSshProcess -Executable $ssh -Arguments $arguments; $process=$diagnostics.Process} catch {throw 'ssh_auth_or_start_failed'}
        $tunnel=[pscustomobject]@{Process=$process;ManagedProcess=$null;Diagnostics=$diagnostics;RuntimeDirectory=$runtime;Profile=$profile;Reused=$false;StartupRemainingSec=[math]::Max(0,$Policy.StartupBudgetSec-$startup.Elapsed.TotalSeconds)}
        if($Persistent){return $tunnel}
        do {
            if($VerifyModels -and (Test-CvsDesktopStopRequested)){throw 'gateway_timeout'}
            if ($process.HasExited) { throw 'ssh_auth_or_start_failed' }
            $remaining=[int][math]::Floor($Policy.StartupBudgetSec-$startup.Elapsed.TotalSeconds)
            if($remaining -lt 1){break}
            if($VerifyModels -and $remaining -lt 5){break}
            $ready=if($VerifyModels){
                $owner=Get-CvsManagedTunnelProcess -Profile $profile
                $owner -and $owner.Id -eq $process.Id -and (Test-CvsGatewayModels -Port ([int]$profile.client.local_port) -TimeoutSec ([math]::Min(45,$remaining)))
            }else{Test-CvsGatewayHealth -Port ([int]$profile.client.local_port) -Profile $profile -TimeoutSec ([math]::Min($Policy.HealthTimeoutSec,$remaining))}
            if($ready){return $tunnel}
            Start-Sleep -Milliseconds 200
        } while ($startup.Elapsed.TotalSeconds -lt $Policy.StartupBudgetSec)
        throw 'gateway_timeout'
    } catch {
        if ($process -and -not $process.HasExited) { Stop-CvsManagedProcess -Profile $profile -Process $process | Out-Null }
        if($diagnostics){$diagnostics.Dispose()}
        Remove-CvsRuntimeDirectory -Path $runtime
        throw
    }
}

function Test-CvsTunnelHasClients {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][int]$OwnerProcessId)
    try {
        return (@(Get-NetTCPConnection -ErrorAction Stop | Where-Object {
            $_.LocalAddress -eq '127.0.0.1' -and $_.LocalPort -eq $Port -and
            $_.OwningProcess -eq $OwnerProcessId -and $_.State -eq 'Established'
        }).Count -gt 0)
    } catch { return $true }
}

function Test-CvsReplacementTunnel {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)]$Policy)
    if(Test-CvsDesktopStopRequested){return $false}
    $reservation=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    try {$reservation.Start();$port=$reservation.LocalEndpoint.Port} finally {$reservation.Stop()}
    # Keep the approved destination and identity; only the temporary loopback port differs.
    $probeProfile=$Profile | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $probeProfile.client.local_port=$port
    $probePolicy=$Policy.PSObject.Copy()
    $probePolicy.StartupBudgetSec=[math]::Max(45,$Policy.StartupBudgetSec)
    $candidate=$null;$ready=$false
    try {
        $candidate=Start-CvsTunnel -Profile $probeProfile -Policy $probePolicy -VerifyModels
        $ready=$true
    } catch { $ready=$false }
    finally {
        if($candidate){try {Stop-CvsTunnel -Tunnel $candidate -IncludeReused} catch {$ready=$false}}
    }
    return $ready
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

function Stop-CvsManagedProcess {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)]$Process)
    if ($Process.HasExited) { return $false }
    $current = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
    if (-not $current -or $current.HasExited) { return $false }
    # Keep the Process object/handle, not just the PID; revalidate birth time and
    # the approved command immediately before killing. PID reuse fails closed.
    if ($current.StartTime.ToUniversalTime().Ticks -ne $Process.StartTime.ToUniversalTime().Ticks) { return $false }
    $record=Get-CimInstance Win32_Process -Filter "ProcessId = $($Process.Id)" -ErrorAction SilentlyContinue
    if (-not $record -or [IO.Path]::GetFileName([string]$record.ExecutablePath) -ine 'ssh.exe' -or
        -not (Test-CvsManagedSshCommandLine -Profile $Profile -CommandLine ([string]$record.CommandLine))) { return $false }
    $owners=@(Get-CvsPortListeners -Port ([int]$Profile.client.local_port))
    if (@($owners | Where-Object OwningProcess -ne $Process.Id).Count) { return $false }
    Stop-Process -InputObject $current -Force -ErrorAction Stop
    return $true
}

function Remove-CvsRuntimeDirectory {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    $resolved=[IO.Path]::GetFullPath($Path)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if ((Split-Path -Parent $resolved).TrimEnd('\','/') -ine $temp -or
        (Split-Path -Leaf $resolved) -cnotmatch '^codex-via-server-[0-9a-f]{32}$' -or
        (Get-Item -LiteralPath $resolved -Force).LinkType) { throw 'unsafe_runtime_directory' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
}

function Stop-CvsTunnel {
    param([Parameter(Mandatory)]$Tunnel, [switch]$IncludeReused)
    $process = $Tunnel.Process
    if (-not $process -and $IncludeReused -and $Tunnel.PSObject.Properties['ManagedProcess']) { $process=$Tunnel.ManagedProcess }
    if ($process -and -not $process.HasExited) {
        $stopped=Stop-CvsManagedProcess -Profile $Tunnel.Profile -Process $process
        if(-not $stopped -and -not $process.HasExited){throw 'unmanaged_listener'}
    }
    if($Tunnel.RuntimeDirectory){Remove-CvsRuntimeDirectory -Path $Tunnel.RuntimeDirectory}
    if($Tunnel.PSObject.Properties['Diagnostics'] -and $Tunnel.Diagnostics){$Tunnel.Diagnostics.Dispose()}
}

function Get-CvsUtcNow { return [DateTimeOffset]::UtcNow }

function Test-CvsDesktopStopRequested {
    return Test-Path -LiteralPath (Join-Path (Get-CvsStateDirectory) 'desktop-stopped')
}

function Wait-CvsMonitorDelay {
    param([double]$Seconds, $Process=$null)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        if(Test-CvsDesktopStopRequested){return $false}
        if($Process -and $Process.HasExited){return $true}
        if($timer.Elapsed.TotalSeconds -ge $Seconds){return $true}
        Start-Sleep -Milliseconds ([math]::Min(1000,[math]::Max(1,($Seconds-$timer.Elapsed.TotalSeconds)*1000)))
    } while($true)
}

function Wait-CvsLocalPortReleased {
    param([int]$Port, [int]$TimeoutSec=10)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        if(-not @(Get-CvsPortListeners -Port $Port).Count){return $true}
        if($timer.Elapsed.TotalSeconds -ge $TimeoutSec){return $false}
        Start-Sleep -Milliseconds 200
    } while($true)
}

function Write-CvsTunnelEvent {
    param(
        [ValidateSet('Starting','Healthy','Suspect','Recovering','Backoff','Stopped')][string]$State,
        [ValidateSet('starting','healthy','recovered','gateway_timeout','gateway_bad_status','gateway_connection_failed',
            'managed_process_exited','managed_listener_missing','transport_stalled','unmanaged_listener','restart_backoff','tailscale_unreachable','health_probe_busy',
            'ssh_host_key_unavailable','ssh_auth_or_start_failed','invalid_runtime_policy','gateway_responsive',
            'recovery_deferred','replacement_unavailable','replacement_verified','stopped')][string]$Code,
        [long]$DurationMs=0, [int]$Failures=0, $LastSuccess=$null, [int]$ReconnectAttempt=0,
        [Nullable[int]]$ExitCode=$null, [Nullable[int]]$ProcessId=$null, [bool]$Reconnected=$false,
        [ValidateSet('unavailable','none','unclassified','server_not_responding','connection_reset','connection_refused','connection_timeout','connection_closed','host_key_rejected','authentication_failed')][string]$SshError='unavailable',
        [ValidateRange(0,599)][int]$HttpStatus=0, [int]$BackoffSec=0,
        [ValidateSet('none','managed_process_exited','transport_stalled','unmanaged_listener','tailscale_unreachable','ssh_host_key_unavailable','ssh_auth_or_start_failed','gateway_timeout')][string]$Reason='none'
    )
    $stateDirectory=Get-CvsStateDirectory
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    Set-CvsPrivateAcl $stateDirectory
    $now=Get-CvsUtcNow
    if($null -ne $LastSuccess){$script:LastTunnelSuccess=$LastSuccess}else{$LastSuccess=$script:LastTunnelSuccess}
    $entry=[ordered]@{TimestampUtc=$now.ToUniversalTime().ToString('o');TimestampLocal=$now.ToLocalTime().ToString('o')
        State=$State;Code=$Code;DurationMs=$DurationMs;ConsecutiveFailures=$Failures
        LastSuccessUtc=if($null -ne $LastSuccess){$LastSuccess.ToUniversalTime().ToString('o')}else{$null}
        ReconnectAttempt=$ReconnectAttempt;Reconnected=$Reconnected;RecoveryReason=$Reason;SshExitCode=$ExitCode;SshError=$SshError;ProcessId=$ProcessId;HttpStatus=$HttpStatus;BackoffSec=$BackoffSec}
    $json=$entry | ConvertTo-Json -Compress
    $logPath=Join-Path $stateDirectory 'persistent-tunnel.log'
    if((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1MB){
        Move-Item -LiteralPath $logPath -Destination "${logPath}.1" -Force
    }
    Add-Content -LiteralPath $logPath -Value $json -Encoding utf8NoBOM
    Set-CvsPrivateAcl $logPath
    $temporary=Join-Path $stateDirectory 'tunnel-status.json.tmp'
    Set-Content -LiteralPath $temporary -Value $json -Encoding utf8NoBOM
    Set-CvsPrivateAcl $temporary
    Move-Item -LiteralPath $temporary -Destination (Join-Path $stateDirectory 'tunnel-status.json') -Force
}

function Invoke-CvsTunnelMonitor {
    param([Parameter(Mandatory)]$Tunnel, [Parameter(Mandatory)]$Policy, [int]$ReconnectAttempt=0, $LastRecovery=$null, [hashtable]$RecoveryContext=@{})
    $process=if($Tunnel.Reused){$Tunnel.ManagedProcess}else{$Tunnel.Process}
    # Keep an open handle so reused processes retain their exit code after termination.
    if($process -is [Diagnostics.Process]){$null=$process.Handle}
    $started=Get-CvsUtcNow; $lastSuccess=$null; $firstFailure=$null; $failures=0; $wasHealthy=[bool]$Tunnel.Reused
    $announcedRecovery=$false; $lastRecoveryCheck=$null
    $startupBudget=if($Tunnel.PSObject.Properties['StartupRemainingSec']){$Tunnel.StartupRemainingSec}else{$Policy.StartupBudgetSec}
    while(-not (Test-CvsDesktopStopRequested)) {
        if($process.HasExited){
            $sshError=if($Tunnel.PSObject.Properties['Diagnostics'] -and $Tunnel.Diagnostics){$Tunnel.Diagnostics.GetErrorCode()}else{'unavailable'}
            Write-CvsTunnelEvent -State Recovering -Code managed_process_exited -ExitCode $process.ExitCode -ProcessId $process.Id -SshError $sshError -ReconnectAttempt $ReconnectAttempt
            return 'managed_process_exited'
        }
        $probeStart=Get-CvsUtcNow
        $timeout=$Policy.HealthTimeoutSec
        if(-not $wasHealthy){
            $remaining=[int][math]::Floor($startupBudget-($probeStart-$started).TotalSeconds)
            if($remaining -lt 1){return 'gateway_timeout'}
            $timeout=[math]::Min($timeout,$remaining)
        }
        $probe=Test-CvsGatewayHealth -Profile $Tunnel.Profile -Port ([int]$Tunnel.Profile.client.local_port) -TimeoutSec $timeout -Detailed
        $now=Get-CvsUtcNow
        if($probe.Code -eq 'health_probe_busy'){
            if(-not (Wait-CvsMonitorDelay -Seconds 1 -Process $process)){return 'stopped'}
            continue
        }
        if($probe.Success){
            $failures=0; $firstFailure=$null; $lastSuccess=$now; $wasHealthy=$true
            $RecoveryContext.HadHealthyProbe=$true
            $code=if($ReconnectAttempt -gt 0 -and -not $announcedRecovery){'recovered'}else{'healthy'}
            $recoveryReason=if($code -eq 'recovered' -and $RecoveryContext.ContainsKey('Reason')){$RecoveryContext.Reason}else{'none'}
            Write-CvsTunnelEvent -State Healthy -Code $code -DurationMs $probe.DurationMs -Failures 0 -LastSuccess $lastSuccess -ReconnectAttempt $ReconnectAttempt -ProcessId $process.Id -HttpStatus $probe.HttpStatus -Reconnected:($code -eq 'recovered') -Reason $recoveryReason
            if($code -eq 'recovered'){$LastRecovery=$now;$RecoveryContext.LastRecovery=$now;$announcedRecovery=$true}
        } else {
            $failures++
            if($null -eq $firstFailure){$firstFailure=$probeStart}
            Write-CvsTunnelEvent -State Suspect -Code $probe.Code -DurationMs $probe.DurationMs -Failures $failures -LastSuccess $lastSuccess -ReconnectAttempt $ReconnectAttempt -ProcessId $process.Id -HttpStatus $probe.HttpStatus
            if($probe.Code -eq 'unmanaged_listener'){return 'unmanaged_listener'}
            if(-not $wasHealthy -and ($now-$started).TotalSeconds -ge $startupBudget){return 'gateway_timeout'}
            $grace=[math]::Max($Policy.MinUnhealthyDurationSec,$Policy.ActiveSessionGraceSec)
            $cooldownPassed=($null -eq $LastRecovery -or ($now-$LastRecovery).TotalSeconds -ge $Policy.RestartCooldownSec)
            $cooldownPassed=$cooldownPassed -and ($null -eq $lastRecoveryCheck -or ($now-$lastRecoveryCheck).TotalSeconds -ge $Policy.RestartCooldownSec)
            if($wasHealthy -and $failures -ge $Policy.ConsecutiveFailureThreshold -and ($now-$firstFailure).TotalSeconds -ge $grace -and $cooldownPassed){
                if(Test-CvsGatewayModels -Port ([int]$Tunnel.Profile.client.local_port) -TimeoutSec ([math]::Max(45,$Policy.HealthTimeoutSec))){
                    $failures=0; $firstFailure=$null; $lastSuccess=Get-CvsUtcNow
                    Write-CvsTunnelEvent -State Suspect -Code gateway_responsive -LastSuccess $lastSuccess -ReconnectAttempt $ReconnectAttempt -ProcessId $process.Id
                } else {
                    $lastRecoveryCheck=Get-CvsUtcNow
                    # Established includes idle pooled sockets; conservatively wait for clients to drain.
                    if(Test-CvsTunnelHasClients -Port ([int]$Tunnel.Profile.client.local_port) -OwnerProcessId $process.Id){
                        Write-CvsTunnelEvent -State Suspect -Code recovery_deferred -Failures $failures -ReconnectAttempt $ReconnectAttempt -ProcessId $process.Id
                    } elseif(-not (Test-CvsReplacementTunnel -Profile $Tunnel.Profile -Policy $Policy)){
                        Write-CvsTunnelEvent -State Suspect -Code replacement_unavailable -Failures $failures -ReconnectAttempt $ReconnectAttempt -ProcessId $process.Id
                    } elseif(-not (Test-CvsDesktopStopRequested)) {
                        if(Test-CvsTunnelHasClients -Port ([int]$Tunnel.Profile.client.local_port) -OwnerProcessId $process.Id){
                            Write-CvsTunnelEvent -State Suspect -Code recovery_deferred -Failures $failures -ReconnectAttempt $ReconnectAttempt -ProcessId $process.Id
                        } else {
                            Write-CvsTunnelEvent -State Recovering -Code replacement_verified -ReconnectAttempt $ReconnectAttempt -ProcessId $process.Id
                            Write-CvsTunnelEvent -State Recovering -Code transport_stalled -Failures $failures -LastSuccess $lastSuccess -ReconnectAttempt $ReconnectAttempt -ProcessId $process.Id
                            return 'transport_stalled'
                        }
                    }
                    $lastRecoveryCheck=Get-CvsUtcNow
                }
            }
        }
        if(Test-CvsDesktopStopRequested){return 'stopped'}
        $delay=$Policy.HealthIntervalSec
        if(-not $wasHealthy){$delay=[math]::Min(1,[math]::Max(0,$startupBudget-($now-$started).TotalSeconds))}
        if(-not (Wait-CvsMonitorDelay -Seconds $delay -Process $process)){return 'stopped'}
    }
    return 'stopped'
}

function Invoke-CvsPersistentTunnel {
    [CmdletBinding()]
    param([switch]$StartRequested)
    $stateDirectory=Get-CvsStateDirectory
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    Set-CvsPrivateAcl $stateDirectory
    try { $lock=[IO.File]::Open((Join-Path $stateDirectory 'persistent-tunnel.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch [IO.IOException] {return}
    $tunnel=$null; $attempt=0; $failureStreak=0; $script:LastTunnelSuccess=$null
    $recovery=@{LastRecovery=$null;HadHealthyProbe=$false;Reason='none'}
    try {
        # A new task activation resumes service; duplicates must not clear a stop request.
        $stopPath=Join-Path $stateDirectory 'desktop-stopped'
        if($StartRequested -and (Test-Path -LiteralPath $stopPath)){Remove-Item -LiteralPath $stopPath -Force}
        try {$policy=Get-CvsTunnelPolicy} catch {
            Write-CvsTunnelEvent -State Backoff -Code invalid_runtime_policy
            throw 'invalid_runtime_policy'
        }
        $policyPath=Join-Path (Get-CvsConfigDirectory) 'runtime-policy.json'
        if(Test-Path -LiteralPath $policyPath){Set-CvsPrivateAcl $policyPath}
        while(-not (Test-CvsDesktopStopRequested)) {
            $reason='ssh_auth_or_start_failed'
            $recovery.HadHealthyProbe=$false
            Write-CvsTunnelEvent -State Starting -Code starting -ReconnectAttempt $attempt
            try {
                $tunnel=Start-CvsTunnel -Persistent -Policy $policy
                $reason=Invoke-CvsTunnelMonitor -Tunnel $tunnel -Policy $policy -ReconnectAttempt $attempt -LastRecovery $recovery.LastRecovery -RecoveryContext $recovery
            } catch {
                # Fixed codes only; never log exception messages, commands or HTTP bodies.
                if($_.Exception.Message -in @('tailscale_unreachable','ssh_host_key_unavailable','ssh_auth_or_start_failed','gateway_timeout','unmanaged_listener')){$reason=$_.Exception.Message}
                Write-CvsTunnelEvent -State Recovering -Code $reason -ReconnectAttempt $attempt
            } finally {
                if($tunnel){
                    try {Stop-CvsTunnel -Tunnel $tunnel -IncludeReused} catch {$reason='unmanaged_listener'}
                    if($reason -ne 'stopped' -and -not (Test-CvsDesktopStopRequested)){
                        if(-not (Wait-CvsLocalPortReleased -Port ([int]$tunnel.Profile.client.local_port) -TimeoutSec $policy.PortReleaseTimeoutSec)){$reason='unmanaged_listener'}
                    }
                    $tunnel=$null
                }
            }
            if($reason -eq 'stopped' -or (Test-CvsDesktopStopRequested)){break}
            $attempt++
            if($recovery.HadHealthyProbe){$failureStreak=0}
            $failureStreak++
            $recovery.Reason=$reason
            $delay=$policy.ReconnectBackoffSec[[math]::Min($failureStreak-1,$policy.ReconnectBackoffSec.Count-1)]
            # The monitor enforces cooldown for established channels. Backoff
            # also caps creation rate when no usable tunnel can be established.
            Write-CvsTunnelEvent -State Backoff -Code restart_backoff -Reason $reason -ReconnectAttempt $attempt -BackoffSec $delay
            if(-not (Wait-CvsMonitorDelay -Seconds $delay)){break}
        }
    } finally {
        if(Test-CvsDesktopStopRequested){Write-CvsTunnelEvent -State Stopped -Code stopped -ReconnectAttempt $attempt}
        $lock.Dispose()
    }
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

function Get-CvsDesktopBackupPath {
    return Join-Path (Get-CvsConfigDirectory) "desktop-config.toml.backup"
}

function Get-CvsDesktopAbsentMarkerPath {
    return Join-Path (Get-CvsConfigDirectory) "desktop-config.toml.absent"
}

function Backup-CvsDesktopCodexConfig {
    $codexHome = Get-CvsCodexHome
    $configPath = Join-Path $codexHome "config.toml"
    $backupPath = Get-CvsDesktopBackupPath
    $absentMarker = Get-CvsDesktopAbsentMarkerPath
    New-Item -ItemType Directory -Force -Path $codexHome,(Get-CvsConfigDirectory) | Out-Null
    if ((Test-Path -LiteralPath $backupPath) -and (Test-Path -LiteralPath $absentMarker)) { throw "Desktop configuration backup state is inconsistent" }
    if ((Test-Path -LiteralPath $backupPath) -or (Test-Path -LiteralPath $absentMarker)) { return }
    if (Test-Path -LiteralPath $configPath) {
        $item = Get-Item -LiteralPath $configPath -Force
        if ($item.LinkType -or $item.PSIsContainer) { throw "Codex config is unsafe" }
        Copy-Item -LiteralPath $configPath -Destination $backupPath
        Set-CvsPrivateAcl $backupPath
    } else {
        New-Item -ItemType File -Path $absentMarker | Out-Null
        Set-CvsPrivateAcl $absentMarker
    }
}

function Remove-CvsDesktopManagedBlocks {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    foreach ($pair in @(
        @($script:DesktopRootBegin, $script:DesktopRootEnd),
        @($script:DesktopProviderBegin, $script:DesktopProviderEnd)
    )) {
        $pattern = '(?ms)^' + [regex]::Escape($pair[0]) + '\r?\n.*?^' + [regex]::Escape($pair[1]) + '\r?\n?'
        $Content = [regex]::Replace($Content, $pattern, '')
    }
    return $Content
}

function Set-CvsDesktopCodexConfig {
    param([Parameter(Mandatory)]$Profile)
    $configPath = Join-Path (Get-CvsCodexHome) "config.toml"
    if (Test-Path -LiteralPath $configPath) {
        $item = Get-Item -LiteralPath $configPath -Force
        if ($item.LinkType -or $item.PSIsContainer) { throw "Codex config is unsafe" }
        $content = Get-Content -LiteralPath $configPath -Raw
    } else {
        $content = ""
    }
    $content = Remove-CvsDesktopManagedBlocks -Content $content
    if ($content -match '(?m)^\s*\[model_providers\.codex_via_server_desktop\]\s*(?:#.*)?$') {
        throw "The reserved desktop provider already exists outside the managed block"
    }

    $lines = @($content -split '\r?\n')
    $kept = [System.Collections.Generic.List[string]]::new()
    $atRoot = $true
    foreach ($line in $lines) {
        if ($atRoot -and $line -match '^\s*\[') { $atRoot = $false }
        if ($atRoot -and $line -match '^\s*model_provider\s*=') { continue }
        $kept.Add($line)
    }
    $preserved = ($kept -join "`r`n").Trim()
    $rootBlock = @(
        $script:DesktopRootBegin,
        "model_provider = `"$($script:DesktopProviderName)`"",
        $script:DesktopRootEnd
    ) -join "`r`n"
    $providerBlock = @(
        $script:DesktopProviderBegin,
        "[model_providers.$($script:DesktopProviderName)]",
        'name = "Codex via Server persistent tunnel"',
        "base_url = `"http://127.0.0.1:$($Profile.client.local_port)/v1`"",
        'wire_api = "responses"',
        'supports_websockets = false',
        'requires_openai_auth = false',
        $script:DesktopProviderEnd
    ) -join "`r`n"
    $parts = @($rootBlock)
    if ($preserved) { $parts += $preserved }
    $parts += $providerBlock
    Set-Content -LiteralPath $configPath -Value (($parts -join "`r`n`r`n") + "`r`n") -Encoding utf8NoBOM
    Set-CvsPrivateAcl $configPath
    return $configPath
}

function Restore-CvsDesktopCodexConfig {
    $configPath = Join-Path (Get-CvsCodexHome) "config.toml"
    $backupPath = Get-CvsDesktopBackupPath
    $absentMarker = Get-CvsDesktopAbsentMarkerPath
    if ((Test-Path -LiteralPath $backupPath) -and (Test-Path -LiteralPath $absentMarker)) { throw "Desktop configuration backup state is inconsistent" }
    if (Test-Path -LiteralPath $backupPath) {
        if ((Test-Path -LiteralPath $configPath) -and (Get-Item -LiteralPath $configPath -Force).LinkType) { throw "Codex config is unsafe" }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configPath) | Out-Null
        Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
        Set-CvsPrivateAcl $configPath
        Remove-Item -LiteralPath $backupPath -Force
    } elseif (Test-Path -LiteralPath $absentMarker) {
        if (Test-Path -LiteralPath $configPath) {
            $item = Get-Item -LiteralPath $configPath -Force
            if ($item.LinkType -or $item.PSIsContainer) { throw "Codex config is unsafe" }
            Remove-Item -LiteralPath $configPath -Force
        }
        Remove-Item -LiteralPath $absentMarker -Force
    } elseif (Test-Path -LiteralPath $configPath) {
        $content = Get-Content -LiteralPath $configPath -Raw
        if ($content.Contains($script:DesktopRootBegin) -or $content.Contains($script:DesktopProviderBegin)) {
            throw "Cannot restore Codex config because the desktop backup is missing"
        }
    }
}

function Get-CvsCurrentUserId {
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Get-CvsDesktopTaskName {
    $root = [IO.Path]::GetFullPath((Get-CvsRoot)).TrimEnd([IO.Path]::DirectorySeparatorChar).ToLowerInvariant()
    $defaultRoot = [IO.Path]::GetFullPath((Join-Path $HOME '.codex-via-server')).ToLowerInvariant()
    if ($root -eq $defaultRoot) { return 'CodexViaServer Persistent Tunnel' }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($root)))
    return 'CodexViaServer Persistent Tunnel ' + $hash.Substring(0, 12)
}

function Register-CvsDesktopTask {
    $installRoot = Get-CvsInstallRoot
    $tunnelScript = Join-Path $installRoot "persistent-tunnel.ps1"
    if (-not (Test-Path -LiteralPath $tunnelScript -PathType Leaf) -or (Get-Item -LiteralPath $tunnelScript -Force).LinkType) {
        throw "Persistent tunnel script is missing or unsafe"
    }
    $pwsh = Get-CvsExecutable "CODEX_VIA_SERVER_PWSH" "pwsh.exe"
    $userId = Get-CvsCurrentUserId
    $paths = @($tunnelScript, (Get-CvsRoot), (Get-CvsCodexHome), (Get-CvsKeyDirectory))
    foreach ($path in $paths) {
        if (-not [IO.Path]::IsPathFullyQualified($path) -or $path -match '["\r\n]' -or $path.EndsWith('\')) { throw 'unsafe_task_path' }
    }
    $actionArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ClientHome "{1}" -CodexHome "{2}" -KeyDirectory "{3}"' -f $paths
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument $actionArguments -WorkingDirectory $installRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $settings = New-ScheduledTaskSettingsSet -Hidden -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal
    Register-ScheduledTask -TaskName (Get-CvsDesktopTaskName) -InputObject $task -Force | Out-Null
}

function Remove-CvsDesktopTask {
    $task = Get-ScheduledTask -TaskName (Get-CvsDesktopTaskName) -ErrorAction SilentlyContinue
    if (-not $task) { return }
    Stop-ScheduledTask -TaskName (Get-CvsDesktopTaskName) -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName (Get-CvsDesktopTaskName) -Confirm:$false
}

function Wait-CvsDesktopGateway {
    param([Parameter(Mandatory)][int]$Port)
    $policy=Get-CvsTunnelPolicy; $timer=[Diagnostics.Stopwatch]::StartNew()
    # Include one automatic retry and its backoff, bounded for interactive callers.
    $waitBudget=[math]::Min(120,2*$policy.StartupBudgetSec+$policy.ReconnectBackoffSec[0])
    while($timer.Elapsed.TotalSeconds -lt $waitBudget) {
        if(Test-CvsDesktopStopRequested){return $false}
        $managed = Get-CvsManagedTunnelProcess
        $remaining=[int][math]::Floor($waitBudget-$timer.Elapsed.TotalSeconds)
        if($remaining -lt 1){break}
        if ($managed -and (Test-CvsGatewayHealth -Port $Port -TimeoutSec ([math]::Min($policy.HealthTimeoutSec,$remaining)))) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Stop-CvsDesktopRuntime {
    [CmdletBinding()]
    param()
    $profile = Get-CvsConnectionProfile
    $process = Get-CvsManagedTunnelProcess -Profile $profile -IncludeStarting
    if ($process -and -not $process.HasExited) {
        return Stop-CvsManagedProcess -Profile $profile -Process $process
    }
    return $false
}

function Install-CvsDesktop {
    [CmdletBinding()]
    param()
    $profile = Get-CvsConnectionProfile
    Protect-CvsClientDirectories
    Protect-CvsApprovedDeviceFiles -Profile $profile
    Backup-CvsDesktopCodexConfig
    try {
        Set-CvsDesktopCodexConfig -Profile $profile | Out-Null
        Register-CvsDesktopTask
        $stopPath=Join-Path (Get-CvsStateDirectory) 'desktop-stopped'
        if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath -Force}
        Start-ScheduledTask -TaskName (Get-CvsDesktopTaskName)
        if (-not (Wait-CvsDesktopGateway -Port ([int]$profile.client.local_port))) { throw "Persistent tunnel health check failed" }
        return [pscustomobject]@{Status="pass";TaskName=(Get-CvsDesktopTaskName);Url="http://127.0.0.1:$($profile.client.local_port)/v1"}
    } catch {
        Remove-CvsDesktopTask
        try { Stop-CvsDesktopRuntime | Out-Null } catch {}
        Restore-CvsDesktopCodexConfig
        throw
    }
}

function Get-CvsDesktopStatus {
    [CmdletBinding()]
    param([switch]$CheckAPI)
    $profile = Get-CvsConnectionProfile
    $task = Get-ScheduledTask -TaskName (Get-CvsDesktopTaskName) -ErrorAction SilentlyContinue
    if (-not $task) { throw "Persistent tunnel task is not installed" }
    $process = Get-CvsManagedTunnelProcess -Profile $profile
    $policy=Get-CvsTunnelPolicy
    $health=Test-CvsGatewayHealth -Profile $profile -Port ([int]$profile.client.local_port) -TimeoutSec $policy.HealthTimeoutSec -Detailed
    $stopped=Test-CvsDesktopStopRequested
    $snapshot=$null; $statePath=Join-Path (Get-CvsStateDirectory) 'tunnel-status.json'
    if(Test-Path -LiteralPath $statePath){try{$snapshot=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json}catch{}}
    $healthSource='live'
    if($health.Code -eq 'health_probe_busy'){
        $healthSource='probe_in_progress'
        # A serialized probe is not a failed probe. Reuse only a recent, healthy
        # supervisor observation for this exact live process, never a stale PID.
        try {
            $last=[DateTimeOffset]$snapshot.LastSuccessUtc
            $age=((Get-CvsUtcNow)-$last).TotalSeconds
            if($process -and $snapshot.State -eq 'Healthy' -and $snapshot.ProcessId -eq $process.Id -and
                $last.UtcDateTime -ge $process.StartTime.ToUniversalTime() -and
                $age -ge 0 -and $age -le ($policy.HealthTimeoutSec+$policy.HealthIntervalSec+2)){
                $health=[pscustomobject]@{Success=$true;Code='healthy';DurationMs=$snapshot.DurationMs}
                $healthSource='recent_supervisor_probe'
            }
        } catch { # Missing, malformed or stale state is never a healthy cache.
        }
    }
    $upstream='not_checked'
    if($CheckAPI -and $health.Success){$upstream=if(Test-CvsGatewayModels -Port ([int]$profile.client.local_port)){'models_available'}else{'models_unavailable'}}
    return [pscustomobject]@{
        Status=if($stopped){'stopped'}elseif($health.Success){'pass'}elseif($health.Code -eq 'health_probe_busy'){'checking'}else{'degraded'}
        TaskName=(Get-CvsDesktopTaskName);TaskState=[string]$task.State
        ProcessId=if($process){$process.Id}else{$null};Url="http://127.0.0.1:$($profile.client.local_port)/v1"
        TunnelHealth=if($health.Success){'healthy'}else{$health.Code};UpstreamAPI=$upstream
        DurationMs=$health.DurationMs;HealthSource=$healthSource;MonitorState=if($stopped){'Stopped'}elseif($snapshot){$snapshot.State}else{'unknown'}
        LastSuccessUtc=if($snapshot){$snapshot.LastSuccessUtc}else{$null}
    }
}

function Start-CvsDesktopCore {
    $profile = Get-CvsConnectionProfile
    $task=Get-ScheduledTask -TaskName (Get-CvsDesktopTaskName) -ErrorAction SilentlyContinue
    if (-not $task) { throw 'Persistent tunnel task is not installed' }
    $stopPath=Join-Path (Get-CvsStateDirectory) 'desktop-stopped'
    if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath -Force}
    if([string]$task.State -ne 'Running'){Start-ScheduledTask -TaskName (Get-CvsDesktopTaskName)}
    if (-not (Wait-CvsDesktopGateway -Port ([int]$profile.client.local_port))) { throw 'desktop_start_unavailable: check desktop-status and persistent-tunnel.log; supervisor recovery remains enabled' }
    return [pscustomobject]@{Status='pass';TaskName=(Get-CvsDesktopTaskName);TunnelHealth='healthy';UpstreamAPI='not_checked';Url="http://127.0.0.1:$($profile.client.local_port)/v1"}
}

function Stop-CvsDesktopCore {
    if (-not (Get-ScheduledTask -TaskName (Get-CvsDesktopTaskName) -ErrorAction SilentlyContinue)) { throw "Persistent tunnel task is not installed" }
    $stateDirectory=Get-CvsStateDirectory
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null; Set-CvsPrivateAcl $stateDirectory
    $stopPath=Join-Path $stateDirectory 'desktop-stopped'
    Set-Content -LiteralPath $stopPath -Value 'stopped' -Encoding utf8NoBOM; Set-CvsPrivateAcl $stopPath
    Stop-ScheduledTask -TaskName (Get-CvsDesktopTaskName) -ErrorAction Stop
    $deadline=[Diagnostics.Stopwatch]::StartNew()
    while([string](Get-ScheduledTask -TaskName (Get-CvsDesktopTaskName)).State -eq 'Running'){
        if($deadline.Elapsed.TotalSeconds -gt 10){throw 'desktop_stop_task_timeout'}
        Start-Sleep -Milliseconds 200
    }
    $runtimeStopped = Stop-CvsDesktopRuntime
    $profile=Get-CvsConnectionProfile
    if(-not (Wait-CvsLocalPortReleased -Port ([int]$profile.client.local_port))){throw 'unmanaged_listener'}
    Write-CvsTunnelEvent -State Stopped -Code stopped
    return [pscustomobject]@{Status="stopped";TaskName=(Get-CvsDesktopTaskName);RuntimeStopped=[bool]$runtimeStopped}
}

function Invoke-CvsDesktopControl {
    param([Parameter(Mandatory)][scriptblock]$Action)
    $mutex=New-CvsMutex -Kind Control; $locked=$false
    try {
        try {$locked=$mutex.WaitOne(10000)} catch [Threading.AbandonedMutexException] {$locked=$true}
        if(-not $locked){throw 'desktop_control_busy'}
        & $Action
    } finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

function Start-CvsDesktop {
    [CmdletBinding()]param()
    Invoke-CvsDesktopControl {Start-CvsDesktopCore}
}

function Stop-CvsDesktop {
    [CmdletBinding()]param()
    Invoke-CvsDesktopControl {Stop-CvsDesktopCore}
}

function Restart-CvsDesktop {
    [CmdletBinding()]
    param()
    Invoke-CvsDesktopControl {Stop-CvsDesktopCore | Out-Null; Start-CvsDesktopCore}
}

function Uninstall-CvsDesktop {
    [CmdletBinding()]
    param()
    Invoke-CvsDesktopControl {
        if(Get-ScheduledTask -TaskName (Get-CvsDesktopTaskName) -ErrorAction SilentlyContinue){
            Stop-CvsDesktopCore | Out-Null
        } else {
            try { Stop-CvsDesktopRuntime | Out-Null } catch [System.Management.Automation.ItemNotFoundException] {}
        }
        Remove-CvsDesktopTask
        Restore-CvsDesktopCodexConfig
        [pscustomobject]@{Status="uninstalled";TaskName=(Get-CvsDesktopTaskName);ConfigRestored=$true}
    }
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
        foreach ($file in @("codex-via-server.ps1","CodexViaServer.psm1","persistent-tunnel.ps1","stop-persistent-tunnel.ps1","VERSION")) {
            $candidate = Join-Path $packageRoot $file
            if (-not (Test-Path $candidate) -or (Get-Item $candidate -Force).LinkType) { throw "Candidate file is missing or unsafe: $file" }
        }
        if ((Get-Content (Join-Path $packageRoot "VERSION") -Raw).Trim() -cne $latest) { throw "Package version mismatch" }
        foreach ($scriptFile in @("codex-via-server.ps1","CodexViaServer.psm1","persistent-tunnel.ps1","stop-persistent-tunnel.ps1")) {
            $tokens=$null;$errors=$null
            [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $packageRoot $scriptFile),[ref]$tokens,[ref]$errors)|Out-Null
            if ($errors.Count -gt 0) { throw "Candidate PowerShell parse failed" }
        }
        if (Test-Path $installRoot) { Copy-Item $installRoot (Join-Path $backup "install") -Recurse -Force } else { New-Item -ItemType File (Join-Path $backup "install.absent") | Out-Null }
        New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
        Copy-Item (Join-Path $packageRoot "*") $installRoot -Recurse -Force
        Set-CvsPrivateAcl $installRoot
        foreach ($file in @("codex-via-server.ps1","CodexViaServer.psm1","persistent-tunnel.ps1","stop-persistent-tunnel.ps1","VERSION")) {
            Set-CvsPrivateAcl (Join-Path $installRoot $file)
        }
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
    Uninstall-CvsDesktop | Out-Null
    $root = Get-CvsRoot
    $config = Join-Path (Get-CvsConfigDirectory) "connection-profile.json"
    $deviceId=$null;$profileName="codex-via-server"
    if (Test-Path $config) { $profile=Get-Content $config -Raw|ConvertFrom-Json;$deviceId=$profile.approved_device.device_id;$profileName=$profile.client.codex_profile }
    if ($profileName -cnotmatch '^[A-Za-z0-9_-]{3,64}$') { throw "Unsafe profile name" }
    $codexHome=Get-CvsCodexHome
    $targets=@((Get-CvsInstallRoot),$config,(Join-Path $codexHome "$profileName.config.toml"))
    $backup=Join-Path (Get-CvsStateDirectory) "uninstall-backups/$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$PID"
    New-Item -ItemType Directory -Force -Path $backup|Out-Null
    foreach($target in $targets){if(Test-Path $target){$item=Get-Item $target -Force;if($item.LinkType){throw "Refusing symbolic link"};Copy-Item $target (Join-Path $backup ([guid]::NewGuid().ToString('N'))) -Recurse -Force;Remove-Item $target -Recurse -Force}}
    if($RemoveDeviceKey -and $deviceId){foreach($key in @((Join-Path (Get-CvsKeyDirectory) $deviceId),(Join-Path (Get-CvsKeyDirectory) "$deviceId.pub"))){if(Test-Path $key){Remove-Item $key -Force}}}
    return [pscustomobject]@{Status="uninstalled";Backup=$backup;DeviceKeyRemoved=[bool]$RemoveDeviceKey}
}

Export-ModuleMember -Function Initialize-CvsDevice, Import-CvsConnectionProfile, Test-CvsVersionAtLeast, Set-CvsPrivateAcl, Start-CvsTunnel, Stop-CvsTunnel, Test-CvsGatewayModels, Test-CvsGatewayHealth, Get-CvsTunnelPolicy, Invoke-CvsPersistentTunnel, Test-CvsDoctor, Invoke-CvsCodex, Install-CvsDesktop, Start-CvsDesktop, Get-CvsDesktopStatus, Get-CvsDesktopTaskName, Restart-CvsDesktop, Stop-CvsDesktop, Uninstall-CvsDesktop, Stop-CvsDesktopRuntime, Update-CvsClient, Uninstall-CvsClient
