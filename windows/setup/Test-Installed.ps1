[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [Parameter(Mandatory)][string]$ApprovedProfile,
    [Parameter(Mandatory)][string]$KeyDirectory,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [ValidateRange(1024,65535)][int]$LocalPort = 18329,
    [string]$Model = 'gpt-6.1-sol'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($LocalPort -eq 18319 -or (Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue)) { throw 'test_port_in_use' }
$root = Join-Path $env:LOCALAPPDATA ('CodexViaServerIntegration/' + [guid]::NewGuid().ToString('N'))
$client = Join-Path $root 'client'
$codex = Join-Path $root 'codex'
$actions = Join-Path $PackageDirectory 'setup/Actions.ps1'
$pwsh = Join-Path $PackageDirectory 'runtime/pwsh/pwsh.exe'
Import-Module (Join-Path $PackageDirectory 'client/CodexViaServer.psm1') -Force
New-Item -ItemType Directory -Path $root,$client,$codex,$EvidenceDirectory -Force | Out-Null
Set-CvsPrivateAcl $root
$checks = [Collections.Generic.List[object]]::new()
$failure = $null; $failureLine = $null; $cleaned = $false; $taskName = $null
$recoverySeconds = $null; $activationSeconds = $null
$profile = $null
$productionListeners = @(Get-NetTCPConnection -LocalPort 18319 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess)
$productionConfig = Join-Path $HOME '.codex/config.toml'
$productionHash = if (Test-Path $productionConfig) { (Get-FileHash $productionConfig).Hash } else { $null }
$proxyBefore = [Environment]::GetEnvironmentVariable('NO_PROXY','User')
$productionTask = Export-ScheduledTask -TaskName 'CodexViaServer Persistent Tunnel' -ErrorAction SilentlyContinue

function Assert-Installed([bool]$Condition, [string]$Name) {
    $checks.Add([ordered]@{ Name=$Name; Passed=$Condition; TimeUtc=[DateTimeOffset]::UtcNow.ToString('o') })
    Write-Output "$Name : $Condition"
    if (-not $Condition) { throw $Name }
}

function Invoke-Action([string]$Name) {
    $info = [Diagnostics.ProcessStartInfo]::new($pwsh)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach ($key in @($info.Environment.Keys)) {
        if ($key -like 'CODEX*' -or $key -in @('OPENAI_API_KEY','CLIPROXY_API_KEY','SERVER_CODEX_API_KEY')) { [void]$info.Environment.Remove($key) }
    }
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$actions,'-Action',$Name,'-ClientHome',$client,'-CodexHome',$codex,'-KeyDirectory',$KeyDirectory,'-ProfilePath',(Join-Path $root 'approved.connection.json'),'-Model',$Model)) { $info.ArgumentList.Add($arg) }
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$info
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(150000)) { $process.Kill($true); throw 'action_timeout' }
        $result=$stdout.GetAwaiter().GetResult() | ConvertFrom-Json
        if (-not $result.Ok -or $process.ExitCode -ne 0) { throw "action_$($Name)_$($result.Code)" }
        return $result
    } finally { $process.Dispose() }
}

function Get-TestListener {
    return ,@(Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue)
}

function Get-TestSsh {
    return ,@(Get-CimInstance Win32_Process -Filter "Name = 'ssh.exe'" | Where-Object {
        $_.ExecutablePath -eq (Join-Path $PackageDirectory 'runtime/ssh/ssh.exe') -and
        $_.CommandLine.Contains("127.0.0.1:${LocalPort}:127.0.0.1:$($profile.gateway.remote_port)")
    })
}

function Wait-TestModels([int]$Seconds = 60) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            $models=Invoke-RestMethod -Uri "http://127.0.0.1:$LocalPort/v1/models" -NoProxy -TimeoutSec 8
            if ($null -ne $models.data -and @($models.data).Count -gt 0) { return $models }
        } catch {}
        Start-Sleep -Seconds 1
    } while ($timer.Elapsed.TotalSeconds -lt $Seconds)
    throw 'models_unavailable'
}

