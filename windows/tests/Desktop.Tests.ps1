$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Import-Module (Join-Path $RepositoryRoot "windows/CodexViaServer.psm1") -Force

Describe "Windows desktop persistent tunnel" {
    InModuleScope CodexViaServer {
        BeforeEach {
            $caseId = [guid]::NewGuid().ToString("N")
            $env:CODEX_VIA_SERVER_HOME = Join-Path $TestDrive "client-$caseId"
            $env:CODEX_VIA_SERVER_INSTALL_ROOT = Join-Path $TestDrive "install-$caseId"
            $env:CODEX_HOME = Join-Path $TestDrive "codex-$caseId"
            New-Item -ItemType Directory -Force -Path $env:CODEX_VIA_SERVER_INSTALL_ROOT,$env:CODEX_HOME | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $env:CODEX_VIA_SERVER_HOME "keys") | Out-Null
            Set-Content -LiteralPath (Join-Path $env:CODEX_VIA_SERVER_INSTALL_ROOT "persistent-tunnel.ps1") -Value "param()"
            Set-Content -LiteralPath (Join-Path $env:CODEX_VIA_SERVER_HOME "keys\windows-test-01") -Value "private-test-fixture"
            Set-Content -LiteralPath (Join-Path $env:CODEX_VIA_SERVER_HOME "keys\windows-test-01.pub") -Value "public-test-fixture"
            $script:DesktopProfile = [pscustomobject]@{
                server = [pscustomobject]@{host="100.64.10.20";ssh_port=22;ssh_user="codex-tunnel";host_fingerprints=@("SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")}
                gateway = [pscustomobject]@{remote_host="127.0.0.1";remote_port=18319}
                client = [pscustomobject]@{local_port=18317;codex_profile="codex-via-server";minimum_codex_version="0.149.1"}
                approved_device = [pscustomobject]@{device_id="windows-test-01"}
            }
            Mock Get-CvsConnectionProfile { $script:DesktopProfile }
            Mock Register-CvsDesktopTask {}
            Mock Start-ScheduledTask {}
            Mock Wait-CvsDesktopGateway { $true }
            Mock Remove-CvsDesktopTask {}
            Mock Stop-CvsDesktopRuntime { $false }
        }

        AfterEach {
            Remove-Item Env:CODEX_VIA_SERVER_HOME,Env:CODEX_VIA_SERVER_INSTALL_ROOT,Env:CODEX_HOME -ErrorAction SilentlyContinue
        }

        It "backs up once and writes an idempotent HTTP no-auth provider" {
            $configPath = Join-Path $env:CODEX_HOME "config.toml"
            $original = @'
model_provider = "original"
model = "example-model"

[model_providers.original]
base_url = "https://example.invalid/v1"
'@
            Set-Content -LiteralPath $configPath -Value $original -Encoding utf8NoBOM

            Install-CvsDesktop | Out-Null
            Install-CvsDesktop | Out-Null

            $managed = Get-Content -LiteralPath $configPath -Raw
            $managed | Should -Match 'model_provider = "codex_via_server_desktop"'
            $managed | Should -Match 'base_url = "http://127\.0\.0\.1:18317/v1"'
            $managed | Should -Not -Match 'base_url = "https://127\.0\.0\.1:'
            $managed | Should -Match 'requires_openai_auth = false'
            ([regex]::Matches($managed, '\[model_providers\.codex_via_server_desktop\]').Count) | Should -Be 1
            (Get-Content -LiteralPath (Get-CvsDesktopBackupPath) -Raw).Trim() | Should -Be $original.Trim()
            if ($IsWindows) {
                foreach ($privatePath in @($env:CODEX_VIA_SERVER_HOME, (Get-CvsConfigDirectory), $configPath, (Join-Path $env:CODEX_VIA_SERVER_HOME "keys\windows-test-01"))) {
                    $privateAcl = Get-Acl -LiteralPath $privatePath
                    $privateAcl.AreAccessRulesProtected | Should -BeTrue
                    @($privateAcl.Access).Count | Should -Be 1
                }
            }
            Should -Invoke Register-CvsDesktopTask -Times 2
        }

        It "restores the exact pre-install Codex configuration" {
            $configPath = Join-Path $env:CODEX_HOME "config.toml"
            $original = "model_provider = `"original`"`r`nmodel = `"example-model`"`r`n"
            Set-Content -LiteralPath $configPath -Value $original -NoNewline -Encoding utf8NoBOM
            $before = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash

            Install-CvsDesktop | Out-Null
            Uninstall-CvsDesktop | Out-Null

            (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash | Should -Be $before
            Test-Path -LiteralPath (Get-CvsDesktopBackupPath) | Should -BeFalse
            Should -Invoke Remove-CvsDesktopTask -Times 1
        }

        It "restarts the current-user task and verifies the endpoint" {
            Mock Get-ScheduledTask { [pscustomobject]@{State="Running"} }
            Mock Stop-ScheduledTask {}
            $result = Restart-CvsDesktop
            $result.Status | Should -Be "pass"
            Should -Invoke Stop-ScheduledTask -Times 1
            Should -Invoke Start-ScheduledTask -Times 1
            Should -Invoke Wait-CvsDesktopGateway -Times 1
        }

        It "starts an installed task and verifies the endpoint" {
            Mock Get-ScheduledTask { [pscustomobject]@{State="Ready"} }
            $result = Start-CvsDesktop
            $result.Status | Should -Be "pass"
            Should -Invoke Start-ScheduledTask -Times 1
            Should -Invoke Wait-CvsDesktopGateway -Times 1
        }

        It "stops the task and only the managed tunnel runtime" {
            Mock Get-ScheduledTask { [pscustomobject]@{State="Running"} }
            Mock Stop-ScheduledTask {}
            Mock Stop-CvsDesktopRuntime { $true }
            $result = Stop-CvsDesktop
            $result.Status | Should -Be "stopped"
            Should -Invoke Stop-ScheduledTask -Times 1
            Should -Invoke Stop-CvsDesktopRuntime -Times 1
        }

        It "routes start and stop commands and protects persistent state" {
            $dispatcher = Get-Content -LiteralPath (Join-Path $script:ModuleRoot "codex-via-server.ps1") -Raw
            $persistent = Get-Content -LiteralPath (Join-Path $script:ModuleRoot "persistent-tunnel.ps1") -Raw
            $dispatcher | Should -Match '"desktop-start"'
            $dispatcher | Should -Match '"desktop-stop"'
            $persistent | Should -Match 'Set-CvsPrivateAcl\s+\$stateDirectory'
            $persistent | Should -Match 'Set-CvsPrivateAcl\s+\$logPath'
            $persistent | Should -Match 'Start-Sleep -Seconds 5'
        }
    }
}

