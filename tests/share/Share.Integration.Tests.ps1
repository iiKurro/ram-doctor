# Pester 5 integration tests: the REAL command line (src\RAM-Doctor-Share.ps1) against a local mock relay
# (System.Net.HttpListener, loopback only - no internet, no GitHub, no Cloudflare). Run:
#   Invoke-Pester tests\share\Share.Integration.Tests.ps1
# Synthetic data only ("Friend", "DESKTOP-DEMO").

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    . (Join-Path $PSScriptRoot 'MockRelay.ps1')
    $script:Cli = Join-Path $script:Repo 'src\RAM-Doctor-Share.ps1'
    $script:Mock = Start-MockRelay
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:ToolVersion = (Get-Content -LiteralPath (Join-Path $script:Repo 'build\VERSION') -Raw).Trim()
    # the SHIPPED config names the relay; tests that need the "no endpoint" (dormant) behaviour use this empty one instead
    $script:EmptyCfg = Join-Path $TestDrive 'empty.config.json'
    [IO.File]::WriteAllText($script:EmptyCfg, '{"endpoint":"","helperName":"7san","maxBytes":2000000}', $script:Utf8)

    # Runs the CLI in its own powershell.exe (exactly how the GUI will) and returns exit code + UTF-8 output.
    function Invoke-ShareCli {
        param([string[]]$CliArgs, [hashtable]$EnvVars = @{})
        # the language of the messages follows the Windows UI language by default; the assertions below are Arabic unless a test says -Lang en
        if ($CliArgs -notcontains '-Lang') { $CliArgs = @($CliArgs) + @('-Lang', 'ar') }
        $out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.out')
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:Cli)) + $CliArgs
        $saved = @{}
        foreach ($k in $EnvVars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process'); [Environment]::SetEnvironmentVariable($k, $EnvVars[$k], 'Process') }
        try {
            $p = Start-Process -FilePath powershell.exe -ArgumentList $argv -WindowStyle Hidden -PassThru -RedirectStandardOutput $out
            $null = $p.Handle
            $p.WaitForExit()
            $code = $p.ExitCode
        } finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') } }
        $text = if (Test-Path -LiteralPath $out) { [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8) } else { '' }
        return [pscustomobject]@{ ExitCode = $code; Output = $text }
    }
    function New-ProfileDir { Join-Path $TestDrive ('prof-' + [guid]::NewGuid().ToString('N')) }
    function Reset-Mock { $script:Mock.State.Requests.Clear(); $script:Mock.State.Counter = 0; $script:Mock.State.Commits.Clear(); $script:Mock.State.Mode = 'ok'; $script:Mock.State.RequireCode = $false }
    function Save-TestProfile([string]$Dir, [string]$Name = 'Friend', [string]$InviteCode = '') {
        $env = @{ RAMDOC_SHARE_NAME = $Name; RAMDOC_SHARE_CODE = $InviteCode }
        $r = Invoke-ShareCli -CliArgs @('-Action', 'SaveProfile', '-ProfileDir', ('"{0}"' -f $Dir)) -EnvVars $env
        if ($r.ExitCode -ne 0) { throw "could not save test profile: $($r.Output)" }
    }
    function Invoke-Share([string]$Dir, [string]$Plan, [string[]]$Extra = @()) {
        Invoke-ShareCli -CliArgs (@('-Action', 'Share', '-ProfileDir', ('"{0}"' -f $Dir), '-PlanPath', ('"{0}"' -f $Plan), '-Endpoint', $script:Mock.Url, '-BackoffSeconds', '0') + $Extra)
    }

    $script:dir = Join-Path $TestDrive 'scan'; New-Item -ItemType Directory -Force -Path $script:dir | Out-Null
    $script:files = New-TestPlanFiles -Dir $script:dir
}

AfterAll { Stop-MockRelay $script:Mock }

