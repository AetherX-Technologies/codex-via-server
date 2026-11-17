[CmdletBinding()]
param(
    [string]$ClientHome,
    [string]$CodexHome,
    [string]$KeyDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$portableEnvironment = Join-Path $PSScriptRoot '../setup/Environment.ps1'
if (Test-Path -LiteralPath $portableEnvironment) { . $portableEnvironment @PSBoundParameters }
else {
    if ($ClientHome) { $env:CODEX_VIA_SERVER_HOME = $ClientHome }
    if ($CodexHome) { $env:CODEX_HOME = $CodexHome }
    if ($KeyDirectory) { $env:CODEX_VIA_SERVER_KEY_DIR = $KeyDirectory }
}
Import-Module (Join-Path $PSScriptRoot 'CodexViaServer.psm1') -Force
# A serialized supervisor monitors both new and reused SSH connections.
Invoke-CvsPersistentTunnel -StartRequested
