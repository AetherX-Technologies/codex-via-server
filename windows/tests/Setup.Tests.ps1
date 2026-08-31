BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    Import-Module (Join-Path $script:RepositoryRoot "windows/CodexViaServer.psm1") -Force
    $script:TestHome = Join-Path $TestDrive "home"
    New-Item -ItemType Directory -Force -Path $script:TestHome | Out-Null
    $env:CODEX_VIA_SERVER_HOME = $script:TestHome
    $env:CODEX_VIA_SERVER_SSH_KEYGEN = (Get-Command ssh-keygen).Source
}

AfterAll {
    Remove-Item Env:CODEX_VIA_SERVER_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_VIA_SERVER_SSH_KEYGEN -ErrorAction SilentlyContinue
}

Describe "Windows setup and enrollment" {
    It "creates a reusable Windows enrollment request" {
        $request = Join-Path $TestDrive "request.json"
        Initialize-CvsDevice -DeviceId "windows-test-01" -OutputPath $request | Should -Be $request
        $first = Get-Content $request -Raw | ConvertFrom-Json
        $first.platform | Should -Be "windows"
        $first.PSObject.Properties.Name | Should -Not -Contain "api_key"
        $key = Join-Path $env:CODEX_VIA_SERVER_HOME "keys/windows-test-01.pub"
        $fingerprint1 = (& $env:CODEX_VIA_SERVER_SSH_KEYGEN -lf $key -E sha256) -split '\s+'
        Initialize-CvsDevice -DeviceId "windows-test-01" -OutputPath $request | Out-Null
        $fingerprint2 = (& $env:CODEX_VIA_SERVER_SSH_KEYGEN -lf $key -E sha256) -split '\s+'
        $fingerprint1[1] | Should -Be $fingerprint2[1]
        if ($IsWindows) {
            $acl = Get-Acl (Join-Path $env:CODEX_VIA_SERVER_HOME "keys/windows-test-01")
            $acl.AreAccessRulesProtected | Should -BeTrue
        }
    }

    It "rejects unsafe device identifiers" {
        { Initialize-CvsDevice -DeviceId "../../unsafe" -OutputPath (Join-Path $TestDrive "unsafe.json") } | Should -Throw
    }

    It "imports a matching no-secret profile without changing default config" {
        $request = Join-Path $TestDrive "enroll-request.json"
        Initialize-CvsDevice -DeviceId "windows-enroll-01" -OutputPath $request | Out-Null
        $publicKey = Join-Path $env:CODEX_VIA_SERVER_HOME "keys/windows-enroll-01.pub"
        $fingerprint = ((& $env:CODEX_VIA_SERVER_SSH_KEYGEN -lf $publicKey -E sha256) -split '\s+')[1]
        $profile = Join-Path $TestDrive "profile.json"
        [ordered]@{
            schema_version = 1
            profile_id = "test-profile"
            server = [ordered]@{host="100.64.10.20";ssh_port=22;ssh_user="codex-tunnel";host_fingerprints=@("SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")}
            gateway = [ordered]@{remote_host="127.0.0.1";remote_port=18319}
            client = [ordered]@{local_port=18317;codex_profile="codex-via-server";minimum_client_version="0.2.0-dev.1";minimum_codex_version="0.149.1"}
            approved_device = [ordered]@{device_id="windows-enroll-01";public_key_fingerprint=$fingerprint}
            issued_at = "2026-08-31T09:00:00Z"
        } | ConvertTo-Json -Depth 8 | Set-Content $profile -Encoding utf8NoBOM
        $codexHome = Join-Path $env:CODEX_VIA_SERVER_HOME ".codex"
        New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
        $defaultConfig = Join-Path $codexHome "config.toml"
        Set-Content $defaultConfig 'sentinel = "unchanged"'
        $before = (Get-FileHash $defaultConfig).Hash
        $env:CODEX_HOME = $codexHome
        Import-CvsConnectionProfile -Path $profile | Out-Null
        (Get-FileHash $defaultConfig).Hash | Should -Be $before
        $generated = Get-Content (Join-Path $codexHome "codex-via-server.config.toml") -Raw
        $generated | Should -Match 'wire_api = "responses"'
        $generated | Should -Not -Match 'env_key|requires_openai_auth|model_catalog_json'
        Remove-Item Env:CODEX_HOME
    }

    It "rejects an unknown nested credential field" {
        $request = Join-Path $TestDrive "unsafe-request.json"
        Initialize-CvsDevice -DeviceId "windows-unsafe-01" -OutputPath $request | Out-Null
        $publicKey = Join-Path $env:CODEX_VIA_SERVER_HOME "keys/windows-unsafe-01.pub"
        $fingerprint = ((& $env:CODEX_VIA_SERVER_SSH_KEYGEN -lf $publicKey -E sha256) -split '\s+')[1]
        $profile = Join-Path $TestDrive "unsafe-profile.json"
        [ordered]@{
            schema_version=1; profile_id="unsafe-profile"
            server=[ordered]@{host="100.64.10.20";ssh_port=22;ssh_user="codex-tunnel";host_fingerprints=@("SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")}
            gateway=[ordered]@{remote_host="127.0.0.1";remote_port=18319;api_key="forbidden"}
            client=[ordered]@{local_port=18317;codex_profile="codex-via-server";minimum_client_version="0.2.0-dev.1";minimum_codex_version="0.149.1"}
            approved_device=[ordered]@{device_id="windows-unsafe-01";public_key_fingerprint=$fingerprint}
            issued_at="2026-08-31T09:01:00Z"
        } | ConvertTo-Json -Depth 8 | Set-Content $profile -Encoding utf8NoBOM
        { Import-CvsConnectionProfile -Path $profile } | Should -Throw
    }

    It "installs into a normal-user directory" {
        $installRoot = Join-Path $TestDrive "installed-client"
        & (Join-Path $script:RepositoryRoot "windows/install.ps1") -InstallRoot $installRoot | Out-Null
        Test-Path (Join-Path $installRoot "codex-via-server.ps1") | Should -BeTrue
        Test-Path (Join-Path $installRoot "CodexViaServer.psm1") | Should -BeTrue
        Test-Path (Join-Path $installRoot "VERSION") | Should -BeTrue
    }
}
