Import-Module (Join-Path $PSScriptRoot '../CodexViaServer.psm1') -Force

Describe 'Bounded private SSH error evidence' {
    InModuleScope CodexViaServer {
        It 'allows keepalive timeout diagnostics at the SSH logging threshold' {
            $profile=[pscustomobject]@{server=@{host='example.test';ssh_port=22;ssh_user='codex-tunnel'};client=@{local_port=18339};gateway=@{remote_port=18319}}
            $arguments=New-CvsSshArguments -Profile $profile -Identity 'test-key' -KnownHosts 'test-hosts'
            $arguments | Should -Contain 'LogLevel=INFO'
        }

        It 'classifies real child stderr without retaining private text or blocking a noisy child' {
            $command="[Console]::Error.WriteLine('Timeout, server PRIVATE_ENDPOINT not responding.'); for(`$i=0;`$i -lt 3000;`$i++){[Console]::Error.WriteLine(('PRIVATE_SECRET_'*300))}; exit 255"
            $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
            $worker=Start-CvsSshProcess -Executable (Get-Process -Id $PID).Path -Arguments $arguments
            try {
                $worker.Process.WaitForExit(15000) | Should -BeTrue
                $worker.GetErrorCode() | Should -Be 'server_not_responding'
                $worker.Process.ExitCode | Should -Be 255
                ($worker | ConvertTo-Json -Depth 1 -WarningAction SilentlyContinue) | Should -Not -Match 'PRIVATE_ENDPOINT|PRIVATE_SECRET'
            } finally {if(-not $worker.Process.HasExited){$worker.Process.Kill()};$worker.Dispose()}
        }

        It 'logs only a fixed SSH error category on process exit' {
            $env:CODEX_VIA_SERVER_HOME=Join-Path $TestDrive 'exit-evidence'
            $command="[Console]::Error.WriteLine('Connection reset by PRIVATE_ENDPOINT'); exit 255"
            $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
            $worker=Start-CvsSshProcess -Executable (Get-Process -Id $PID).Path -Arguments $arguments
            try {
                $worker.Process.WaitForExit(10000) | Should -BeTrue
                $tunnel=[pscustomobject]@{Reused=$false;Process=$worker.Process;Diagnostics=$worker;Profile=@{client=@{local_port=18339}}}
                Invoke-CvsTunnelMonitor -Tunnel $tunnel -Policy (Get-CvsTunnelPolicy) | Should -Be 'managed_process_exited'
                $text=Get-Content (Join-Path (Get-CvsStateDirectory) 'persistent-tunnel.log') -Raw
                $entry=$text|ConvertFrom-Json
                $entry.SshError | Should -Be 'connection_reset'
                $entry.SshExitCode | Should -Be 255
                $text | Should -Not -Match 'PRIVATE_ENDPOINT'
            } finally {$worker.Dispose();Remove-Item Env:CODEX_VIA_SERVER_HOME -ErrorAction SilentlyContinue}
        }

        It 'rejects free text in the SSH error field' {
            {Write-CvsTunnelEvent -State Recovering -Code managed_process_exited -SshError 'PRIVATE_ENDPOINT'} | Should -Throw
        }
    }
}