Describe 'CLI: profile (name only; the invite code is optional)' -Tag 'Integration' {
    It 'reports an empty profile and a dormant endpoint when the config names no relay' {
        $r = Invoke-ShareCli -CliArgs @('-Action', 'ShowProfile', '-ProfileDir', ('"{0}"' -f (New-ProfileDir)), '-ConfigPath', ('"{0}"' -f $script:EmptyCfg))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'PROFILE: configured=false name= userId= helper=7san endpointConfigured=false'
    }
    It 'the shipped config names the relay, so the Share UI is offered' {
        $r = Invoke-ShareCli -CliArgs @('-Action', 'ShowProfile', '-ProfileDir', ('"{0}"' -f (New-ProfileDir)))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'PROFILE: configured=false name= userId= helper=7san endpointConfigured=true'
    }
    It 'saves a profile with ONLY a username, keeps the userId fixed' {
        $d = New-ProfileDir
        $s = Invoke-ShareCli -CliArgs @('-Action', 'SaveProfile', '-Username', 'Friend', '-ProfileDir', ('"{0}"' -f $d))
        $s.ExitCode | Should -Be 0
        $s.Output | Should -Match 'RESULT: OK'
        $a = Invoke-ShareCli -CliArgs @('-Action', 'ShowProfile', '-ProfileDir', ('"{0}"' -f $d), '-Endpoint', $script:Mock.Url)
        $a.Output | Should -Match 'PROFILE: configured=true name=Friend userId=[0-9a-f]{8} helper=7san endpointConfigured=true'
        $j = ($a.Output -split "`r?`n" | Where-Object { $_ -like 'PROFILE_JSON:*' }) -replace '^PROFILE_JSON:\s*', '' | ConvertFrom-Json
        $j.hasCode | Should -BeFalse
        [void](Invoke-ShareCli -CliArgs @('-Action', 'SaveProfile', '-Username', 'Friend', '-ProfileDir', ('"{0}"' -f $d)))
        $b = Invoke-ShareCli -CliArgs @('-Action', 'ShowProfile', '-ProfileDir', ('"{0}"' -f $d))
        ($b.Output -replace '(?s).*userId=([0-9a-f]{8}).*', '$1') | Should -Be $j.userId
    }
    It 'accepts an Arabic username via the environment and refuses renaming' {
        $d = New-ProfileDir
        (Invoke-ShareCli -CliArgs @('-Action', 'SaveProfile', '-ProfileDir', ('"{0}"' -f $d)) -EnvVars @{ RAMDOC_SHARE_NAME = 'أحمد 7' }).ExitCode | Should -Be 0
        (Invoke-ShareCli -CliArgs @('-Action', 'ShowProfile', '-ProfileDir', ('"{0}"' -f $d))).Output | Should -Match 'name=أحمد 7 '
        $r = Invoke-ShareCli -CliArgs @('-Action', 'SaveProfile', '-Username', 'Other', '-ProfileDir', ('"{0}"' -f $d))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'RESULT: ERROR .*ثابت'
    }
    It 'rejects an invalid name with a friendly message' {
        $r = Invoke-ShareCli -CliArgs @('-Action', 'SaveProfile', '-Username', 'a', '-ProfileDir', ('"{0}"' -f (New-ProfileDir)))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'RESULT: ERROR .*حرفين'
    }
    It 'stores an optional code, never prints it, and DeleteProfile resets everything' {
        $d = New-ProfileDir
        $secret = 'inv-Zx81qLmN42'
        $s = Invoke-ShareCli -CliArgs @('-Action', 'SaveProfile', '-Username', 'Friend', '-ProfileDir', ('"{0}"' -f $d)) -EnvVars @{ RAMDOC_SHARE_CODE = $secret }
        $s.ExitCode | Should -Be 0
        $s.Output | Should -Not -Match $secret
        $show = Invoke-ShareCli -CliArgs @('-Action', 'ShowProfile', '-ProfileDir', ('"{0}"' -f $d))
        $show.Output | Should -Not -Match $secret
        $show.Output | Should -Match '"hasCode":true'
        (Get-Content (Join-Path $d 'profile.json') -Raw) | Should -Not -Match $secret
        (Invoke-ShareCli -CliArgs @('-Action', 'DeleteProfile', '-ProfileDir', ('"{0}"' -f $d))).ExitCode | Should -Be 0
        (Invoke-ShareCli -CliArgs @('-Action', 'ShowProfile', '-ProfileDir', ('"{0}"' -f $d))).Output | Should -Match 'configured=false'
    }
}

