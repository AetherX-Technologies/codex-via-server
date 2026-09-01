[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "CodexViaServer.psm1") -Force
Stop-CvsDesktopRuntime
