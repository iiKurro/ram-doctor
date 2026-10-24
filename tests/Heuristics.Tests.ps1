#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Unit tests for the pure helper functions of the scan engine. The script is never executed: the functions are lifted
# out with the PowerShell parser (AST) and defined in the test scope, so there is no scan, no admin, no side effect.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $script:EngineFile = Join-Path (Get-RepoRoot) 'src\RAM-Doctor.ps1'
    $names = 'Test-RandomName', 'Test-OneEdit', 'Get-ExePathFromCommand', 'Resolve-ExePath', 'Get-PathZone'
    $script:Found = Get-FunctionSource -Path $script:EngineFile -Name $names
    $script:HaveAll = ($script:Found.Count -eq $names.Count)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $names = 'Test-RandomName', 'Test-OneEdit', 'Get-ExePathFromCommand', 'Resolve-ExePath', 'Get-PathZone'
    $src = Get-FunctionSource -Path (Join-Path (Get-RepoRoot) 'src\RAM-Doctor.ps1') -Name $names
    foreach ($n in $names) { if ($src.ContainsKey($n)) { . ([scriptblock]::Create($src[$n])) } }
    # script-level variables the helpers read (set at the top of the engine script)
    $WinDir = $env:SystemRoot.TrimEnd('\')
    $WinDirL = $WinDir.ToLowerInvariant()
}

Describe 'Engine helper functions' -Skip:(-not $script:HaveAll) {

    Context 'Test-RandomName (spots machine-generated file names)' {
        It 'flags "<Name>"' -ForEach @(
            @{ Name = 'xk3v9qzt.exe' }
            @{ Name = 'a1b2c3d4e5f6.exe' }
            @{ Name = 'qz8wm1rt.exe' }
        ) { Test-RandomName $Name | Should -BeTrue }

        It 'leaves "<Name>" alone' -ForEach @(
            @{ Name = 'chrome.exe' }
            @{ Name = 'wingset.exe' }
            @{ Name = 'steamwebhelper.exe' }
            @{ Name = 'notepad++.exe' }
            @{ Name = 'abc.exe' }
            @{ Name = 'Discord.exe' }
        ) { Test-RandomName $Name | Should -BeFalse }
    }

    Context 'Test-OneEdit (look-alike detection for system process names)' {
        It '"<A>" vs "<B>" is a single edit' -ForEach @(
            @{ A = 'svchosts'; B = 'svchost' }
            @{ A = 'lsas'; B = 'lsass' }
            @{ A = 'expl0rer'; B = 'explorer' }
            @{ A = 'svhost'; B = 'svchost' }
        ) { Test-OneEdit $A $B | Should -BeTrue }

        It '"<A>" vs "<B>" is not a look-alike' -ForEach @(
            @{ A = 'svchost'; B = 'svchost' }
            @{ A = 'lsass'; B = 'csrss' }
            @{ A = 'cmd'; B = 'powershell' }
            @{ A = 'explorer'; B = 'explorerer2' }
        ) { Test-OneEdit $A $B | Should -BeFalse }
    }

    Context 'Get-ExePathFromCommand (service / autorun command line -> executable path)' {
        It 'takes a quoted path with spaces' {
            Get-ExePathFromCommand '"C:\Program Files\Example App\app.exe" -k run' | Should -Be 'C:\Program Files\Example App\app.exe'
        }
        It 'takes an unquoted path with spaces up to the extension' {
            Get-ExePathFromCommand 'C:\Program Files\Example App\app.exe -k run' | Should -Be 'C:\Program Files\Example App\app.exe'
        }
        It 'expands environment variables' {
            Get-ExePathFromCommand '%SystemRoot%\system32\svchost.exe -k netsvcs' | Should -Be (Join-Path $env:SystemRoot 'system32\svchost.exe')
        }
        It 'understands the NT prefix used by driver entries' {
            Get-ExePathFromCommand '\??\C:\Windows\system32\drivers\example.sys' | Should -Be 'C:\Windows\system32\drivers\example.sys'
        }
        It 'understands \SystemRoot\ driver paths' {
            Get-ExePathFromCommand '\SystemRoot\System32\drivers\example.sys' | Should -Be (Join-Path $env:SystemRoot 'System32\drivers\example.sys')
        }
        It 'returns an empty string for an empty command' {
            Get-ExePathFromCommand '' | Should -Be ''
        }
    }

    Context 'Get-PathZone (where does this file live?)' {
        It '"<Path>" is in zone <Zone>' -ForEach @(
            @{ Path = 'C:\Windows\System32\cmd.exe'; Zone = 'Windows' }
            @{ Path = 'C:\Windows\Temp\x.exe'; Zone = 'Temp' }
            @{ Path = 'C:\Users\Example\AppData\Local\Temp\x.exe'; Zone = 'Temp' }
            @{ Path = 'C:\Users\Public\x.exe'; Zone = 'Public' }
            @{ Path = 'C:\Users\Example\Downloads\x.exe'; Zone = 'Downloads' }
            @{ Path = 'C:\Users\Example\AppData\Local\Programs\App\a.exe'; Zone = 'UserPrograms' }
            @{ Path = 'C:\Users\Example\AppData\Roaming\x.exe'; Zone = 'AppData' }
            @{ Path = 'C:\ProgramData\Vendor\a.exe'; Zone = 'ProgramData' }
            @{ Path = 'C:\Program Files\Vendor\a.exe'; Zone = 'ProgramFiles' }
            @{ Path = 'D:\tools\a.exe'; Zone = 'Other' }
            @{ Path = ''; Zone = 'Unknown' }
        ) { Get-PathZone $Path | Should -Be $Zone }
    }
}
