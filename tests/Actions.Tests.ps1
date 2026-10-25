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

Describe 'Actions: crash-safe undo record and honest results' -Tag 'Integration' {
    BeforeAll {
        . (Join-Path $script:Root 'src\lib\Store.ps1')
        function Get-BatchDir($Case) { @(Get-ChildItem -LiteralPath (Join-Path $Case.Store 'Quarantine') -Directory | Sort-Object Name)[-1].FullName }
        function Get-ResultLine($Run) { @(($Run.StdOut -split "`r?`n") | Where-Object { $_ -like 'RESULT:*' } | Select-Object -Last 1) -join '' }
        function Get-ListJson($Case) {
            $r = Invoke-Actions $Case @('-Mode', 'List')
            @(($r.StdOut -split "`r?`n") | Where-Object { $_ -like 'BATCH_JSON: *' } | ForEach-Object { $_.Substring(12) | ConvertFrom-Json })
        }
        function Set-ManifestText($Case, [string]$Text) { [IO.File]::WriteAllText((Join-Path (Get-BatchDir $Case) 'manifest.json'), $Text, (New-Object Text.UTF8Encoding($true))) }
        function Edit-Manifest($Case, [scriptblock]$Change) {
            $f = Join-Path (Get-BatchDir $Case) 'manifest.json'
            $m = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            & $Change $m
            [IO.File]::WriteAllText($f, ($m | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($true)))
        }
        function New-QuarantinedCase([string]$Name) {
            $c = New-Case $Name
            $q = Invoke-Actions $c @('-Mode', 'Quarantine', '-Plan', $c.Plan, '-Select', '1')
            $q.ExitCode | Should -Be 0 -Because $q.StdOut
            return $c
        }
    }

    It 'writes the undo record before the first change and keeps the previous version as manifest.json.bak' {
        $c = New-QuarantinedCase 'writeahead'
        $dir = Get-BatchDir $c
        Test-Path -LiteralPath (Join-Path $dir 'manifest.json.bak') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dir 'manifest.json.tmp') | Should -BeFalse
        $m = Get-Manifest $c
        $m.schema | Should -Be 1
        $m.seq | Should -Be 1
        (Get-Content -LiteralPath (Join-Path $dir 'manifest.json.bak') -Raw -Encoding UTF8 | ConvertFrom-Json).entries[0].ops[0].type | Should -Be 'QuarantineFile'
    }

    It 'a truncated manifest is recovered from manifest.json.bak and the file is restored (C1)' {
        $c = New-QuarantinedCase 'truncated'
        $f = Join-Path (Get-BatchDir $c) 'manifest.json'
        $txt = [IO.File]::ReadAllText($f)
        [IO.File]::WriteAllText($f, $txt.Substring(0, [int]($txt.Length / 2)))
        $list = Get-ListJson $c
        $list[0].state | Should -Be 'restorable'
        $r = Invoke-Actions $c @('-Mode', 'Restore')
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        Get-ResultLine $r | Should -Be 'RESULT: OK'
        Test-Path -LiteralPath $c.Victim | Should -BeTrue
        (Get-FileHash -LiteralPath $c.Victim -Algorithm SHA256).Hash | Should -Be $c.Sha
        @(Get-ChildItem -LiteralPath (Get-BatchDir $c) -Filter 'manifest.json.damaged-*').Count | Should -Be 1 -Because 'the damaged record is kept for inspection'
    }

    It 'a restore that is refused for one item says so (exit 2, PARTIAL), keeps the batch restorable, and a later run finishes it (H1)' {
        $c = New-QuarantinedCase 'partial'
        $quar = @(Get-Quarantined $c)[0].FullName
        $good = [IO.File]::ReadAllBytes($quar)
        [IO.File]::AppendAllText($quar, 'tampered')
        $r = Invoke-Actions $c @('-Mode', 'Restore')
        $r.ExitCode | Should -Be 2
        Get-ResultLine $r | Should -Be 'RESULT: PARTIAL 1'
        $r.StdOut | Should -Not -Match 'Restore finished'
        $r.StdOut | Should -Match 'Restore INCOMPLETE'
        (Get-Manifest $c).PSObject.Properties['restoredAt'] | Should -BeNullOrEmpty
        (Get-ListJson $c)[0].state | Should -Be 'restorable'
        [IO.File]::WriteAllBytes($quar, $good)
        $r2 = Invoke-Actions $c @('-Mode', 'Restore')
        $r2.ExitCode | Should -Be 0 -Because $r2.StdOut
        Test-Path -LiteralPath $c.Victim | Should -BeTrue
        (Get-Manifest $c).restoredAt | Should -Not -BeNullOrEmpty
    }

    It 'a quarantined copy that disappeared is a failure, not a success (H1)' {
        $c = New-QuarantinedCase 'missingcopy'
        [IO.File]::Delete(@(Get-Quarantined $c)[0].FullName)
        $r = Invoke-Actions $c @('-Mode', 'Restore')
        $r.ExitCode | Should -Be 2
        $r.StdOut | Should -Match 'quarantined copy is missing'
        (Get-Manifest $c).PSObject.Properties['restoredAt'] | Should -BeNullOrEmpty
    }

    It 'an unknown operation type (from a newer version) is never counted as restored (L1)' {
        $c = New-QuarantinedCase 'unknownop'
        Edit-Manifest $c { param($m) $m.entries[0].ops = @($m.entries[0].ops) + [pscustomobject]@{ type = 'FutureThing'; status = 'done' } }
        $r = Invoke-Actions $c @('-Mode', 'Restore')
        $r.ExitCode | Should -Be 2
        $r.StdOut | Should -Match "unknown operation type 'FutureThing'"
        (Get-Manifest $c).PSObject.Properties['restoredAt'] | Should -BeNullOrEmpty
    }

    It 'a step left "pending" by a crash before the move is resolved (the file is still in place)' {
        $c = New-QuarantinedCase 'pending'
        $quar = @(Get-Quarantined $c)[0].FullName
        [IO.File]::Move($quar, $c.Victim)          # as if the PC lost power right before moving the file
        Edit-Manifest $c { param($m) $m.entries[0].ops[0].status = 'pending' }
        $r = Invoke-Actions $c @('-Mode', 'Restore')
        $r.ExitCode | Should -Be 0 -Because $r.StdOut
        $r.StdOut | Should -Match 'already in its original place'
        (Get-FileHash -LiteralPath $c.Victim -Algorithm SHA256).Hash | Should -Be $c.Sha
    }

    It 'a batch whose two undo records are damaged is refused for restore, its files kept, and can still be purged' {
        $c = New-QuarantinedCase 'bothbad'
        $dir = Get-BatchDir $c
        Set-ManifestText $c '{"entries": ['
        [IO.File]::WriteAllBytes((Join-Path $dir 'manifest.json.bak'), [byte[]](0, 0, 0))
        $r = Invoke-Actions $c @('-Mode', 'Restore', '-Batch', (Split-Path $dir -Leaf))
        $r.ExitCode | Should -Be 1
        Get-ResultLine $r | Should -Be 'RESULT: FAILED damaged'
        (Get-Quarantined $c).Count | Should -Be 1
        (Get-ListJson $c)[0].state | Should -Be 'damaged'
        $p = Invoke-Actions $c @('-Mode', 'Purge', '-OlderThanDays', '0')
        $p.ExitCode | Should -Be 0 -Because $p.StdOut
        (Get-Quarantined $c).Count | Should -Be 0
        (Get-ListJson $c)[0].state | Should -Be 'purged'
        @(Get-ChildItem -LiteralPath $dir -Filter 'manifest.json*.damaged-*').Count | Should -Be 2 -Because 'damaged records are never deleted'
    }

    It 'a batch folder without any undo record (interrupted 1.0.x quarantine) is listed as orphan and can be purged' {
        $c = New-Case 'orphan'
        $fd = Join-Path $c.Store 'Quarantine\20261025-120000\files'
        [void][IO.Directory]::CreateDirectory($fd)
        [IO.File]::WriteAllText((Join-Path $fd '001_x.exe.quar'), 'orphan')
        $l = Get-ListJson $c
        $l[0].state | Should -Be 'orphan'
        $l[0].files | Should -Be 1
        Get-ResultLine (Invoke-Actions $c @('-Mode', 'Restore', '-Batch', '20261025-120000')) | Should -Be 'RESULT: FAILED orphan'
        (Invoke-Actions $c @('-Mode', 'Purge', '-OlderThanDays', '0')).ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $fd '001_x.exe.quar') | Should -BeFalse
    }

    It 'a manifest written by a newer version (schema 99) is neither restored nor purged' {
        $c = New-QuarantinedCase 'toonew'
        Edit-Manifest $c { param($m) $m | Add-Member -NotePropertyName schema -NotePropertyValue 99 -Force }
        Get-ResultLine (Invoke-Actions $c @('-Mode', 'Restore')) | Should -Match '^RESULT: FAILED'
        (Invoke-Actions $c @('-Mode', 'Purge', '-OlderThanDays', '0')).StdOut | Should -Match 'newer version'
        (Get-Quarantined $c).Count | Should -Be 1
        (Get-Manifest $c).schema | Should -Be 99
    }

    It 'numbers the batches (seq) so "the last one" does not depend on the clock, and List reports them newest first (L2)' {
        $c = New-QuarantinedCase 'seq'
        Invoke-Actions $c @('-Mode', 'Restore') | Out-Null
        $q2 = Invoke-Actions $c @('-Mode', 'Quarantine', '-Plan', $c.Plan, '-Select', '1')
        $q2.ExitCode | Should -Be 0
        # pretend the clock went backwards: the second batch gets a name that sorts BEFORE the first one
        $dirs = @(Get-ChildItem -LiteralPath (Join-Path $c.Store 'Quarantine') -Directory | Sort-Object Name)
        Rename-Item -LiteralPath $dirs[1].FullName -NewName '20000101-000000'
        $l = Get-ListJson $c
        $l[0].name | Should -Be '20000101-000000'
        $l[0].seq | Should -Be 2
        $l[0].state | Should -Be 'restorable'
        $l[1].seq | Should -Be 1
    }

    It 'answers BUSY (exit 4) and changes nothing while another action holds the store lock (M2)' {
        $c = New-Case 'busy'
        $h = Enter-StoreLock -Name (Get-StoreLockName -Prefix 'store' -Path $c.Store) -TimeoutMs 0 -TrustedOwners @()
        try {
            $h.Status | Should -Be 'Ok'
            $r = Invoke-Actions $c @('-Mode', 'Quarantine', '-Plan', $c.Plan, '-Select', '1')
            $r.ExitCode | Should -Be 4
            Get-ResultLine $r | Should -Be 'RESULT: BUSY'
            Test-Path -LiteralPath $c.Victim | Should -BeTrue
        }
        finally { Exit-StoreLock $h }
        (Invoke-Actions $c @('-Mode', 'Quarantine', '-Plan', $c.Plan, '-Select', '1')).ExitCode | Should -Be 0
    }

    It 'purges a batch dated in the future only when asked for all batches, and says why otherwise (L3)' {
        $c = New-QuarantinedCase 'future'
        $dir = Get-BatchDir $c
        [IO.Directory]::SetCreationTime($dir, (Get-Date).AddDays(30))
        $r = Invoke-Actions $c @('-Mode', 'Purge', '-OlderThanDays', '7')
        $r.StdOut | Should -Match 'date lies in the future'
        (Get-Quarantined $c).Count | Should -Be 1
        $r0 = Invoke-Actions $c @('-Mode', 'Purge', '-OlderThanDays', '0')
        Get-ResultLine $r0 | Should -Be 'RESULT: OK 1'
        (Get-Quarantined $c).Count | Should -Be 0
    }

    It 'keeps stored file names short and unique (L5) and prunes old action logs (L6)' {
        $c = New-Case 'names'
        [void][IO.Directory]::CreateDirectory($c.Store)
        foreach ($i in 1..40) { [IO.File]::WriteAllText((Join-Path $c.Store ('actions-20200101-{0:D6}.log' -f $i)), 'old log') }
        $run = Invoke-ActionsSnippet -StoreDir $c.Store -Code @'
$d = Join-Path $env:TEMP ('ramdoc-names-' + [guid]::NewGuid().ToString('N').Substring(0, 6)); [void][IO.Directory]::CreateDirectory($d)
$a = Get-StoredPath $d 7 ('x' * 240 + '.exe') ''
$b = Get-StoredPath $d 7 'short.exe' 'startup'
[IO.File]::WriteAllText($b, 'taken')
$b2 = Get-StoredPath $d 7 'short.exe' 'startup'
[IO.File]::Delete($b); [IO.Directory]::Delete($d)
'RESULT:' + (@{ a = [IO.Path]::GetFileName($a); b = [IO.Path]::GetFileName($b); b2 = [IO.Path]::GetFileName($b2) } | ConvertTo-Json -Compress)
'@
        $res = Get-SnippetResult -Run $run
        $res.a.Length | Should -BeLessThan 110
        $res.a | Should -Match '^007_x+~[0-9a-f]{8}\.quar$'
        $res.b | Should -Be '007_startup_short.exe.quar'
        $res.b2 | Should -Be '007_startup_short.exe-2.quar' -Because 'an existing stored name is never reused'
        (Invoke-Actions $c @('-Mode', 'Purge', '-OlderThanDays', '0')).ExitCode | Should -Be 0
        @(Get-ChildItem -LiteralPath $c.Store -Filter 'actions-*.log').Count | Should -BeLessOrEqual 31
    }
}

