function Invoke-SetupSelfTest {
    $checks = [Collections.Generic.List[string]]::new()
    function Assert-Setup([bool]$Condition, [string]$Name) {
        if (-not $Condition) { throw $Name }
        $checks.Add($Name)
    }
    $cliVersion = Invoke-QuietNative $env:CODEX_VIA_SERVER_CODEX @('--version')
    Assert-Setup ($cliVersion -match 'codex-cli \d+\.\d+') 'bundled_codex_runs'
    $searchVersion = Invoke-QuietNative (Join-Path (Split-Path -Parent $env:CODEX_VIA_SERVER_CODEX) 'rg.exe') @('--version')
    Assert-Setup ($searchVersion -match 'ripgrep 15\.2\.0') 'bundled_file_search_runs'
    $sshVersion = & $env:CODEX_VIA_SERVER_SSH -V 2>&1 | Out-String
    Assert-Setup ($LASTEXITCODE -eq 0 -and $sshVersion -match 'OpenSSH') 'bundled_ssh_runs'
    $request = Join-Path $ClientHome 'test-device.request.json'
    Initialize-CvsDevice -DeviceId 'windows-setup-test' -OutputPath $request | Out-Null
    $key = Join-Path $ClientHome 'keys/windows-setup-test'
    $before = (Get-FileHash -LiteralPath $key).Hash
    Initialize-CvsDevice -DeviceId 'windows-setup-test' -OutputPath $request | Out-Null
    Assert-Setup ((Get-FileHash -LiteralPath $key).Hash -ceq $before) 'request_reuses_device_identity'
    $requestData = Get-Content -LiteralPath $request -Raw | ConvertFrom-Json
    Assert-Setup ($requestData.public_key -match '^ssh-ed25519 ' -and $requestData.PSObject.Properties.Name -notcontains 'api_key') 'request_contains_only_public_identity'
    $fingerprint = ((& $env:CODEX_VIA_SERVER_SSH_KEYGEN -lf "$key.pub" -E sha256) -split '\s+')[1]
    Import-Module (Join-Path $PSScriptRoot 'Admin.psm1') -Force -DisableNameChecking
    $device = Get-CvsAdminRequest $request
    Assert-Setup ($device.DeviceId -eq 'windows-setup-test' -and $device.Fingerprint -ceq $fingerprint) 'admin_validates_real_public_identity'
    $wire = Invoke-QuietNative $env:CODEX_VIA_SERVER_PWSH @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'Actions.ps1'),'-Action','AdminRequest','-ProfilePath',$request,'-ClientHome',$ClientHome,'-CodexHome',$CodexHome) | ConvertFrom-Json
    Assert-Setup ($wire.Ok -and $wire.Code -eq 'admin_request_valid' -and $wire.Confirmation -ceq $device.Confirmation) 'packaged_admin_action_protocol'
    $profile = [ordered]@{
        schema_version = 1; profile_id = 'setup-test'; issued_at = '2026-11-09T00:00:00Z'
        server = @{ host = '100.64.10.20'; ssh_port = 22; ssh_user = 'codex-tunnel'; host_fingerprints = @('SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA') }
        gateway = @{ remote_host = '127.0.0.1'; remote_port = 18319 }
        client = @{ local_port = 18319; codex_profile = 'setup-test'; minimum_client_version = '0.2.0-dev.1'; minimum_codex_version = '0.149.1' }
        approved_device = @{ device_id = 'windows-setup-test'; public_key_fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' }
    }
    $profilePath = Join-Path $ClientHome 'test.connection.json'
    $profile | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profilePath
    $rejected = $false
    try { Import-CvsConnectionProfile -Path $profilePath | Out-Null } catch { $rejected = $true }
    Assert-Setup $rejected 'rejects_wrong_device_approval'
    $profile.approved_device.public_key_fingerprint = $fingerprint
    $profile.gateway.api_key = 'synthetic-forbidden-field'
    $profile | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profilePath
    $rejected = $false
    try { Import-CvsConnectionProfile -Path $profilePath | Out-Null } catch { $rejected = $true }
    Assert-Setup $rejected 'rejects_credential_fields'
    $profile.gateway.Remove('api_key')
    $profile | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profilePath
    Import-CvsConnectionProfile -Path $profilePath | Out-Null
    Assert-Setup (Test-Path -LiteralPath (Join-Path $ClientHome 'config/connection-profile.json')) 'matching_approval_imported'
    $adminPath = Join-Path $ClientHome 'test-admin.json'
    Save-CvsAdminConfig -ProfilePath $profilePath -User 'root' -Identity $key -OutputPath $adminPath
    $adminConfig = Read-CvsAdminConfig $adminPath
    $adminAcl = Get-Acl -LiteralPath $adminPath
    Assert-Setup ($adminConfig.admin.identity -ceq $key -and $adminAcl.AreAccessRulesProtected -and @($adminAcl.Access).Count -eq 1) 'admin_settings_private_without_copying_key'
    $rejected = $false
    try { Save-CvsAdminConfig -ProfilePath $profilePath -User 'codex-tunnel' -Identity $key -OutputPath (Join-Path $ClientHome 'invalid-admin.json') } catch { $rejected=$true }
    Assert-Setup $rejected 'admin_rejects_restricted_tunnel_identity'
    New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
    $config = Join-Path $CodexHome 'config.toml'
    Set-Content -LiteralPath $config -Value 'model = "synthetic-original"' -NoNewline
    $original = (Get-FileHash -LiteralPath $config).Hash
    # Replace only task operations in this isolated child process, never the actual user's task.
    $module = Get-Module CodexViaServer
    & $module {
        function script:Register-CvsDesktopTask {}
        function script:Start-ScheduledTask {}
        function script:Wait-CvsDesktopGateway { $true }
        function script:Get-ScheduledTask { $null }
        function script:Stop-CvsDesktopRuntime { $false }
        function script:Remove-CvsDesktopTask {}
    }
    Install-CvsDesktop | Out-Null
    Install-CvsDesktop | Out-Null
    $configured = Get-Content -LiteralPath $config -Raw
    Assert-Setup ($configured -match 'http://127\.0\.0\.1:18319/v1' -and $configured -match 'requires_openai_auth = false') 'http_loopback_without_api_key'
    Assert-Setup (([regex]::Matches($configured, '\[model_providers.codex_via_server_desktop\]')).Count -eq 1) 'configuration_idempotent'
    $acl = Get-Acl -LiteralPath $key
    Assert-Setup ($acl.AreAccessRulesProtected -and @($acl.Access).Count -eq 1) 'device_key_acl_private'
    Uninstall-CvsDesktop | Out-Null
    Assert-Setup ((Get-FileHash -LiteralPath $config).Hash -ceq $original) 'uninstall_restores_configuration'
    $envScript = Join-Path $PSScriptRoot 'Environment.ps1'
    $clientLiteral = "'" + $ClientHome.Replace("'", "''") + "'"
    $codexLiteral = "'" + $CodexHome.Replace("'", "''") + "'"
    $fresh = Invoke-QuietNative $env:CODEX_VIA_SERVER_PWSH @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', ". '$($envScript.Replace("'", "''"))' -ClientHome $clientLiteral -CodexHome $codexLiteral; if ((Test-Path -LiteralPath `$env:CODEX_VIA_SERVER_SSH) -and (Test-Path -LiteralPath `$env:CODEX_VIA_SERVER_PWSH) -and `$env:CODEX_VIA_SERVER_HOME -eq $clientLiteral -and `$env:CODEX_HOME -eq $codexLiteral -and `$env:CODEX_VIA_SERVER_KEY_DIR -eq (Join-Path $clientLiteral 'keys')) { 'OK' } else { exit 1 }")
    Assert-Setup ($fresh.Trim() -eq 'OK') 'fresh_logon_process_finds_portable_runtime'
    return [ordered]@{ Ok = $true; Code = 'self_test_passed'; Passed = $checks.Count; Checks = @($checks); CodexVersion = $cliVersion.Trim(); PowerShellVersion = $PSVersionTable.PSVersion.ToString() }
}
