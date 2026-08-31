$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$Version = (Get-Content (Join-Path $RepositoryRoot "VERSION") -Raw).Trim()
$Package = Get-Content (Join-Path $RepositoryRoot "package.json") -Raw | ConvertFrom-Json
$Compatibility = Get-Content (Join-Path $RepositoryRoot "compatibility.json") -Raw | ConvertFrom-Json
$RequiredSchemas = @(
    "enrollment-request.schema.json",
    "connection-profile.schema.json",
    "compatibility.schema.json"
)

if ($Package.version -ne $Version) {
    throw "package.json version does not match VERSION"
}

if ($Compatibility.project_version -ne $Version) {
    throw "compatibility.json project_version does not match VERSION"
}

if ($Compatibility.connection_profile_schema_versions -notcontains 1) {
    throw "connection profile schema version 1 is not supported"
}

foreach ($SchemaName in $RequiredSchemas) {
    $SchemaPath = Join-Path $RepositoryRoot "schemas/$SchemaName"

    if (-not (Test-Path $SchemaPath -PathType Leaf)) {
        throw "missing schema: $SchemaName"
    }

    $null = Get-Content $SchemaPath -Raw | ConvertFrom-Json
}

Write-Output "PASS: Windows repository contract checks"
