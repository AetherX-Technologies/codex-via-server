[CmdletBinding()]
param([string]$InstallRoot = (Join-Path $HOME ".codex-via-server\bin"))

$ErrorActionPreference = "Stop"
$SourceRoot = Split-Path -Parent $PSScriptRoot

function Set-CvsInstallAcl {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsWindows) { return }
    $item = Get-Item -LiteralPath $Path -Force
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in @($acl.Access)) { [void]$acl.PurgeAccessRules($existingRule.IdentityReference) }
    $inheritance = if ($item.PSIsContainer) { [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit } else { [System.Security.AccessControl.InheritanceFlags]::None }
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($identity, [System.Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
    [void]$acl.AddAccessRule($rule)
    [System.IO.FileSystemAclExtensions]::SetAccessControl($item, $acl)
}

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "codex-via-server.ps1") -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "CodexViaServer.psm1") -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "persistent-tunnel.ps1") -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "stop-persistent-tunnel.ps1") -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $SourceRoot "VERSION") -Destination $InstallRoot -Force
Set-CvsInstallAcl $InstallRoot
foreach ($name in @("codex-via-server.ps1", "CodexViaServer.psm1", "persistent-tunnel.ps1", "stop-persistent-tunnel.ps1", "VERSION")) {
    Set-CvsInstallAcl (Join-Path $InstallRoot $name)
}
Write-Output "Installed Windows client: $InstallRoot"
