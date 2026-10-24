#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Integration tests for src\RAM-Doctor-Actions.ps1 - the only script that changes anything.
# Everything happens inside a private temp folder on a harmless text file; no process is stopped, no service touched,
# no admin needed (-AllowNonAdmin skips the elevation guard and the restore point).

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $script:Root = Get-RepoRoot
    $script:Actions = Join-Path $script:Root 'src\RAM-Doctor-Actions.ps1'
    $script:Work = New-TempDirectory 'ramdoc-actions'

    function New-Case {
        # a victim file + a plan that points at it + a private quarantine store
        param([string]$Name, [string]$HostName = $env:COMPUTERNAME, [string]$ShaOverride = '', [bool]$Protected = $false)
        $dir = Join-Path $script:Work $Name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $victim = Join-Path $dir 'qz8wm1rt-fixture.exe'
        [IO.File]::WriteAllText($victim, 'RAM Doctor CI fixture. Plain text, not an executable.', [Text.Encoding]::ASCII)
        $sha = (Get-FileHash -LiteralPath $victim -Algorithm SHA256).Hash
        if ($ShaOverride) { $sha = $ShaOverride }
        $plan = New-SyntheticPlan -HostName $HostName -SuspectPath $victim -Sha256 $sha -Protected $Protected
        $planFile = Join-Path $dir 'plan.json'
        Write-PlanFile -Plan $plan -Path $planFile
        return [pscustomobject]@{ Dir = $dir; Victim = $victim; Sha = (Get-FileHash -LiteralPath $victim -Algorithm SHA256).Hash; Plan = $planFile; Store = (Join-Path $dir 'store') }
    }

    function Invoke-Actions {
        param($Case, [string[]]$More)
        $args2 = @('-StoreDir', $Case.Store, '-AllowNonAdmin', '-Yes', '-NoRestorePoint') + $More
        return (Invoke-ChildPowerShell -File $script:Actions -ArgumentList $args2 -TimeoutSec 120)
    }

    function Get-Quarantined($Case) { @(Get-ChildItem -LiteralPath $Case.Store -Recurse -Filter '*.quar' -File -ErrorAction SilentlyContinue) }
    function Get-Manifest($Case) {
        $m = Get-ChildItem -LiteralPath $Case.Store -Recurse -Filter 'manifest.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($m) { return (Get-Content -LiteralPath $m.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) }
    }
}

AfterAll {
    if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Actions: quarantine -> restore -> purge lifecycle' -Tag 'Integration' {
    BeforeAll {
        $script:Case = New-Case 'lifecycle'
    }

    It 'the synthetic plan used here satisfies the plan contract' {
        Test-RamPlan -Plan (Get-Content -LiteralPath $script:Case.Plan -Raw -Encoding UTF8 | ConvertFrom-Json) | Should -BeNullOrEmpty
    }

    It 'quarantine moves the file aside (renamed *.quar), records it in a manifest, and deletes nothing' {
        $r = Invoke-Actions $script:Case @('-Mode', 'Quarantine', '-Plan', $script:Case.Plan, '-Select', '1')
        $r.TimedOut | Should -BeFalse
        $r.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:Case.Victim | Should -BeFalse
        $q = Get-Quarantined $script:Case
        $q.Count | Should -Be 1
        (Get-FileHash -LiteralPath $q[0].FullName -Algorithm SHA256).Hash | Should -Be $script:Case.Sha
        $m = Get-Manifest $script:Case
        $m.entries.Count | Should -Be 1
        (@($m.entries[0].ops | Where-Object { $_.type -eq 'QuarantineFile' -and $_.status -eq 'done' })).Count | Should -Be 1
        $r.StdOut | Should -Match 'Done\. Quarantine batch'
    }

    It 'restore puts the file back byte-identical and marks the batch as restored' {
        $r = Invoke-Actions $script:Case @('-Mode', 'Restore')
        $r.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:Case.Victim | Should -BeTrue
        (Get-FileHash -LiteralPath $script:Case.Victim -Algorithm SHA256).Hash | Should -Be $script:Case.Sha
        (Get-Quarantined $script:Case).Count | Should -Be 0
        $r.StdOut | Should -Match 'Restore finished'
        (Get-Manifest $script:Case).PSObject.Properties['restoredAt'] | Should -Not -BeNullOrEmpty   # the window reads this to disable the button
    }

    It 'restoring the same batch twice is a harmless no-op' {
        $r = Invoke-Actions $script:Case @('-Mode', 'Restore')
        $r.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:Case.Victim | Should -BeTrue
        $r.StdOut | Should -Match 'already restored'
    }

    It 'purge deletes the quarantined file for good and marks the batch as purged' {
        $q1 = Invoke-Actions $script:Case @('-Mode', 'Quarantine', '-Plan', $script:Case.Plan, '-Select', '1')
        $q1.ExitCode | Should -Be 0
        (Get-Quarantined $script:Case).Count | Should -Be 1
        $r = Invoke-Actions $script:Case @('-Mode', 'Purge', '-OlderThanDays', '0')
        $r.ExitCode | Should -Be 0
        (Get-Quarantined $script:Case).Count | Should -Be 0
        Test-Path -LiteralPath $script:Case.Victim | Should -BeFalse
        $purged = @(Get-ChildItem -LiteralPath $script:Case.Store -Recurse -Filter 'manifest.json' -File | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) } | Where-Object { $_.PSObject.Properties['purgedAt'] })
        $purged.Count | Should -BeGreaterThan 0       # the window reads this too
    }

    It '"List" shows the batches without changing anything' {
        $r = Invoke-Actions $script:Case @('-Mode', 'List')
        $r.ExitCode | Should -Be 0
    }
}

