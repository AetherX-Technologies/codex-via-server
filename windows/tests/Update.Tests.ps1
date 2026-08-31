$script:RepositoryRoot=(Resolve-Path(Join-Path $PSScriptRoot "../..")).Path
Import-Module (Join-Path $script:RepositoryRoot "windows/CodexViaServer.psm1") -Force

Describe "Windows update and uninstall" {
 InModuleScope CodexViaServer {
  BeforeEach {
   $env:CODEX_VIA_SERVER_HOME=Join-Path $TestDrive "home"
   $env:CODEX_VIA_SERVER_INSTALL_ROOT=Join-Path $TestDrive "install"
   New-Item -ItemType Directory -Force $env:CODEX_VIA_SERVER_INSTALL_ROOT|Out-Null
   Set-Content (Join-Path $env:CODEX_VIA_SERVER_INSTALL_ROOT "VERSION") "0.1.0"
   Set-Content (Join-Path $env:CODEX_VIA_SERVER_INSTALL_ROOT "codex-via-server.ps1") "old-script"
   Set-Content (Join-Path $env:CODEX_VIA_SERVER_INSTALL_ROOT "CodexViaServer.psm1") "old-module"
  }
  AfterEach {Remove-Item Env:CODEX_VIA_SERVER_HOME,Env:CODEX_VIA_SERVER_INSTALL_ROOT,Env:CODEX_VIA_SERVER_TEST_FAIL_STAGE -ErrorAction SilentlyContinue}

  It "reports available versions without installing" {
   Mock Get-CvsLatestRelease {[pscustomobject]@{tag_name="v0.2.0";asset_url="https://example.invalid/a";checksums_url="https://example.invalid/c"}}
   $result=Update-CvsClient -CheckOnly
   $result.Installed|Should -Be "0.1.0";$result.Latest|Should -Be "0.2.0"
   (Get-Content (Join-Path $env:CODEX_VIA_SERVER_INSTALL_ROOT "codex-via-server.ps1"))|Should -Be "old-script"
  }

  It "restores the old installation after an injected failure" {
   $package=Join-Path $TestDrive "package";New-Item -ItemType Directory -Force (Join-Path $package "codex-via-server-windows")|Out-Null
   Set-Content (Join-Path $package "codex-via-server-windows/VERSION") "0.2.0"
   Set-Content (Join-Path $package "codex-via-server-windows/codex-via-server.ps1") "param()"
   Set-Content (Join-Path $package "codex-via-server-windows/CodexViaServer.psm1") "function Test-Module {}"
   $zip=Join-Path $TestDrive "client.zip";Compress-Archive (Join-Path $package "codex-via-server-windows") $zip
   $hash=(Get-FileHash $zip).Hash.ToLowerInvariant();$checks=Join-Path $TestDrive "checksums.txt";Set-Content $checks "$hash  codex-via-server-windows.zip"
   Mock Get-CvsLatestRelease {[pscustomobject]@{tag_name="v0.2.0";asset_url="asset";checksums_url="checksums"}}
   Mock Invoke-WebRequest {param($Uri,$OutFile);Copy-Item $(if($Uri -eq "asset"){$zip}else{$checks}) $OutFile}
   $env:CODEX_VIA_SERVER_TEST_FAIL_STAGE="after-copy"
   {Update-CvsClient}|Should -Throw
   (Get-Content (Join-Path $env:CODEX_VIA_SERVER_INSTALL_ROOT "codex-via-server.ps1"))|Should -Be "old-script"
  }

  It "uninstalls project files but preserves device key and default config" {
   $config=Get-CvsConfigDirectory;New-Item -ItemType Directory -Force $config|Out-Null
   Set-Content (Join-Path $config "connection-profile.json") '{"approved_device":{"device_id":"device-01"},"client":{"codex_profile":"codex-via-server"}}'
   $keys=Get-CvsKeyDirectory;New-Item -ItemType Directory -Force $keys|Out-Null;Set-Content (Join-Path $keys "device-01") "key"
   $codex=Join-Path (Get-CvsRoot) ".codex";New-Item -ItemType Directory -Force $codex|Out-Null;Set-Content (Join-Path $codex "config.toml") "default";Set-Content (Join-Path $codex "codex-via-server.config.toml") "generated"
   Uninstall-CvsClient|Out-Null
   Test-Path (Join-Path $keys "device-01")|Should -BeTrue
   Test-Path (Join-Path $codex "config.toml")|Should -BeTrue
   Test-Path $env:CODEX_VIA_SERVER_INSTALL_ROOT|Should -BeFalse
  }
 }
}
