[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PowerShellDirectory,
    [Parameter(Mandatory)][string]$CodexDirectory,
    [Parameter(Mandatory)][string]$OpenSshDirectory,
    [Parameter(Mandatory)][string]$DesktopInstaller,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or -not [Environment]::Is64BitProcess) { throw 'Build requires Windows x64 PowerShell 7.' }
$repository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ($output.StartsWith($repository + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep generated binaries outside the repository.' }
New-Item -ItemType Directory -Path $output -Force | Out-Null
$work = Join-Path $output ('build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$stage = Join-Path $work 'payload'
New-Item -ItemType Directory -Path $stage | Out-Null

function Assert-Signer([string]$Path, [string]$Publisher) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne $Publisher) { throw "Untrusted build input: $([IO.Path]::GetFileName($Path))" }
}

function Copy-Payload([string]$Source, [string]$Name) {
    $item = Get-Item -LiteralPath $Source -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Payload input must be a regular file.' }
    $target = Join-Path $stage $Name
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath $item.FullName -Destination $target
}

Assert-Signer (Join-Path $PowerShellDirectory 'pwsh.exe') 'Microsoft Corporation'
Assert-Signer (Join-Path $CodexDirectory 'codex.exe') 'OpenAI OpCo, LLC'
Assert-Signer (Join-Path $OpenSshDirectory 'ssh.exe') 'Microsoft Corporation'
Assert-Signer $DesktopInstaller 'Microsoft Corporation'
# A distribution directory is an explicit build input; never collect files from a user profile.
foreach ($file in Get-ChildItem -LiteralPath $PowerShellDirectory -Recurse -File) {
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Name -match '(?i)^(connection-profile|auth|config)\.json$|^id_(rsa|ed25519)$|\.env$') { throw 'Unexpected private or linked file in PowerShell distribution.' }
    Copy-Payload $file.FullName ('runtime/pwsh/' + [IO.Path]::GetRelativePath($PowerShellDirectory, $file.FullName).Replace('\', '/'))
}
foreach ($name in @('codex.exe', 'codex-code-mode-host.exe', 'codex-command-runner.exe', 'codex-windows-sandbox-setup.exe', 'codex-windows-sandbox-service.exe', 'codex-exec-server.exe')) {
    Assert-Signer (Join-Path $CodexDirectory $name) 'OpenAI OpCo, LLC'
    Copy-Payload (Join-Path $CodexDirectory $name) "runtime/codex/$name"
}
foreach ($name in @('LICENSE', 'NOTICE')) { Copy-Payload (Join-Path $CodexDirectory $name) "runtime/codex/$name" }
# ripgrep is unsigned upstream; pin the copy from the integrity-verified official Codex 0.167.0 npm package.
if ((Get-FileHash -LiteralPath (Join-Path $CodexDirectory 'rg.exe')).Hash -cne '14231169855EC5205CF5A1B6F1DB358FF4AED4247C86B69CE8AAE647C77F6680') { throw 'Unexpected ripgrep build input.' }
foreach ($name in @('rg.exe', 'RIPGREP-LICENSE-MIT', 'RIPGREP-UNLICENSE')) { Copy-Payload (Join-Path $CodexDirectory $name) "runtime/codex/$name" }
foreach ($name in @('ssh.exe', 'ssh-keygen.exe', 'ssh-keyscan.exe')) {
    Assert-Signer (Join-Path $OpenSshDirectory $name) 'Microsoft Corporation'
    Copy-Payload (Join-Path $OpenSshDirectory $name) "runtime/ssh/$name"
}
foreach ($file in Get-ChildItem -LiteralPath $OpenSshDirectory -File | Where-Object { $_.Extension -eq '.dll' -or $_.Name -match '(?i)license|notice' }) { Copy-Payload $file.FullName "runtime/ssh/$($file.Name)" }
Copy-Payload $DesktopInstaller 'runtime/desktop/CodexInstaller.exe'
foreach ($name in @('codex-via-server.ps1', 'CodexViaServer.psm1', 'persistent-tunnel.ps1', 'stop-persistent-tunnel.ps1')) { Copy-Payload (Join-Path $repository "windows/$name") "client/$name" }
Copy-Payload (Join-Path $repository 'VERSION') 'client/VERSION'
foreach ($name in @('Actions.ps1', 'Environment.ps1', 'Launch-Codex.ps1', 'SelfTest.ps1', 'Admin.psm1')) { Copy-Payload (Join-Path $PSScriptRoot $name) "setup/$name" }
foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object Extension -in @('.ps1', '.psm1')) {
    if (-not $file.FullName.StartsWith((Join-Path $stage 'runtime'))) {
        $parseErrors = $null; [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
        if ($parseErrors) { throw "Script parse failed: $($file.Name)" }
    }
}
$manifest = Join-Path $work 'payload.manifest'
$lines = foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName) {
    [IO.Path]::GetRelativePath($stage, $file.FullName).Replace('\', '/') + "`t" + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
[IO.File]::WriteAllLines($manifest, $lines, [Text.UTF8Encoding]::new($false))
$zip = Join-Path $work 'payload.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
$hashFile = Join-Path $work 'payload.sha256'
[IO.File]::WriteAllText($hashFile, (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant())
$exe = Join-Path $output 'CodexViaServer-Setup-win-x64.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /utf8output "/out:$exe" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll "/resource:$zip,payload.zip" "/resource:$hashFile,payload.sha256" "/resource:$manifest,payload.manifest" (Join-Path $PSScriptRoot 'Setup.cs') (Join-Path $PSScriptRoot 'AdminForm.cs')
if ($LASTEXITCODE -ne 0) { throw 'Setup compilation failed.' }
$version = & (Join-Path $CodexDirectory 'codex.exe') --version
[ordered]@{
    File = [IO.Path]::GetFileName($exe); SHA256 = (Get-FileHash -LiteralPath $exe).Hash
    Bytes = (Get-Item -LiteralPath $exe).Length; PayloadFiles = $lines.Count; Codex = "$version"
    PowerShell = (& (Join-Path $PowerShellDirectory 'pwsh.exe') -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'build.json') -Encoding utf8NoBOM
Copy-Item -LiteralPath $manifest -Destination (Join-Path $output 'payload.manifest') -Force
Get-Content -LiteralPath (Join-Path $output 'build.json')