try {
    $profile=Get-Content -LiteralPath $ApprovedProfile -Raw | ConvertFrom-Json
    $profile.client.local_port=$LocalPort
    $profile | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $root 'approved.connection.json') -Encoding utf8NoBOM
    Set-CvsPrivateAcl (Join-Path $root 'approved.connection.json')
    # Reuse this computer's approved identity by path; never copy its private key.
    Set-Content -LiteralPath (Join-Path $codex 'config.toml') -Value "model = `"$Model`"`nmodel_reasoning_effort = `"low`"" -Encoding utf8NoBOM
    $originalHash=(Get-FileHash (Join-Path $codex 'config.toml')).Hash
    $result=Invoke-Action 'Enroll'
    Assert-Installed ($result.Code -eq 'configured') 'real_enrollment_and_task_install'
    $bytes=[Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($client).ToLowerInvariant())
    $suffix=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).Substring(0,12)
    $taskName='CodexViaServer Persistent Tunnel ' + $suffix
    $task=Get-ScheduledTask -TaskName $taskName
    Assert-Installed ($task.Triggers[0].CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and $task.Settings.MultipleInstances -eq 'IgnoreNew') 'real_logon_trigger_and_single_instance_policy'
    Assert-Installed ($task.Actions[0].Arguments.Contains($client) -and $task.Actions[0].Arguments.Contains($KeyDirectory) -and $task.Actions[0].Execute -eq $pwsh) 'cold_task_has_explicit_runtime_and_directories'
    $models=Wait-TestModels
    Assert-Installed (@($models.data.id) -contains $Model) 'real_models_contains_selected_model'
    $listener=Get-TestListener
    Assert-Installed ($listener.Count -eq 1 -and $listener[0].LocalAddress -eq '127.0.0.1' -and (Get-Process -Id $listener[0].OwningProcess).ProcessName -eq 'ssh') 'real_ssh_owns_loopback_listener'
    $ssh=Get-Process -Id $listener[0].OwningProcess
    Start-ScheduledTask -TaskName $taskName
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 3
    Assert-Installed ((Get-TestListener).Count -eq 1 -and (Get-TestListener)[0].OwningProcess -eq $ssh.Id) 'installer_exit_and_repeated_start_keep_one_tunnel'
    $native=Get-CimInstance Win32_Process -Filter "ProcessId=$($ssh.Id)"
    Assert-Installed ($native.CommandLine -cmatch '(?:^|\s)-C(?:\s|$)') 'installed_ssh_uses_compression'
    Assert-Installed ($native.ExecutablePath -eq (Join-Path $PackageDirectory 'runtime/ssh/ssh.exe') -and $native.CommandLine.Contains("127.0.0.1:${LocalPort}:127.0.0.1:$($profile.gateway.remote_port)")) 'kill_target_is_only_the_test_ssh'
    $recoveryTimer=[Diagnostics.Stopwatch]::StartNew()
    Stop-Process -InputObject $ssh -Force
    $models=Wait-TestModels
    $replacement=(Get-TestListener)[0].OwningProcess
    Assert-Installed ($replacement -ne $ssh.Id) 'real_task_recovers_forced_ssh_exit'
    $recoverySeconds=[math]::Round($recoveryTimer.Elapsed.TotalSeconds,2)
    Write-Output "recovery_seconds : $recoverySeconds"
    $live=Invoke-Action 'Live'
    Assert-Installed ($live.Code -eq 'live_passed') 'bundled_official_codex_real_response'
    $stop=Invoke-Action 'Stop'
    Assert-Installed ((Get-TestListener).Count -eq 0) 'stop_releases_port'
    Start-Sleep -Seconds 7
    Assert-Installed ((Get-TestListener).Count -eq 0) 'manual_stop_does_not_auto_restart'
    $activationTimer=[Diagnostics.Stopwatch]::StartNew()
    Start-ScheduledTask -TaskName $taskName
    $models=Wait-TestModels -Seconds 60
    $activationSeconds=[math]::Round($activationTimer.Elapsed.TotalSeconds,2)
    Assert-Installed ((Get-TestListener).Count -eq 1) 'new_task_activation_resumes_after_stop'
    Write-Output "activation_seconds : $activationSeconds"
    $stop=Invoke-Action 'Stop'
    $start=Invoke-Action 'Start'; $models=Wait-TestModels
    Assert-Installed ($start.Code -eq 'started') 'start_after_stop'
    $restart=Invoke-Action 'Restart'; $models=Wait-TestModels
    Assert-Installed ($restart.Code -eq 'restarted' -and (Get-TestListener).Count -eq 1) 'restart_restores_one_working_tunnel'
    $stop=Invoke-Action 'Stop'
    Start-ScheduledTask -TaskName $taskName
    $pendingTimer=[Diagnostics.Stopwatch]::StartNew(); $pendingObserved=$false
    do {
        if ((Get-TestSsh).Count -gt 0 -and (Get-TestListener).Count -eq 0) { $pendingObserved=$true; break }
        Start-Sleep -Milliseconds 50
    } while ($pendingTimer.Elapsed.TotalSeconds -lt 35 -and (Get-TestListener).Count -eq 0)
    Assert-Installed $pendingObserved 'observed_real_ssh_before_listener_bind'
    $stop=Invoke-Action 'Stop'
    Assert-Installed ((Get-TestSsh).Count -eq 0 -and (Get-TestListener).Count -eq 0) 'stop_cleans_pending_ssh'
    Start-Sleep -Seconds 7
    Assert-Installed ((Get-TestSsh).Count -eq 0 -and (Get-TestListener).Count -eq 0) 'stopped_startup_has_no_delayed_orphan'
    $uninstall=Invoke-Action 'Uninstall'; $cleaned=$true
    Assert-Installed (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) -and (Get-TestListener).Count -eq 0) 'uninstall_removes_task_and_listener'
    Assert-Installed ((Get-FileHash (Join-Path $codex 'config.toml')).Hash -eq $originalHash) 'uninstall_restores_exact_original_config'
    Assert-Installed ([Environment]::GetEnvironmentVariable('NO_PROXY','User') -ceq $proxyBefore) 'uninstall_restores_original_user_proxy_bypass'
    $leaks=@(Get-ChildItem (Join-Path $client 'state') -File | Where-Object Extension -in @('.log','.json') | Select-String -Pattern 'PRIVATE KEY|ssh-ed25519 |SHA256:|sk-[A-Za-z0-9]{16}|Authorization|api_key' -List)
    Assert-Installed ($leaks.Count -eq 0) 'test_logs_have_no_key_identity_or_fingerprint'
} catch {
    $failureLine = $_.InvocationInfo.ScriptLineNumber
    $failure=if ($_.Exception.Message -cmatch '^[A-Za-z0-9_]+$') { $_.Exception.Message } else { 'integration_exception' }
    Write-Output "FAILED : $failure"
} finally {
    if (-not $cleaned -and (Test-Path (Join-Path $client 'config/connection-profile.json'))) {
        try { $null=Invoke-Action 'Uninstall'; $cleaned=$true } catch { $checks.Add(@{Name='cleanup';Passed=$false}) }
    }
    if ($null -ne $profile) {
        $noOrphans=(Get-TestSsh).Count -eq 0 -and (Get-TestListener).Count -eq 0
        $checks.Add(@{Name='cleanup_leaves_no_pending_or_listening_ssh';Passed=$noOrphans})
        if (-not $noOrphans) { $cleaned=$false }
    }
    $productionAfter=@(Get-NetTCPConnection -LocalPort 18319 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess)
    $configUnchanged=if ($productionHash) { (Get-FileHash $productionConfig).Hash -eq $productionHash } else { -not (Test-Path $productionConfig) }
    $productionUnchanged=($productionAfter -join ',') -eq ($productionListeners -join ',') -and $configUnchanged -and (Export-ScheduledTask -TaskName 'CodexViaServer Persistent Tunnel' -ErrorAction SilentlyContinue) -ceq $productionTask
    $checks.Add(@{Name='production_task_config_and_listener_unchanged';Passed=$productionUnchanged})
    [ordered]@{ Ok=($null -eq $failure -and $cleaned -and $productionUnchanged); Failure=$failure; FailureLine=$failureLine; Cleaned=$cleaned; Checks=@($checks); RecoverySeconds=$recoverySeconds; ActivationSeconds=$activationSeconds; TestWaitBudgetSeconds=60; PrivateTestRoot=$root; Model=$Model; NotTested=@('new_device_admin_approval','Windows_reboot','Desktop_message','Microsoft_Store_install') } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'installed-test.json') -Encoding utf8NoBOM
}
if ($failure -or -not $cleaned -or -not $productionUnchanged) { exit 1 }
