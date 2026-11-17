param(
    [string]$ClientHome = (Join-Path $HOME '.codex-via-server'),
    [string]$CodexHome = (Join-Path $HOME '.codex'),
    [string]$KeyDirectory = (Join-Path $ClientHome 'keys')
)

$package = Split-Path -Parent $PSScriptRoot
$env:CODEX_VIA_SERVER_HOME = $ClientHome
$env:CODEX_HOME = $CodexHome
$env:CODEX_VIA_SERVER_KEY_DIR = $KeyDirectory
$env:CODEX_VIA_SERVER_INSTALL_ROOT = Join-Path $package 'client'
$env:CODEX_VIA_SERVER_PWSH = Join-Path $package 'runtime/pwsh/pwsh.exe'
$env:CODEX_VIA_SERVER_CODEX = Join-Path $package 'runtime/codex/codex.exe'
$env:PATH = (Join-Path $package 'runtime/codex') + [IO.Path]::PathSeparator + $env:PATH
$env:CODEX_VIA_SERVER_SSH = Join-Path $package 'runtime/ssh/ssh.exe'
$env:CODEX_VIA_SERVER_SSH_KEYGEN = Join-Path $package 'runtime/ssh/ssh-keygen.exe'
$env:CODEX_VIA_SERVER_SSH_KEYSCAN = Join-Path $package 'runtime/ssh/ssh-keyscan.exe'
$env:CODEX_VIA_SERVER_TAILSCALE = Join-Path $env:ProgramFiles 'Tailscale/tailscale.exe'
foreach ($name in @('CODEX_VIA_SERVER_CONNECTION_PROFILE', 'SERVER_CODEX_API_KEY', 'CLIPROXY_API_KEY', 'OPENAI_API_KEY')) {
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}
$env:NO_PROXY = (@($env:NO_PROXY -split ',' | Where-Object { $_ }) + @('127.0.0.1', 'localhost', '::1') | Select-Object -Unique) -join ','
