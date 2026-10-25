#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# The plan JSON is the contract between the scan (writer) and the actions script + window (readers).
# These tests pin the contract down so a change on one side cannot silently break the other.

BeforeDiscovery {
    $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
    $script:FixturePlans = @()
    if (Test-Path -LiteralPath $script:FixtureDir) {
        $script:FixturePlans = @(Get-ChildItem -LiteralPath $script:FixtureDir -Filter 'plan*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
    }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    # what the real scan writes goes through ConvertTo-Json -> file -> ConvertFrom-Json; test that exact round trip
    function ConvertTo-RoundTrip($o) { return ($o | ConvertTo-Json -Depth 8 | ConvertFrom-Json) }
}

Describe 'Plan JSON contract' {

    It 'accepts a valid synthetic plan (in memory)' {
        Test-RamPlan -Plan (New-SyntheticPlan) | Should -BeNullOrEmpty
    }

    It 'accepts it after a JSON round trip, as the readers see it' {
        Test-RamPlan -Plan (ConvertTo-RoundTrip (New-SyntheticPlan)) | Should -BeNullOrEmpty
    }

    It 'keeps empty arrays as arrays through the round trip (readers rely on .Count)' {
        $p = ConvertTo-RoundTrip (New-SyntheticPlan)
        $p.suspects[0].procs -is [System.Array] | Should -BeTrue
        $p.suspects[0].procs.Count | Should -Be 0
    }

    It 'accepts the optional language field ("<Lang>") and a plan without it (older releases)' -ForEach @(@{ Lang = 'ar' }, @{ Lang = 'en' }) {
        $p = ConvertTo-RoundTrip (New-SyntheticPlan)
        Test-RamPlan -Plan $p | Should -BeNullOrEmpty
        $p | Add-Member -NotePropertyName lang -NotePropertyValue $Lang
        Test-RamPlan -Plan (ConvertTo-RoundTrip $p) | Should -BeNullOrEmpty
    }

    It 'accepts a plan with no suspects' {
        $p = New-SyntheticPlan
        $p.suspects = @()
        Test-RamPlan -Plan (ConvertTo-RoundTrip $p) | Should -BeNullOrEmpty
    }

    It 'accepts a suspect with every kind of attached context' {
        $p = New-SyntheticPlan
        $s = $p.suspects[0]
        $s.procs = @([pscustomobject]@{ pid = 4242; start = '2026-01-01 10:00:00'; cmd = 'x.exe'; privMB = 10; growthMB = 1; remote = @() })
        $s.services = @([pscustomobject]@{ name = 'ExampleSvc'; display = 'Example'; startMode = 'Auto'; state = 'Stopped' })
        $s.tasks = @([pscustomobject]@{ taskPath = '\'; taskName = 'ExampleTask'; state = 'Ready'; cmd = 'x.exe' })
        $s.autoruns = @([pscustomobject]@{ via = 'Registry'; location = 'HKCU:\Example'; name = 'Example'; value = '"x.exe"'; file = '' },
            [pscustomobject]@{ via = 'StartupFolder'; location = 'C:\Example'; name = 'x.lnk'; value = 'x.exe'; file = 'C:\Example\x.lnk' })
        $s.drivers = @([pscustomobject]@{ name = 'ExampleDrv'; display = 'Example'; startMode = 'Manual' })
        $s.wmi = @([pscustomobject]@{ class = 'CommandLineEventConsumer'; name = 'Example'; cmd = 'x.exe' })
        Test-RamPlan -Plan (ConvertTo-RoundTrip $p) | Should -BeNullOrEmpty
    }

    Context 'violations are reported (one case per rule)' {
        It '<Case>' -ForEach @(
            @{ Case = "missing top-level 'host'"; Mutate = { param($p) $p.PSObject.Properties.Remove('host') }; Expect = "missing 'host'" }
            @{ Case = "wrong tool name"; Mutate = { param($p) $p.tool = 'Other' }; Expect = 'plan.tool' }
            @{ Case = "unknown language"; Mutate = { param($p) $p | Add-Member -NotePropertyName lang -NotePropertyValue 'fr' }; Expect = 'plan.lang invalid' }
            @{ Case = 'unparseable created date'; Mutate = { param($p) $p.created = 'yesterday-ish' }; Expect = 'plan.created' }
            @{ Case = 'verdict level outside ok/low/med/high'; Mutate = { param($p) $p.verdict.Level = 'purple' }; Expect = 'verdict.Level invalid' }
            @{ Case = 'empty verdict headline'; Mutate = { param($p) $p.verdict.Headline = '' }; Expect = 'Headline is empty' }
            @{ Case = 'observation without Title'; Mutate = { param($p) $p.observations[0].PSObject.Properties.Remove('Title') }; Expect = "missing 'Title'" }
            @{ Case = 'suspect risk outside High/Medium/Low'; Mutate = { param($p) $p.suspects[0].risk = 'Critical' }; Expect = 'risk invalid' }
            @{ Case = 'suspect id below 1'; Mutate = { param($p) $p.suspects[0].id = 0 }; Expect = 'id must be an integer' }
            @{ Case = 'sha256 of the wrong length'; Mutate = { param($p) $p.suspects[0].sha256 = 'ABC' }; Expect = 'sha256' }
            @{ Case = 'empty reasons'; Mutate = { param($p) $p.suspects[0].reasons = @() }; Expect = 'reasons must be a non-empty array' }
            @{ Case = 'suspect without protectedFile'; Mutate = { param($p) $p.suspects[0].PSObject.Properties.Remove('protectedFile') }; Expect = "missing 'protectedFile'" }
            @{ Case = 'process entry without pid'; Mutate = { param($p) $p.suspects[0].procs = @([pscustomobject]@{ start = 'x' }) }; Expect = "missing 'pid'" }
            @{ Case = 'autorun via something unknown'; Mutate = { param($p) $p.suspects[0].autoruns = @([pscustomobject]@{ via = 'Magic'; location = 'a'; name = 'b'; value = 'c'; file = '' }) }; Expect = 'via invalid' }
            @{ Case = 'tasks that is not an array'; Mutate = { param($p) $p.suspects[0].tasks = 'none' }; Expect = 'tasks must be an array' }
        ) {
            $p = ConvertTo-RoundTrip (New-SyntheticPlan)
            & $Mutate $p
            $violations = @(Test-RamPlan -Plan $p)
            $violations.Count | Should -BeGreaterThan 0
            ($violations -join ' | ') | Should -Match ([regex]::Escape($Expect))
        }

        It 'rejects duplicated suspect ids' {
            $p = ConvertTo-RoundTrip (New-SyntheticPlan)
            $second = ConvertTo-RoundTrip $p.suspects[0]
            $p.suspects = @($p.suspects[0], $second)
            (@(Test-RamPlan -Plan $p) -join ' | ') | Should -Match 'duplicated'
        }
    }

    Context 'memory breakdown: additive fields of scans after 1.1.2' {
        BeforeAll {
            . (Join-Path (Get-RepoRoot) 'src\lib\Strings.ps1')   # Get-HiddenMemoryLines, what the window and the summaries read
            # the memory object the scan writes now (numbers of the scan that started the project)
            function Add-Breakdown($p) {
                $p.memory = [pscustomobject]@{
                    TotalGB = 31.11; UsedGB = 18.19; ProcPrivateGB = 8.56; ProcSharedGB = 9.88; NonPagedGB = 0.9; UnaccountedGB = 0
                    HiddenGB = 9.63; SharedUniqueGB = 4.47; DriverReservedGB = 2.26; DriverReservedKnown = $true; DriverReservedGrowthMB = 0
                    KernelPoolsGB = 2.07; SystemOtherGB = 0.83; UnexplainedGB = 0; UnattributedGB = 2.26
                    TopShared = @([pscustomobject]@{ name = 'brave.exe'; count = 32; sharedMB = 5240 })
                    DriverReservedCandidates = @('NVIDIA GeForce RTX 4070')
                }
                return $p
            }
        }
        It 'accepts a plan with the breakdown, also after the JSON round trip' {
            Test-RamPlan -Plan (Add-Breakdown (New-SyntheticPlan)) | Should -BeNullOrEmpty
            Test-RamPlan -Plan (ConvertTo-RoundTrip (Add-Breakdown (New-SyntheticPlan))) | Should -BeNullOrEmpty
        }
        It 'keeps one shared-memory user and one candidate as arrays through the round trip (readers rely on .Count)' {
            $p = ConvertTo-RoundTrip (Add-Breakdown (New-SyntheticPlan))
            $p.memory.TopShared -is [System.Array] | Should -BeTrue
            $p.memory.DriverReservedCandidates -is [System.Array] | Should -BeTrue
            $p.memory.TopShared[0].name | Should -Be 'brave.exe'
        }
        It 'keeps the old field next to the corrected one (1.0-1.1 readers still find UnaccountedGB)' {
            $p = ConvertTo-RoundTrip (Add-Breakdown (New-SyntheticPlan))
            $p.memory.UnaccountedGB | Should -Be 0
            $p.memory.UnattributedGB | Should -Be 2.26
        }
        It 'a plan of an older release (no breakdown) is still valid and its readers show no breakdown' {
            $old = ConvertTo-RoundTrip (New-SyntheticPlan)
            Test-RamPlan -Plan $old | Should -BeNullOrEmpty
            @(Get-HiddenMemoryLines -Memory $old.memory).Count | Should -Be 0
            $old.PSObject.Properties.Remove('memory')
            Test-RamPlan -Plan $old | Should -BeNullOrEmpty
            @(Get-HiddenMemoryLines -Memory $old.memory).Count | Should -Be 0
        }
        It 'the readers turn the breakdown into one line plus the biggest shared-memory users' {
            $lines = @(Get-HiddenMemoryLines -Memory (ConvertTo-RoundTrip (Add-Breakdown (New-SyntheticPlan))).memory -Lang en)
            $lines.Count | Should -Be 2
            $lines[0] | Should -Match '^Not shown by Task Manager: 9\.63 GB'
            $lines[1] | Should -Match 'brave\.exe \(32 processes\) 5\.12 GB'
        }
        It 'rejects <Case>' -ForEach @(
            @{ Case = 'a negative part'; Mutate = { param($p) $p.memory.SharedUniqueGB = -1 }; Expect = 'SharedUniqueGB must not be negative' }
            @{ Case = 'a part that is not a number'; Mutate = { param($p) $p.memory.HiddenGB = 'a lot' }; Expect = 'HiddenGB must be a number' }
            @{ Case = 'DriverReservedKnown that is not a boolean'; Mutate = { param($p) $p.memory.DriverReservedKnown = 'yes' }; Expect = 'DriverReservedKnown must be a boolean' }
            @{ Case = 'TopShared that is not an array'; Mutate = { param($p) $p.memory.TopShared = 'brave' }; Expect = 'TopShared must be an array' }
            @{ Case = 'a TopShared entry without a name'; Mutate = { param($p) $p.memory.TopShared = @([pscustomobject]@{ count = 1; sharedMB = 2 }) }; Expect = "TopShared[0]: missing 'name'" }
            @{ Case = 'candidates that are not strings'; Mutate = { param($p) $p.memory.DriverReservedCandidates = @(1, 2) }; Expect = 'DriverReservedCandidates must contain strings only' }
        ) {
            $p = ConvertTo-RoundTrip (Add-Breakdown (New-SyntheticPlan))
            & $Mutate $p
            (@(Test-RamPlan -Plan $p) -join ' | ') | Should -Match ([regex]::Escape($Expect))
        }
    }

    Context 'fixture plans in tests\fixtures (if the engine provides any)' {
        # a plain loop instead of -ForEach: Pester 6 refuses an empty -ForEach array
        It 'every plan*.json fixture satisfies the contract' -Skip:($script:FixturePlans.Count -eq 0) {
            # variables from BeforeDiscovery do not exist at run time, so look the fixtures up again
            $dir = Join-Path $PSScriptRoot 'fixtures'
            foreach ($fx in @(Get-ChildItem -LiteralPath $dir -Filter 'plan*.json' -File)) {
                $plan = Get-Content -LiteralPath $fx.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                @(Test-RamPlan -Plan $plan) | Should -BeNullOrEmpty -Because $fx.Name
            }
        }
    }
}