Describe 'CLI: Summary (offline, no profile, no network)' -Tag 'Integration' {
    It 'writes a short redacted UTF-8 (BOM) summary.txt and prints SUMMARY: <path>' {
        Reset-Mock
        $pv = Join-Path $TestDrive 'sum1'
        $r = Invoke-ShareCli -CliArgs @('-Action', 'Summary', '-PlanPath', ('"{0}"' -f $script:files.Plan), '-PreviewDir', ('"{0}"' -f $pv))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match ('SUMMARY: ' + [regex]::Escape((Join-Path $pv 'summary.txt')))
        $f = Join-Path $pv 'summary.txt'
        Test-Path $f | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($f)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $text = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)
        $text.Length | Should -BeLessOrEqual 1500
        $text | Should -Match 'تقرير RAM Doctor'
        $text | Should -Not -Match 'Friend|DESKTOP-DEMO|abc123secret99|friend@example\.com'
        $script:Mock.State.Requests.Count | Should -Be 0
    }
    It 'fails cleanly for a missing plan' {
        $r = Invoke-ShareCli -CliArgs @('-Action', 'Summary', '-PlanPath', ('"{0}"' -f (Join-Path $TestDrive 'nope.json')))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'RESULT: ERROR '
    }
}

Describe 'CLI: Preview' -Tag 'Integration' {
    It 'writes the three redacted files and reports sizes' {
        $pv = Join-Path $TestDrive 'prev1'
        $r = Invoke-ShareCli -CliArgs @('-Action', 'Preview', '-PlanPath', ('"{0}"' -f $script:files.Plan), '-PreviewDir', ('"{0}"' -f $pv), '-ProfileDir', ('"{0}"' -f (New-ProfileDir)))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match ('PREVIEW: ' + [regex]::Escape($pv))
        $r.Output | Should -Match 'FILES: summary\.md=\d+\.\d report\.html=\d+\.\d plan\.json=\d+\.\d'
        foreach ($n in 'summary.md', 'report.html', 'plan.json') { Test-Path (Join-Path $pv $n) | Should -BeTrue }
        $all = (Get-ChildItem $pv -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) }) -join "`n"
        $all | Should -Not -Match 'Friend\\|DESKTOP-DEMO|abc123secret99|hunter2|friend@example\.com|SECRET123XYZ'
    }
}

