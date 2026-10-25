#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Unit tests for the pure helper functions of the scan engine. The script is never executed: the functions are lifted
# out with the PowerShell parser (AST) and defined in the test scope, so there is no scan, no admin, no side effect.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $script:EngineFile = Join-Path (Get-RepoRoot) 'src\RAM-Doctor.ps1'
    $names = 'Test-RandomName', 'Test-OneEdit', 'Get-ExePathFromCommand', 'Resolve-ExePath', 'Get-PathZone'
    $script:Found = Get-FunctionSource -Path $script:EngineFile -Name $names
    $script:HaveAll = ($script:Found.Count -eq $names.Count)
    $memNames = 'Get-MemoryBreakdown', 'Get-DriverReservedBytes', 'Get-DriverReservedLevel', 'Get-DriverReservedCandidates', 'Get-WhereHeadline', 'Get-VerdictHeadline'
    $script:HaveMem = ((Get-FunctionSource -Path $script:EngineFile -Name $memNames).Count -eq $memNames.Count)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $names = 'Test-RandomName', 'Test-OneEdit', 'Get-ExePathFromCommand', 'Resolve-ExePath', 'Get-PathZone',
    'Get-MemoryBreakdown', 'Get-DriverReservedBytes', 'Get-DriverReservedLevel', 'Get-DriverReservedCandidates', 'Get-WhereHeadline', 'Get-VerdictHeadline'
    $engine = Join-Path (Get-RepoRoot) 'src\RAM-Doctor.ps1'
    $src = Get-FunctionSource -Path $engine -Name $names
    foreach ($n in $names) { if ($src.ContainsKey($n)) { . ([scriptblock]::Create($src[$n])) } }
    # script-level variables the helpers read (set at the top of the engine script)
    $WinDir = $env:SystemRoot.TrimEnd('\')
    $WinDirL = $WinDir.ToLowerInvariant()
    $m = [regex]::Match([IO.File]::ReadAllText($engine), "(?m)^\`$DisplayDriverRx\s*=\s*'([^']+)'")
    $DisplayDriverRx = $m.Groups[1].Value
    # the headline helpers read the string table
    . (Join-Path (Get-RepoRoot) 'src\lib\Strings.ps1')
    # the friend's scan that started the project (GB): used 18.19, private 8.56, shared summed over processes 9.88,
    # non-paged 0.9, paged in RAM 1.17, cache 0.63, driver code 0.06, modified 0.14, ConT 2310 MB
    $script:Friend = @{ Used = 18.19; Private = 8.56; SharedSum = 9.88; NonPaged = 0.9; PagedResident = 1.17; CacheResident = 0.63; DriverResident = 0.06; Modified = 0.14; DriverReserved = 2310 / 1024 }
    # the plan's memory fields for the same numbers (what Get-WhereHeadline reads)
    $script:FriendGB = [pscustomobject]@{ HiddenGB = 9.63; SharedUniqueGB = 4.47; DriverReservedGB = 2.26; KernelPoolsGB = 2.07; SystemOtherGB = 0.83; UnexplainedGB = 0 }
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

Describe 'Where the memory is that Task Manager does not show' -Skip:(-not $script:HaveMem) {

    Context 'Get-MemoryBreakdown (parts of the used memory)' {
        It 'explains the friend scan: shared memory of programs and driver reservations, nothing unexplained' {
            $f = $script:Friend
            $b = Get-MemoryBreakdown @f
            [math]::Round($b.Hidden, 2) | Should -Be 9.63          # used - private: what the Task Manager column leaves out
            [math]::Round($b.Kernel, 2) | Should -Be 2.07          # non-paged 0.9 + paged in RAM 1.17
            [math]::Round($b.System, 2) | Should -Be 0.83          # cache 0.63 + driver code 0.06 + modified 0.14
            [math]::Round($b.Drivers, 2) | Should -Be 2.26         # ConT 2310 MB
            [math]::Round($b.Shared, 2) | Should -Be 4.47          # counted once, far below the 9.88 summed over processes
            [math]::Round($b.Unexplained, 2) | Should -Be 0
            [math]::Round($b.Unattributed, 2) | Should -Be 2.26
        }
        It 'does not let the double-counted shared working sets hide the driver reservation (the old formula said 0)' {
            $f = $script:Friend
            $old = [math]::Max(0.0, $f.Used - ($f.Private + $f.SharedSum) - $f.NonPaged - $f.Modified)
            $old | Should -Be 0
            (Get-MemoryBreakdown @f).Unattributed | Should -BeGreaterThan 2.2
        }
        It 'puts what even the summed shared memory cannot cover into "unexplained"' {
            $b = Get-MemoryBreakdown -Used 12 -Private 4 -SharedSum 1 -NonPaged 0.5 -PagedResident 0.5 -CacheResident 0 -DriverResident 0 -Modified 0 -DriverReserved 0
            $b.Hidden | Should -Be 8
            $b.Kernel | Should -Be 1
            $b.Shared | Should -Be 1
            $b.Unexplained | Should -Be 6
            $b.Unattributed | Should -Be 6
        }
        It 'clamps: private memory above the used memory (sampling noise) gives zero parts, never negative ones' {
            $b = Get-MemoryBreakdown -Used 10 -Private 11 -SharedSum 3 -NonPaged 1 -PagedResident 1 -CacheResident 1 -DriverResident 0 -Modified 0 -DriverReserved 1
            foreach ($p in 'Hidden', 'Kernel', 'System', 'Drivers', 'Shared', 'Unexplained', 'Unattributed') { $b.$p | Should -Be 0 -Because $p }
        }
        It 'clamps: each part takes at most what is left, so a reservation larger than the rest cannot be counted twice' {
            $b = Get-MemoryBreakdown -Used 10 -Private 6 -SharedSum 5 -NonPaged 1 -PagedResident 1 -CacheResident 0.5 -DriverResident 0 -Modified 0 -DriverReserved 9
            $b.Hidden | Should -Be 4
            $b.Kernel | Should -Be 2
            $b.System | Should -Be 0.5
            $b.Drivers | Should -Be 1.5
            $b.Shared | Should -Be 0
        }
        It 'ignores negative inputs' {
            $b = Get-MemoryBreakdown -Used 8 -Private 4 -SharedSum -2 -NonPaged -1 -PagedResident 0 -CacheResident 0 -DriverResident 0 -Modified 0 -DriverReserved -5
            $b.Kernel | Should -Be 0
            $b.Drivers | Should -Be 0
            $b.Shared | Should -Be 0
            $b.Unexplained | Should -Be 4
        }
        It 'the parts always add up to the hidden memory (<Case>)' -ForEach @(
            @{ Case = 'friend'; A = @(18.19, 8.56, 9.88, 0.9, 1.17, 0.63, 0.06, 0.14, 2.26) }
            @{ Case = 'kernel leak'; A = @(14.9, 3.1, 1.9, 9.6, 0.8, 0.9, 0.1, 0.11, 0) }
            @{ Case = 'tiny shared'; A = @(20, 5, 0.2, 1, 1, 1, 0.1, 0.3, 0.4) }
            @{ Case = 'everything kernel'; A = @(6, 1, 4, 3, 3, 1, 0, 0, 2) }
        ) {
            $b = Get-MemoryBreakdown -Used $A[0] -Private $A[1] -SharedSum $A[2] -NonPaged $A[3] -PagedResident $A[4] -CacheResident $A[5] -DriverResident $A[6] -Modified $A[7] -DriverReserved $A[8]
            [math]::Round($b.Kernel + $b.System + $b.Drivers + $b.Shared + $b.Unexplained, 6) | Should -Be ([math]::Round($b.Hidden, 6))
        }
    }

    Context 'Get-DriverReservedBytes (contiguous allocations outside the non-paged pool counter)' {
        It 'counts the tag in full when the other tags explain the counter (the documented case: friend scan)' {
            Get-DriverReservedBytes -ContigBytes 2310MB -OtherNonPagedTagBytes 700MB -NonPagedCounter 920MB | Should -Be ([double]2310MB)
        }
        It 'counts nothing when the counter is big enough to hold the tag (it may sit inside the pool on that build)' {
            Get-DriverReservedBytes -ContigBytes 2GB -OtherNonPagedTagBytes 500MB -NonPagedCounter 2700MB | Should -Be 0
        }
        It 'counts only the provable part when the other tags explain less than half of the counter' {
            Get-DriverReservedBytes -ContigBytes 1000MB -OtherNonPagedTagBytes 300MB -NonPagedCounter 900MB | Should -Be ([double]400MB)
        }
        It 'is zero without contiguous allocations' {
            Get-DriverReservedBytes -ContigBytes 0 -OtherNonPagedTagBytes 800MB -NonPagedCounter 1GB | Should -Be 0
        }
    }

    Context 'Get-DriverReservedLevel (thresholds of the driver-reserved observation)' {
        It '<Mb> MB, grew <GrowMb> MB, scale <Scale> -> "<Want>"' -ForEach @(
            @{ Mb = 300; GrowMb = 0; Scale = 1; Want = '' }
            @{ Mb = 511; GrowMb = 200; Scale = 1; Want = '' }
            @{ Mb = 512; GrowMb = 0; Scale = 1; Want = 'med' }
            @{ Mb = 2310; GrowMb = 0; Scale = 1; Want = 'med' }       # the friend scan: big but stable = a setting, not a leak
            @{ Mb = 2310; GrowMb = 29; Scale = 1; Want = 'med' }
            @{ Mb = 2310; GrowMb = 30; Scale = 1; Want = 'high' }     # big AND growing
            @{ Mb = 1500; GrowMb = 400; Scale = 1; Want = 'med' }     # growing but below 2 GB
            @{ Mb = 300; GrowMb = 0; Scale = 0.5; Want = 'med' }      # -ThresholdScale 0.5 = twice as sensitive
            @{ Mb = 1100; GrowMb = 50; Scale = 0.5; Want = 'high' }
        ) {
            Get-DriverReservedLevel -Bytes ($Mb * 1MB) -GrowthBytes ($GrowMb * 1MB) -Scale $Scale | Should -Be $Want
        }
    }

    Context 'Get-DriverReservedCandidates (the tag cannot name the driver: honest candidates only)' {
        It 'lists display adapters (no Microsoft basic adapter, no trademark marks) and graphics / virtual-display drivers of other makers' {
            $drivers = @(
                [pscustomobject]@{ Name = 'nvlddmkm'; Display = 'nvlddmkm'; Path = 'C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf\nvlddmkm.sys'; Company = 'NVIDIA Corporation'; Trust = 'OS' },
                [pscustomobject]@{ Name = 'amdkmdag'; Display = 'amdkmdag'; Path = 'C:\Windows\System32\DriverStore\FileRepository\u0.inf\amdkmdag.sys'; Company = 'Advanced Micro Devices, Inc.'; Trust = 'OS' },
                [pscustomobject]@{ Name = 'BasicDisplay'; Display = 'BasicDisplay'; Path = 'C:\Windows\System32\drivers\BasicDisplay.sys'; Company = 'Microsoft Corporation'; Trust = 'OS' },
                [pscustomobject]@{ Name = 'parsecvdd'; Display = 'Parsec Virtual Display'; Path = 'C:\Windows\System32\drivers\parsecvdd.sys'; Company = 'Parsec Cloud, Inc.'; Trust = 'Signed' },
                [pscustomobject]@{ Name = 'exnet'; Display = 'Example Network Filter'; Path = 'C:\Windows\System32\drivers\exnet.sys'; Company = 'Example'; Trust = 'Signed' },
                [pscustomobject]@{ Name = 'RdpVideoMiniport'; Display = 'Remote Desktop Video Miniport Driver'; Path = 'C:\Windows\System32\drivers\rdpvideominiport.sys'; Company = ''; Trust = 'OS' }
            )
            $c = @(Get-DriverReservedCandidates -Drivers $drivers -Adapters @('AMD Radeon(TM) Graphics', 'NVIDIA GeForce RTX 4070', 'Microsoft Basic Display Adapter', 'Parsec Virtual Display Adapter'))
            $c | Should -Be @('AMD Radeon Graphics', 'NVIDIA GeForce RTX 4070', 'Parsec Virtual Display Adapter', 'nvlddmkm.sys', 'amdkmdag.sys', 'parsecvdd.sys (Parsec Virtual Display)')
        }
        It 'keeps the list short' {
            $many = @(1..10 | ForEach-Object { "Example Adapter $_" })
            @(Get-DriverReservedCandidates -Adapters $many).Count | Should -Be 6
            @(Get-DriverReservedCandidates -Adapters $many -Max 3).Count | Should -Be 3
        }
        It 'returns an empty list when nothing fits' {
            @(Get-DriverReservedCandidates -Drivers @() -Adapters @('Microsoft Basic Display Adapter')).Count | Should -Be 0
        }
    }

    Context 'Headline: "where is my memory?" and its place in the verdict order' {
        BeforeAll { $script:WasLang = Get-UiLang; Set-UiLang 'en' }
        AfterAll { Set-UiLang $script:WasLang }

        It 'answers the friend scan with the two biggest hidden parts, in numbers' {
            Get-WhereHeadline $script:FriendGB | Should -Be 'No leak found: most of the memory Task Manager does not show (9.6 GB) is shared memory of open programs (~4.5 GB) and memory reserved by hardware drivers (~2.3 GB)'
        }
        It 'says the same in Arabic' {
            Set-UiLang 'ar'
            try {
                $h = Get-WhereHeadline $script:FriendGB
                $h | Should -Be (Get-Text 'verdict.where' '9.6' (Get-Text 'verdict.part.shared') '4.5' (Get-Text 'verdict.part.drivers') '2.3')
                $h | Should -Match '[\u0600-\u06FF]'
            } finally { Set-UiLang 'en' }
        }
        It 'names one part when the second one is negligible' {
            $b = [pscustomobject]@{ HiddenGB = 3; SharedUniqueGB = 2.95; DriverReservedGB = 0; KernelPoolsGB = 0.05; SystemOtherGB = 0; UnexplainedGB = 0 }
            Get-WhereHeadline $b | Should -Be (Get-Text 'verdict.where.one' '3' (Get-Text 'verdict.part.shared') '3')
        }
        It 'stays quiet when less than 1 GB is hidden or the plan has no breakdown' {
            Get-WhereHeadline ([pscustomobject]@{ HiddenGB = 0.6; SharedUniqueGB = 0.4; DriverReservedGB = 0; KernelPoolsGB = 0.2; SystemOtherGB = 0; UnexplainedGB = 0 }) | Should -Be ''
            Get-WhereHeadline $null | Should -Be ''
        }
        It 'friend scan (no leak, medium findings only): the breakdown leads, the findings are pointed to' {
            Get-VerdictHeadline -Breakdown $script:FriendGB -MaxLevel 2 | Should -Be ((Get-WhereHeadline $script:FriendGB) + (Get-Text 'verdict.where.more'))
        }
        It 'nothing found at all: the breakdown alone' {
            Get-VerdictHeadline -Breakdown $script:FriendGB -MaxLevel 0 | Should -Be (Get-WhereHeadline $script:FriendGB)
        }
        It '<Case> wins over the breakdown' -ForEach @(
            @{ Case = 'a hidden process or a high-risk file'; Flags = @{ Urgent = $true; KernelPool = $true }; Key = 'verdict.urgent' }
            @{ Case = 'a kernel pool above its threshold'; Flags = @{ KernelPool = $true; DriverReservedLeak = $true }; Key = 'verdict.driver' }
            @{ Case = 'unexplained memory'; Flags = @{ Unexplained = $true }; Key = 'verdict.unacc' }
        ) {
            $a = $Flags.Clone()
            Get-VerdictHeadline @a -Breakdown $script:FriendGB -MaxLevel 3 | Should -Be (Get-Text $Key)
        }
        It 'a growing driver reservation is named as the likely cause' {
            Get-VerdictHeadline -DriverReservedLeak $true -DriverReservedGB 2.6 -Breakdown $script:FriendGB -MaxLevel 3 | Should -Be (Get-Text 'verdict.drvres' '2.6')
        }
        It 'never says "no leak" next to a high finding or a program that is growing right now' {
            Get-VerdictHeadline -Breakdown $script:FriendGB -MaxLevel 3 | Should -Be (Get-Text 'verdict.medium')
            $grow = Get-VerdictHeadline -Growing $true -Breakdown $script:FriendGB -MaxLevel 2
            $grow | Should -Be ((Get-Text 'verdict.where.part' '9.6' (Get-Text 'verdict.part.shared') '4.5' (Get-Text 'verdict.part.drivers') '2.3') + (Get-Text 'verdict.where.more'))
            $grow | Should -Not -Match 'No leak'
            $grow | Should -Match '^Most of the memory Task Manager does not show \(9\.6 GB\)'
        }
        It 'plans without a breakdown keep the classic headlines' {
            Get-VerdictHeadline -Breakdown $null -MaxLevel 2 | Should -Be (Get-Text 'verdict.medium')
            Get-VerdictHeadline -Breakdown $null -MaxLevel 0 | Should -Be (Get-Text 'verdict.ok')
        }
    }
}
