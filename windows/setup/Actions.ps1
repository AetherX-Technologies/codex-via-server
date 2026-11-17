[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Enroll', 'Check', 'Start', 'Stop', 'Restart', 'Uninstall', 'Desktop', 'Live', 'SelfTest', 'AdminConfigure', 'AdminRequest', 'AdminCheck', 'AdminApprove')][string]$Action,
    [string]$ProfilePath,
    [string]$Model,
    [string]$AdminConfig,
    [string]$AdminUser,
    [string]$AdminIdentity,
    [string]$OutputPath,
    [string]$ClientHome = (Join-Path $HOME '.codex-via-server'),
    [string]$CodexHome = (Join-Path $HOME '.codex'),
    [string]$KeyDirectory = (Join-Path $ClientHome 'keys')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Environment.ps1') -ClientHome $ClientHome -CodexHome $CodexHome -KeyDirectory $KeyDirectory
Import-Module (Join-Path $env:CODEX_VIA_SERVER_INSTALL_ROOT 'CodexViaServer.psm1') -Force -DisableNameChecking
$package = Split-Path -Parent $PSScriptRoot
$code = 'prepare_failed'

function Assert-SafePath([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'unsafe_path' }
        $cursor = Split-Path -Parent $cursor
    }
}

function Invoke-QuietNative([string]$File, [string[]]$NativeArguments, [int]$Seconds = 30) {
    $info = [Diagnostics.ProcessStartInfo]::new($File)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($argument in $NativeArguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($Seconds * 1000)) { $process.Kill($true); throw 'native_timeout' }
        if ($process.ExitCode -ne 0) { throw 'native_failed' }
        return $stdout.GetAwaiter().GetResult()
    } finally { $process.Dispose() }
}

function Get-DesktopInstalled {
    return [bool](Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)
}

function Set-SetupShortcuts {
    $shell = New-Object -ComObject WScript.Shell
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex via Server'
    New-Item -ItemType Directory -Path $menu -Force | Out-Null
    $manager = $shell.CreateShortcut((Join-Path $menu '服务器连接设置.lnk'))
    $manager.TargetPath = Join-Path $package 'Setup.exe'; $manager.Save()
    $cli = $shell.CreateShortcut((Join-Path $menu 'Codex CLI.lnk'))
    $cli.TargetPath = $env:CODEX_VIA_SERVER_PWSH
    $cli.Arguments = '-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot 'Launch-Codex.ps1')
    $cli.WorkingDirectory = $HOME; $cli.Save()
}

function Set-LoopbackBypass {
    $path = Join-Path $ClientHome 'state/setup-no-proxy.json'
    $before = [Environment]::GetEnvironmentVariable('NO_PROXY', 'User')
    $after = (@($before -split ',' | Where-Object { $_ }) + @($env:NO_PROXY -split ',' | Where-Object { $_ }) | Select-Object -Unique) -join ','
    if (-not (Test-Path -LiteralPath $path)) {
        @{ Before = $before; After = $after } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        Set-CvsPrivateAcl $path
    }
    [Environment]::SetEnvironmentVariable('NO_PROXY', $after, 'User')
}