Describe 'CLI: private output folders and a damaged profile (M3, M4)' -Tag 'Integration' {
    It 'Preview and Summary without -PreviewDir use a fresh RAM-Doctor-share-<random> folder each time' {
        $dirs = @()
        try {
            foreach ($i in 1, 2) {
                $r = Invoke-ShareCli -CliArgs @('-Action', 'Preview', '-PlanPath', ('"{0}"' -f $script:files.Plan), '-ProfileDir', ('"{0}"' -f (New-ProfileDir)))
                $r.ExitCode | Should -Be 0
                $dirs += ([regex]::Match($r.Output, 'PREVIEW:\s*(.+?)\r?\n')).Groups[1].Value.Trim()
            }
            $s = Invoke-ShareCli -CliArgs @('-Action', 'Summary', '-PlanPath', ('"{0}"' -f $script:files.Plan))
            $dirs += Split-Path -Parent ([regex]::Match($s.Output, 'SUMMARY:\s*(.+?)\r?\n')).Groups[1].Value.Trim()
            foreach ($d in $dirs) { [IO.Path]::GetFileName($d) | Should -Match '^RAM-Doctor-share-[0-9a-f]{32}$' }
            @($dirs | Select-Object -Unique).Count | Should -Be 3
            Test-Path -LiteralPath (Join-Path $dirs[0] 'plan.json') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $env:TEMP 'RAM-Doctor-share-preview') | Should -BeFalse -Because 'the fixed folder of 1.0.x is not used any more'
        }
        finally {
            . (Join-Path $script:Repo 'src\lib\Store.ps1')
            foreach ($d in $dirs) { [void](Remove-StorePrivateDir $d) }
        }
    }
    It 'ShowProfile says "damaged" for an unreadable profile; SaveProfile then keeps the old userId' {
        $d = New-ProfileDir
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'profile.json'), '{ "v": 1, "displayName": "Friend", "userId": "0a1b2c3d", "crea', (New-Object Text.UTF8Encoding($true)))
        $show = Invoke-ShareCli -CliArgs @('-Action', 'ShowProfile', '-ProfileDir', ('"{0}"' -f $d))
        $j = ($show.Output -split "`r?`n" | Where-Object { $_ -like 'PROFILE_JSON:*' }) -replace '^PROFILE_JSON:\s*', '' | ConvertFrom-Json
        $j.configured | Should -BeFalse
        $j.damaged | Should -BeTrue
        (Invoke-ShareCli -CliArgs @('-Action', 'SaveProfile', '-Username', 'Friend', '-ProfileDir', ('"{0}"' -f $d))).ExitCode | Should -Be 0
        (Invoke-ShareCli -CliArgs @('-Action', 'ShowProfile', '-ProfileDir', ('"{0}"' -f $d))).Output | Should -Match 'userId=0a1b2c3d'
    }
}
Describe 'CLI: Share against the local mock relay' -Tag 'Integration' {
    BeforeEach { Reset-Mock; $script:pd = New-ProfileDir; Save-TestProfile -Dir $script:pd }

    It 'uploads exactly the protocol-v1 body (no code when none is stored) and prints the URL' {
        $r = Invoke-Share $pd $files.Plan
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'RESULT: OK https://github\.com/example/private-reports/tree/main/reports/demo-[0-9a-f]{8}/20260101-120000'
        $reqs = @($Mock.State.Requests)
        $reqs.Count | Should -Be 1
        $q = $reqs[0]
        $q.Method | Should -Be 'POST'
        $q.Path | Should -Be '/v1/reports'
        $q.ContentType | Should -Be 'application/json; charset=utf-8'
        $q.UserAgent | Should -Match '^RAM-Doctor/'
        $b = $q.Body | ConvertFrom-Json
        $b.v | Should -Be 1
        $b.displayName | Should -Be 'Friend'
        $b.userId | Should -Match '^[0-9a-f]{8}$'
        $b.PSObject.Properties.Name | Should -Not -Contain 'code'
        $b.tool.name | Should -Be 'RAM-Doctor'
        $b.tool.version | Should -Be $script:ToolVersion
        $b.createdAt | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        $b.host | Should -Be '<PC>'
        @($b.files | ForEach-Object { $_.name }) | Should -Be @('summary.md', 'report.html', 'plan.json')
        [Text.Encoding]::UTF8.GetByteCount($q.Body) | Should -BeLessOrEqual 2000000
        $q.Body | Should -Not -Match 'abc123secret99|hunter2|friend@example\.com|SECRET123XYZ|S-1-5-21-1111|DESKTOP-DEMO'
        $q.Body | Should -Not -Match 'Users\\\\Friend'
        $b.files[1].content | Should -Match '<!-- ram-doctor-report'
    }
    It 'sends "code" only when one is stored, and never prints it' {
        $d = New-ProfileDir; $secret = 'inv-Qw99Lm0pXz'
        $env = @{ RAMDOC_SHARE_NAME = 'Friend'; RAMDOC_SHARE_CODE = $secret }
        (Invoke-ShareCli -CliArgs @('-Action', 'SaveProfile', '-ProfileDir', ('"{0}"' -f $d)) -EnvVars $env).ExitCode | Should -Be 0
        $r = Invoke-Share $d $files.Plan
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -Match $secret
        ((@($Mock.State.Requests)[0].Body) | ConvertFrom-Json).code | Should -Be $secret
    }
    It 'keeps the host name only with -IncludeHostName' {
        $r = Invoke-Share $pd $files.Plan @('-IncludeHostName')
        $r.ExitCode | Should -Be 0
        ((@($Mock.State.Requests)[0].Body) | ConvertFrom-Json).host | Should -Be 'DESKTOP-DEMO'
    }
    It 'drops report.html when the body would exceed the size limit' {
        $d2 = Join-Path $TestDrive 'big'; New-Item -ItemType Directory -Force -Path $d2 | Out-Null
        $f2 = New-TestPlanFiles -Dir $d2 -Stamp '20260105-000000'
        [IO.File]::AppendAllText($f2.Html, ('<p>' + ('lorem ipsum dolor ' * 130000) + '</p>'), (New-Object System.Text.UTF8Encoding($true)))
        $r = Invoke-Share $pd $f2.Plan
        $r.ExitCode | Should -Be 0
        @(((@($Mock.State.Requests)[0].Body) | ConvertFrom-Json).files | ForEach-Object { $_.name }) | Should -Be @('summary.md', 'plan.json')
    }
    It 'DryRun builds everything but makes no request' {
        $r = Invoke-ShareCli -CliArgs @('-Action', 'Share', '-DryRun', '-ProfileDir', ('"{0}"' -f $pd), '-PlanPath', ('"{0}"' -f $files.Plan))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'RESULT: OK dryrun'
        $Mock.State.Requests.Count | Should -Be 0
    }
    It 'Health reaches the relay' {
        $r = Invoke-ShareCli -CliArgs @('-Action', 'Health', '-Endpoint', $Mock.Url)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'HEALTH: ok=true'
        @($Mock.State.Requests)[0].Path | Should -Be '/v1/health'
    }

    It 'maps <status> to "<code>" after exactly <calls> request(s)' -ForEach @(
        @{ status = '400'; code = '400'; calls = 1; text = 'غير صالحة' },
        @{ status = '413'; code = '413'; calls = 1; text = 'كبير' },
        @{ status = '429'; code = '429'; calls = 1; text = 'انتظر' },
        @{ status = '500'; code = '500'; calls = 3; text = 'لا تستجيب' }
    ) {
        $Mock.State.Mode = $status
        $r = Invoke-Share $pd $files.Plan
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match ('RESULT: ERROR ' + $code + ' .*' + $text)
        @($Mock.State.Requests | Where-Object Path -eq '/v1/reports').Count | Should -Be $calls
    }
    It '401 with a stored code says the code is wrong (no retry)' {
        $d = New-ProfileDir
        (Invoke-ShareCli -CliArgs @('-Action', 'SaveProfile', '-ProfileDir', ('"{0}"' -f $d)) -EnvVars @{ RAMDOC_SHARE_NAME = 'Friend'; RAMDOC_SHARE_CODE = 'wrong-code-1' }).ExitCode | Should -Be 0
        $Mock.State.Mode = '401'
        $r = Invoke-Share $d $files.Plan
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'RESULT: ERROR 401 رمز الدعوة غير صحيح'
        $Mock.State.Requests.Count | Should -Be 1
    }
    It '401 without a code tells the user the helper enabled an invite code' {
        $Mock.State.RequireCode = $true
        $r = Invoke-Share $pd $files.Plan
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'RESULT: ERROR 401 المساعد فعّل رمز دعوة؛ اطلبه منه'
        $Mock.State.Requests.Count | Should -Be 1
    }
    It 'sends the same requestId on every retry: a lost answer does not store the report twice (M5)' {
        $Mock.State.Mode = 'lostanswer'
        $r = Invoke-Share $pd $files.Plan
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'RESULT: OK https://'
        $r.Output | Should -Match 'already had this upload'
        $ids = @($Mock.State.Requests | Where-Object Path -eq '/v1/reports' | ForEach-Object { ($_.Body | ConvertFrom-Json).requestId })
        $ids.Count | Should -Be 2
        $ids[0] | Should -Match '^[A-Za-z0-9-]{16,64}$'
        $ids[1] | Should -Be $ids[0]
        $Mock.State.Commits.Count | Should -Be 1
    }
    It 'a new Share is a new upload with a new requestId' {
        (Invoke-Share $pd $files.Plan).ExitCode | Should -Be 0
        (Invoke-Share $pd $files.Plan).ExitCode | Should -Be 0
        $ids = @($Mock.State.Requests | ForEach-Object { ($_.Body | ConvertFrom-Json).requestId })
        $ids.Count | Should -Be 2
        $ids[1] | Should -Not -Be $ids[0]
        $Mock.State.Commits.Count | Should -Be 2
    }
    It '409 in_progress: waits Retry-After and asks again with the same requestId' {
        $Mock.State.Mode = 'inprogress'
        $r = Invoke-Share $pd $files.Plan
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $ids = @($Mock.State.Requests | Where-Object Path -eq '/v1/reports' | ForEach-Object { ($_.Body | ConvertFrom-Json).requestId })
        $ids.Count | Should -Be 2
        $ids[1] | Should -Be $ids[0]
        $Mock.State.Commits.Count | Should -Be 1
    }
    It 'a relay from before requestId (400 unknown_field) gets the same report once more without the field' {
        $Mock.State.Mode = 'oldrelay'
        $r = Invoke-Share $pd $files.Plan
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $bodies = @($Mock.State.Requests | Where-Object Path -eq '/v1/reports' | ForEach-Object { $_.Body | ConvertFrom-Json })
        $bodies.Count | Should -Be 2
        $bodies[0].PSObject.Properties.Name | Should -Contain 'requestId'
        $bodies[1].PSObject.Properties.Name | Should -Not -Contain 'requestId'
        $bodies[1].files.Count | Should -Be $bodies[0].files.Count
    }
    It 'recovers from transient 5xx (500, 500, then OK)' {
        $Mock.State.Mode = 'flaky'
        $r = Invoke-Share $pd $files.Plan
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'RESULT: OK https://'
        @($Mock.State.Requests | Where-Object Path -eq '/v1/reports').Count | Should -Be 3
    }
    It 'reports "offline" when nothing listens' {
        $r = Invoke-ShareCli -CliArgs @('-Action', 'Share', '-ProfileDir', ('"{0}"' -f $pd), '-PlanPath', ('"{0}"' -f $files.Plan), '-Endpoint', 'http://127.0.0.1:1', '-BackoffSeconds', '0')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'RESULT: ERROR offline .*الاتصال'
    }
    It 'stays dormant when the config names no endpoint' {
        $r = Invoke-ShareCli -CliArgs @('-Action', 'Share', '-ProfileDir', ('"{0}"' -f $pd), '-PlanPath', ('"{0}"' -f $files.Plan), '-ConfigPath', ('"{0}"' -f $script:EmptyCfg))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'RESULT: ERROR not-configured '
        $Mock.State.Requests.Count | Should -Be 0
    }
    It 'refuses plain http to a non-loopback host' {
        $r = Invoke-ShareCli -CliArgs @('-Action', 'Share', '-ProfileDir', ('"{0}"' -f $pd), '-PlanPath', ('"{0}"' -f $files.Plan), '-Endpoint', 'http://example.com')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'RESULT: ERROR insecure-endpoint '
    }
    It 'needs a profile and a plan' {
        (Invoke-Share (New-ProfileDir) $files.Plan).Output | Should -Match 'RESULT: ERROR no-profile '
        (Invoke-Share $pd (Join-Path $TestDrive 'missing.json')).Output | Should -Match 'RESULT: ERROR no-plan '
        $bad = Join-Path $TestDrive 'Plan-X-20260101-000000.json'; Set-Content -LiteralPath $bad -Value '{ nope'
        (Invoke-Share $pd $bad).Output | Should -Match 'RESULT: ERROR bad-plan '
    }
}

