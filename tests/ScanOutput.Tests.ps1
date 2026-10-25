#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# The scan's output folder housekeeping (Remove-OldScans in src\RAM-Doctor.ps1), lifted out with the parser: the scan is
# not run. Synthetic file names only (host DESKTOP-DEMO).

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $script:HaveFn = (Get-FunctionSource -Path (Join-Path (Get-RepoRoot) 'src\RAM-Doctor.ps1') -Name 'Remove-OldScans').Count -eq 1
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $src = Get-FunctionSource -Path (Join-Path (Get-RepoRoot) 'src\RAM-Doctor.ps1') -Name 'Remove-OldScans'
    if ($src.ContainsKey('Remove-OldScans')) { . ([scriptblock]::Create($src['Remove-OldScans'])) }
    $script:Work = New-TempDirectory 'ramdoc-scanout'
    function New-Scan([string]$Dir, [string]$HostName, [string]$Stamp, [int]$AgeDays = 0) {
        foreach ($n in "Plan-$HostName-$Stamp.json", "RAMDoctor-$HostName-$Stamp.html") {
            $f = Join-Path $Dir $n
            [IO.File]::WriteAllText($f, '{}')
            if ($AgeDays) { (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddDays(-$AgeDays) }
        }
    }
    function Get-Names([string]$Dir) { @(Get-ChildItem -LiteralPath $Dir -File | ForEach-Object Name | Sort-Object) }
}

AfterAll { if ($script:Work) { Remove-TreeForce -Path $script:Work } }

Describe 'Remove-OldScans' -Skip:(-not $script:HaveFn) {
    It 'keeps the 3 newest scans of this PC and always counts the scan just written as one of them (clock behind)' {
        $d = Join-Path $script:Work 'clock'; [void][IO.Directory]::CreateDirectory($d)
        foreach ($s in '20261020-100000', '20261021-100000', '20261022-100000', '20261023-100000') { New-Scan $d 'DESKTOP-DEMO' $s }
        New-Scan $d 'DESKTOP-DEMO' '20261001-090000'          # the scan just written, by a PC whose clock is behind
        [IO.File]::WriteAllText((Join-Path $d 'Plan-DESKTOP-DEMO-20261020-100000.json.bak'), '{}')
        Remove-OldScans -Dir $d -HostName 'DESKTOP-DEMO' -CurrentStamp '20261001-090000'
        $plans = @(Get-Names $d | Where-Object { $_ -like 'Plan-*' })
        $plans | Should -Contain 'Plan-DESKTOP-DEMO-20261001-090000.json'
        $plans | Should -Contain 'Plan-DESKTOP-DEMO-20261023-100000.json'
        $plans | Should -Contain 'Plan-DESKTOP-DEMO-20261022-100000.json'
        $plans.Count | Should -Be 3
        Test-Path -LiteralPath (Join-Path $d 'RAMDoctor-DESKTOP-DEMO-20261001-090000.html') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $d 'RAMDoctor-DESKTOP-DEMO-20261020-100000.html') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $d 'Plan-DESKTOP-DEMO-20261020-100000.json.bak') | Should -BeFalse
    }

    It 'never eats the files of a similar host name, and removes other hosts only after 30 days (renamed PC)' {
        $d = Join-Path $script:Work 'hosts'; [void][IO.Directory]::CreateDirectory($d)
        foreach ($s in '20261020-100000', '20261021-100000', '20261022-100000', '20261023-100000') { New-Scan $d 'PC' $s }
        New-Scan $d 'PC-2' '20261001-100000'                          # recent scan of another PC: kept
        New-Scan $d 'OLD-NAME' '20250101-100000' -AgeDays 90          # the PC was renamed long ago: removed
        [IO.File]::WriteAllText((Join-Path $d 'notes.txt'), 'not ours')
        Remove-OldScans -Dir $d -HostName 'PC' -CurrentStamp '20261023-100000'
        $n = Get-Names $d
        @($n | Where-Object { $_ -match '^Plan-PC-2-' }).Count | Should -Be 1
        @($n | Where-Object { $_ -like '*OLD-NAME*' }).Count | Should -Be 0
        @($n | Where-Object { $_ -match '^Plan-PC-\d{8}-' }).Count | Should -Be 3
        $n | Should -Contain 'notes.txt'
    }
}
