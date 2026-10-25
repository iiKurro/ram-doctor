# Pester 5 unit tests for src/lib/Share.ps1 (no network). Run:  Invoke-Pester tests\share\Share.Unit.Tests.ps1
# All data is synthetic ("Friend", "DESKTOP-DEMO"); real machine names are only built at run time.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $script:Repo 'src\lib\Share.ps1')
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    $script:ToolVersion = (Get-Content -LiteralPath (Join-Path $script:Repo 'build\VERSION') -Raw).Trim()




}

Describe 'Username validation' -Tag 'Unit' {
    It 'accepts <name>' -ForEach @(
        @{ name = 'Friend' }, @{ name = 'أحمد 7' }, @{ name = 'a_b-c' }, @{ name = 'محمد_العلي' }, @{ name = 'ab' }, @{ name = ('x' * 24) }
    ) { (Test-ShareUsername $name).Ok | Should -BeTrue }

    It 'rejects <why>' -ForEach @(
        @{ why = 'too short'; name = 'a' }, @{ why = 'too long'; name = ('x' * 25) }, @{ why = 'symbols'; name = 'bad@name' },
        @{ why = 'slash'; name = 'a/b' }, @{ why = 'only separators'; name = '--' }, @{ why = 'empty'; name = '' }, @{ why = 'emoji'; name = "ab$([char]::ConvertFromUtf32(0x1F600))" }
    ) { $r = Test-ShareUsername $name; $r.Ok | Should -BeFalse; $r.Error | Should -Not -BeNullOrEmpty }

    It 'normalises blanks (trim + collapse)' {
        (Test-ShareUsername '  Friend   Two ').Name | Should -Be 'Friend Two'
    }
}

Describe 'Folder slug' -Tag 'Unit' {
    It 'matches the relay rule (lower-case, runs of other chars -> single dash)' {
        ConvertTo-ShareSlug 'Friend Two_3' | Should -Be 'friend-two-3'
        ConvertTo-ShareSlug 'أحمد 7' | Should -Be 'أحمد-7'
        ConvertTo-ShareSlug '--' | Should -Be 'user'
    }
}

Describe 'Config and endpoint' -Tag 'Unit' {
    It 'shipped config is either dormant (empty endpoint) or names an https relay' {
        $cfg = Get-ShareConfig -Path (Join-Path $script:Repo 'src\share.config.json')
        $cfg.endpoint | Should -Match '^(|https://[A-Za-z0-9.-]+(/.*)?)$'
        $cfg.maxBytes | Should -Be 2000000
    }
    It 'missing/invalid config degrades to defaults' {
        (Get-ShareConfig -Path (Join-Path $TestDrive 'nope.json')).endpoint | Should -Be ''
        Set-Content -LiteralPath (Join-Path $TestDrive 'bad.json') -Value '{ not json'
        (Get-ShareConfig -Path (Join-Path $TestDrive 'bad.json')).helperName | Should -Be '7san'
    }
    It 'endpoint rules: <ep> -> <expected>' -ForEach @(
        @{ ep = ''; expected = 'not-configured' }, @{ ep = 'https://relay.example.workers.dev'; expected = $null },
        @{ ep = 'http://example.com'; expected = 'insecure-endpoint' }, @{ ep = 'http://127.0.0.1:8080'; expected = $null }, @{ ep = 'garbage'; expected = 'insecure-endpoint' }
    ) { Test-ShareEndpoint $ep | Should -Be $expected }
}

