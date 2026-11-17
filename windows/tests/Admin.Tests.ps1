BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../setup/Admin.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '../CodexViaServer.psm1') -DisableNameChecking
    $script:SavedHome = $env:CODEX_VIA_SERVER_HOME
    $script:SavedKeyDir = $env:CODEX_VIA_SERVER_KEY_DIR
    $env:CODEX_VIA_SERVER_HOME = Join-Path $TestDrive 'device'
    $env:CODEX_VIA_SERVER_KEY_DIR = Join-Path $env:CODEX_VIA_SERVER_HOME 'keys'
    $script:RequestPath = Join-Path $TestDrive 'new-device.request.json'
    Initialize-CvsDevice -DeviceId 'new-device-01' -OutputPath $script:RequestPath | Out-Null
    $script:Device = Get-CvsAdminRequest $script:RequestPath
    $script:ConfigPath = Join-Path $TestDrive 'admin.json'
    $script:Config = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../admin/admin.example.json') -Raw | ConvertFrom-Json
    $script:Config.admin.identity = Join-Path $env:CODEX_VIA_SERVER_KEY_DIR 'new-device-01'
    $script:Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:ConfigPath
}

AfterAll {
    $env:CODEX_VIA_SERVER_HOME = $script:SavedHome
    $env:CODEX_VIA_SERVER_KEY_DIR = $script:SavedKeyDir
}

