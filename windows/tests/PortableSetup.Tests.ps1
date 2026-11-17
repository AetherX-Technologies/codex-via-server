BeforeAll {
    $script:SetupRoot = (Resolve-Path (Join-Path $PSScriptRoot '../setup')).Path
    if (-not ('PortableSetupEntryPoint' -as [type])) {
        $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
        $script:AssemblyPath = Join-Path $TestDrive 'Setup.dll'
        & $compiler /nologo /target:library /platform:x64 "/out:$script:AssemblyPath" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll (Join-Path $script:SetupRoot 'Setup.cs') (Join-Path $script:SetupRoot 'AdminForm.cs')
        if ($LASTEXITCODE -ne 0) { throw 'Setup C# compilation failed' }
        $script:SetupAssembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($script:AssemblyPath))
        $script:ProgramType = $script:SetupAssembly.GetType('Program')
    }
}

Describe 'Portable Windows setup trust boundaries' {
    It 'rejects archive traversal and ambiguous Windows paths' {
        $method = $script:ProgramType.GetMethod('EntryPath', [Reflection.BindingFlags]'Static,NonPublic')
        foreach ($name in @('../escape', 'C:/escape', '/escape', 'a/../../escape', 'a\escape', 'a./escape', 'a /escape')) {
            { $method.Invoke($null, @($TestDrive, $name)) } | Should -Throw
        }
        $safe = $method.Invoke($null, @($TestDrive, 'runtime/pwsh/pwsh.exe'))
        $safe | Should -Be (Join-Path $TestDrive 'runtime/pwsh/pwsh.exe')
    }

    It 'quotes Windows process arguments without shell evaluation' {
        $method = $script:ProgramType.GetMethod('Quote', [Reflection.BindingFlags]'Static,NonPublic')
        $method.Invoke($null, @('a b\')) | Should -Be '"a b\\"'
        $method.Invoke($null, @('a"b')) | Should -Be '"a\"b"'
        $method.Invoke($null, @('')) | Should -Be '""'
    }

    It 'finds the complete runtime in a clean login environment' {
        $environmentNames = @('CODEX_VIA_SERVER_HOME', 'CODEX_HOME', 'CODEX_VIA_SERVER_INSTALL_ROOT', 'CODEX_VIA_SERVER_PWSH', 'CODEX_VIA_SERVER_CODEX', 'CODEX_VIA_SERVER_SSH', 'CODEX_VIA_SERVER_SSH_KEYGEN', 'CODEX_VIA_SERVER_SSH_KEYSCAN', 'CODEX_VIA_SERVER_TAILSCALE', 'CODEX_VIA_SERVER_KEY_DIR', 'CODEX_VIA_SERVER_CONNECTION_PROFILE', 'NO_PROXY', 'PATH', 'OPENAI_API_KEY', 'CLIPROXY_API_KEY', 'SERVER_CODEX_API_KEY')
        $saved = @{}; foreach ($name in $environmentNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            $env:CODEX_VIA_SERVER_KEY_DIR = 'unexpected-identity'
            $env:OPENAI_API_KEY = 'synthetic-inherited-value'
            . (Join-Path $script:SetupRoot 'Environment.ps1') -ClientHome (Join-Path $TestDrive 'client') -CodexHome (Join-Path $TestDrive 'codex')
            $env:CODEX_VIA_SERVER_HOME | Should -Be (Join-Path $TestDrive 'client')
            $env:CODEX_HOME | Should -Be (Join-Path $TestDrive 'codex')
            $env:CODEX_VIA_SERVER_SSH | Should -Be (Join-Path (Split-Path -Parent $script:SetupRoot) 'runtime/ssh/ssh.exe')
            $env:CODEX_VIA_SERVER_PWSH | Should -Match 'runtime.pwsh.pwsh.exe$'
            $env:CODEX_VIA_SERVER_KEY_DIR | Should -Be (Join-Path $TestDrive 'client/keys')
            $env:OPENAI_API_KEY | Should -BeNullOrEmpty
            $env:NO_PROXY.Split(',') | Should -Contain '127.0.0.1'
            $env:PATH.Split([IO.Path]::PathSeparator)[0] | Should -Be (Join-Path (Split-Path -Parent $script:SetupRoot) 'runtime/codex')
        } finally { foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') } }
    }

    It 'parses all packaged PowerShell entry points' {
        foreach ($file in Get-ChildItem $script:SetupRoot -Filter '*.ps1') {
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because $file.Name
        }
    }
}