Describe 'CLI: English (-Lang en)' -Tag 'Integration' {
    BeforeAll {
        $script:enPd = Join-Path $TestDrive ('en-' + [guid]::NewGuid().ToString('N'))
        Save-TestProfile $script:enPd
        $script:enDir = Join-Path $TestDrive 'scan-en'; New-Item -ItemType Directory -Force -Path $script:enDir | Out-Null
        $script:enFiles = New-TestPlanFiles -Dir $script:enDir -Lang en
    }
    It 'answers profile errors in English' {
        $d = New-ProfileDir
        $r = Invoke-ShareCli -CliArgs @('-Action', 'SaveProfile', '-Username', 'a', '-ProfileDir', ('"{0}"' -f $d), '-Lang', 'en')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'RESULT: ERROR The username must be 2 to 24 characters long\.'
        [void](Invoke-ShareCli -CliArgs @('-Action', 'SaveProfile', '-Username', 'Friend', '-ProfileDir', ('"{0}"' -f $d), '-Lang', 'en'))
        $r2 = Invoke-ShareCli -CliArgs @('-Action', 'SaveProfile', '-Username', 'Other', '-ProfileDir', ('"{0}"' -f $d), '-Lang', 'en')
        $r2.Output | Should -Match 'RESULT: ERROR .*permanent'
        $r2.Output | Should -Not -Match '[؀-ۿ]'
    }
    It 'answers relay and setup errors in English' {
        Reset-Mock
        $Mock.State.Mode = '413'
        $r = Invoke-Share $script:enPd $script:enFiles.Plan @('-Lang', 'en')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'RESULT: ERROR 413 The report is too large to upload\.'
        $off = Invoke-ShareCli -CliArgs @('-Action', 'Share', '-ProfileDir', ('"{0}"' -f $script:enPd), '-PlanPath', ('"{0}"' -f $script:enFiles.Plan), '-Endpoint', 'http://127.0.0.1:1', '-BackoffSeconds', '0', '-Lang', 'en')
        $off.Output | Should -Match 'RESULT: ERROR offline Could not connect'
        (Invoke-ShareCli -CliArgs @('-Action', 'Share', '-ProfileDir', ('"{0}"' -f (New-ProfileDir)), '-PlanPath', ('"{0}"' -f $script:enFiles.Plan), '-Endpoint', $Mock.Url, '-Lang', 'en')).Output | Should -Match 'RESULT: ERROR no-profile Your profile has not been created yet'
        Reset-Mock
    }
    It 'an English plan uploads an English summary without a right-to-left block, and the report as it is' {
        Reset-Mock
        $r = Invoke-Share $script:enPd $script:enFiles.Plan @('-Lang', 'en')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'RESULT: OK https://'
        $body = (@($Mock.State.Requests | Where-Object Path -eq '/v1/reports'))[0].Body | ConvertFrom-Json
        $s = ($body.files | Where-Object name -eq 'summary.md').content
        $s | Should -Not -Match '<div dir="rtl">'
        $s | Should -Match '\*\*Most likely cause'
        $s | Should -Not -Match '[؀-ۿ]'
        (($body.files | Where-Object name -eq 'plan.json').content | ConvertFrom-Json).lang | Should -Be 'en'
    }
    It 'writes the short chat summary with English labels' {
        $pv = Join-Path $TestDrive 'sum-en'
        $r = Invoke-ShareCli -CliArgs @('-Action', 'Summary', '-PlanPath', ('"{0}"' -f $script:enFiles.Plan), '-PreviewDir', ('"{0}"' -f $pv), '-Lang', 'en')
        $r.ExitCode | Should -Be 0
        $text = [IO.File]::ReadAllText((Join-Path $pv 'summary.txt'), [Text.Encoding]::UTF8)
        $text | Should -Match 'RAM Doctor report'
        $text | Should -Match 'Verdict: Most likely cause'
        $text | Should -Match 'Suspicious files \(2\):'
        $text | Should -Not -Match '[؀-ۿ]'
        $text | Should -Not -Match 'Friend|DESKTOP-DEMO|abc123secret99|friend@example\.com'
    }
    It 'rejects a language other than ar or en' {
        (Invoke-ShareCli -CliArgs @('-Action', 'ShowProfile', '-ProfileDir', ('"{0}"' -f (New-ProfileDir)), '-Lang', 'fr')).ExitCode | Should -Not -Be 0
    }
}
