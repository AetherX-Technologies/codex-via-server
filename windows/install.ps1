[CmdletBinding()]
param([string]$InstallRoot = (Join-Path $HOME ".codex-via-server\bin"))

$ErrorActionPreference = "Stop"
$SourceRoot = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "codex-via-server.ps1") -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "CodexViaServer.psm1") -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "persistent-tunnel.ps1") -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "stop-persistent-tunnel.ps1") -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $SourceRoot "VERSION") -Destination $InstallRoot -Force
Write-Output "Installed Windows client: $InstallRoot"