Describe 'Profile (name + fixed userId, optional DPAPI code)' -Tag 'Unit' {
    BeforeEach { $script:pd = Join-Path $TestDrive ('prof-' + [guid]::NewGuid().ToString('N')) }

    It 'creates a profile with only a username (no code)' {
        $r = Save-ShareProfile -Username 'Friend' -ProfileDir $pd
        $r.Ok | Should -BeTrue
        $r.Profile.userId | Should -Match '^[0-9a-f]{8}$'
        Get-ShareInviteCode -Profile $r.Profile | Should -BeNullOrEmpty
        (Get-Content (Join-Path $pd 'profile.json') -Raw) | Should -Not -Match '"code":\s*"[^"]'
    }
    It 'keeps the userId fixed and refuses renaming' {
        $a = (Save-ShareProfile -Username 'Friend' -ProfileDir $pd).Profile
        (Save-ShareProfile -Username 'Friend' -ProfileDir $pd).Profile.userId | Should -Be $a.userId
        $r = Save-ShareProfile -Username 'Other' -ProfileDir $pd
        $r.Ok | Should -BeFalse
        $r.Error | Should -Be (Get-ShareMessage 'name-fixed')
        (Get-ShareProfile -ProfileDir $pd).displayName | Should -Be 'Friend'
    }
    It 'stores an optional invite code with DPAPI (never plain text) and round-trips it' {
        $code = 'inv-' + (New-RandWord 'k' 10)
        $r = Save-ShareProfile -Username 'أحمد 7' -Code $code -ProfileDir $pd
        $r.Ok | Should -BeTrue
        (Get-Content (Join-Path $pd 'profile.json') -Raw -Encoding UTF8) | Should -Not -Match ([regex]::Escape($code))
        Get-ShareInviteCode -Profile (Get-ShareProfile -ProfileDir $pd) | Should -Be $code
        (Get-ShareProfile -ProfileDir $pd).displayName | Should -Be 'أحمد 7'
    }
    It 'saving again without a code keeps the stored code; with a code replaces it' {
        [void](Save-ShareProfile -Username 'Friend' -Code 'first-code' -ProfileDir $pd)
        [void](Save-ShareProfile -Username 'Friend' -ProfileDir $pd)
        Get-ShareInviteCode -Profile (Get-ShareProfile -ProfileDir $pd) | Should -Be 'first-code'
        [void](Save-ShareProfile -Username 'Friend' -Code 'second-code' -ProfileDir $pd)
        Get-ShareInviteCode -Profile (Get-ShareProfile -ProfileDir $pd) | Should -Be 'second-code'
    }
    It 'rejects a malformed code but never demands one' {
        (Save-ShareProfile -Username 'Friend' -Code 'a b' -ProfileDir $pd).Ok | Should -BeFalse
        (Save-ShareProfile -Username 'Friend' -Code 'abc' -ProfileDir $pd).Ok | Should -BeFalse
        (Save-ShareProfile -Username 'x' -ProfileDir $pd).Ok | Should -BeFalse
    }
    It 'delete removes the profile; a new one gets a new userId' {
        $a = (Save-ShareProfile -Username 'Friend' -ProfileDir $pd).Profile.userId
        Remove-ShareProfile -ProfileDir $pd
        Get-ShareProfile -ProfileDir $pd | Should -BeNullOrEmpty
        $b = (Save-ShareProfile -Username 'Friend' -ProfileDir $pd).Profile.userId
        $b | Should -Match '^[0-9a-f]{8}$'
    }
}

