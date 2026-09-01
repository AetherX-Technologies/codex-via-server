[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "CodexViaServer.psm1") -Force
$RemainingArguments = @($RemainingArguments | Where-Object { $null -ne $_ })

switch ($Command) {
    "setup" {
        $deviceIdIndex = [Array]::IndexOf($RemainingArguments, "--device-id")
        $outputIndex = [Array]::IndexOf($RemainingArguments, "--output")
        if ($deviceIdIndex -lt 0 -or $outputIndex -lt 0) { throw "setup requires --device-id and --output" }
        Initialize-CvsDevice -DeviceId $RemainingArguments[$deviceIdIndex + 1] -OutputPath $RemainingArguments[$outputIndex + 1]
    }
    "enroll" {
        if ($RemainingArguments.Count -ne 1) { throw "enroll requires one profile path" }
        Import-CvsConnectionProfile -Path $RemainingArguments[0]
    }
    "doctor" {
        $doctorArguments = @($RemainingArguments)
        $live = $doctorArguments -contains "--live"
        $yes = $doctorArguments -contains "--yes"
        $modelIndex = [Array]::IndexOf($doctorArguments, "--model")
        $model = if ($modelIndex -ge 0) { $doctorArguments[$modelIndex + 1] } else { $null }
        Test-CvsDoctor -Live:$live -Yes:$yes -Model $model
    }
    "desktop-install" {
        if (@($RemainingArguments).Count -ne 0) { throw "desktop-install does not accept arguments" }
        Install-CvsDesktop
    }
    "desktop-start" {
        if (@($RemainingArguments).Count -ne 0) { throw "desktop-start does not accept arguments" }
        Start-CvsDesktop
    }
    "desktop-status" {
        if (@($RemainingArguments).Count -ne 0) { throw "desktop-status does not accept arguments" }
        Get-CvsDesktopStatus
    }
    "desktop-restart" {
        if (@($RemainingArguments).Count -ne 0) { throw "desktop-restart does not accept arguments" }
        Restart-CvsDesktop
    }
    "desktop-stop" {
        if (@($RemainingArguments).Count -ne 0) { throw "desktop-stop does not accept arguments" }
        Stop-CvsDesktop
    }
    "desktop-uninstall" {
        if (@($RemainingArguments).Count -ne 0) { throw "desktop-uninstall does not accept arguments" }
        Uninstall-CvsDesktop
    }
    "update" {
        Update-CvsClient -CheckOnly:($RemainingArguments -contains "--check-only") -Force:($RemainingArguments -contains "--force")
    }
    "uninstall" {
        Uninstall-CvsClient -RemoveDeviceKey:($RemainingArguments -contains "--remove-device-key") -Yes:($RemainingArguments -contains "--yes")
    }
    default {
        $arguments = @()
        if ($Command) { $arguments += $Command }
        if ($RemainingArguments) { $arguments += $RemainingArguments }
        exit (Invoke-CvsCodex -Arguments $arguments)
    }
}
