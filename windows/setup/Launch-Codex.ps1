$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Environment.ps1')
Import-Module (Join-Path $env:CODEX_VIA_SERVER_INSTALL_ROOT 'CodexViaServer.psm1') -Force
$status = Start-CvsDesktop
if ($status.Status -ne 'pass') { throw 'Tunnel is unavailable. Open Codex server setup to check it.' }
& $env:CODEX_VIA_SERVER_CODEX
exit $LASTEXITCODE
