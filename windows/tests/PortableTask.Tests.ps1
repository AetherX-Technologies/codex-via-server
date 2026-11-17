$Repository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Import-Module (Join-Path $Repository 'windows/CodexViaServer.psm1') -Force

Describe 'Portable task survives its installing process' {
    InModuleScope CodexViaServer {
        BeforeEach {
            $script:SavedEnvironment = @{}
            foreach ($name in @('CODEX_VIA_SERVER_HOME', 'CODEX_HOME', 'CODEX_VIA_SERVER_KEY_DIR', 'CODEX_VIA_SERVER_INSTALL_ROOT', 'CODEX_VIA_SERVER_PWSH', 'CODEX_VIA_SERVER_TASK_NAME')) {
                $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            $env:CODEX_VIA_SERVER_HOME = Join-Path $TestDrive 'independent client'
            $env:CODEX_HOME = Join-Path $TestDrive 'independent codex'
            $env:CODEX_VIA_SERVER_KEY_DIR = Join-Path $TestDrive 'device keys'
            $env:CODEX_VIA_SERVER_INSTALL_ROOT = Join-Path $TestDrive 'client scripts'
            $env:CODEX_VIA_SERVER_PWSH = 'C:\portable\pwsh.exe'
            New-Item -ItemType Directory -Path $env:CODEX_VIA_SERVER_INSTALL_ROOT -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $env:CODEX_VIA_SERVER_INSTALL_ROOT 'persistent-tunnel.ps1') -Value 'param()'
            Mock Register-ScheduledTask {}
        }

        AfterEach {
            foreach ($name in $script:SavedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name], 'Process') }
        }

        It 'persists the client, Codex and key directories in the task action' {
            Register-CvsDesktopTask
            Should -Invoke Register-ScheduledTask -ParameterFilter {
                $InputObject.Actions[0].Arguments.Contains('-ClientHome "' + $env:CODEX_VIA_SERVER_HOME + '"') -and
                $InputObject.Actions[0].Arguments.Contains('-CodexHome "' + $env:CODEX_HOME + '"') -and
                $InputObject.Actions[0].Arguments.Contains('-KeyDirectory "' + $env:CODEX_VIA_SERVER_KEY_DIR + '"')
            } -Times 1 -Exactly
        }

        It 'keeps the existing default task name and isolates other client homes' {
            $env:CODEX_VIA_SERVER_HOME = Join-Path $HOME '.codex-via-server'
            Get-CvsDesktopTaskName | Should -Be 'CodexViaServer Persistent Tunnel'
            $env:CODEX_VIA_SERVER_HOME = Join-Path $TestDrive 'first'
            $first = Get-CvsDesktopTaskName
            $env:CODEX_VIA_SERVER_HOME = Join-Path $TestDrive 'second'
            Get-CvsDesktopTaskName | Should -Not -Be $first
            $env:CODEX_VIA_SERVER_HOME = Join-Path $TestDrive 'FIRST'
            Get-CvsDesktopTaskName | Should -Be $first
        }

        It 'rejects a path that can escape task argument quoting' {
            $env:CODEX_HOME = 'C:\unsafe"path'
            { Register-CvsDesktopTask } | Should -Throw '*unsafe_task_path*'
            Should -Invoke Register-ScheduledTask -Times 0
        }
    }
}
