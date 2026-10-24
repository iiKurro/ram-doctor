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
