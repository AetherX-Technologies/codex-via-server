Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$clientModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'client/CodexViaServer.psm1'
if (-not (Test-Path -LiteralPath $clientModule)) { $clientModule = Join-Path $PSScriptRoot '../CodexViaServer.psm1' }
$script:Client = Import-Module $clientModule -PassThru -DisableNameChecking

function Assert-AdminPath([string]$Path, [switch]$Existing) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'admin_unsafe_path' }
    for ($cursor = $Path; $cursor; $cursor = Split-Path -Parent $cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'admin_unsafe_path' }
    }
    if ($Existing -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'admin_file_missing' }
}

function Read-AdminJson([string]$Path) {
    Assert-AdminPath $Path -Existing
    if ((Get-Item -LiteralPath $Path).Length -gt 65536) { throw 'admin_invalid_json' }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Assert-AdminFields($Value, [string[]]$Fields) {
    if ($Value -isnot [pscustomobject] -or (Compare-Object @($Value.PSObject.Properties.Name | Sort-Object) @($Fields | Sort-Object))) { throw 'admin_invalid_fields' }
}

function Read-CvsAdminConfig([string]$Path) {
    $config = Read-AdminJson $Path
    Assert-AdminFields $config @('schema_version','profile_id','admin','tunnel','gateway','client')
    Assert-AdminFields $config.admin @('host','port','user','identity','host_fingerprints')
    Assert-AdminFields $config.tunnel @('host','port','user')
    Assert-AdminFields $config.gateway @('remote_host','remote_port')
    Assert-AdminFields $config.client @('local_port','codex_profile','minimum_client_version','minimum_codex_version')
    if (($config.schema_version -isnot [int] -and $config.schema_version -isnot [long]) -or $config.schema_version -ne 1 -or $config.profile_id -isnot [string] -or $config.profile_id -cnotmatch '^[a-z0-9][a-z0-9._-]{1,62}[a-z0-9]$') { throw 'admin_invalid_config' }
    $hostPattern = '^(100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\.(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})|[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?){1,6})$'
    foreach ($hostName in @($config.admin.host,$config.tunnel.host)) { if ($hostName -isnot [string] -or $hostName -cnotmatch $hostPattern) { throw 'admin_invalid_host' } }
    foreach ($port in @($config.admin.port,$config.tunnel.port,$config.gateway.remote_port,$config.client.local_port)) {
        if (($port -isnot [int] -and $port -isnot [long]) -or $port -lt 1 -or $port -gt 65535) { throw 'admin_invalid_port' }
    }
    if ($config.gateway.remote_port -lt 1024 -or $config.client.local_port -lt 1024 -or $config.gateway.remote_host -cne '127.0.0.1' -or $config.tunnel.user -cne 'codex-tunnel') { throw 'admin_invalid_gateway' }
    # shortcut: one SSH endpoint supplies both admin and tunnel pins; separate hosts need separate pin fields.
    if ($config.admin.host -cne $config.tunnel.host -or $config.admin.port -ne $config.tunnel.port) { throw 'admin_endpoint_mismatch' }
    if ($config.admin.user -isnot [string] -or $config.admin.user -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$' -or $config.admin.user -ceq 'codex-tunnel') { throw 'admin_identity_required' }
    if ($config.admin.host_fingerprints -isnot [array] -or $config.admin.host_fingerprints.Count -lt 1 -or $config.admin.host_fingerprints.Count -gt 4) { throw 'admin_invalid_fingerprints' }
    foreach ($pin in $config.admin.host_fingerprints) { if ($pin -isnot [string] -or $pin -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$') { throw 'admin_invalid_fingerprints' } }
    if ($config.client.codex_profile -isnot [string] -or $config.client.codex_profile -cnotmatch '^[A-Za-z0-9_-]{3,64}$') { throw 'admin_invalid_config' }
    foreach ($version in @($config.client.minimum_client_version,$config.client.minimum_codex_version)) { if ($version -isnot [string] -or $version -cnotmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'admin_invalid_config' } }
    if ($config.admin.identity -isnot [string]) { throw 'admin_identity_required' }
    Assert-AdminPath $config.admin.identity -Existing
    return $config
}

function Write-AdminJson($Value, [string]$Path) {
    Assert-AdminPath $Path
    if (Test-Path -LiteralPath $Path) { throw 'admin_output_exists' }
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'admin_output_directory_missing' }
    $temporary = Join-Path $directory ('.cvs-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew); $stream.Dispose()
        Set-CvsPrivateAcl $temporary
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Save-CvsAdminConfig([string]$ProfilePath, [string]$User, [string]$Identity, [string]$OutputPath) {
    $profile = Read-AdminJson $ProfilePath
    & $script:Client { param($p) Assert-CvsConnectionProfile $p } $profile
    $config = [pscustomobject]@{
        schema_version=1; profile_id=$profile.profile_id
        admin=[pscustomobject]@{host=$profile.server.host;port=$profile.server.ssh_port;user=$User;identity=$Identity;host_fingerprints=$profile.server.host_fingerprints}
        tunnel=[pscustomobject]@{host=$profile.server.host;port=$profile.server.ssh_port;user='codex-tunnel'}
        gateway=$profile.gateway; client=$profile.client
    }
    # Save only paths and verified service defaults; never read or copy the administrator key.
    Write-AdminJson $config $OutputPath
    try { Read-CvsAdminConfig $OutputPath | Out-Null } catch { Remove-Item -LiteralPath $OutputPath -Force; throw }
}

function Get-CvsAdminRequest([string]$Path) {
    $request = Read-AdminJson $Path
    Assert-AdminFields $request @('schema_version','device_id','platform','public_key','requested_at')
    if (($request.schema_version -isnot [int] -and $request.schema_version -isnot [long]) -or $request.schema_version -ne 1 -or $request.device_id -isnot [string] -or $request.platform -isnot [string] -or $request.device_id -cnotmatch '^[a-z0-9][a-z0-9._-]{1,62}[a-z0-9]$' -or $request.platform -cnotin @('windows','macos')) { throw 'admin_invalid_request' }
    if ($request.public_key -isnot [string] -or $request.public_key -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]{32,}={0,3}( [A-Za-z0-9][A-Za-z0-9._@+-]{0,127})?$' -or $request.public_key.Length -gt 512) { throw 'admin_invalid_request' }
    $date = [DateTimeOffset]::MinValue
    $dateText = if ($request.requested_at -is [datetime]) { $request.requested_at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [string]$request.requested_at }
    if (-not [DateTimeOffset]::TryParseExact($dateText,'yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$date)) { throw 'admin_invalid_request' }
    $request.requested_at = $dateText
    $publicBlob = $request.public_key.Split(' ')[1]
    $blob = [Convert]::FromBase64String($publicBlob)
    # Ed25519 SSH wire format: string("ssh-ed25519"), string(32-byte public key).
    if ($blob.Length -ne 51 -or [Convert]::ToHexString($blob[0..18]) -cne '0000000B7373682D6564323535313900000020') { throw 'admin_invalid_request' }
    $fingerprint = 'SHA256:' + [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData($blob)).TrimEnd('=')
    return [pscustomobject]@{Request=$request;DeviceId=$request.device_id;Platform=$request.platform;Fingerprint=$fingerprint;Confirmation="$($request.device_id)|$($request.platform)|$fingerprint"}
}

function Invoke-AdminSsh([string[]]$Arguments, [string]$InputText) {
    $info = [Diagnostics.ProcessStartInfo]::new($env:CODEX_VIA_SERVER_SSH)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach ($arg in $Arguments) { $info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo=$info
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if ($InputText) { $process.StandardInput.WriteLine($InputText) }; $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) { $process.Kill($true); throw 'admin_result_unknown' }
        if ($process.ExitCode -ne 0) { throw 'admin_command_failed' }
        $text=$stdout.GetAwaiter().GetResult()
        if ($text.Length -gt 1048576) { throw 'admin_invalid_response' }
        return $text
    } finally { $process.Dispose() }
}

function Invoke-CvsAdminCommand($Config, [ValidateSet('list','approve')][string]$Command, [string]$InputText) {
    $runtime = Join-Path ([IO.Path]::GetTempPath()) ('cvs-admin-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runtime | Out-Null; Set-CvsPrivateAcl $runtime
    try {
        $pinProfile = [pscustomobject]@{server=[pscustomobject]@{host=$Config.admin.host;ssh_port=$Config.admin.port;host_fingerprints=$Config.admin.host_fingerprints}}
        try { $known = & $script:Client { param($p,$r) Get-CvsVerifiedKnownHosts -Profile $p -RuntimeDirectory $r } $pinProfile $runtime } catch { throw 'admin_host_unverified' }
        $arguments = @('-F','NUL','-p',[string]$Config.admin.port,'-i',[string]$Config.admin.identity,
            '-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no',
            '-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$known",'-o','GlobalKnownHostsFile=NUL','-o','UpdateHostKeys=no',
            '-o','ProxyCommand=none','-o','ProxyJump=none','-o','PermitLocalCommand=no','-o','ClearAllForwardings=yes',
            '-o','ConnectTimeout=8','-o','ConnectionAttempts=1','-o','LogLevel=ERROR','-T',"$($Config.admin.user)@$($Config.admin.host)")
        if ($Config.admin.user -cne 'root') { $arguments += @('sudo','-n') }
        $arguments += @('/usr/local/sbin/codex-via-server-devices',$Command)
        if ($Command -eq 'approve') { $arguments += '-' }
        return Invoke-AdminSsh $arguments $InputText
    } finally { Remove-Item -LiteralPath $runtime -Recurse -Force }
}

function Read-AdminDevices($Config) {
    $items = Invoke-CvsAdminCommand $Config list | ConvertFrom-Json -NoEnumerate
    if ($items -isnot [array]) { throw 'admin_invalid_response' }
    return ,$items
}

function Get-CvsAdminDevices([string]$ConfigPath) {
    $config = Read-CvsAdminConfig $ConfigPath
    return ,(Read-AdminDevices $config)
}

function Approve-CvsAdminRequest([string]$ConfigPath, [string]$RequestPath, [string]$OutputPath, [string]$ExpectedConfirmation) {
    $config = Read-CvsAdminConfig $ConfigPath
    $device = Get-CvsAdminRequest $RequestPath
    if ($device.Confirmation -cne $ExpectedConfirmation) { throw 'admin_request_changed' }
    Assert-AdminPath $OutputPath
    if ((Test-Path -LiteralPath $OutputPath) -or -not (Test-Path -LiteralPath (Split-Path -Parent $OutputPath) -PathType Container)) { throw 'admin_output_exists' }
    # Recover a completed approval after a lost response without adding another identity.
    $devices = Read-AdminDevices $config
    $existing = @($devices | Where-Object device_id -CEQ $device.DeviceId)
    if ($existing.Count -gt 1) { throw 'admin_invalid_response' }
    if ($existing.Count -eq 1) {
        if ($existing[0].public_key_fingerprint -cne $device.Fingerprint -or $existing[0].platform -cne $device.Platform) { throw 'admin_device_conflict' }
    } else {
        try { $response = Invoke-CvsAdminCommand $config approve ($device.Request | ConvertTo-Json -Compress) | ConvertFrom-Json } catch { throw 'admin_result_unknown' }
        if ($response.status -cne 'approved' -or $response.device_id -cne $device.DeviceId -or $response.public_key_fingerprint -cne $device.Fingerprint -or $response.platform -cne $device.Platform) { throw 'admin_result_unknown' }
    }
    $profile = [pscustomobject]@{
        schema_version=1;profile_id=$config.profile_id
        server=[pscustomobject]@{host=$config.tunnel.host;ssh_port=$config.tunnel.port;ssh_user='codex-tunnel';host_fingerprints=$config.admin.host_fingerprints}
        gateway=$config.gateway;client=$config.client
        approved_device=[pscustomobject]@{device_id=$device.DeviceId;public_key_fingerprint=$device.Fingerprint}
        issued_at=[DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    & $script:Client { param($p) Assert-CvsConnectionProfile $p } $profile
    Write-AdminJson $profile $OutputPath
    return $OutputPath
}

Export-ModuleMember -Function Save-CvsAdminConfig,Read-CvsAdminConfig,Get-CvsAdminRequest,Get-CvsAdminDevices,Approve-CvsAdminRequest