Describe 'Redaction rules' -Tag 'Unit' {
    BeforeAll { $script:R = New-ShareRedactor -NoAutoDetect -UserNames 'Friend' -ComputerName 'DESKTOP-DEMO' }

    It 'masks profile paths in every spelling, keeps Public/Default' {
        Protect-Text 'C:\Users\Friend\AppData\Local\Temp\x.exe' $R | Should -Be 'C:\Users\<USER>\AppData\Local\Temp\x.exe'
        Protect-Text 'C:\\Users\\Friend\\x' $R | Should -Be 'C:\\Users\\<USER>\\x'
        Protect-Text 'C:/Users/Friend/x' $R | Should -Be 'C:/Users/<USER>/x'
        Protect-Text 'C:\Users\Public\Documents' $R | Should -Be 'C:\Users\Public\Documents'
        Protect-Text '\Device\HarddiskVolume3\Users\Jane Doe\x' $R | Should -Be '\Device\HarddiskVolume3\Users\<USER>\x'
    }
    It 'masks the account name and the computer name as whole words only' {
        Protect-Text 'owner Friend on DESKTOP-DEMO' $R | Should -Be 'owner <USER> on <PC>'
        Protect-Text 'Friendly neighbours' $R | Should -Be 'Friendly neighbours'
        Protect-Text 'RAMDoctor-DESKTOP-DEMO-20260101-120000.html' $R | Should -Be 'RAMDoctor-<PC>-20260101-120000.html'
    }
    It 'keeps the computer name when asked' {
        $keep = New-ShareRedactor -NoAutoDetect -ComputerName 'DESKTOP-DEMO' -IncludeHostName
        Protect-Text 'on DESKTOP-DEMO' $keep | Should -Be 'on DESKTOP-DEMO'
    }
    It 'discovers every name seen under \Users\ in the text' {
        $r2 = New-ShareRedactor -NoAutoDetect -DiscoverFrom @('C:\Users\Zed Quux\a and D:\Users\Mallory2\b')
        Protect-Text 'Zed Quux ran Mallory2.exe' $r2 | Should -Be '<USER> ran <USER>.exe'
    }
    It 'masks e-mails, SIDs, OneDrive org names' {
        Protect-Text 'mail a.b+c@example.co.uk now' $R | Should -Be 'mail <EMAIL> now'
        Protect-Text 'HKEY_USERS\S-1-5-21-1111-2222-3333-1001\Run' $R | Should -Be 'HKEY_USERS\<SID>\Run'
        Protect-Text 'C:\Users\Friend\OneDrive - Contoso Ltd\a' $R | Should -Be 'C:\Users\<USER>\OneDrive - <ORG>\a'
    }
    It 'masks secrets: <case>' -ForEach @(
        @{ case = '--token VALUE'; text = 'tool.exe --token s3cr3tVALUE1 --x'; secret = 's3cr3tVALUE1' },
        @{ case = 'password=VALUE'; text = 'password=hunter2hunter2 next'; secret = 'hunter2hunter2' },
        @{ case = 'env style API_KEY_21ST'; text = 'API_KEY_21ST=abcDEF123456'; secret = 'abcDEF123456' },
        @{ case = 'x-api-key header'; text = 'curl --header x-api-key:ZZtop998877 http://h'; secret = 'ZZtop998877' },
        @{ case = 'Authorization Bearer'; text = 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig'; secret = 'eyJhbGciOiJIUzI1NiJ9' } # allow-secret-scan (fake value for tests),
        @{ case = 'long bearer token'; text = 'sent bearer abcdefghijklmnopqrstuvwx now'; secret = 'abcdefghijklmnopqrstuvwx' },
        @{ case = 'quoted secret'; text = 'secret="top secret value" end'; secret = 'top secret value' },
        @{ case = 'html-escaped quotes'; text = 'secret=&quot;top secret value&quot; end'; secret = 'top secret value' },
        @{ case = 'URL user:pass@'; text = 'https://bob:p4ssw0rdX@example.org/path'; secret = 'p4ssw0rdX' },
        @{ case = 'query token'; text = 'GET /x?id=1&token=QQQ111222&y=2'; secret = 'QQQ111222' },
        @{ case = 'query token after &amp;'; text = '/x?id=1&amp;token=QQQ111222&amp;y=2'; secret = 'QQQ111222' },
        @{ case = '-EncodedCommand'; text = 'powershell -EncodedCommand ' + ('QUJDREVGR0hJSktM' * 3); secret = 'QUJDREVGR0hJSktM' },
        @{ case = '-enc'; text = 'powershell -NoP -enc ' + ('SGVsbG8gV29ybGQh' * 3) + ' -x'; secret = 'SGVsbG8gV29ybGQh' },
        @{ case = 'long base64 blob'; text = 'blob ' + ('A1b2' * 40) + ' end'; secret = 'A1b2A1b2A1b2' }
    ) {
        $out = Protect-Text $text $R
        $out | Should -Not -Match ([regex]::Escape($secret))
        $out | Should -Match 'REDACTED|BASE64'
    }
    It 'keeps what the helper needs' {
        $sha = ('0123456789abcdef' * 4)
        $t = "sha256 $sha ip 8.8.8.8 and 203.0.113.7:3333 driver netflt64.sys tag EtwB risk High svchost.exe"
        Protect-Text $t $R | Should -Be $t
    }
    It 'is idempotent' {
        $t = 'C:\Users\Friend\a --token abc12345 DESKTOP-DEMO a@b.org https://u:p@h.com/?token=zzz'
        $once = Protect-Text $t $R
        Protect-Text $once $R | Should -Be $once
    }
    It 'handles null/empty' {
        Protect-Text '' $R | Should -Be ''
        Protect-Text $null $R | Should -BeNullOrEmpty
    }
    It 'masks the real account and computer names of THIS machine (built at run time)' {
        $u = $env:USERNAME; $pc = $env:COMPUTERNAME
        if (-not $u -or $u.Length -lt 3 -or ($script:ShareGenericNames -contains $u.ToLowerInvariant())) { Set-ItResult -Skipped -Because 'account name too generic to test'; return }
        $t = "C:\Users\$u\x and $u logged on $pc"
        $out = Protect-Text $t
        $out | Should -Not -Match ('(?i)' + [regex]::Escape($u))
        $out | Should -Not -Match ('(?i)' + [regex]::Escape($pc))
    }
}

Describe 'Redaction property test (random synthetic secrets)' -Tag 'Unit' {
    It 'never lets generated names/secrets through, never touches hashes/IPs/drivers/tags (200 rounds)' {
        $null = Get-Random -SetSeed 20260101
        $sha = ('9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08')
        for ($i = 0; $i -lt 200; $i++) {
            $u = New-RandWord 'u' 7; $pc = New-RandWord 'DESKTOP-' 6; $s1 = New-RandWord 's' 12; $s2 = New-RandWord 'p' 10
            $s3 = New-RandWord 'w' 9; $s4 = New-RandWord 'q' 14; $s5 = New-RandWord 'b' 22; $mailUser = New-RandWord 'm' 6
            $b64 = -join ((1..60) | ForEach-Object { 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123456789'[(Get-Random -Maximum 42)] })
            $text = @(
                "C:\Users\$u\AppData\Local\Temp\$u-tool.exe",
                "\\$pc\share and $pc.local",
                "app.exe --token $s1 --password $s2",
                "https://$u`:$s3@example.org/p?token=$s4&x=1",
                "Authorization: Bearer $s5",
                "powershell -enc $b64",
                "mail $mailUser@example.com",
                "sha256 $sha ip 8.8.8.8 driver netflt64.sys tag EtwB"
            ) -join "`r`n"
            $r = New-ShareRedactor -NoAutoDetect -UserNames $u -ComputerName $pc
            $out = Protect-Text $text $r
            foreach ($secret in @($u, $pc, $s1, $s2, $s3, $s4, $s5, $b64, $mailUser)) {
                if ($out.IndexOf($secret, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "round ${i}: leaked '$secret' in:`n$out" }
            }
            foreach ($keep in @($sha, '8.8.8.8', 'netflt64.sys', 'EtwB')) { if ($out.IndexOf($keep) -lt 0) { throw "round ${i}: lost '$keep'" } }
        }
    }
}

Describe 'Redaction of JSON and HTML' -Tag 'Unit' {
    BeforeAll { $script:R = New-ShareRedactor -NoAutoDetect -UserNames 'Friend' -ComputerName 'DESKTOP-DEMO' }

    It 'keeps JSON valid, arrays as arrays, numbers and booleans' {
        $j = '{"host":"DESKTOP-DEMO","one":["C:\\Users\\Friend\\a"],"none":[],"n":3,"b":true,"nested":{"cmd":"x --token abc12345"}}'
        $out = Protect-ShareJson -Json $j -Redactor $R
        $o = $out | ConvertFrom-Json
        $o.host | Should -Be '<PC>'
        @($o.one).Count | Should -Be 1
        $o.one[0] | Should -Be 'C:\Users\<USER>\a'
        @($o.none).Count | Should -Be 0
        $o.n | Should -Be 3
        $o.b | Should -BeTrue
        $o.nested.cmd | Should -Match 'REDACTED'
        $out | Should -Match '"one":\s*\['
    }
    It 'passes <script>, <style> and the ram-doctor-report marker through byte for byte' {
        $files = New-TestPlanFiles -Dir $TestDrive -Stamp '20260102-000000'
        $raw = Get-Content -LiteralPath $files.Html -Raw -Encoding UTF8
        $out = Protect-Html -Html $raw -Redactor $R
        $out | Should -Match '<!-- ram-doctor-report v1\.0\.0 host=<PC> -->'
        $out | Should -Match ([regex]::Escape($files.Script))
        $out | Should -Match '<style>\.card\{color:#1a1a1a\} /\* Friend \*/</style>'
        # visible text IS redacted
        $out | Should -Match 'الجهاز: <b><PC></b>'
        $out | Should -Not -Match 'abc123secret99'
        $out | Should -Not -Match 'hunter2'
        $out | Should -Not -Match 'friend@example\.com'
        $out | Should -Match $files.Sha
    }
    It 'the marker survives even if the account is called "report" or "doctor"' {
        $r3 = New-ShareRedactor -NoAutoDetect -UserNames 'report', 'doctor'
        $h = '<!-- ram-doctor-report v1 --><p>doctor report for report</p><script>var report=1;</script>'
        $o = Protect-Html -Html $h -Redactor $r3
        $o | Should -Match '^<!-- ram-doctor-report v1 -->'
        $o | Should -Match '<script>var report=1;</script>'
        $o | Should -Match '<p><USER> <USER> for <USER></p>'
    }
}

Describe 'Bundle and summary.md' -Tag 'Unit' {
    BeforeAll {
        $script:dir = Join-Path $TestDrive 'bundle'; New-Item -ItemType Directory -Force -Path $script:dir | Out-Null
        $script:files = New-TestPlanFiles -Dir $script:dir
        $script:profile = [pscustomobject]@{ displayName = 'Friend'; userId = 'a1b2c3d4' }
        $script:bundle = New-ShareBundle -PlanPath $files.Plan -Profile $profile
    }
    It 'has exactly the three whitelisted files' {
        @($bundle.Files | ForEach-Object { $_.name }) | Should -Be @('summary.md', 'report.html', 'plan.json')
    }
    It 'redacts the host by default and keeps it with -IncludeHostName' {
        $bundle.Host | Should -Be '<PC>'
        (New-ShareBundle -PlanPath $files.Plan -Profile $profile -IncludeHostName).Host | Should -Be 'DESKTOP-DEMO'
    }
    It 'plan.json is valid JSON, redacted, same schema' {
        $p = ($bundle.Files | Where-Object name -eq 'plan.json').content | ConvertFrom-Json
        $p.host | Should -Be '<PC>'
        $p.verdict.Level | Should -Be 'high'
        @($p.suspects).Count | Should -Be 2
        $p.suspects[0].path | Should -Be 'C:\Users\<USER>\AppData\Local\Temp\svch0st.exe'
        $p.suspects[0].sha256 | Should -Be $files.Sha
        ($bundle.Files | Where-Object name -eq 'plan.json').content | Should -Not -Match 'abc123secret99|SECRET123XYZ|friend@example\.com|S-1-5-21-1111'
    }
    It 'summary.md: RTL blocks, verdict, memory, suspects, VirusTotal link, profile' {
        $s = ($bundle.Files | Where-Object name -eq 'summary.md').content
        $s | Should -Match '# RAM Doctor report - Friend \(a1b2c3d4\)'
        $s | Should -Match '<div dir="rtl">'
        $s | Should -Match 'تسرّب ذاكرة في تعريف'
        $s | Should -Match '\| Kernel non-paged pool \| 9\.6 \|'
        $s | Should -Match ('https://www\.virustotal\.com/gui/file/' + $files.Sha)
        $s | Should -Match 'svch0st\.exe'
        $s | Should -Match 'Unsigned'
        $s | Should -Not -Match 'Friend\\|DESKTOP-DEMO|abc123secret99|friend@example\.com'
    }
    It 'report.html keeps the marker and the script' {
        $h = ($bundle.Files | Where-Object name -eq 'report.html').content
        $h | Should -Match '<!-- ram-doctor-report'
        $h | Should -Match ([regex]::Escape($files.Script))
    }
    It 'bad plan files fail with a stable key' {
        $bad = Join-Path $TestDrive 'Plan-X-20260101-000000.json'; Set-Content -LiteralPath $bad -Value '{ nope'
        { New-ShareBundle -PlanPath $bad -Profile $profile } | Should -Throw 'bad-plan'
        { New-ShareBundle -PlanPath (Join-Path $TestDrive 'missing.json') -Profile $profile } | Should -Throw 'no-plan'
    }
}

Describe 'Short chat summary (offline)' -Tag 'Unit' {
    BeforeAll {
        $script:dir2 = Join-Path $TestDrive 'short'; New-Item -ItemType Directory -Force -Path $script:dir2 | Out-Null
        $script:f2 = New-TestPlanFiles -Dir $script:dir2
        $script:big = New-TestPlanFiles -Dir $script:dir2 -Stamp '20260103-000000' -ManySuspects 14
    }
    It 'contains the essentials, in Arabic with English terms' {
        $t = New-ShareShortSummary -PlanPath $f2.Plan
        $t | Should -Match 'تقرير RAM Doctor'
        $t | Should -Match 'الحكم: السبب الأرجح'
        $t | Should -Match 'الذاكرة: مستخدم 14\.2/15\.84 GB \| Non-paged 9\.6 GB \| Paged 0\.8 GB \| غير منسوبة 0\.2 GB'
        $t | Should -Match 'أهم الملاحظات:'
        $t | Should -Match 'ملفات مشبوهة \(2\):'
        $t | Should -Match '\[عالٍ\] svch0st\.exe \(Unsigned\)'
        $t | Should -Match ('sha256:' + $f2.Sha.Substring(0, 12))
        $t | Should -Not -Match ($f2.Sha)           # only the short prefix
        $t | Should -Match ('RAM-Doctor ' + [regex]::Escape($script:ToolVersion) + ' \| وقت الفحص: 2026-01-01 12:00:00')
    }
    It 'omits info-level observations and the host unless asked' {
        $t = New-ShareShortSummary -PlanPath $f2.Plan
        $t | Should -Not -Match 'ذاكرة التخزين المؤقت'
        $t | Should -Not -Match 'DESKTOP-DEMO|الجهاز:'
        (New-ShareShortSummary -PlanPath $f2.Plan -IncludeHostName) | Should -Match 'الجهاز: DESKTOP-DEMO'
    }
    It 'applies the same redaction (paths, emails, secrets, host)' {
        $t = New-ShareShortSummary -PlanPath $f2.Plan
        $t | Should -Not -Match 'Friend|abc123secret99|friend@example\.com|SECRET123XYZ|DESKTOP-DEMO'
    }
    It 'respects the length cap even with many long suspects/observations' {
        $t = New-ShareShortSummary -PlanPath $big.Plan
        $t.Length | Should -BeLessOrEqual 1500
        $t | Should -Match 'تقرير RAM Doctor'
        $t | Should -Match ('RAM-Doctor ' + [regex]::Escape($script:ToolVersion))
    }
    It 'honours a smaller -MaxChars' {
        (New-ShareShortSummary -PlanPath $big.Plan -MaxChars 600).Length | Should -BeLessOrEqual 600
    }
    It 'says so when there are no suspects' {
        $p = Get-Content $f2.Plan -Raw -Encoding UTF8 | ConvertFrom-Json
        $p.suspects = @()
        $np = Join-Path $script:dir2 'Plan-DESKTOP-DEMO-20260104-000000.json'
        [IO.File]::WriteAllText($np, ($p | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
        (New-ShareShortSummary -PlanPath $np) | Should -Match 'ملفات مشبوهة: لا يوجد'
    }
}

Describe 'Languages (Arabic and English)' -Tag 'Unit' {
    BeforeAll {
        $script:dir3 = Join-Path $TestDrive 'lang'; New-Item -ItemType Directory -Force -Path $script:dir3 | Out-Null
        $script:enPlan = New-TestPlanFiles -Dir $script:dir3 -Lang en
        $script:arPlan = New-TestPlanFiles -Dir $script:dir3 -Stamp '20260102-120000' -Lang ar
        $script:legacy = New-TestPlanFiles -Dir $script:dir3 -Stamp '20260103-120000'
    }
    It 'the message <key> exists in both languages and is really translated' -ForEach @(
        @{ key = 'not-configured' }, @{ key = 'insecure-endpoint' }, @{ key = 'no-profile' }, @{ key = 'no-plan' }, @{ key = 'bad-plan' },
        @{ key = '400' }, @{ key = '401' }, @{ key = '401-nocode' }, @{ key = '413' }, @{ key = '429' }, @{ key = '5xx' }, @{ key = 'offline' },
        @{ key = 'bad-response' }, @{ key = 'name-length' }, @{ key = 'name-chars' }, @{ key = 'code-invalid' }, @{ key = 'name-fixed' },
        @{ key = 'code-unreadable' }, @{ key = 'profile-write' }
    ) {
        $ar = Get-ShareMessage $key -Lang ar
        $en = Get-ShareMessage $key -Lang en
        $ar | Should -Not -Be $key
        $en | Should -Not -Be $key
        $ar | Should -Match '[؀-ۿ]'
        $en | Should -Not -Match '[؀-ۿ]'
    }
    It 'an unknown key comes back unchanged, in either language' {
        Get-ShareMessage 'zzz-unknown' -Lang en | Should -Be 'zzz-unknown'
        Get-ShareMessage 'zzz-unknown' -Lang ar | Should -Be 'zzz-unknown'
    }
    It 'messages follow the language chosen with Set-UiLang' {
        $was = Get-UiLang
        try {
            Set-UiLang 'en'; (Test-ShareUsername 'a').Error | Should -Match '^The username must be 2 to 24'
            Set-UiLang 'ar'; (Test-ShareUsername 'a').Error | Should -Match 'حرفين'
        } finally { Set-UiLang $was }
    }
    It 'a plan decides the language of its own texts: lang field, -Lang override, Arabic for older plans' {
        (New-ShareShortSummary -PlanPath $script:enPlan.Plan) | Should -Match '^RAM Doctor report'
        (New-ShareShortSummary -PlanPath $script:arPlan.Plan) | Should -Match '^تقرير RAM Doctor'
        (New-ShareShortSummary -PlanPath $script:legacy.Plan) | Should -Match '^تقرير RAM Doctor'
        (New-ShareShortSummary -PlanPath $script:legacy.Plan -Lang en) | Should -Match '^RAM Doctor report'
        (New-ShareShortSummary -PlanPath $script:enPlan.Plan -Lang ar) | Should -Match '^تقرير RAM Doctor'
    }
    It 'the English short summary has English labels only, keeps the redaction and the length cap' {
        $t = New-ShareShortSummary -PlanPath $script:enPlan.Plan
        $t | Should -Match 'Verdict: Most likely cause: a memory leak in a kernel-level driver'
        $t | Should -Match 'Memory: 14\.2/15\.84 GB used \| Non-paged 9\.6 GB \| Paged 0\.8 GB \| Unattributed 0\.2 GB'
        $t | Should -Match 'Top notes:'
        $t | Should -Match 'Suspicious files \(2\):'
        $t | Should -Match '\[High\] svch0st\.exe \(Unsigned\)'
        $t | Should -Match ('RAM-Doctor ' + [regex]::Escape($script:ToolVersion) + ' \| Scan time: 2026-01-01 12:00:00')
        $t | Should -Not -Match '[؀-ۿ]'
        $t | Should -Not -Match 'Friend|abc123secret99|friend@example\.com|SECRET123XYZ|DESKTOP-DEMO'
        $t.Length | Should -BeLessOrEqual 1500
        (New-ShareShortSummary -PlanPath $script:enPlan.Plan -IncludeHostName) | Should -Match 'Computer: DESKTOP-DEMO'
    }
    It 'summary.md: Arabic plans keep the right-to-left blocks, English plans have none (the relay would show them as text)' {
        $prof = [pscustomobject]@{ displayName = 'Friend'; userId = 'a1b2c3d4' }
        $en = (New-ShareBundle -PlanPath $script:enPlan.Plan -Profile $prof).Files | Where-Object name -eq 'summary.md'
        $en.content | Should -Not -Match 'dir="rtl"'
        $en.content | Should -Match '\*\*Most likely cause'
        $en.content | Should -Not -Match '[؀-ۿ]'
        $ar = (New-ShareBundle -PlanPath $script:arPlan.Plan -Profile $prof).Files | Where-Object name -eq 'summary.md'
        $ar.content | Should -Match '<div dir="rtl">'
    }
    It 'the language field survives the redaction into plan.json' {
        $prof = [pscustomobject]@{ displayName = 'Friend'; userId = 'a1b2c3d4' }
        $pj = ((New-ShareBundle -PlanPath $script:enPlan.Plan -Profile $prof).Files | Where-Object name -eq 'plan.json').content | ConvertFrom-Json
        $pj.lang | Should -Be 'en'
    }
}

Describe 'Where the memory is: the breakdown lines of the summaries' -Tag 'Unit' {
    BeforeAll {
        $script:dir5 = Join-Path $TestDrive 'breakdown'; New-Item -ItemType Directory -Force -Path $script:dir5 | Out-Null
        $script:bdEn = New-TestPlanFiles -Dir $script:dir5 -Lang en -Breakdown
        $script:bdAr = New-TestPlanFiles -Dir $script:dir5 -Stamp '20260102-120000' -Lang ar -Breakdown
        $script:noBd = New-TestPlanFiles -Dir $script:dir5 -Stamp '20260103-120000' -Lang en
        $script:prof5 = [pscustomobject]@{ displayName = 'Friend'; userId = 'a1b2c3d4' }
    }
    It 'the copied summary explains in numbers what Task Manager does not show (English)' {
        $t = New-ShareShortSummary -PlanPath $script:bdEn.Plan
        $t | Should -Match 'Not shown by Task Manager: 9\.63 GB = shared memory of programs ~4\.47 GB \+ reserved by drivers 2\.26 GB \+ Windows kernel 2\.07 GB \+ cache and other 0\.83 GB'
        $t | Should -Match 'Biggest users of shared memory: brave\.exe \(32 processes\) 5\.12 GB'
        $t | Should -Match 'Unattributed 2\.26 GB'          # the corrected value, not the 0 of the old formula
        $t | Should -Not -Match '[؀-ۿ]'
        $t.Length | Should -BeLessOrEqual 1500
    }
    It 'the copied summary says the same in Arabic' {
        $t = New-ShareShortSummary -PlanPath $script:bdAr.Plan
        $t | Should -Match ([regex]::Escape((Get-Text 'sum.hidden' '9.63' '4.47' '2.26' '2.07' '0.83' -Lang ar)))
        $t | Should -Match ([regex]::Escape((Get-Text 'sum.shared.item' 'brave.exe' 32 '5.12' -Lang ar)))
    }
    It 'keeps the redaction: a program name that carries the user name is masked' {
        $t = New-ShareShortSummary -PlanPath $script:bdEn.Plan
        $t | Should -Match '<USER>-sync\.exe'
        $t | Should -Not -Match 'Friend|DESKTOP-DEMO'
    }
    It 'plans of older releases get no breakdown line and keep their old value' {
        $t = New-ShareShortSummary -PlanPath $script:noBd.Plan
        $t | Should -Not -Match 'Not shown by Task Manager'
        $t | Should -Match 'Unattributed 0\.2 GB'
        @(Get-HiddenMemoryLines -Memory ((Get-Content $script:noBd.Plan -Raw -Encoding UTF8 | ConvertFrom-Json).memory)).Count | Should -Be 0
        @(Get-HiddenMemoryLines -Memory $null).Count | Should -Be 0
    }
    It 'says when the driver reservations could not be measured' {
        $p = Get-Content $script:bdEn.Plan -Raw -Encoding UTF8 | ConvertFrom-Json
        $p.memory.DriverReservedKnown = $false
        (@(Get-HiddenMemoryLines -Memory $p.memory -Lang en))[0] | Should -Match 'not measured: scan as administrator'
        $p.memory.UnexplainedGB = 1.5
        (@(Get-HiddenMemoryLines -Memory $p.memory -Lang en))[0] | Should -Match '\+ not explained 1\.5 GB'
    }
    It 'summary.md has a table of the hidden memory, the biggest shared-memory users and the candidate drivers' {
        $md = ((New-ShareBundle -PlanPath $script:bdEn.Plan -Profile $script:prof5).Files | Where-Object name -eq 'summary.md').content
        $md | Should -Match '## Where the memory is that Task Manager does not show'
        $md | Should -Match '\| Not shown by Task Manager \(used minus private\) \| 9\.63 \|'
        $md | Should -Match '\| Shared memory of open programs \(estimate, each page once\) \| 4\.47 \|'
        $md | Should -Match '\| Reserved by hardware drivers \(contiguous, pool tag ConT\) \| 2\.26 \|'
        $md | Should -Match '\| Not attributed to any process \| 2\.26 \|'
        $md | Should -Match 'brave\.exe \(32 processes\) 5\.12 GB'
        $md | Should -Match 'candidate drivers \(the tag cannot name the driver\): NVIDIA GeForce RTX 4070, Parsec Virtual Display Adapter, amdkmdag\.sys'
        $md | Should -Match '<USER>-sync\.exe'
        $md | Should -Not -Match 'Friend-sync|DESKTOP-DEMO'
    }
    It 'summary.md of an older plan has no breakdown table and the old "not attributed" value' {
        $md = ((New-ShareBundle -PlanPath $script:noBd.Plan -Profile $script:prof5).Files | Where-Object name -eq 'summary.md').content
        $md | Should -Not -Match 'Where the memory is'
        $md | Should -Match '\| Not attributed to any process \| 0\.2 \|'
    }
}

Describe 'Request body' -Tag 'Unit' {
    It 'follows protocol v1 and omits "code" when none is stored' {
        $d = Join-Path $TestDrive 'req'; New-Item -ItemType Directory -Force -Path $d | Out-Null
        $f = New-TestPlanFiles -Dir $d
        $b = New-ShareBundle -PlanPath $f.Plan -Profile ([pscustomobject]@{ displayName = 'Friend'; userId = 'a1b2c3d4' })
        $j = New-ShareRequestJson -Profile ([pscustomobject]@{ displayName = 'Friend'; userId = 'a1b2c3d4' }) -Bundle $b
        $o = $j | ConvertFrom-Json
        $o.v | Should -Be 1
        $o.displayName | Should -Be 'Friend'
        $o.userId | Should -Be 'a1b2c3d4'
        $o.PSObject.Properties.Name | Should -Not -Contain 'code'
        $o.tool.name | Should -Be 'RAM-Doctor'
        $o.createdAt | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        $o.host | Should -Be '<PC>'
        @($o.files | ForEach-Object { $_.name }) | Should -Be @('summary.md', 'report.html', 'plan.json')
        $o2 = (New-ShareRequestJson -Profile ([pscustomobject]@{ displayName = 'Friend'; userId = 'a1b2c3d4' }) -Code 'inv-123456' -Bundle $b) | ConvertFrom-Json
        $o2.code | Should -Be 'inv-123456'
    }
    It 'carries a requestId (the relay format: 16-64 of A-Z a-z 0-9 -), new for every upload, or the one given' {
        $d = Join-Path $TestDrive 'reqid'; New-Item -ItemType Directory -Force -Path $d | Out-Null
        $f = New-TestPlanFiles -Dir $d
        $p = [pscustomobject]@{ displayName = 'Friend'; userId = 'a1b2c3d4' }
        $b = New-ShareBundle -PlanPath $f.Plan -Profile $p
        $a = (New-ShareRequestJson -Profile $p -Bundle $b) | ConvertFrom-Json
        $a.requestId | Should -Match '^[A-Za-z0-9-]{16,64}$'
        ((New-ShareRequestJson -Profile $p -Bundle $b) | ConvertFrom-Json).requestId | Should -Not -Be $a.requestId
        ((New-ShareRequestJson -Profile $p -Bundle $b -RequestId 'fixed-0123456789abcdef') | ConvertFrom-Json).requestId | Should -Be 'fixed-0123456789abcdef'
        $a.PSObject.Properties.Name | Should -Be @('v', 'displayName', 'userId', 'requestId', 'tool', 'createdAt', 'host', 'files')
    }
}

Describe 'Profile file: crash-safe and damage-aware (M4)' -Tag 'Unit' {
    BeforeEach { $script:pd2 = Join-Path $TestDrive ('pd-' + [guid]::NewGuid().ToString('N')) }
    It 'is written with a schema field and its previous version is kept as profile.json.bak' {
        [void](Save-ShareProfile -Username 'Friend' -ProfileDir $pd2)
        [void](Save-ShareProfile -Username 'Friend' -Code 'code-1234' -ProfileDir $pd2)
        (Get-Content (Join-Path $pd2 'profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json).schema | Should -Be 1
        Test-Path (Join-Path $pd2 'profile.json.bak') | Should -BeTrue
    }
    It 'reads a 1.0.x profile (no schema field)' {
        New-Item -ItemType Directory -Force -Path $pd2 | Out-Null
        [IO.File]::WriteAllText((Join-Path $pd2 'profile.json'), '{ "v": 1, "displayName": "Friend", "userId": "0a1b2c3d", "createdAt": "2026-10-01T10:00:00Z", "code": "" }', (New-Object Text.UTF8Encoding($true)))
        (Get-ShareProfile -ProfileDir $pd2).userId | Should -Be '0a1b2c3d'
        (Get-ShareProfileState -ProfileDir $pd2).Status | Should -Be 'Ok'
    }
    It 'a damaged profile is reported as Damaged (not as "no profile"), and a new one keeps the old userId' {
        New-Item -ItemType Directory -Force -Path $pd2 | Out-Null
        [IO.File]::WriteAllText((Join-Path $pd2 'profile.json'), '{ "v": 1, "displayName": "Friend", "userId": "0a1b2c3d", "crea', (New-Object Text.UTF8Encoding($true)))
        $st = Get-ShareProfileState -ProfileDir $pd2
        $st.Status | Should -Be 'Damaged'
        $st.Profile | Should -BeNullOrEmpty
        (Get-ShareProfileState -ProfileDir $pd2).Status | Should -Be 'Damaged' -Because 'it stays damaged until a new profile is saved'
        $r = Save-ShareProfile -Username 'Friend' -ProfileDir $pd2
        $r.Ok | Should -BeTrue
        $r.Profile.userId | Should -Be '0a1b2c3d'
        (Get-ShareProfileState -ProfileDir $pd2).Status | Should -Be 'Ok'
    }
    It 'delete removes the profile, its backup and the damaged copies (the user asked for their data to go)' {
        [void](Save-ShareProfile -Username 'Friend' -ProfileDir $pd2)
        [void](Save-ShareProfile -Username 'Friend' -ProfileDir $pd2)
        [IO.File]::WriteAllText((Join-Path $pd2 'profile.json.damaged-20261025-101500'), 'x')
        [IO.File]::WriteAllText((Join-Path $pd2 'other.txt'), 'not ours')
        Remove-ShareProfile -ProfileDir $pd2
        @(Get-ChildItem $pd2 -File | ForEach-Object Name) | Should -Be @('other.txt')
    }
}