try {
    foreach ($path in @($ClientHome, $CodexHome, (Join-Path $CodexHome 'config.toml'))) { Assert-SafePath $path }
    foreach ($directory in @('keys', 'config', 'state', 'requests')) { Assert-SafePath (Join-Path $ClientHome $directory) }
    foreach ($name in @('CODEX_VIA_SERVER_PWSH', 'CODEX_VIA_SERVER_CODEX', 'CODEX_VIA_SERVER_SSH', 'CODEX_VIA_SERVER_SSH_KEYGEN', 'CODEX_VIA_SERVER_SSH_KEYSCAN')) {
        if (-not (Test-Path -LiteralPath ([Environment]::GetEnvironmentVariable($name)) -PathType Leaf)) { throw 'runtime_missing' }
    }
    foreach ($dir in @($ClientHome, (Join-Path $ClientHome 'state'))) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null; Set-CvsPrivateAcl $dir
    }
    $result = [ordered]@{ Ok = $true; Code = 'ok' }
    if ($Action.StartsWith('Admin')) {
        $code = 'admin_failed'
        Import-Module (Join-Path $PSScriptRoot 'Admin.psm1') -Force -DisableNameChecking
    }
    switch ($Action) {
        'AdminConfigure' {
            Save-CvsAdminConfig -ProfilePath $ProfilePath -User $AdminUser -Identity $AdminIdentity -OutputPath $OutputPath
            $result.Code='admin_config_saved'; $result.ConfigPath=$OutputPath
        }
        'AdminRequest' {
            $device=Get-CvsAdminRequest $ProfilePath
            $result.Code='admin_request_valid'; $result.DeviceId=$device.DeviceId; $result.Platform=$device.Platform; $result.Fingerprint=$device.Fingerprint; $result.Confirmation=$device.Confirmation
        }
        'AdminCheck' {
            $devices=Get-CvsAdminDevices $AdminConfig
            $result.Code='admin_connected'; $result.DeviceCount=$devices.Count
        }
        'AdminApprove' {
            Approve-CvsAdminRequest -ConfigPath $AdminConfig -RequestPath $ProfilePath -OutputPath $OutputPath -ExpectedConfirmation $Model | Out-Null
            $result.Code='admin_approved'; $result.OutputPath=$OutputPath
        }
        'Prepare' {
            $code = 'tailscale_not_ready'
            if (-not (Test-Path -LiteralPath $env:CODEX_VIA_SERVER_TAILSCALE)) { throw 'tailscale_missing' }
            $tail = Invoke-QuietNative $env:CODEX_VIA_SERVER_TAILSCALE @('status', '--json') 15 | ConvertFrom-Json
            if ($tail.BackendState -ne 'Running') { throw 'tailscale_not_ready' }
            Set-SetupShortcuts
            $installedProfile = Join-Path $ClientHome 'config/connection-profile.json'
            if (Test-Path -LiteralPath $installedProfile) {
                $result.Code = 'existing_profile'; $result.ProfilePath = $installedProfile
            } else {
                $code = 'request_failed'
                $idPath = Join-Path $ClientHome 'state/setup-device-id.txt'
                $id = if (Test-Path -LiteralPath $idPath) { (Get-Content -LiteralPath $idPath -Raw).Trim() } else { 'windows-' + [guid]::NewGuid().ToString('N').Substring(0, 12) }
                $request = Join-Path $ClientHome "requests/$id.request.json"
                Assert-SafePath $request
                Initialize-CvsDevice -DeviceId $id -OutputPath $request | Out-Null
                Set-Content -LiteralPath $idPath -Value $id -Encoding utf8NoBOM; Set-CvsPrivateAcl $idPath
                $result.Code = 'awaiting_approval'; $result.RequestPath = $request; $result.DeviceId = $id
                $result.DeviceFingerprint = ((Invoke-QuietNative $env:CODEX_VIA_SERVER_SSH_KEYGEN @('-lf',(Join-Path $KeyDirectory "$id.pub"),'-E','sha256')) -split '\s+')[1]
            }
            $result.DesktopInstalled = Get-DesktopInstalled
        }
        'Enroll' {
            $code = 'existing_task'
            if (Get-ScheduledTask -TaskName (Get-CvsDesktopTaskName) -ErrorAction SilentlyContinue) { throw 'existing_task' }
            $code = 'profile_rejected'
            Import-CvsConnectionProfile -Path $ProfilePath | Out-Null
            $code = 'tunnel_install_failed'
            Install-CvsDesktop | Out-Null
            Set-LoopbackBypass
            $status = Get-CvsDesktopStatus -CheckAPI
            $result.Code = if ($status.Status -eq 'pass' -and $status.UpstreamAPI -eq 'models_available') { 'configured' } else { 'gateway_unavailable' }
            $result.Ok = $result.Code -eq 'configured'
            $result.DesktopInstalled = Get-DesktopInstalled
        }
        'Check' {
            $code = 'check_failed'
            $status = Get-CvsDesktopStatus -CheckAPI
            $result.Ok = $status.Status -eq 'pass' -and $status.UpstreamAPI -eq 'models_available'
            $result.Code = if ($result.Ok) { 'healthy' } else { 'gateway_unavailable' }
            if ($result.Ok) {
                $models = Invoke-RestMethod -Uri "$($status.Url)/models" -NoProxy -TimeoutSec 15
                $result.Models = @($models.data | ForEach-Object { [string]$_.id } | Where-Object { $_ -cmatch '^[A-Za-z0-9._:/-]{1,128}$' } | Sort-Object)
            }
        }
        'Start' { $code = 'start_failed'; Start-CvsDesktop | Out-Null; $result.Code = 'started' }
        'Stop' { $code = 'stop_failed'; Stop-CvsDesktop | Out-Null; $result.Code = 'stopped' }
        'Restart' { $code = 'restart_failed'; Restart-CvsDesktop | Out-Null; $result.Code = 'restarted' }
        'Uninstall' {
            $code = 'uninstall_failed'
            Uninstall-CvsDesktop | Out-Null
            $bypassPath = Join-Path $ClientHome 'state/setup-no-proxy.json'
            if (Test-Path -LiteralPath $bypassPath) {
                $saved = Get-Content -LiteralPath $bypassPath -Raw | ConvertFrom-Json
                if ([Environment]::GetEnvironmentVariable('NO_PROXY', 'User') -ceq $saved.After) { [Environment]::SetEnvironmentVariable('NO_PROXY', $saved.Before, 'User') }
                Remove-Item -LiteralPath $bypassPath -Force
            }
            $result.Code = 'uninstalled'
        }
        'Desktop' {
            $code = 'desktop_install_failed'
            if (-not (Get-DesktopInstalled)) {
                # shortcut: Store policies may require user interaction; never report completion from launcher exit alone.
                Start-Process -FilePath (Join-Path $package 'runtime/desktop/CodexInstaller.exe') -Wait | Out-Null
            }
            $result.Ok = Get-DesktopInstalled
            $result.Code = if ($result.Ok) { 'desktop_installed' } else { 'desktop_install_pending' }
        }
        'Live' {
            $code = 'live_failed'
            if ($Model -cnotmatch '^[A-Za-z0-9._:/-]{1,128}$') { throw 'invalid_model' }
            $text = Invoke-QuietNative $env:CODEX_VIA_SERVER_CODEX @('exec', '--skip-git-repo-check', '--sandbox', 'read-only', '--ephemeral', '--model', $Model, '-c', 'model_provider="codex_via_server_desktop"', 'Reply only OK.') 90
            if ($text.Trim() -ne 'OK') { throw 'live_incomplete' }
            $result.Code = 'live_passed'
        }
        'SelfTest' {
            $code = 'self_test_failed'
            . (Join-Path $PSScriptRoot 'SelfTest.ps1')
            $result = Invoke-SetupSelfTest
        }
    }
} catch {
    if ($Action.StartsWith('Admin') -and $_.Exception.Message -cmatch '^admin_[a-z_]+$') { $code=$_.Exception.Message }
    $result = [ordered]@{ Ok = $false; Code = $code }
}
# Only fixed action/result codes are logged; native output and exceptions can contain private metadata.
if (Test-Path -LiteralPath (Join-Path $ClientHome 'state')) {
    $log = Join-Path $ClientHome 'state/setup.log'
    try {
        Add-Content -LiteralPath $log -Value "$([DateTimeOffset]::UtcNow.ToString('o')) $Action $($result.Code)" -Encoding utf8NoBOM
        Set-CvsPrivateAcl $log
    } catch {}
}
$result | ConvertTo-Json -Depth 4 -Compress
if (-not $result.Ok) { exit 1 }
