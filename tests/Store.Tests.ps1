#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Unit tests for src\lib\Store.ps1: atomic JSON writes, safe reads with the .bak fallback, the inter-process lock.
# Everything happens inside a private temp folder; nothing else is touched and no process is started.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $script:StoreLib = Join-Path (Get-RepoRoot) 'src\lib\Store.ps1'
    . $script:StoreLib
    $script:Work = New-TempDirectory 'ramdoc-store'
    $script:N = 0
    $script:Bom = New-Object System.Text.UTF8Encoding($true)

    function New-CaseDir([string]$Name) {
        $script:N++
        $d = Join-Path $script:Work ('{0:D2}-{1}' -f $script:N, $Name)
        [void][IO.Directory]::CreateDirectory($d)
        return $d
    }
    function Get-Names([string]$Dir) { @([IO.Directory]::GetFileSystemEntries($Dir) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object) }
    function Get-B64([string]$Path) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }
    function Write-Text([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $script:Bom) }
}

AfterAll {
    if ($script:Work) { Remove-TreeForce -Path $script:Work }
}

Describe 'Write-JsonAtomic and Read-JsonSafe: normal use' {
    It 'round-trips Arabic and other Unicode text in a folder and file with Arabic names' {
        $dir = Join-Path (New-CaseDir 'unicode') 'تقارير الفحص – ملف ✓'
        [void][IO.Directory]::CreateDirectory($dir)
        $file = Join-Path $dir 'بيان.json'
        $obj = [ordered]@{ name = 'صديق'; note = 'Grüße – 日本語 – ✓'; items = @(1, 2, 3); nested = [ordered]@{ ok = $true } }
        Write-JsonAtomic -Path $file -Object $obj -Schema 2

        $r = Read-JsonSafe -Path $file -MaxSchema 2
        $r.Status | Should -Be 'Ok'
        $r.Source | Should -Be 'main'
        $r.Schema | Should -Be 2
        $r.Data.name | Should -Be 'صديق'
        $r.Data.note | Should -Be 'Grüße – 日本語 – ✓'
        (@($r.Data.items) -join ',') | Should -Be '1,2,3'
        $r.Data.nested.ok | Should -BeTrue
        $b = [IO.File]::ReadAllBytes($file)
        ('{0:X2}{1:X2}{2:X2}' -f $b[0], $b[1], $b[2]) | Should -Be 'EFBBBF' -Because 'Windows PowerShell 5.1 readers need the UTF-8 BOM'
        (Get-Names $dir) -join '|' | Should -Be 'بيان.json' -Because 'no .tmp is left behind and the first write has no .bak yet'
    }

    It 'keeps the previous version as .bak, writes "schema" first and replaces a schema field of the input' {
        $dir = New-CaseDir 'bak'
        $file = Join-Path $dir 'manifest.json'
        Write-JsonAtomic -Path $file -Object ([pscustomobject]@{ v = 'one' }) -Schema 1
        Write-JsonAtomic -Path $file -Object ([pscustomobject]@{ schema = 7; v = 'two' }) -Schema 1
        (Read-JsonSafe -Path $file -MaxSchema 1).Data.v | Should -Be 'two'
        (Get-Content -LiteralPath "$file.bak" -Raw -Encoding UTF8 | ConvertFrom-Json).v | Should -Be 'one'
        [IO.File]::ReadAllText($file) | Should -Match '^\s*\{\s*"schema":\s*1,'
        (Get-Names $dir) -join '|' | Should -Be 'manifest.json|manifest.json.bak'
    }

    It 'reads a 1.0.x file (no schema field) as schema 1 and leaves it untouched' {
        $dir = New-CaseDir 'legacy'
        $file = Join-Path $dir 'manifest.json'
        $legacy = @'
{
    "batch":  "20261024-215344",
    "created":  "2026-10-24 21:53:44",
    "host":  "DESKTOP-DEMO",
    "plan":  "C:\\Users\\Friend\\Desktop\\RAM-Doctor-Reports\\Plan-DESKTOP-DEMO-20261024-215251.json",
    "entries":  [
                    {
                        "id":  1,
                        "name":  "svch0st.exe",
                        "risk":  "High",
                        "ops":  [ { "type":  "QuarantineFile", "status":  "done" } ]
                    }
                ]
}
'@
        Write-Text $file $legacy
        $before = Get-B64 $file
        $r = Read-JsonSafe -Path $file -MaxSchema 1
        $r.Status | Should -Be 'Ok'
        $r.Schema | Should -Be 1
        $r.Data.entries[0].name | Should -Be 'svch0st.exe'
        Get-B64 $file | Should -Be $before
        (Get-Names $dir) -join '|' | Should -Be 'manifest.json'
    }

    It 'reports Missing when no copy exists, and creates nothing' {
        $dir = New-CaseDir 'missing'
        $r = Read-JsonSafe -Path (Join-Path $dir 'profile.json') -MaxSchema 1
        $r.Status | Should -Be 'Missing'
        $r.Data | Should -BeNullOrEmpty
        @(Get-Names $dir).Count | Should -Be 0
    }

    It 'ignores the leftover .tmp of a crashed write and replaces it on the next write' {
        $dir = New-CaseDir 'tmp'
        $file = Join-Path $dir 'state.json'
        Write-JsonAtomic -Path $file -Object @{ v = 1 } -Schema 1
        [IO.File]::WriteAllText("$file.tmp", '{ "v": 2, "half-writ')
        $r = Read-JsonSafe -Path $file -MaxSchema 1
        $r.Status | Should -Be 'Ok'
        $r.Data.v | Should -Be 1
        Write-JsonAtomic -Path $file -Object @{ v = 3 } -Schema 1
        (Read-JsonSafe -Path $file -MaxSchema 1).Data.v | Should -Be 3
        Test-Path -LiteralPath "$file.tmp" | Should -BeFalse
    }
}