Describe "Windows managed SSH process ownership" {
    InModuleScope CodexViaServer {
        BeforeEach {
            $env:CODEX_VIA_SERVER_HOME = Join-Path $TestDrive "client"
            $env:CODEX_VIA_SERVER_KEY_DIR = Join-Path $env:CODEX_VIA_SERVER_HOME "keys"
            New-Item -ItemType Directory -Force -Path $env:CODEX_VIA_SERVER_KEY_DIR | Out-Null
            $script:ProcessProfile = [pscustomobject]@{
                server = [pscustomobject]@{host="100.64.10.20";ssh_port=22;ssh_user="codex-tunnel"}
                gateway = [pscustomobject]@{remote_port=18319}
                client = [pscustomobject]@{local_port=18317}
                approved_device = [pscustomobject]@{device_id="windows-test-01"}
            }
            $runtime = Join-Path ([System.IO.Path]::GetTempPath()) "codex-via-server-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            $knownHosts = Join-Path $runtime "known_hosts"
            $identity = Join-Path $env:CODEX_VIA_SERVER_KEY_DIR "windows-test-01"
            $arguments = New-CvsSshArguments -Profile $script:ProcessProfile -Identity $identity -KnownHosts $knownHosts
            $encoded = @($arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
            $script:ManagedCommandLine = '"C:\Windows\System32\OpenSSH\ssh.exe" ' + ($encoded -join ' ')
            Mock Get-NetTCPConnection { [pscustomobject]@{OwningProcess=4321} }
            Mock Get-Process { [pscustomobject]@{Id=4321;HasExited=$false} }
        }

        AfterEach {
            Remove-Item Env:CODEX_VIA_SERVER_HOME,Env:CODEX_VIA_SERVER_KEY_DIR -ErrorAction SilentlyContinue
        }

        It "recognizes the exact approved restricted SSH listener" {
            Mock Get-CimInstance { [pscustomobject]@{Name="ssh.exe";ExecutablePath="C:\Windows\System32\OpenSSH\ssh.exe";CommandLine=$script:ManagedCommandLine} }
            $process = Get-CvsManagedTunnelProcess -Profile $script:ProcessProfile
            $process.Id | Should -Be 4321
        }

        It "returns no process when the approved port has no listener" {
            Mock Get-NetTCPConnection { $null }
            Mock Get-CimInstance {}
            Get-CvsManagedTunnelProcess -Profile $script:ProcessProfile | Should -BeNullOrEmpty
            Should -Invoke Get-CimInstance -Times 0
        }

        It "rejects an SSH listener with a different forwarding target" {
            $otherCommand = $script:ManagedCommandLine.Replace("127.0.0.1:18317:127.0.0.1:18319", "127.0.0.1:18317:127.0.0.1:19999")
            Mock Get-CimInstance { [pscustomobject]@{Name="ssh.exe";ExecutablePath="C:\Windows\System32\OpenSSH\ssh.exe";CommandLine=$otherCommand} }
            Get-CvsManagedTunnelProcess -Profile $script:ProcessProfile | Should -BeNullOrEmpty
        }

        It "never stops an unrelated SSH listener" {
            Mock Get-CvsConnectionProfile { $script:ProcessProfile }
            Mock Get-CvsManagedTunnelProcess { $null }
            Mock Stop-Process {}
            Stop-CvsDesktopRuntime | Should -BeFalse
            Should -Invoke Stop-Process -Times 0
        }

        It "stops an exact matching managed SSH listener" {
            Mock Get-CvsConnectionProfile { $script:ProcessProfile }
            Mock Get-CvsManagedTunnelProcess { [pscustomobject]@{Id=4321;HasExited=$false} }
            Mock Stop-Process {}
            Stop-CvsDesktopRuntime | Should -BeTrue
            Should -Invoke Stop-Process -Times 1 -ParameterFilter { $Id -eq 4321 -and $Force }
        }
    }
}

Describe "Windows desktop Scheduled Task definition" {
    InModuleScope CodexViaServer {
        BeforeEach {
            $env:CODEX_VIA_SERVER_INSTALL_ROOT = Join-Path $TestDrive ("task-install-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force -Path $env:CODEX_VIA_SERVER_INSTALL_ROOT | Out-Null
            Set-Content -LiteralPath (Join-Path $env:CODEX_VIA_SERVER_INSTALL_ROOT "persistent-tunnel.ps1") -Value "param()"
            Mock Get-CvsExecutable { "C:\Program Files\PowerShell\7\pwsh.exe" }
            Mock Get-CvsCurrentUserId { "EXAMPLE\standard-user" }
            $script:RegisteredTask = $null
            Mock Register-ScheduledTask { $script:RegisteredTask = $InputObject }
        }

        AfterEach {
            Remove-Item Env:CODEX_VIA_SERVER_INSTALL_ROOT -ErrorAction SilentlyContinue
        }

        It "registers a hidden current-user logon task with recovery and no time limit" {
            Register-CvsDesktopTask
            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq "CodexViaServer Persistent Tunnel" -and $Force }
            $script:RegisteredTask.Actions.Execute | Should -Be "C:\Program Files\PowerShell\7\pwsh.exe"
            $script:RegisteredTask.Actions.Arguments | Should -Match '-NonInteractive'
            $script:RegisteredTask.Actions.Arguments | Should -Match 'persistent-tunnel\.ps1'
            $script:RegisteredTask.Triggers.UserId | Should -Be "EXAMPLE\standard-user"
            $script:RegisteredTask.Settings.Hidden | Should -BeTrue
            $script:RegisteredTask.Settings.RestartCount | Should -Be 999
            $script:RegisteredTask.Settings.MultipleInstances | Should -Be "IgnoreNew"
            $script:RegisteredTask.Settings.ExecutionTimeLimit | Should -Be "PT0S"
            $script:RegisteredTask.Principal.UserId | Should -Be "EXAMPLE\standard-user"
            $script:RegisteredTask.Principal.LogonType | Should -Be "Interactive"
            $script:RegisteredTask.Principal.RunLevel | Should -Be "Limited"
        }
    }
}

Describe "Windows command dispatcher" {
    BeforeAll {
        $DispatcherScript = (Resolve-Path (Join-Path $PSScriptRoot "../codex-via-server.ps1")).Path
    }

    It "accepts doctor with no optional arguments" {
        $emptyHome = Join-Path $TestDrive "missing-profile"
        $previousHome = $env:CODEX_VIA_SERVER_HOME
        $previousProfile = $env:CODEX_VIA_SERVER_CONNECTION_PROFILE
        try {
            $env:CODEX_VIA_SERVER_HOME = $emptyHome
            $env:CODEX_VIA_SERVER_CONNECTION_PROFILE = Join-Path $emptyHome "missing.json"
            $output = & pwsh -NoLogo -NoProfile -NonInteractive -File $DispatcherScript doctor 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            if ($null -eq $previousHome) { Remove-Item Env:CODEX_VIA_SERVER_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_VIA_SERVER_HOME = $previousHome }
            if ($null -eq $previousProfile) { Remove-Item Env:CODEX_VIA_SERVER_CONNECTION_PROFILE -ErrorAction SilentlyContinue } else { $env:CODEX_VIA_SERVER_CONNECTION_PROFILE = $previousProfile }
        }
        $exitCode | Should -Not -Be 0
        ($output | Out-String) | Should -Not -Match 'Value cannot be null|IndexOf'
    }

    It "accepts desktop commands with no optional arguments" {
        $dispatcher = Get-Content -LiteralPath $DispatcherScript -Raw
        $dispatcher | Should -Match '\$RemainingArguments = @\(\$RemainingArguments \| Where-Object'
    }
}
