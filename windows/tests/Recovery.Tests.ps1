Import-Module (Join-Path $PSScriptRoot '../CodexViaServer.psm1') -Force

Describe 'Lightweight gateway health contract' {
    InModuleScope CodexViaServer {
        BeforeEach {
            $env:CODEX_VIA_SERVER_HOME=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Mock Get-CvsManagedTunnelProcess { [pscustomobject]@{Id=42;HasExited=$false} }
            Mock Get-CvsConnectionProfile { [pscustomobject]@{client=@{local_port=18317}} }
            Mock Invoke-WebRequest { [pscustomobject]@{StatusCode=204;Content=''} }
            Mock Invoke-RestMethod { throw 'models must not be downloaded' }
        }
        AfterEach {Remove-Item Env:CODEX_VIA_SERVER_HOME -ErrorAction SilentlyContinue}
        It 'requires a managed owner, bypasses proxies and accepts only empty 204' {
            $r = Test-CvsGatewayHealth -Port 18317 -Detailed
            $r.Success | Should -BeTrue
            $r.Code | Should -Be 'healthy'
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $Uri -eq 'http://127.0.0.1:18317/healthz' -and $NoProxy -and $TimeoutSec -eq 8 -and $MaximumRedirection -eq 0
            }
            Should -Invoke Invoke-RestMethod -Times 0
        }
        It 'rejects status <Status>' -TestCases @(@{Status=200},@{Status=401},@{Status=404},@{Status=302}) {
            param($Status)
            Mock Invoke-WebRequest { [pscustomobject]@{StatusCode=$Status;Content=''} }
            $r=Test-CvsGatewayHealth -Port 18317 -Detailed
            $r.Success | Should -BeFalse
            $r.Code | Should -Be 'gateway_bad_status'
        }
        It 'rejects a nonempty response body' {
            Mock Invoke-WebRequest { [pscustomobject]@{StatusCode=204;Content='unexpected'} }
            Test-CvsGatewayHealth -Port 18317 | Should -BeFalse
        }
        It 'classifies zero-byte timeout without leaking the exception text' {
            Mock Invoke-WebRequest { throw [TimeoutException]::new('private diagnostic content') }
            $r=Test-CvsGatewayHealth -Port 18317 -Detailed
            $r.Code | Should -Be 'gateway_timeout'
            ($r | ConvertTo-Json) | Should -Not -Match 'private diagnostic'
        }
        It 'rejects connection refusal' {
            Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('refused') }
            Test-CvsGatewayHealth -Port 18317 | Should -BeFalse
        }
        It 'does not contact an unowned local listener' {
            Mock Get-CvsManagedTunnelProcess { $null }
            Mock Get-CvsPortListeners { [pscustomobject]@{OwningProcess=999} }
            (Test-CvsGatewayHealth -Port 18317 -Detailed).Code | Should -Be 'unmanaged_listener'
            Should -Invoke Invoke-WebRequest -Times 0
        }
        It 'does not infer SSH process exit merely from a missing listener during startup' {
            Mock Get-CvsManagedTunnelProcess {$null}
            Mock Get-CvsPortListeners {@()}
            (Test-CvsGatewayHealth -Port 18317 -Detailed).Code | Should -Be 'managed_listener_missing'
            Should -Invoke Invoke-WebRequest -Times 0
        }
        It 'rechecks ownership if SSH binds between the two listener snapshots' {
            $script:ownerLookups=0
            Mock Get-CvsManagedTunnelProcess {
                $script:ownerLookups++
                if($script:ownerLookups -gt 1){[pscustomobject]@{Id=42;HasExited=$false}}
            }
            Mock Get-CvsPortListeners {[pscustomobject]@{OwningProcess=42}}
            (Test-CvsGatewayHealth -Port 18317 -Detailed).Code | Should -Be 'healthy'
            Should -Invoke Invoke-WebRequest -Times 1
        }
        It 'leaves a missing snapshot for the next probe instead of taking a third racing snapshot' {
            $script:listenerLookups=0
            Mock Get-CvsManagedTunnelProcess {$null}
            Mock Get-CvsPortListeners {
                $script:listenerLookups++
                if($script:listenerLookups -gt 1){[pscustomobject]@{OwningProcess=42}}
            }
            (Test-CvsGatewayHealth -Port 18317 -Detailed).Code | Should -Be 'managed_listener_missing'
            Should -Invoke Invoke-WebRequest -Times 0
        }
        It 'keeps models as a separate bounded no-proxy functionality test' {
            Mock Invoke-RestMethod { [pscustomobject]@{data=@()} }
            Test-CvsGatewayModels -Port 18317 | Should -BeTrue
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $NoProxy -and $TimeoutSec -eq 45 }
        }
        It 'skips rather than overlaps a probe owned by another thread' {
            $mutex=New-CvsMutex -Kind Health
            # Derive the same name without exposing deployment metadata.
            $bytes=[Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath((Get-CvsRoot)).ToLowerInvariant())
            $name='Local\CodexViaServer-Health-'+[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
            $state=[hashtable]::Synchronized(@{Ready=$false;Release=$false})
            $job=Start-ThreadJob -ArgumentList $name,$state -ScriptBlock {
                param($lockName,$signal)
                $lock=[Threading.Mutex]::new($false,$lockName)
                $held=$false
                try {
                    $held=$lock.WaitOne(1000);$signal.Ready=$held
                    $timer=[Diagnostics.Stopwatch]::StartNew()
                    while(-not $signal.Release -and $timer.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 20}
                } finally {if($held){$lock.ReleaseMutex()};$lock.Dispose()}
            }
            try {
                $timer=[Diagnostics.Stopwatch]::StartNew()
                while(-not $state.Ready -and $timer.Elapsed.TotalSeconds -lt 5){Start-Sleep -Milliseconds 20}
                $state.Ready | Should -BeTrue
                (Test-CvsGatewayHealth -Port 18317 -Detailed).Code | Should -Be 'health_probe_busy'
                Should -Invoke Invoke-WebRequest -Times 0
            } finally {
                $state.Release=$true;$mutex.Dispose()
                $job | Wait-Job -Timeout 5 | Out-Null
                $job | Stop-Job -ErrorAction SilentlyContinue
                $job | Remove-Job -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Prompt process-exit recovery' {
    InModuleScope CodexViaServer {
        BeforeEach {
            Mock Test-CvsDesktopStopRequested {$false}
            Mock Write-CvsTunnelEvent {param($Code,$ExitCode,$ProcessId);$script:exitEvent=@{Code=$Code;ExitCode=$ExitCode;ProcessId=$ProcessId}}
            Mock Test-CvsGatewayHealth {[pscustomobject]@{Success=$true;Code='healthy';DurationMs=0;HttpStatus=204}}
        }
        It 'wakes the monitor delay when its process exits' {
            $timer=[Diagnostics.Stopwatch]::StartNew()
            Wait-CvsMonitorDelay -Seconds 10 -Process ([pscustomobject]@{HasExited=$true}) | Should -BeTrue
            $timer.Elapsed.TotalSeconds | Should -BeLessThan 2
        }
        It 'retains the real reused process exit code and wakes its monitor' {
            $worker=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 2; exit 23') -WindowStyle Hidden -PassThru
            $observed=Get-Process -Id $worker.Id
            try {
                $tunnel=[pscustomobject]@{Reused=$true;ManagedProcess=$observed;Profile=@{client=@{local_port=18317}}}
                $policy=[pscustomobject]@{StartupBudgetSec=30;HealthTimeoutSec=8;HealthIntervalSec=10}
                $timer=[Diagnostics.Stopwatch]::StartNew()
                Invoke-CvsTunnelMonitor -Tunnel $tunnel -Policy $policy | Should -Be 'managed_process_exited'
                $script:exitEvent.ExitCode | Should -Be 23
                $script:exitEvent.ProcessId | Should -Be $worker.Id
                $timer.Elapsed.TotalSeconds | Should -BeLessThan 6
            } finally {
                if(-not $worker.HasExited){Stop-Process -InputObject $worker -Force}
                $observed.Dispose();$worker.Dispose()
            }
        }
        It 'honors manual stop even when the process has exited' {
            Mock Test-CvsDesktopStopRequested {$true}
            Wait-CvsMonitorDelay -Seconds 10 -Process ([pscustomobject]@{HasExited=$true}) | Should -BeFalse
        }
    }
}

Describe 'Independent local runtime policy' {
    InModuleScope CodexViaServer {
        BeforeEach {
            $env:CODEX_VIA_SERVER_HOME=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Get-CvsConfigDirectory) -Force | Out-Null
        }
        AfterEach { Remove-Item Env:CODEX_VIA_SERVER_HOME -ErrorAction SilentlyContinue }
        It 'has bounded conservative backwards-compatible defaults' {
            $p=Get-CvsTunnelPolicy
            $p.HealthTimeoutSec | Should -Be 8
            $p.HealthIntervalSec | Should -Be 10
            $p.ConsecutiveFailureThreshold | Should -Be 3
            $p.MinUnhealthyDurationSec | Should -Be 45
            $p.ActiveSessionGraceSec | Should -Be 90
            $p.RestartCooldownSec | Should -Be 60
            $p.StartupBudgetSec | Should -Be 30
            $p.ReconnectBackoffSec | Should -Be @(5,10,20,40,60)
        }
        It 'reads partial overrides without editing the approved profile' {
            Set-Content (Join-Path (Get-CvsConfigDirectory) 'runtime-policy.json') '{"HealthTimeoutSec":12}'
            (Get-CvsTunnelPolicy).HealthTimeoutSec | Should -Be 12
            Test-Path (Join-Path (Get-CvsConfigDirectory) 'connection-profile.json') | Should -BeFalse
        }
        It 'rejects invalid policy <Json>' -TestCases @(
            @{Json='{"HealthTimeoutSec":0}'},@{Json='{"HealthTimeoutSec":-1}'},
            @{Json='{"StartupBudgetSec":99999}'},@{Json='{"HealthTimeoutSec":"8"}'},
            @{Json='{"HealthTimeoutSec":1.5}'},@{Json='{"Unknown":1}'},
            @{Json='{"ReconnectBackoffSec":[5,0]}'},@{Json='{"ReconnectBackoffSec":[10,5]}'},
            @{Json='{"ReconnectBackoffSec":[]}'},@{Json='null'},@{Json='[]'},@{Json='{broken'}
        ) {
            param($Json)
            Set-Content (Join-Path (Get-CvsConfigDirectory) 'runtime-policy.json') $Json
            {Get-CvsTunnelPolicy} | Should -Throw '*invalid_runtime_policy*'
        }
    }
}

Describe 'Desktop waits for a bounded automatic startup retry' {
    InModuleScope CodexViaServer {
        It 'does not roll back while a connection can become ready after the first attempt budget' {
            $script:readyClock=[Diagnostics.Stopwatch]::StartNew()
            Mock Get-CvsTunnelPolicy {[pscustomobject]@{StartupBudgetSec=1;HealthTimeoutSec=1;ReconnectBackoffSec=@(1)}}
            Mock Test-CvsDesktopStopRequested {$false}
            Mock Get-CvsManagedTunnelProcess {[pscustomobject]@{Id=42}}
            Mock Test-CvsGatewayHealth {$script:readyClock.Elapsed.TotalSeconds -ge 1}
            Wait-CvsDesktopGateway -Port 18317 | Should -BeTrue
        }
    }
}

Describe 'Persistent supervisor same-path new and reused recovery' {
    InModuleScope CodexViaServer {
        BeforeEach {
            $env:CODEX_VIA_SERVER_HOME=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:clock=[DateTimeOffset]'2026-01-01T00:00:00Z'
            $script:probes=0; $script:starts=0; $script:events=@(); $script:stop=$false
            $script:policy=Get-CvsTunnelPolicy
            $script:process=[pscustomobject]@{Id=42;HasExited=$false;StartTime=[datetime]'2026-01-01T00:00:00Z';ExitCode=255}
            $script:profile=[pscustomobject]@{client=@{local_port=18317}}
            Mock Get-CvsUtcNow { $script:clock }
            Mock Get-CvsTunnelPolicy { $script:policy }
            Mock Test-CvsDesktopStopRequested { $script:stop }
            Mock Wait-CvsMonitorDelay { param($Seconds); $script:clock=$script:clock.AddSeconds($Seconds); return (-not $script:stop) }
            Mock Write-CvsTunnelEvent { param($State,$Code,$Failures,$ReconnectAttempt); $script:events+=@{State=$State;Code=$Code;Failures=$Failures;Attempt=$ReconnectAttempt} }
            Mock Start-CvsTunnel {
                $script:starts++
                [pscustomobject]@{Process=$script:process;ManagedProcess=$null;Reused=$false;Profile=$script:profile;RuntimeDirectory=$null}
            }
            Mock Stop-CvsTunnel { $true }
            Mock Test-CvsGatewayModels { $false }
            Mock Test-CvsReplacementTunnel { $true }
            Mock Test-CvsTunnelHasClients { $false }
            Mock Wait-CvsLocalPortReleased { $true }
            Mock Test-CvsGatewayHealth {
                $script:probes++
                $script:clock=$script:clock.AddSeconds(1)
                if($script:probes -ge 4){$script:stop=$true}
                [pscustomobject]@{Success=$true;Code='healthy';DurationMs=1000;HttpStatus=204}
            }
        }
        AfterEach {Remove-Item Env:CODEX_VIA_SERVER_HOME -ErrorAction SilentlyContinue}
        It 'continuously checks a newly created live SSH rather than only HasExited' {
            Invoke-CvsPersistentTunnel
            $script:probes | Should -Be 4
            $script:starts | Should -Be 1
            @($script:events | Where-Object State -eq 'Healthy').Count | Should -BeGreaterThan 0
        }
        It 'tolerates one or two timeouts and resets failures on success' {
            Mock Test-CvsGatewayHealth {
                $script:probes++; $script:clock=$script:clock.AddSeconds(8)
                if($script:probes -ge 5){$script:stop=$true}
                $ok=$script:probes -in @(1,4,5)
                [pscustomobject]@{Success=$ok;Code=if($ok){'healthy'}else{'gateway_timeout'};DurationMs=8000;HttpStatus=if($ok){204}else{0}}
            }
            Invoke-CvsPersistentTunnel
            $script:starts | Should -Be 1
            @($script:events | Where-Object Code -eq 'transport_stalled').Count | Should -Be 0
            @($script:events | Where-Object {$_.State -eq 'Healthy' -and $_.Failures -eq 0}).Count | Should -BeGreaterThan 1
        }
        It 'tolerates relay latency and isolated over-budget 9/10 second stalls without early recovery' {
            $script:latencies=@(0.8,1.9,9.0,1.2,10.5,1.0)
            Mock Test-CvsGatewayHealth {
                $latency=$script:latencies[$script:probes];$script:probes++
                $ok=$latency -le 8
                $script:clock=$script:clock.AddSeconds([math]::Min(8,$latency))
                if($script:probes -ge $script:latencies.Count){$script:stop=$true}
                [pscustomobject]@{Success=$ok;Code=if($ok){'healthy'}else{'gateway_timeout'};DurationMs=[int]([math]::Min(8,$latency)*1000);HttpStatus=if($ok){204}else{0}}
            }
            Invoke-CvsPersistentTunnel
            $script:starts | Should -Be 1
            @($script:events | Where-Object Code -eq 'transport_stalled').Count | Should -Be 0
        }
        It 'does not kill after three failures until the uniform grace also expires' {
            Mock Test-CvsGatewayHealth {
                $script:probes++;$script:clock=$script:clock.AddSeconds(8)
                if($script:probes -eq 5){$script:stop=$true}
                [pscustomobject]@{Success=($script:probes -eq 1);Code='gateway_timeout';DurationMs=8000;HttpStatus=0}
            }
            Invoke-CvsPersistentTunnel
            $script:starts | Should -Be 1
            @($script:events | Where-Object Code -eq 'transport_stalled').Count | Should -Be 0
        }
        It 'recovers a live but zero-byte stalled <Kind> SSH and waits for port release' -TestCases @(@{Kind='new'},@{Kind='reused'}) {
            param($Kind)
            Mock Start-CvsTunnel {
                $script:starts++
                $reuse=$Kind -eq 'reused'
                [pscustomobject]@{Process=if($reuse){$null}else{$script:process};ManagedProcess=if($reuse){$script:process}else{$null};Reused=$reuse;Profile=$script:profile;RuntimeDirectory=$null}
            }
            Mock Test-CvsGatewayHealth {
                $script:probes++; $script:clock=$script:clock.AddSeconds(8)
                if($script:starts -ge 2){$script:stop=$true}
                $ok=($script:probes -eq 1 -or $script:starts -ge 2)
                [pscustomobject]@{Success=$ok;Code=if($ok){'healthy'}else{'gateway_timeout'};DurationMs=8000;HttpStatus=if($ok){204}else{0}}
            }
            Invoke-CvsPersistentTunnel
            $script:starts | Should -Be 2
            @($script:events | Where-Object Code -eq 'transport_stalled').Count | Should -Be 1
            Should -Invoke Stop-CvsTunnel -ParameterFilter {$IncludeReused} -Times 2
            Should -Invoke Wait-CvsLocalPortReleased -Times 1
            @($script:events | Where-Object Code -eq 'recovered').Count | Should -Be 1
        }
        It 'recovers exited processes without waiting for failure grace' {
            $script:process.HasExited=$true
            Mock Start-CvsTunnel { $script:starts++; if($script:starts -eq 2){$script:process.HasExited=$false}; [pscustomobject]@{Process=$script:process;ManagedProcess=$null;Reused=$false;Profile=$script:profile;RuntimeDirectory=$null} }
            Mock Test-CvsGatewayHealth { $script:stop=$true; [pscustomobject]@{Success=$true;Code='healthy';DurationMs=1;HttpStatus=204} }
            Invoke-CvsPersistentTunnel
            @($script:events | Where-Object Code -eq 'managed_process_exited').Count | Should -Be 1
        }
        It 'keeps the same SSH when healthz stalls but the API still answers' {
            Mock Test-CvsGatewayHealth {
                $script:probes++; $script:clock=$script:clock.AddSeconds(8)
                if ($script:probes -ge 16) { $script:stop=$true }
                [pscustomobject]@{Success=($script:probes -eq 1);Code='gateway_timeout';DurationMs=8000;HttpStatus=0}
            }
            Mock Test-CvsGatewayModels { $true }
            Invoke-CvsPersistentTunnel
            $script:starts | Should -Be 1
            Should -Invoke Test-CvsGatewayModels -Times 2 -ParameterFilter { $TimeoutSec -eq 45 -and $Port -eq 18317 }
            @($script:events | Where-Object Code -eq 'transport_stalled').Count | Should -Be 0
        }
        It 'keeps existing client streams when both HTTP probes fail' {
            Mock Test-CvsTunnelHasClients { $true }
            Mock Test-CvsGatewayHealth {
                $script:probes++; $script:clock=$script:clock.AddSeconds(8)
                if($script:probes -ge 12){$script:stop=$true}
                [pscustomobject]@{Success=($script:probes -eq 1);Code='gateway_timeout';DurationMs=8000;HttpStatus=0}
            }
            Invoke-CvsPersistentTunnel
            $script:starts | Should -Be 1
            @($script:events | Where-Object Code -eq 'transport_stalled').Count | Should -Be 0
            @($script:events | Where-Object Code -eq 'recovery_deferred').Count | Should -BeGreaterThan 0
        }
        It 'keeps the old SSH when a separately verified replacement is unavailable' {
            Mock Test-CvsReplacementTunnel { $false }
            Mock Test-CvsGatewayHealth {
                $script:probes++; $script:clock=$script:clock.AddSeconds(8)
                if($script:probes -ge 12){$script:stop=$true}
                [pscustomobject]@{Success=($script:probes -eq 1);Code='gateway_timeout';DurationMs=8000;HttpStatus=0}
            }
            Invoke-CvsPersistentTunnel
            $script:starts | Should -Be 1
            @($script:events | Where-Object Code -eq 'replacement_unavailable').Count | Should -BeGreaterThan 0
        }
        It 'rechecks client connections after verifying the replacement' {
            $script:clientChecks=0
            Mock Test-CvsTunnelHasClients { $script:clientChecks++; $script:clientChecks -gt 1 }
            Mock Test-CvsGatewayHealth {
                $script:probes++; $script:clock=$script:clock.AddSeconds(8)
                if($script:probes -ge 12){$script:stop=$true}
                [pscustomobject]@{Success=($script:probes -eq 1);Code='gateway_timeout';DurationMs=8000;HttpStatus=0}
            }
            Invoke-CvsPersistentTunnel
            $script:starts | Should -Be 1
            @($script:events | Where-Object Code -eq 'recovery_deferred').Count | Should -BeGreaterThan 0
        }
        It 'caps exponential reconnect backoff and stop wins over retry' {
            $script:delays=@()
            Mock Start-CvsTunnel {$script:starts++; throw 'tailscale_unreachable'}
            Mock Wait-CvsMonitorDelay { param($Seconds); $script:delays+= $Seconds; if($script:starts -ge 7){$script:stop=$true}; -not $script:stop }
            Invoke-CvsPersistentTunnel
            $script:delays | Should -Be @(5,10,20,40,60,60,60)
            $script:starts | Should -Be 7
        }
        It 'honors the restart cooldown even when the failure grace is shorter' {
            $script:policy.ActiveSessionGraceSec=10; $script:policy.MinUnhealthyDurationSec=10
            $script:policy.RestartCooldownSec=120
            Mock Test-CvsGatewayHealth {
                $script:probes++;$script:clock=$script:clock.AddSeconds(8)
                if($script:probes -ge 5){$script:stop=$true}
                [pscustomobject]@{Success=$false;Code='gateway_timeout';DurationMs=8000;HttpStatus=0}
            }
            $tunnel=Start-CvsTunnel -Persistent
            $tunnel.Reused=$true; $tunnel.ManagedProcess=$script:process
            Invoke-CvsTunnelMonitor -Tunnel $tunnel -Policy $script:policy -LastRecovery $script:clock | Should -Be 'stopped'
            @($script:events | Where-Object Code -eq 'transport_stalled').Count | Should -Be 0
        }
        It 'does not start any SSH after manual stop' {
            $script:stop=$true
            Invoke-CvsPersistentTunnel
            Should -Invoke Start-CvsTunnel -Times 0
        }
        It 'does not grant another full startup budget after key verification and SSH creation' {
            Mock Test-CvsGatewayHealth {
                $script:clock=$script:clock.AddSeconds(2)
                [pscustomobject]@{Success=$false;Code='gateway_timeout';DurationMs=2000;HttpStatus=0}
            }
            $tunnel=Start-CvsTunnel -Persistent
            $tunnel | Add-Member StartupRemainingSec 2
            Invoke-CvsTunnelMonitor -Tunnel $tunnel -Policy $script:policy | Should -Be 'gateway_timeout'
            Should -Invoke Test-CvsGatewayHealth -Times 1 -ParameterFilter {$TimeoutSec -eq 2}
        }
        It 'observes a new listener before the remaining startup budget expires' {
            Mock Test-CvsGatewayHealth {
                $script:probes++;$script:clock=$script:clock.AddSeconds(0.1)
                $ok=$script:probes -gt 1
                if($ok){$script:stop=$true}
                [pscustomobject]@{Success=$ok;Code=if($ok){'healthy'}else{'managed_listener_missing'};DurationMs=100;HttpStatus=if($ok){204}else{0}}
            }
            $tunnel=Start-CvsTunnel -Persistent
            $tunnel | Add-Member StartupRemainingSec 3
            Invoke-CvsTunnelMonitor -Tunnel $tunnel -Policy $script:policy | Should -Be 'stopped'
            $script:probes | Should -Be 2
            @($script:events | Where-Object Code -eq 'healthy').Count | Should -Be 1
        }
        It 'resets creation backoff after a healthy channel while preserving the total reconnect count' {
            $script:delays=@()
            Mock Start-CvsTunnel {
                $script:starts++
                if($script:starts -in @(1,2,4)){throw 'tailscale_unreachable'}
                [pscustomobject]@{Process=$script:process;ManagedProcess=$null;Reused=$false;Profile=$script:profile;RuntimeDirectory=$null}
            }
            Mock Invoke-CvsTunnelMonitor {param($RecoveryContext);$RecoveryContext.HadHealthyProbe=$true;return 'transport_stalled'}
            Mock Wait-CvsMonitorDelay {param($Seconds);$script:delays+=$Seconds;if($script:starts -ge 4){$script:stop=$true};-not $script:stop}
            Invoke-CvsPersistentTunnel
            $script:delays | Should -Be @(5,10,5,10)
            @($script:events | Where-Object Code -eq 'restart_backoff')[-1].Attempt | Should -Be 4
        }
        It 'does not recover by repeatedly downloading models or infer activity from TCP' {
            Mock Test-CvsGatewayModels {throw 'not a health probe'}
            Invoke-CvsPersistentTunnel
            Should -Invoke Test-CvsGatewayModels -Times 0
        }
        It 'allows only one supervisor even outside Task Scheduler' {
            New-Item -ItemType Directory -Path (Get-CvsStateDirectory) -Force | Out-Null
            $lock=[IO.File]::Open((Join-Path (Get-CvsStateDirectory) 'persistent-tunnel.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try {Invoke-CvsPersistentTunnel} finally {$lock.Dispose()}
            Should -Invoke Start-CvsTunnel -Times 0
        }
        It 'resumes an explicit new activation after stop but still honors the next stop' {
            New-Item -ItemType Directory -Path (Get-CvsStateDirectory) -Force | Out-Null
            Set-Content (Join-Path (Get-CvsStateDirectory) 'desktop-stopped') 'stopped'
            Mock Test-CvsDesktopStopRequested { Test-Path (Join-Path (Get-CvsStateDirectory) 'desktop-stopped') }
            Mock Start-CvsTunnel {
                $script:starts++
                Set-Content (Join-Path (Get-CvsStateDirectory) 'desktop-stopped') 'stopped'
                [pscustomobject]@{Process=$script:process;Reused=$false;Profile=$script:profile;RuntimeDirectory=$null}
            }
            Invoke-CvsPersistentTunnel -StartRequested
            $script:starts | Should -Be 1
            Test-CvsDesktopStopRequested | Should -BeTrue
        }

        It 'does not let a duplicate activation remove another supervisors stop request' {
            New-Item -ItemType Directory -Path (Get-CvsStateDirectory) -Force | Out-Null
            $stopFile=Join-Path (Get-CvsStateDirectory) 'desktop-stopped'
            Set-Content $stopFile 'stopped'
            $lock=[IO.File]::Open((Join-Path (Get-CvsStateDirectory) 'persistent-tunnel.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try { Invoke-CvsPersistentTunnel -StartRequested } finally { $lock.Dispose() }
            Test-Path $stopFile | Should -BeTrue
            Should -Invoke Start-CvsTunnel -Times 0
        }
    }
}

Describe 'Structured private bounded tunnel logs' {
    InModuleScope CodexViaServer {
        BeforeEach {
            $env:CODEX_VIA_SERVER_HOME=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:LastTunnelSuccess=$null
        }
        AfterEach {Remove-Item Env:CODEX_VIA_SERVER_HOME -ErrorAction SilentlyContinue}
        It 'retains last success, uses fixed safe fields and refuses arbitrary diagnostic text' {
            $success=[DateTimeOffset]'2026-01-01T00:00:00Z'
            Write-CvsTunnelEvent -State Healthy -Code healthy -LastSuccess $success -HttpStatus 204
            Write-CvsTunnelEvent -State Backoff -Code restart_backoff -Reason transport_stalled -ReconnectAttempt 1 -BackoffSec 5
            $statusJson=Get-Content (Join-Path (Get-CvsStateDirectory) 'tunnel-status.json') -Raw
            $entry=$statusJson | ConvertFrom-Json
            ([DateTimeOffset]$entry.LastSuccessUtc).ToUniversalTime() | Should -Be $success
            $entry.RecoveryReason | Should -Be 'transport_stalled'
            $statusJson | Should -Match '"TimestampLocal":"[^"\r\n]+[+-]\d{2}:\d{2}"'
            {Write-CvsTunnelEvent -State Backoff -Code 'secret-content'} | Should -Throw
            $raw=Get-Content (Join-Path (Get-CvsStateDirectory) 'persistent-tunnel.log') -Raw
            $raw | Should -Not -Match 'Authorization|PRIVATE KEY|SHA256:|secret-content|https?://'
            if($IsWindows){
                $acl=Get-Acl (Join-Path (Get-CvsStateDirectory) 'tunnel-status.json')
                $acl.AreAccessRulesProtected | Should -BeTrue
                @($acl.Access).Count | Should -Be 1
            }
        }
        It 'keeps only the active log plus one size-limited rotation' {
            Write-CvsTunnelEvent -State Healthy -Code healthy
            $path=Join-Path (Get-CvsStateDirectory) 'persistent-tunnel.log'
            Set-Content -LiteralPath $path -Value ('x' * (1MB+1))
            Write-CvsTunnelEvent -State Suspect -Code gateway_timeout
            Test-Path "${path}.1" | Should -BeTrue
            (Get-Item $path).Length | Should -BeLessThan 4096
            @(Get-ChildItem (Get-CvsStateDirectory) -Filter 'persistent-tunnel.log*').Count | Should -Be 2
        }
    }
}

Describe 'Recovery process identity and reused ownership boundaries' {
    InModuleScope CodexViaServer {
        BeforeEach {
            $script:profile=[pscustomobject]@{client=@{local_port=18317}}
            # A real Process object is needed by Stop-Process's parameter type;
            # the actual stop operation is always mocked.
            $script:original=[Diagnostics.Process]::GetCurrentProcess()
            Mock Get-Process {$script:original}
            Mock Get-CimInstance {[pscustomobject]@{ExecutablePath='C:\Windows\System32\OpenSSH\ssh.exe';CommandLine='fictional fixture'}}
            Mock Test-CvsManagedSshCommandLine {$true}
            Mock Get-CvsPortListeners {[pscustomobject]@{OwningProcess=$script:original.Id}}
            Mock Stop-Process {}
        }
        It 'revalidates ownership and birth time before stopping exactly one process' {
            Stop-CvsManagedProcess -Profile $script:profile -Process $script:original | Should -BeTrue
            Should -Invoke Stop-Process -Times 1 -ParameterFilter {$InputObject.Id -eq $script:original.Id -and $Force -and -not $Name}
        }
        It 'refuses a reused PID' {
            Mock Get-Process {[pscustomobject]@{Id=42;HasExited=$false;StartTime=[datetime]'2026-01-02T00:00:00Z'}}
            Stop-CvsManagedProcess -Profile $script:profile -Process $script:original | Should -BeFalse
            Should -Invoke Stop-Process -Times 0
        }
        It 'refuses a different SSH contract on the same PID' {
            Mock Test-CvsManagedSshCommandLine {$false}
            Stop-CvsManagedProcess -Profile $script:profile -Process $script:original | Should -BeFalse
            Should -Invoke Stop-Process -Times 0
        }
        It 'refuses an unrelated port owner' {
            Mock Get-CvsPortListeners {[pscustomobject]@{OwningProcess=999}}
            Stop-CvsManagedProcess -Profile $script:profile -Process $script:original | Should -BeFalse
            Should -Invoke Stop-Process -Times 0
        }
        It 'leaves reused tunnels alive for ordinary CLI cleanup' {
            Stop-CvsTunnel -Tunnel ([pscustomobject]@{Process=$null;ManagedProcess=$script:original;RuntimeDirectory=$null;Profile=$script:profile;Reused=$true})
            Should -Invoke Stop-Process -Times 0
        }
        It 'cleans a strictly owned reused tunnel when the supervisor requests recovery' {
            Stop-CvsTunnel -Tunnel ([pscustomobject]@{Process=$null;ManagedProcess=$script:original;RuntimeDirectory=$null;Profile=$script:profile;Reused=$true}) -IncludeReused
            Should -Invoke Stop-Process -Times 1
        }
        It 'refuses recursive cleanup outside an exact generated temporary directory' {
            {Remove-CvsRuntimeDirectory -Path $TestDrive} | Should -Throw '*unsafe_runtime_directory*'
        }
    }
}

Describe 'Read-only desktop diagnostic independent of Codex CLI' {
    InModuleScope CodexViaServer {
        BeforeEach {
            $env:CODEX_VIA_SERVER_HOME=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Mock Get-CvsConnectionProfile {[pscustomobject]@{client=@{local_port=18317}}}
            Mock Get-ScheduledTask {[pscustomobject]@{State='Running'}}
            Mock Get-CvsManagedTunnelProcess {[pscustomobject]@{Id=42}}
            Mock Test-CvsGatewayHealth {[pscustomobject]@{Success=$true;Code='healthy';DurationMs=2}}
            Mock Get-CvsExecutable {throw 'codex.exe not installed'}
            Mock Test-CvsGatewayModels {$false}
            Mock Start-ScheduledTask {}
            Mock Stop-Process {}
            Mock Write-CvsTunnelEvent {}
        }
        AfterEach {Remove-Item Env:CODEX_VIA_SERVER_HOME -ErrorAction SilentlyContinue}
        It 'distinguishes healthy tunnel from failed upstream functionality without restarting' {
            $result=Get-CvsDesktopStatus -CheckAPI
            $result.TunnelHealth | Should -Be 'healthy'
            $result.UpstreamAPI | Should -Be 'models_unavailable'
            Should -Invoke Start-ScheduledTask -Times 0
            Should -Invoke Stop-Process -Times 0
            Should -Invoke Get-CvsExecutable -Times 0
            Should -Invoke Write-CvsTunnelEvent -Times 0
            Test-Path $env:CODEX_VIA_SERVER_HOME | Should -BeFalse
        }
        It 'does not check upstream API in ordinary status' {
            (Get-CvsDesktopStatus).UpstreamAPI | Should -Be 'not_checked'
            Should -Invoke Test-CvsGatewayModels -Times 0
        }
        It 'uses only a recent healthy supervisor result while another probe is busy' {
            $now=[DateTimeOffset]::UtcNow
            Mock Get-CvsManagedTunnelProcess {[pscustomobject]@{Id=42;StartTime=[datetime]::UtcNow.AddMinutes(-1)}}
            Mock Test-CvsGatewayHealth {[pscustomobject]@{Success=$false;Code='health_probe_busy';DurationMs=0}}
            New-Item -ItemType Directory -Path (Get-CvsStateDirectory) -Force | Out-Null
            $path=Join-Path (Get-CvsStateDirectory) 'tunnel-status.json'
            @{State='Healthy';ProcessId=42;LastSuccessUtc=$now.AddSeconds(-2).ToString('o');DurationMs=800} | ConvertTo-Json | Set-Content $path
            $before=(Get-FileHash $path).Hash
            $r=Get-CvsDesktopStatus
            $r.Status | Should -Be 'pass'
            $r.HealthSource | Should -Be 'recent_supervisor_probe'
            (Get-FileHash $path).Hash | Should -Be $before
        }
        It 'does not turn stale or reused-PID success into a healthy observation' {
            Mock Get-CvsManagedTunnelProcess {[pscustomobject]@{Id=42;StartTime=[datetime]::UtcNow}}
            Mock Test-CvsGatewayHealth {[pscustomobject]@{Success=$false;Code='health_probe_busy';DurationMs=0}}
            New-Item -ItemType Directory -Path (Get-CvsStateDirectory) -Force | Out-Null
            @{State='Healthy';ProcessId=42;LastSuccessUtc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o');DurationMs=800} | ConvertTo-Json | Set-Content (Join-Path (Get-CvsStateDirectory) 'tunnel-status.json')
            $r=Get-CvsDesktopStatus
            $r.Status | Should -Be 'checking'
            $r.TunnelHealth | Should -Be 'health_probe_busy'
        }
    }
}

Describe 'Real loopback HTTP stall with the production supervisor' {
    InModuleScope CodexViaServer {
        It 'keeps forwarding when only healthz hangs and real models HTTP still works' {
            $savedRoot=$env:CODEX_VIA_SERVER_HOME
            $env:CODEX_VIA_SERVER_HOME=Join-Path $TestDrive 'health-endpoint-only'
            $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
            $listener.Start()
            $state=[hashtable]::Synchronized(@{Stop=$false;Models=0})
            $port=$listener.LocalEndpoint.Port
            $job=Start-ThreadJob -ArgumentList $listener,$state -ScriptBlock {
                param($server,$signal)
                $pending=[Collections.Generic.List[Net.Sockets.TcpClient]]::new()
                try {
                    while(-not $signal.Stop){
                        if(-not $server.Pending()){Start-Sleep -Milliseconds 10;continue}
                        $client=$server.AcceptTcpClient(); $pending.Add($client)
                        $client.ReceiveTimeout=2000; $stream=$client.GetStream(); $buffer=[byte[]]::new(4096)
                        $count=$stream.Read($buffer,0,$buffer.Length)
                        $request=[Text.Encoding]::ASCII.GetString($buffer,0,$count)
                        if($request.StartsWith('GET /v1/models ')){
                            $body='{"data":[]}'
                            $reply=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body")
                            $stream.Write($reply,0,$reply.Length);$stream.Flush();$client.Dispose();$signal.Models++
                        }
                    }
                } finally {foreach($client in $pending){$client.Dispose()}}
            }
            try {
                $script:apiSignal=$state
                $script:apiProcess=[pscustomobject]@{Id=4243;HasExited=$false}
                Mock Get-CvsManagedTunnelProcess {$script:apiProcess}
                Mock Test-CvsDesktopStopRequested {$script:apiSignal.Models -gt 0}
                Mock Write-CvsTunnelEvent {}
                $policy=Get-CvsTunnelPolicy
                $policy.HealthTimeoutSec=1; $policy.HealthIntervalSec=0.1
                $policy.ActiveSessionGraceSec=1; $policy.MinUnhealthyDurationSec=1
                $tunnel=[pscustomobject]@{Reused=$true;ManagedProcess=$script:apiProcess;Profile=@{client=@{local_port=$port}}}
                Invoke-CvsTunnelMonitor -Tunnel $tunnel -Policy $policy | Should -Be 'stopped'
                $state.Models | Should -Be 1
                Should -Invoke Write-CvsTunnelEvent -Times 1 -ParameterFilter {$Code -eq 'gateway_responsive'}
                Should -Invoke Write-CvsTunnelEvent -Times 0 -ParameterFilter {$Code -eq 'transport_stalled'}
            } finally {
                $state.Stop=$true;$listener.Stop()
                $job | Wait-Job -Timeout 5 | Out-Null
                $job | Stop-Job -ErrorAction SilentlyContinue
                $job | Remove-Job -Force -ErrorAction SilentlyContinue
                if($null -eq $savedRoot){Remove-Item Env:CODEX_VIA_SERVER_HOME -ErrorAction SilentlyContinue}else{$env:CODEX_VIA_SERVER_HOME=$savedRoot}
            }
        }

        It 'recovers accepted TCP connections that return zero HTTP bytes without any external service' {
            $savedRoot=$env:CODEX_VIA_SERVER_HOME
            $env:CODEX_VIA_SERVER_HOME=Join-Path $TestDrive 'http-stall'
            $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
            $listener.Start()
            $script:fakeState=[hashtable]::Synchronized(@{Stop=$false;Ready=$false;Mode='healthy';Requests=0;AutoStall=$true;AfterRecovery=0})
            $script:fakeProfile=[pscustomobject]@{client=@{local_port=$listener.LocalEndpoint.Port}}
            $script:fakeStarts=0; $script:fakeEvents=@()
            $job=Start-ThreadJob -ArgumentList $listener,$script:fakeState -ScriptBlock {
                param($server,$state)
                $pending=[Collections.Generic.List[Net.Sockets.TcpClient]]::new()
                $state.Ready=$true
                try {
                    while(-not $state.Stop){
                        if(-not $server.Pending()){Start-Sleep -Milliseconds 10;continue}
                        $client=$server.AcceptTcpClient(); $pending.Add($client)
                        $client.ReceiveTimeout=2000
                        $stream=$client.GetStream(); $buffer=[byte[]]::new(4096)
                        [void]$stream.Read($buffer,0,$buffer.Length)
                        $state.Requests++
                        if($state.Mode -eq 'stalled'){continue}
                        # Delays representative of a healthy relayed link are
                        # tolerated; no model list or external account is used.
                        Start-Sleep -Milliseconds 80
                        $reply=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 204 No Content`r`nConnection: close`r`n`r`n")
                        $stream.Write($reply,0,$reply.Length);$stream.Flush();$client.Dispose()
                        if($state.AutoStall){$state.AutoStall=$false;$state.Mode='stalled'}else{$state.AfterRecovery++}
                    }
                } finally {foreach($client in $pending){$client.Dispose()}}
            }
            try {
                $ready=[Diagnostics.Stopwatch]::StartNew()
                while(-not $script:fakeState.Ready -and $ready.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 20}
                $script:fakeState.Ready | Should -BeTrue
                $script:httpPolicy=Get-CvsTunnelPolicy
                $script:httpPolicy.HealthTimeoutSec=1; $script:httpPolicy.HealthIntervalSec=1
                $script:httpPolicy.ActiveSessionGraceSec=3; $script:httpPolicy.MinUnhealthyDurationSec=3
                $script:httpPolicy.ReconnectBackoffSec=@(1); $script:httpPolicy.RestartCooldownSec=1
                $script:fakeProcess=[pscustomobject]@{Id=4242;HasExited=$false}
                Mock Get-CvsTunnelPolicy {$script:httpPolicy}
                Mock Get-CvsManagedTunnelProcess {$script:fakeProcess}
                Mock Test-CvsTunnelHasClients {$false}
                Mock Test-CvsReplacementTunnel {$true}
                Mock Test-CvsDesktopStopRequested {$script:fakeState.AfterRecovery -ge 1}
                Mock Start-CvsTunnel {
                    $script:fakeStarts++
                    [pscustomobject]@{Process=$script:fakeProcess;ManagedProcess=$null;Reused=$false;Profile=$script:fakeProfile;RuntimeDirectory=$null}
                }
                Mock Stop-CvsTunnel {$script:fakeState.Mode='healthy'}
                Mock Wait-CvsLocalPortReleased {$true}
                Mock Write-CvsTunnelEvent {param($State,$Code);$script:fakeEvents+=@{State=$State;Code=$Code}}
                Invoke-CvsPersistentTunnel
                $script:fakeStarts | Should -Be 2
                @($script:fakeEvents | Where-Object Code -eq 'gateway_timeout').Count | Should -BeGreaterOrEqual 3
                @($script:fakeEvents | Where-Object Code -eq 'transport_stalled').Count | Should -Be 1
                @($script:fakeEvents | Where-Object Code -eq 'recovered').Count | Should -Be 1
                Should -Invoke Stop-CvsTunnel -Times 2 -ParameterFilter {$IncludeReused}
            } finally {
                $script:fakeState.Stop=$true;$listener.Stop()
                $job | Wait-Job -Timeout 5 | Out-Null
                $job | Stop-Job -ErrorAction SilentlyContinue
                $job | Remove-Job -Force -ErrorAction SilentlyContinue
                if($null -eq $savedRoot){Remove-Item Env:CODEX_VIA_SERVER_HOME -ErrorAction SilentlyContinue}else{$env:CODEX_VIA_SERVER_HOME=$savedRoot}
            }
        }
    }
}

Describe 'Replacement verification and conservative client detection' {
    InModuleScope CodexViaServer {
        BeforeEach {
            $script:replacementProfile=[pscustomobject]@{client=@{local_port=18317};server=@{host='example.invalid';ssh_port=22};gateway=@{remote_port=18319}}
            $script:replacementPolicy=Get-CvsTunnelPolicy
            Mock Test-CvsDesktopStopRequested {$false}
            Mock Start-CvsTunnel {[pscustomobject]@{Process=[pscustomobject]@{Id=77}}}
            Mock Stop-CvsTunnel {}
        }
        It 'verifies another loopback port without changing the approved destination' {
            Test-CvsReplacementTunnel -Profile $script:replacementProfile -Policy $script:replacementPolicy | Should -BeTrue
            $script:replacementProfile.client.local_port | Should -Be 18317
            $script:replacementPolicy.StartupBudgetSec | Should -Be 30
            Should -Invoke Start-CvsTunnel -Times 1 -ParameterFilter {
                $VerifyModels -and -not $Persistent -and $Profile.client.local_port -ne 18317 -and
                $Profile.server.host -eq 'example.invalid' -and $Profile.gateway.remote_port -eq 18319 -and $Policy.StartupBudgetSec -eq 45
            }
            Should -Invoke Stop-CvsTunnel -Times 1 -ParameterFilter {$IncludeReused}
        }
        It 'fails closed on candidate creation or cleanup failure' -TestCases @(@{Stage='create'},@{Stage='cleanup'}) {
            param($Stage)
            if($Stage -eq 'create'){Mock Start-CvsTunnel {throw 'private address must not leak'}}else{Mock Stop-CvsTunnel {throw 'cleanup_failed'}}
            Test-CvsReplacementTunnel -Profile $script:replacementProfile -Policy $script:replacementPolicy | Should -BeFalse
        }
        It 'does not create candidates after a manual stop' {
            Mock Test-CvsDesktopStopRequested {$true}
            Test-CvsReplacementTunnel -Profile $script:replacementProfile -Policy $script:replacementPolicy | Should -BeFalse
            Should -Invoke Start-CvsTunnel -Times 0
        }
        It 'protects only established clients of the managed loopback port' {
            Mock Get-NetTCPConnection { @(
                [pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=18317;OwningProcess=42;State='Established'},
                [pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=18317;OwningProcess=99;State='Established'}
            ) }
            Test-CvsTunnelHasClients -Port 18317 -OwnerProcessId 42 | Should -BeTrue
            Test-CvsTunnelHasClients -Port 18318 -OwnerProcessId 42 | Should -BeFalse
            Test-CvsTunnelHasClients -Port 18317 -OwnerProcessId 43 | Should -BeFalse
        }
        It 'preserves the old tunnel when TCP inspection fails' {
            Mock Get-NetTCPConnection {throw 'inspection_failed'}
            Test-CvsTunnelHasClients -Port 18317 -OwnerProcessId 42 | Should -BeTrue
        }
    }
}