Describe 'Write-JsonAtomic: refusals' {
    It 'refuses data it cannot store faithfully and leaves nothing behind' {
        $dir = New-CaseDir 'refuse'
        $file = Join-Path $dir 'x.json'
        { Write-JsonAtomic -Path $file -Object @(1, 2) -Schema 1 } | Should -Throw '*must be a hashtable*'
        { Write-JsonAtomic -Path $file -Object 'text' -Schema 1 } | Should -Throw '*must be a hashtable*'
        { Write-JsonAtomic -Path $file -Object @{ a = @{ b = @{ c = @{ d = 1 } } } } -Schema 1 -Depth 2 } | Should -Throw '*nested deeper*'
        { Write-JsonAtomic -Path (Join-Path $dir 'no-such-folder\x.json') -Object @{ a = 1 } -Schema 1 } | Should -Throw '*does not exist*'
        @(Get-Names $dir).Count | Should -Be 0
    }

    It 'never overwrites a file that a newer version wrote' {
        $dir = New-CaseDir 'newer'
        $file = Join-Path $dir 'profile.json'
        Write-Text $file '{ "schema": 5, "v": "from a newer version" }'
        $before = Get-B64 $file
        { Write-JsonAtomic -Path $file -Object @{ v = 'old' } -Schema 1 } | Should -Throw '*newer version*'
        Get-B64 $file | Should -Be $before
        (Get-Names $dir) -join '|' | Should -Be 'profile.json'
    }

    It 'sets a damaged current file aside instead of pushing it over the good .bak' {
        $dir = New-CaseDir 'nopush'
        $file = Join-Path $dir 'manifest.json'
        Write-JsonAtomic -Path $file -Object @{ v = 'good' } -Schema 1
        Write-JsonAtomic -Path $file -Object @{ v = 'newer' } -Schema 1
        Write-Text $file '{ "v": "tru'
        Write-JsonAtomic -Path $file -Object @{ v = 'third' } -Schema 1
        (Get-Content -LiteralPath "$file.bak" -Raw -Encoding UTF8 | ConvertFrom-Json).v | Should -Be 'good'
        (Read-JsonSafe -Path $file -MaxSchema 1).Data.v | Should -Be 'third'
        @(Get-Names $dir | Where-Object { $_ -like 'manifest.json.damaged-*' }).Count | Should -Be 1
    }

    It 'in a folder that cannot be written: throws a clear error, keeps the original byte for byte, leaves no .tmp' {
        $dir = New-CaseDir 'readonly'
        $file = Join-Path $dir 'profile.json'
        $other = Join-Path $dir 'other.json'
        Write-JsonAtomic -Path $file -Object @{ v = 'original' } -Schema 1
        Write-Text $other '{ "broken": '
        $before = Get-B64 $file
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = [IO.Directory]::GetAccessControl($dir)
        $deny = New-Object Security.AccessControl.FileSystemAccessRule($me, [Security.AccessControl.FileSystemRights]'CreateFiles', [Security.AccessControl.AccessControlType]::Deny)
        $acl.AddAccessRule($deny)
        [IO.Directory]::SetAccessControl($dir, $acl)
        try {
            { Write-JsonAtomic -Path $file -Object @{ v = 'new' } -Schema 1 } | Should -Throw '*previous version is unchanged*'
            Get-B64 $file | Should -Be $before
            Test-Path -LiteralPath "$file.tmp" | Should -BeFalse
            # reading there never throws either, even when a damaged file cannot be renamed aside
            $r = Read-JsonSafe -Path $other -MaxSchema 1
            $r.Status | Should -Be 'Damaged'
            $r.Message | Should -Match 'could not be renamed aside'
            Test-Path -LiteralPath $other | Should -BeTrue
            (Read-JsonSafe -Path $file -MaxSchema 1).Data.v | Should -Be 'original'
        }
        finally {
            [void]$acl.RemoveAccessRule($deny)
            [IO.Directory]::SetAccessControl($dir, $acl)
        }
    }
}

