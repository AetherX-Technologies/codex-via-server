[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = if ($env:CODEX_VIA_SERVER_HOME) { $env:CODEX_VIA_SERVER_HOME } else { Join-Path $HOME ".codex-via-server" }
$module = Join-Path $PSScriptRoot "CodexViaServer.psm1"
$stateDirectory = Join-Path $root "state"
$logPath = Join-Path $stateDirectory "persistent-tunnel.log"

New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
Import-Module $module -Force

function Write-CvsPersistentLog {
    param([Parameter(Mandatory)][string]$Message)
    if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1MB) {
        Move-Item -LiteralPath $logPath -Destination "${logPath}.1" -Force
    }
    Add-Content -LiteralPath $logPath -Value ("{0} {1}" -f [DateTimeOffset]::Now.ToString("o"), $Message) -Encoding utf8NoBOM
}

Write-CvsPersistentLog "persistent tunnel service started"
try {
    while ($true) {
        $tunnel = $null
        try {
            $tunnel = Start-CvsTunnel
            if ($tunnel.Reused) {
                Write-CvsPersistentLog ("reusing managed tunnel local_port={0}" -f $tunnel.Profile.client.local_port)
                while ($true) {
                    if ($tunnel.ManagedProcess.HasExited) { throw "Managed tunnel process exited" }
                    if (-not (Test-CvsGatewayModels -Port ([int]$tunnel.Profile.client.local_port))) { throw "Managed tunnel health check failed" }
                    Start-Sleep -Seconds 5
                }
            } else {
                Write-CvsPersistentLog ("tunnel established pid={0} local_port={1}" -f $tunnel.Process.Id, $tunnel.Profile.client.local_port)
                while (-not $tunnel.Process.HasExited) { Start-Sleep -Seconds 5 }
                Write-CvsPersistentLog ("tunnel exited code={0}" -f $tunnel.Process.ExitCode)
            }
        } catch {
            Write-CvsPersistentLog ("tunnel attempt failed type={0}" -f $_.Exception.GetType().Name)
        } finally {
            if ($tunnel) { Stop-CvsTunnel $tunnel }
        }
        Start-Sleep -Seconds 15
    }
} finally {
    Write-CvsPersistentLog "persistent tunnel service stopped"
}
