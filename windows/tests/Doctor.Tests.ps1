$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Import-Module (Join-Path $script:RepositoryRoot "windows/CodexViaServer.psm1") -Force

Describe "Windows doctor and launcher" {
    InModuleScope CodexViaServer {
        BeforeEach {
            $script:FakeProfile = [pscustomobject]@{
                server = [pscustomobject]@{host="100.64.10.20";ssh_port=22;ssh_user="codex-tunnel";host_fingerprints=@("SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")}
                gateway = [pscustomobject]@{remote_host="127.0.0.1";remote_port=18319}
                client = [pscustomobject]@{local_port=18317;codex_profile="codex-via-server";minimum_codex_version="0.149.1"}
                approved_device = [pscustomobject]@{device_id="windows-test-01"}
            }
            Mock Get-CvsConnectionProfile { $script:FakeProfile }
            Mock Test-CvsVersionAtLeast { $true }
            Mock Test-CvsCodexConfiguration { "0.151.0" }
            Mock Get-CvsManagedTunnelProcess { $null }
            Mock Get-CvsPortListeners { @() }
        }

        It "requires explicit live confirmation" {
            { Test-CvsDoctor -Live -Model test-model } | Should -Throw
        }

        It "runs doctor through a tunnel and cleans up" {
            Mock Start-CvsTunnel { [pscustomobject]@{Process=$null;RuntimeDirectory=$null;Profile=$script:FakeProfile} }
            Mock Stop-CvsTunnel {}
            Mock Invoke-WebRequest { [pscustomobject]@{Content='data: {"type":"response.completed"}'} }
            $result = Test-CvsDoctor -Live -Yes -Model test-model
            $result.Status | Should -Be "pass"
            Should -Invoke Start-CvsTunnel -Times 1
            Should -Invoke Stop-CvsTunnel -Times 1
        }

        It "removes possible provider secrets before launching Codex" {
            Mock Start-CvsTunnel { [pscustomobject]@{Process=$null;RuntimeDirectory=$null;Profile=$script:FakeProfile} }
            Mock Stop-CvsTunnel {}
            $env:SERVER_CODEX_API_KEY="secret"
            $env:CLIPROXY_API_KEY="secret"
            $env:OPENAI_API_KEY="secret"
            Mock Invoke-CvsOfficialCodex {
                $env:SERVER_CODEX_API_KEY | Should -BeNullOrEmpty
                $env:CLIPROXY_API_KEY | Should -BeNullOrEmpty
                $env:OPENAI_API_KEY | Should -BeNullOrEmpty
                return 0
            }
            Invoke-CvsCodex -Arguments @("exec", "prompt") | Should -Be 0
            Should -Invoke Stop-CvsTunnel -Times 1
        }

        It "builds a restricted SSH argument list" {
            $arguments = $null
            $policy = Get-CvsTunnelPolicy
            Mock Get-CvsConnectionProfile { $script:FakeProfile }
            Mock Test-CvsTailscaleReachability { throw 'ping_unavailable_while_ssh_works' }
            Mock Test-CvsLocalPortAvailable {}
            Mock Get-CvsVerifiedKnownHosts { "C:\temp\known_hosts" }
            Mock Get-CvsKeyDirectory { $TestDrive }
            Mock Test-Path { $true }
            Mock Get-Item { [pscustomobject]@{LinkType=$null} }
            Mock Set-CvsPrivateAcl {}
            Mock Get-CvsExecutable { "C:\Windows\System32\OpenSSH\ssh.exe" }
            Mock Start-CvsSshProcess {
                $script:arguments = $Arguments
                [pscustomobject]@{Process=[pscustomobject]@{HasExited=$false;Id=4321}}
            }
            Mock Test-CvsGatewayHealth { $true }
            $tunnel = Start-CvsTunnel -Policy $policy
            Should -Invoke Test-CvsTailscaleReachability -Times 0
            $joined = $script:arguments -join " "
            $joined | Should -Match '127\.0\.0\.1:18317:127\.0\.0\.1:18319'
            $joined | Should -Match 'BatchMode=yes'
            $joined | Should -Match 'IdentitiesOnly=yes'
            $joined | Should -Match 'PasswordAuthentication=no'
            $joined | Should -Match 'ProxyCommand=none'
            $joined | Should -Match 'ProxyJump=none'
            $joined | Should -Match '(?:^|\s)-T(?:\s|$)'
            $joined | Should -Match 'TCPKeepAlive=yes'
            $joined | Should -Not -Match 'api.key|Authorization|CLIPROXY'
            $tunnel.Profile.server.ssh_user | Should -Be 'codex-tunnel'
        }

        It "reuses only a verified managed SSH listener" {
            $managed = [pscustomobject]@{HasExited=$false;Id=2468}
            Mock Get-CvsManagedTunnelProcess { $managed }
            Mock Test-CvsGatewayHealth { $true }
            Mock Test-CvsTailscaleReachability {}
            $tunnel = Start-CvsTunnel
            $tunnel.Reused | Should -BeTrue
            $tunnel.Process | Should -BeNullOrEmpty
            $tunnel.ManagedProcess.Id | Should -Be 2468
            Should -Invoke Test-CvsTailscaleReachability -Times 0
        }

        It "accepts DERP Tailscale reachability without waiting for a direct path" {
            Mock Get-CvsExecutable { "C:\Program Files\Tailscale\tailscale.exe" }
            Mock Invoke-CvsBoundedNative {}
            Test-CvsTailscaleReachability -HostName "100.64.10.20"
            Should -Invoke Invoke-CvsBoundedNative -Times 1 -ParameterFilter {
                $TimeoutSec -eq 10 -and ($Arguments -join ' ') -eq 'ping --timeout=5s --c=1 --until-direct=false 100.64.10.20'
            }
        }

        It "stops the SSH process and removes runtime state" {
            $runtime = Join-Path ([IO.Path]::GetTempPath()) ('codex-via-server-'+[guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $runtime | Out-Null
            $process = [pscustomobject]@{HasExited=$false;Id=4321}
            Mock Stop-CvsManagedProcess { $true }
            Stop-CvsTunnel ([pscustomobject]@{Process=$process;RuntimeDirectory=$runtime;Profile=$script:FakeProfile})
            Should -Invoke Stop-CvsManagedProcess -Times 1 -ParameterFilter {$Process.Id -eq 4321}
            Test-Path $runtime | Should -BeFalse
        }
    }
}