Describe 'Actions: safety invariants' -Tag 'Integration' {

    It 'refuses a plan that was made on another computer, and touches nothing' {
        $c = New-Case 'otherpc' -HostName 'SOME-OTHER-PC-0001'
        $r = Invoke-Actions $c @('-Mode', 'Quarantine', '-Plan', $c.Plan, '-Select', '1')
        $r.ExitCode | Should -Be 1
        ($r.StdOut + $r.StdErr) | Should -Match 'Refusing'
        Test-Path -LiteralPath $c.Victim | Should -BeTrue
        (Get-Quarantined $c).Count | Should -Be 0
    }

    It 'skips an item whose file changed since the scan (hash mismatch)' {
        $c = New-Case 'changed' -ShaOverride ('B' * 64)
        $r = Invoke-Actions $c @('-Mode', 'Quarantine', '-Plan', $c.Plan, '-Select', '1')
        Test-Path -LiteralPath $c.Victim | Should -BeTrue
        (Get-Quarantined $c).Count | Should -Be 0
        $r.StdOut | Should -Match 'changed since the scan'
    }

    It 'never moves a file flagged protectedFile (Windows / Microsoft files)' {
        $c = New-Case 'protected' -Protected $true
        $r = Invoke-Actions $c @('-Mode', 'Quarantine', '-Plan', $c.Plan, '-Select', '1')
        Test-Path -LiteralPath $c.Victim | Should -BeTrue
        (Get-Quarantined $c).Count | Should -Be 0
    }

    It 'ignores a selection number that is not in the plan' {
        $c = New-Case 'unknownid'
        $r = Invoke-Actions $c @('-Mode', 'Quarantine', '-Plan', $c.Plan, '-Select', '7')
        Test-Path -LiteralPath $c.Victim | Should -BeTrue
        (Get-Quarantined $c).Count | Should -Be 0
    }

    It 'only acts on the numbers passed in -Select ("1,2" is two numbers, never twelve)' {
        $c = New-Case 'selectparse'
        $plan = Get-Content -LiteralPath $c.Plan -Raw -Encoding UTF8 | ConvertFrom-Json
        $second = Join-Path $c.Dir 'second-fixture.exe'
        [IO.File]::WriteAllText($second, 'second fixture', [Text.Encoding]::ASCII)
        $s2 = New-SyntheticPlan -SuspectPath $second -Sha256 (Get-FileHash -LiteralPath $second -Algorithm SHA256).Hash
        $entry = $s2.suspects[0]; $entry.id = 2
        $plan.suspects = @($plan.suspects) + $entry
        Write-PlanFile -Plan $plan -Path $c.Plan
        $r = Invoke-Actions $c @('-Mode', 'Quarantine', '-Plan', $c.Plan, '-Select', '1,2')
        (Get-Quarantined $c).Count | Should -Be 2
        Test-Path -LiteralPath $c.Victim | Should -BeFalse
        Test-Path -LiteralPath $second | Should -BeFalse
    }
}