Describe 'Windows administrator approval boundaries' {
    It 'fingerprints the actual generated SSH public key without reading its private key' {
        $native = & ssh-keygen.exe -lf ($script:Config.admin.identity + '.pub') -E sha256
        $script:Device.Fingerprint | Should -Be ($native -split '\s+')[1]
    }

    It 'rejects extra credential or command fields before any server operation' {
        $bad = Get-Content $script:RequestPath -Raw | ConvertFrom-Json
        $bad | Add-Member api_key 'synthetic-test-value'
        $path = Join-Path $TestDrive 'bad.request.json'
        $bad | ConvertTo-Json | Set-Content $path
        { Get-CvsAdminRequest $path } | Should -Throw '*admin_invalid_fields*'
    }

    It 'rejects multiline keys and invalid Ed25519 wire data' {
        $bad = Get-Content $script:RequestPath -Raw | ConvertFrom-Json
        foreach ($key in @(($bad.public_key + "`ncommand=x"), ('ssh-ed25519 ' + ('A' * 68)))) {
            $bad.public_key = $key
            $path = Join-Path $TestDrive 'invalid-key.json'; $bad | ConvertTo-Json | Set-Content $path
            { Get-CvsAdminRequest $path } | Should -Throw
        }
    }

    It 'rejects coercible JSON types at the approval boundary' {
        $bad = Get-Content $script:RequestPath -Raw | ConvertFrom-Json
        $bad.schema_version = '1'; $path=Join-Path $TestDrive 'wrong-type.request.json'
        $bad | ConvertTo-Json | Set-Content $path
        { Get-CvsAdminRequest $path } | Should -Throw '*admin_invalid_request*'
        $bad=Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
        $bad.client.codex_profile=@('one','two'); $path=Join-Path $TestDrive 'wrong-type.admin.json'
        $bad | ConvertTo-Json -Depth 10 | Set-Content $path
        { Read-CvsAdminConfig $path } | Should -Throw '*admin_invalid_config*'
    }

    It 'rejects tunnel users, unsafe hosts, empty pins and additional nested settings' {
        foreach ($case in @('user','host','pins','extra')) {
            $bad = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            switch ($case) {
                user { $bad.admin.user = 'codex-tunnel' }
                host { $bad.admin.host = 'host;echo bad' }
                pins { $bad.admin.host_fingerprints = @() }
                extra { $bad.admin | Add-Member command 'anything' }
            }
            $path = Join-Path $TestDrive "bad-$case.json"; $bad | ConvertTo-Json -Depth 10 | Set-Content $path
            { Read-CvsAdminConfig $path } | Should -Throw
        }
    }

    It 'does not treat a missing administrator key as an installed approval service' {
        $bad = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
        $bad.admin.identity = Join-Path $TestDrive 'missing-admin-key'
        $path=Join-Path $TestDrive 'missing-key.json'; $bad | ConvertTo-Json -Depth 10 | Set-Content $path
        { Read-CvsAdminConfig $path } | Should -Throw '*admin_file_missing*'
    }

    It 'rejects an application changed after administrator confirmation' {
        Mock Invoke-CvsAdminCommand -ModuleName Admin { throw 'must_not_connect' }
        { Approve-CvsAdminRequest $script:ConfigPath $script:RequestPath (Join-Path $TestDrive 'changed.json') 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' } | Should -Throw '*admin_request_changed*'
        Should -Invoke Invoke-CvsAdminCommand -ModuleName Admin -Times 0
    }

    It 'exports a matching profile only after server approval and client imports that profile' {
        Mock Invoke-CvsAdminCommand -ModuleName Admin {
            param($Config,$Command,$InputText)
            if ($Command -eq 'list') { return '[]' }
            $r = $InputText | ConvertFrom-Json
            $fingerprint = (Get-CvsAdminRequest $script:RequestPath).Fingerprint
            return @{status='approved';device_id=$r.device_id;platform=$r.platform;public_key_fingerprint=$fingerprint} | ConvertTo-Json
        }
        $output=Join-Path $TestDrive 'fresh.connection.json'
        Approve-CvsAdminRequest $script:ConfigPath $script:RequestPath $output $script:Device.Confirmation | Should -Be $output
        $profile=Get-Content $output -Raw | ConvertFrom-Json
        $profile.approved_device.device_id | Should -Be $script:Device.DeviceId
        $acl=Get-Acl $output; $acl.AreAccessRulesProtected | Should -BeTrue
        @($acl.Access).Count | Should -Be 1
        $saved=$env:CODEX_HOME; $env:CODEX_HOME=Join-Path $TestDrive 'codex'
        try { Import-CvsConnectionProfile $output | Should -Exist } finally { $env:CODEX_HOME=$saved }
        Should -Invoke Invoke-CvsAdminCommand -ModuleName Admin -Times 1 -ParameterFilter { $Command -eq 'approve' }
    }

    It 'recovers an already approved identical request without sending approve again' {
        Mock Invoke-CvsAdminCommand -ModuleName Admin {
            return @(@{device_id=$script:Device.DeviceId;platform=$script:Device.Platform;public_key_fingerprint=$script:Device.Fingerprint}) | ConvertTo-Json -AsArray
        }
        $output=Join-Path $TestDrive 'recovered.connection.json'
        Approve-CvsAdminRequest $script:ConfigPath $script:RequestPath $output $script:Device.Confirmation | Should -Be $output
        Should -Invoke Invoke-CvsAdminCommand -ModuleName Admin -Times 0 -ParameterFilter { $Command -eq 'approve' }
    }

    It 'never overwrites an approval for a different identity with the same device name' {
        Mock Invoke-CvsAdminCommand -ModuleName Admin {
            return @(@{device_id=$script:Device.DeviceId;platform='windows';public_key_fingerprint='SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'}) | ConvertTo-Json -AsArray
        }
        $output=Join-Path $TestDrive 'conflict.connection.json'
        { Approve-CvsAdminRequest $script:ConfigPath $script:RequestPath $output $script:Device.Confirmation } | Should -Throw '*admin_device_conflict*'
        Test-Path $output | Should -BeFalse
        Should -Invoke Invoke-CvsAdminCommand -ModuleName Admin -Times 0 -ParameterFilter { $Command -eq 'approve' }
    }

    It 'does not create a connection profile for a mismatched server response or lost approval response' {
        foreach ($case in @('mismatch','lost')) {
            Mock Invoke-CvsAdminCommand -ModuleName Admin {
                param($Config,$Command,$InputText)
                if ($Command -eq 'list') { return '[]' }
                if ($case -eq 'lost') { throw 'native_timeout' }
                return '{"status":"approved","device_id":"wrong-device","public_key_fingerprint":"wrong","platform":"windows"}'
            }
            $output=Join-Path $TestDrive "$case.connection.json"
            { Approve-CvsAdminRequest $script:ConfigPath $script:RequestPath $output $script:Device.Confirmation } | Should -Throw '*admin_result_unknown*'
            Test-Path $output | Should -BeFalse
        }
    }

    It 'does not send an approval if the destination already exists' {
        Mock Invoke-CvsAdminCommand -ModuleName Admin { throw 'must_not_connect' }
        $output=Join-Path $TestDrive 'existing.json'; Set-Content $output 'preserve'
        { Approve-CvsAdminRequest $script:ConfigPath $script:RequestPath $output $script:Device.Confirmation } | Should -Throw '*admin_output_exists*'
        Get-Content $output | Should -Be 'preserve'
        Should -Invoke Invoke-CvsAdminCommand -ModuleName Admin -Times 0
    }

    It 'uses pinned noninteractive SSH and a fixed server command with JSON only on stdin' {
        Mock Get-CvsVerifiedKnownHosts -ModuleName CodexViaServer { param($Profile,$RuntimeDirectory) return Join-Path $RuntimeDirectory 'known_hosts' }
        Mock Invoke-AdminSsh -ModuleName Admin { param($Arguments,$InputText) return '[]' }
        Get-CvsAdminDevices $script:ConfigPath | Should -BeNullOrEmpty
        Should -Invoke Invoke-AdminSsh -ModuleName Admin -Times 1 -ParameterFilter {
            $Arguments -contains 'BatchMode=yes' -and $Arguments -contains 'IdentitiesOnly=yes' -and
            $Arguments -contains 'PasswordAuthentication=no' -and $Arguments -contains 'KbdInteractiveAuthentication=no' -and
            $Arguments -contains 'StrictHostKeyChecking=yes' -and $Arguments -contains 'ProxyCommand=none' -and
            $Arguments -contains 'ProxyJump=none' -and $Arguments -contains 'PermitLocalCommand=no' -and
            $Arguments -contains 'ClearAllForwardings=yes' -and $Arguments[-2] -eq '/usr/local/sbin/codex-via-server-devices' -and $Arguments[-1] -eq 'list' -and -not $InputText
        }
    }

    It 'never sends administrator commands after host pin verification fails' {
        Mock Get-CvsVerifiedKnownHosts -ModuleName CodexViaServer { throw 'wrong_host_key' }
        Mock Invoke-AdminSsh -ModuleName Admin { throw 'must_not_connect' }
        { Get-CvsAdminDevices $script:ConfigPath } | Should -Throw '*admin_host_unverified*'
        Should -Invoke Invoke-AdminSsh -ModuleName Admin -Times 0
    }

    It 'binds administrator confirmation to both device name and platform as well as its public key' {
        Mock Invoke-CvsAdminCommand -ModuleName Admin { throw 'must_not_connect' }
        $changed = Get-Content $script:RequestPath -Raw | ConvertFrom-Json
        $changed.device_id = 'renamed-device'; $path = Join-Path $TestDrive 'renamed.request.json'
        $changed | ConvertTo-Json | Set-Content $path
        { Approve-CvsAdminRequest $script:ConfigPath $path (Join-Path $TestDrive 'rename.json') $script:Device.Confirmation } | Should -Throw '*admin_request_changed*'
        Should -Invoke Invoke-CvsAdminCommand -ModuleName Admin -Times 0
    }
}