Describe 'Read-JsonSafe: damage and recovery' {
    It 'a main file that is <Case> is kept as a .damaged-(time) copy and the .bak copy is used (Recovered)' -ForEach @(
        @{ Case = 'truncated'; Make = { param($b) $b[0..([int]($b.Length / 2))] }; Reason = 'not valid JSON' }
        @{ Case = 'all NUL bytes (power loss)'; Make = { param($b) [byte[]]::new($b.Length) }; Reason = 'NUL' }
        @{ Case = 'empty'; Make = { param($b) }; Reason = 'empty' }
        @{ Case = 'not UTF-8'; Make = { param($b) 0xC3, 0x28, 0xFF, 0xFE }; Reason = 'UTF-8' }
        @{ Case = 'a JSON array'; Make = { param($b) [Text.Encoding]::UTF8.GetBytes('[1,2,3]') }; Reason = 'object' }
        @{ Case = 'carrying a bad schema value'; Make = { param($b) [Text.Encoding]::UTF8.GetBytes('{"schema":"two","v":1}') }; Reason = 'schema' }
    ) {
        $dir = New-CaseDir 'damaged'
        $file = Join-Path $dir 'manifest.json'
        Write-JsonAtomic -Path $file -Object @{ batch = 'first'; entries = @(@{ id = 1 }) } -Schema 1
        Write-JsonAtomic -Path $file -Object @{ batch = 'second'; entries = @(@{ id = 1 }, @{ id = 2 }) } -Schema 1
        $bad = [byte[]]@(& $Make ([IO.File]::ReadAllBytes($file)))
        [IO.File]::WriteAllBytes($file, $bad)

        $r = Read-JsonSafe -Path $file -MaxSchema 1
        $r.Status | Should -Be 'Recovered'
        $r.Source | Should -Be 'bak'
        $r.Data.batch | Should -Be 'first'
        $r.Message | Should -Match $Reason
        @($r.DamagedFiles).Count | Should -Be 1
        [IO.Path]::GetFileName($r.DamagedFiles[0]) | Should -Match '^manifest\.json\.damaged-\d{8}-\d{6}'
        Get-B64 $r.DamagedFiles[0] | Should -Be ([Convert]::ToBase64String($bad)) -Because 'the damaged file is kept exactly as it was'
        Test-Path -LiteralPath "$file.bak" | Should -BeTrue -Because 'the good copy is never moved'
    }

    It 'main and .bak both bad: Damaged, no data, both kept on disk, and it stays Damaged on the next read' {
        $dir = New-CaseDir 'bothbad'
        $file = Join-Path $dir 'manifest.json'
        Write-Text $file '{"entries": ['
        [IO.File]::WriteAllBytes("$file.bak", [byte[]](0, 0, 0, 0))
        $r = Read-JsonSafe -Path $file -MaxSchema 1
        $r.Status | Should -Be 'Damaged'
        $r.Data | Should -BeNullOrEmpty
        @($r.DamagedFiles).Count | Should -Be 2
        foreach ($d in $r.DamagedFiles) { Test-Path -LiteralPath $d | Should -BeTrue }
        $main = @($r.DamagedFiles | Where-Object { [IO.Path]::GetFileName($_) -like 'manifest.json.damaged-*' })
        [IO.File]::ReadAllText($main[0]) | Should -Be '{"entries": ['
        $again = Read-JsonSafe -Path $file -MaxSchema 1
        $again.Status | Should -Be 'Damaged' -Because 'a damaged profile must not silently turn into a new one on the next start'
        @($again.DamagedFiles).Count | Should -Be 2
        Write-JsonAtomic -Path $file -Object @{ entries = @() } -Schema 1
        (Read-JsonSafe -Path $file -MaxSchema 1).Status | Should -Be 'Ok'
    }

    It 'a file from a newer version (schema 99) is TooNew, gives no data and is left exactly as it is' {
        $dir = New-CaseDir 'toonew'
        $file = Join-Path $dir 'manifest.json'
        Write-JsonAtomic -Path $file -Object @{ v = 'old' } -Schema 1
        Write-JsonAtomic -Path $file -Object @{ v = 'old2' } -Schema 1
        Write-Text $file '{ "schema": 99, "v": "future" }'
        $before = Get-B64 $file
        $r = Read-JsonSafe -Path $file -MaxSchema 1
        $r.Status | Should -Be 'TooNew'
        $r.Schema | Should -Be 99
        $r.Data | Should -BeNullOrEmpty -Because 'the older .bak must not be used in place of newer data'
        $r.Message | Should -Match 'newer version'
        Get-B64 $file | Should -Be $before
        (Get-Names $dir) -join '|' | Should -Be 'manifest.json|manifest.json.bak'
    }

    It 'a -Validate check that fails counts as damage; a check that throws never escapes' {
        $dir = New-CaseDir 'validate'
        $file = Join-Path $dir 'manifest.json'
        $check = { param($d) $d.entries -is [array] }
        Write-JsonAtomic -Path $file -Object @{ entries = @(1) } -Schema 1
        Write-JsonAtomic -Path $file -Object @{ entries = 'not a list' } -Schema 1
        $r = Read-JsonSafe -Path $file -MaxSchema 1 -Validate $check
        $r.Status | Should -Be 'Recovered'
        @($r.Data.entries).Count | Should -Be 1
        $r.Message | Should -Match 'content check'

        $other = Join-Path $dir 'other.json'
        Write-JsonAtomic -Path $other -Object @{ v = 1 } -Schema 1
        $t = Read-JsonSafe -Path $other -MaxSchema 1 -Validate { throw 'synthetic validator failure' }
        $t.Status | Should -Be 'Damaged'
        $t.Message | Should -Match 'synthetic validator failure'
    }
}