Describe 'Actions: save failures, a locked record, an interrupted restore' -Tag 'Integration' {
    BeforeAll {
        . (Join-Path $script:Root 'src\lib\Store.ps1')
        function Get-BatchDirs($Case) { @(Get-ChildItem -LiteralPath (Join-Path $Case.Store 'Quarantine') -Directory -ErrorAction SilentlyContinue | Sort-Object Name) }
        function Get-ResultLine($Run) { @(($Run.StdOut -split "`r?`n") | Where-Object { $_ -like 'RESULT:*' } | Select-Object -Last 1) -join '' }
        # Runs one mode IN-PROCESS of a child powershell (Actions dot-sourced with -LoadFunctionsOnly) with Save-Manifest
        # replaced: saves number $From..$To fail as if the disk were full. $Extra is more code run before the mode.
        function Invoke-WithFailingSaves($Case, [string]$Mode, [int]$From, [int]$To, [string]$Extra = '') {
            $code = @"
`$Plan = '$($Case.Plan)'; `$SelectIds = @(1); `$Yes = [switch]`$true; `$NoRestorePoint = [switch]`$true; `$Batch = ''
[void](Initialize-StoreRoot)
`$script:saveN = 0
function Save-Manifest(`$manifest, [string]`$dir) {
    `$script:saveN++
    if (`$script:saveN -ge $From -and `$script:saveN -le $To) { throw 'simulated: there is not enough space on the disk' }
    Write-JsonAtomic -Path (Join-Path `$dir 'manifest.json') -Object `$manifest -Schema `$ManifestSchema -Depth 12
}
$Extra
Invoke-$($Mode)Mode
"@
            return (Invoke-ActionsSnippet -StoreDir $Case.Store -Code $code)
        }
    }

    It 'the first step cannot be recorded: nothing is changed, no batch is left, RESULT: FAILED nosave' {
        $c = New-Case 'save-begin'
        $r = Invoke-WithFailingSaves $c 'Quarantine' 2 99      # save 1 = the empty record, save 2 = the first "pending" step
        $r.ExitCode | Should -Be 1 -Because $r.StdOut
        Get-ResultLine $r | Should -Be 'RESULT: FAILED nosave'
        $r.StdOut | Should -Match 'undo record could not be saved'
        Test-Path -LiteralPath $c.Victim | Should -BeTrue
        @(Get-BatchDirs $c).Count | Should -Be 0
    }

    It 'a step that happened but could not be marked done stays "pending" (FAILED nosave + batch name) and Restore undoes it' {
        $c = New-Case 'save-complete'
        $r = Invoke-WithFailingSaves $c 'Quarantine' 3 99      # save 2 = "pending" before the move, save 3 = "done" after it
        $r.ExitCode | Should -Be 1 -Because $r.StdOut
        $batch = @(Get-BatchDirs $c)
        $batch.Count | Should -Be 1
        Get-ResultLine $r | Should -Be ("RESULT: FAILED nosave " + $batch[0].Name)
        Test-Path -LiteralPath $c.Victim | Should -BeFalse -Because 'the move itself happened'
        (Get-Manifest $c).entries[0].ops[0].status | Should -Be 'pending'
        $rs = Invoke-Actions $c @('-Mode', 'Restore')
        $rs.ExitCode | Should -Be 0 -Because $rs.StdOut
        (Get-FileHash -LiteralPath $c.Victim -Algorithm SHA256).Hash | Should -Be $c.Sha
    }

    It 'an unexpected error is reported as FAILED error, not as a full disk' {
        $c = New-Case 'unexpected'
        $r = Invoke-WithFailingSaves $c 'Quarantine' 0 0 -Extra "function Get-StoredPath { throw 'simulated bug' }"
        $r.ExitCode | Should -Be 1
        Get-ResultLine $r | Should -Be 'RESULT: FAILED error'
        $r.StdOut | Should -Match 'unexpected error: simulated bug'
        Test-Path -LiteralPath $c.Victim | Should -BeTrue
    }

    It 'a record that another program holds is refused (FAILED unreadable): no .bak fallback, nothing overwritten, not "damaged"' {
        $c = New-Case 'held'
        (Invoke-Actions $c @('-Mode', 'Quarantine', '-Plan', $c.Plan, '-Select', '1')).ExitCode | Should -Be 0
        $dir = @(Get-BatchDirs $c)[0].FullName
        $mf = Join-Path $dir 'manifest.json'
        $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mf))
        $hold = [IO.File]::Open($mf, 'Open', 'Read', 'None')
        try {
            $r = Invoke-Actions $c @('-Mode', 'Restore')
            $r.ExitCode | Should -Be 1 -Because $r.StdOut
            Get-ResultLine $r | Should -Be 'RESULT: FAILED unreadable'
            $l = Invoke-Actions $c @('-Mode', 'List')
            $l.StdOut | Should -Match '"state":"unreadable"'
            $l.StdOut | Should -Not -Match '"state":"damaged"'
        }
        finally { $hold.Dispose() }
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($mf)) | Should -Be $before
        @(Get-ChildItem -LiteralPath $dir -Filter '*.damaged-*').Count | Should -Be 0
        Test-Path -LiteralPath $c.Victim | Should -BeFalse -Because 'nothing was restored while the record was held'
        (Invoke-Actions $c @('-Mode', 'Restore')).ExitCode | Should -Be 0
        Test-Path -LiteralPath $c.Victim | Should -BeTrue
    }

    It 'a restore to a ".restored" name whose record could not be updated is finished by the next run (restoringTo)' {
        $c = New-Case 'interrupted'
        (Invoke-Actions $c @('-Mode', 'Quarantine', '-Plan', $c.Plan, '-Select', '1')).ExitCode | Should -Be 0
        [IO.File]::WriteAllText($c.Victim, 'a new file with the same name')   # the original path is taken: restore goes to <name>.restored
        $r = Invoke-WithFailingSaves $c 'Restore' 2 99          # save 1 = "restoringTo" before the move; every later save fails
        $r.ExitCode | Should -Be 3 -Because $r.StdOut
        Get-ResultLine $r | Should -Be 'RESULT: UNSAVED'
        $restored = $c.Victim + '.restored'
        (Get-FileHash -LiteralPath $restored -Algorithm SHA256).Hash | Should -Be $c.Sha
        (Get-Manifest $c).entries[0].ops[0].restoringTo | Should -Be $restored
        $r2 = Invoke-Actions $c @('-Mode', 'Restore')
        $r2.ExitCode | Should -Be 0 -Because $r2.StdOut
        $r2.StdOut | Should -Match 'already put back by an earlier restore'
        (Get-Manifest $c).restoredAt | Should -Not -BeNullOrEmpty
    }
}
