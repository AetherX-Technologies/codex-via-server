[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "CodexViaServer.psm1") -Force

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
        $live = $RemainingArguments -contains "--live"
        $yes = $RemainingArguments -contains "--yes"
        $modelIndex = [Array]::IndexOf($RemainingArguments, "--model")
        $model = if ($modelIndex -ge 0) { $RemainingArguments[$modelIndex + 1] } else { $null }
        Test-CvsDoctor -Live:$live -Yes:$yes -Model $model
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