Describe 'Use-StoreLock' {
    BeforeAll {
        $script:Me = [Security.Principal.WindowsIdentity]::GetCurrent()
        # A second thread in this process that holds the lock until released (a mutex is re-entrant for its own thread).
        function Start-LockHolder([string]$Name) {
            $ready = New-Object Threading.ManualResetEvent($false)
            $release = New-Object Threading.ManualResetEvent($false)
            $ps = [powershell]::Create()
            [void]$ps.AddScript({
                    param($lib, $lockName, $ready, $release)
                    . $lib
                    $r = Use-StoreLock -Name $lockName -TimeoutMs 0 -TrustedOwners @() -Script { [void]$ready.Set(); [void]$release.WaitOne(30000) }
                    $r.Status
                }).AddArgument($script:StoreLib).AddArgument($Name).AddArgument($ready).AddArgument($release)
            $h = $ps.BeginInvoke()
            if (-not $ready.WaitOne(15000)) { [void]$release.Set(); $ps.Dispose(); throw 'the lock holder did not start' }
            return [pscustomobject]@{ PS = $ps; Handle = $h; Ready = $ready; Release = $release }
        }
        function Stop-LockHolder($Holder) {
            [void]$Holder.Release.Set()
            $out = @($Holder.PS.EndInvoke($Holder.Handle))
            $Holder.PS.Dispose(); $Holder.Ready.Dispose(); $Holder.Release.Dispose()
            return ($out -join ',')
        }
        function New-LockName { 'test-' + [guid]::NewGuid().ToString('N') }
    }

    It 'runs the script and returns its output' {
        $r = Use-StoreLock -Name (New-LockName) -Script { 'a'; 'b' }
        $r.Status | Should -Be 'Ok'
        $r.Guarded | Should -BeTrue
        $r.Scope | Should -BeIn @('Global', 'Local')
        ($r.Value -join ',') | Should -Be 'a,b'
    }

    It 'answers Busy (and does not run the script) while another thread holds the lock, Ok once it is free' {
        $name = New-LockName
        $holder = Start-LockHolder $name
        try {
            $flag = @{ ran = $false }
            $r = Use-StoreLock -Name $name -TimeoutMs 200 -TrustedOwners @($script:Me.Owner.Value) -Script { $flag.ran = $true }
            $r.Status | Should -Be 'Busy'
            $r.Message | Should -Match 'held by another process'
            $flag.ran | Should -BeFalse
        }
        finally { $done = Stop-LockHolder $holder }
        $done | Should -Be 'Ok'
        $r2 = Use-StoreLock -Name $name -TimeoutMs 2000 -Script { 'free' }
        $r2.Status | Should -Be 'Ok'
        $r2.Value | Should -Be 'free'
    }

    It 'releases the lock when the script throws, and the error reaches the caller' {
        $name = New-LockName
        # an extra handle keeps the named mutex alive, so a lock that was not released would stay taken
        $keep = [Threading.Mutex]::new($false, "Global\RAM-Doctor-$name")
        try {
            { Use-StoreLock -Name $name -Script { throw 'synthetic failure' } } | Should -Throw '*synthetic failure*'
            $holder = Start-LockHolder $name      # throws 'did not start' if the lock had not been released
            Stop-LockHolder $holder | Should -Be 'Ok'
        }
        finally { $keep.Dispose() }
    }

    It 'ignores a lock created by an owner that is not trusted instead of waiting for it' {
        $name = New-LockName
        $holder = Start-LockHolder $name
        try {
            $untrusted = 'S-1-5-80-0'        # a SID no test process runs as
            $r = Use-StoreLock -Name $name -TimeoutMs 200 -TrustedOwners @($untrusted) -Script { 'ran' }
            $r.Status | Should -Be 'Ok'
            $r.Value | Should -Be 'ran'
            $r.Message | Should -Match 'untrusted owner'
            $r.Scope | Should -Be 'Local' -Because 'the squatted Global name is skipped'
        }
        finally { [void](Stop-LockHolder $holder) }
    }

    It 'the script sees the caller''s variables, not the lock function''s own ones' {
        $Name = 'caller-name'; $Script = 'caller-script'; $m = 'caller-m'; $res = 'caller-res'
        $r = Use-StoreLock -Name (New-LockName) -Script { "$Name|$Script|$m|$res" }
        $r.Value | Should -Be 'caller-name|caller-script|caller-m|caller-res'
    }
}
