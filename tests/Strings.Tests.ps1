#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# The one string table (src\lib\Strings.ps1): Arabic and English must stay in step, and nothing user-facing may live anywhere else.
# ASCII only (Arabic is matched by code point).

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $script:Root = Get-RepoRoot
    . (Join-Path $script:Root 'src\lib\Strings.ps1')
    $script:Ar = $script:RdText['ar']
    $script:En = $script:RdText['en']
    $script:ArabicRx = '[\u0600-\u06FF]'
    # keys whose English text is Arabic on purpose: the language button names the language it switches TO
    $script:ArabicInEnglish = @('gui.lang.other', 'gui.lang.tip')
    # keys whose Arabic text is Latin on purpose, for the same reason
    $script:LatinInArabic = @('gui.lang.other', 'gui.lang.tip')
    # keys built at run time from a prefix (the source only contains the prefix)
    $script:DynamicPrefixes = @('rpt.next.', 'gui.step.', 'share.msg.')
    $script:SrcFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'src') -Recurse -File -Include *.ps1 | Where-Object { $_.Name -ne 'Strings.ps1' })
    # the screenshot script drives the window with keys of its own (a state the window never shows by itself): it counts as a user of the table
    $script:UsageFiles = @($script:SrcFiles) + @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'tests\gui') -File -Filter *.ps1)
    function Get-Placeholders([string]$s) { @([regex]::Matches($s, '\{(\d+)(?::[^}]*)?\}') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique) }
}

Describe 'String table: both languages are complete' {
    It 'has the same keys in Arabic and English' {
        $missEn = @($script:Ar.Keys | Where-Object { -not $script:En.ContainsKey($_) })
        $missAr = @($script:En.Keys | Where-Object { -not $script:Ar.ContainsKey($_) })
        ($missEn + $missAr) | Should -BeNullOrEmpty -Because ("only in ar: $($missEn -join ', ') / only in en: $($missAr -join ', ')")
        $script:Ar.Count | Should -BeGreaterThan 300
    }
    It 'uses the same placeholders ({0}, {1} ...) in both languages' {
        $bad = @($script:Ar.Keys | Where-Object { $script:En.ContainsKey($_) -and ((Get-Placeholders $script:Ar[$_]) -join ',') -ne ((Get-Placeholders $script:En[$_]) -join ',') })
        $bad | Should -BeNullOrEmpty -Because ($bad -join ', ')
    }
    It 'keeps Arabic text out of the English table and Arabic text in the Arabic table' {
        $badEn = @($script:En.Keys | Where-Object { $_ -notin $script:ArabicInEnglish -and $script:En[$_] -match $script:ArabicRx })
        $badAr = @($script:Ar.Keys | Where-Object { $_ -notin $script:LatinInArabic -and $script:Ar[$_] -notmatch $script:ArabicRx })
        $badEn | Should -BeNullOrEmpty -Because "Arabic inside the English table: $($badEn -join ', ')"
        $badAr | Should -BeNullOrEmpty -Because "no Arabic in the Arabic table: $($badAr -join ', ')"
    }
    It 'has a different text in each language (nothing was left untranslated)' {
        $same = @($script:Ar.Keys | Where-Object { $script:En.ContainsKey($_) -and $script:Ar[$_] -ceq $script:En[$_] })
        $same | Should -BeNullOrEmpty -Because ($same -join ', ')
    }
    It 'has no empty text and no leftover placeholder word' {
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($l in 'ar', 'en') {
            foreach ($k in $script:RdText[$l].Keys) {
                $v = [string]$script:RdText[$l][$k]
                if ([string]::IsNullOrWhiteSpace($v) -or $v -match '(?i)lorem|xxx|\[\[|@@') { $bad.Add("$l/$k") }
            }
        }
        $bad | Should -BeNullOrEmpty -Because ($bad -join ', ')
    }
    It 'formats every text with enough arguments and leaves no {n} behind, in both languages' {
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($l in 'ar', 'en') {
            foreach ($k in $script:RdText[$l].Keys) {
                $n = @(Get-Placeholders $script:RdText[$l][$k])
                $args1 = @(1..([Math]::Max(1, $n.Count + 1)) | ForEach-Object { "v$_" })
                $s = if ($n.Count -gt 0) { Get-Text $k @args1 -Lang $l } else { Get-Text $k -Lang $l }
                if ($s -match '\{\d+\}' -or $s -match '^\[\[') { $bad.Add("$l/$k") }
            }
        }
        $bad | Should -BeNullOrEmpty -Because ($bad -join ', ')
    }
}

Describe 'String table: it is the only place with user-facing text' {
    It 'no Arabic text anywhere in src outside lib\Strings.ps1' {
        $bad = @($script:SrcFiles | Where-Object { [IO.File]::ReadAllText($_.FullName) -match $script:ArabicRx } | ForEach-Object { $_.Name })
        $bad | Should -BeNullOrEmpty -Because "move the text into src\lib\Strings.ps1: $($bad -join ', ')"
    }
    It 'every key the code asks for exists in the table' {
        $used = New-Object System.Collections.Generic.HashSet[string]
        foreach ($f in $script:SrcFiles) {
            $text = [IO.File]::ReadAllText($f.FullName)
            foreach ($m in [regex]::Matches($text, "'((?:sig|obs|verdict|tag|anom|trust|level|rpt|gui|share|sum|sep|tour)\.[A-Za-z0-9.\-]*)'")) { [void]$used.Add($m.Groups[1].Value) }
        }
        $used.Count | Should -BeGreaterThan 100
        # a trailing dot marks a prefix that the code completes at run time; 'share.config.json' is a file name, not a key
        $missing = @($used | Where-Object { -not $_.EndsWith('.') -and $_ -notmatch '\.(json|ps1|cs)$' -and -not $script:Ar.ContainsKey($_) })
        $missing | Should -BeNullOrEmpty -Because ($missing -join ', ')
    }
    It 'every key in the table is used by the code (no dead texts)' {
        $all = ($script:UsageFiles | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $dead = @($script:Ar.Keys | Where-Object {
                $k = $_
                -not $all.Contains("'$k'") -and -not ($script:DynamicPrefixes | Where-Object { $k.StartsWith($_) })
            })
        $dead | Should -BeNullOrEmpty -Because "unused keys: $($dead -join ', ')"
    }
}

Describe 'Get-Text and the language rule' {
    It 'looks the text up in the chosen language' {
        Get-Text 'level.high' -Lang ar | Should -Be $script:Ar['level.high']
        Get-Text 'level.high' -Lang en | Should -Be 'High'
    }
    It 'follows Set-UiLang and restores it' {
        $was = Get-UiLang
        try {
            Set-UiLang 'en'; Get-UiLang | Should -Be 'en'; Get-Text 'level.low' | Should -Be 'Low'
            Set-UiLang 'ar'; Get-UiLang | Should -Be 'ar'; Get-Text 'level.low' | Should -Be $script:Ar['level.low']
        } finally { Set-UiLang $was }
    }
    It 'formats arguments with the invariant culture' {
        Get-Text 'obs.top.b' 'a.exe' 3 (1.5) 'Signed' -Lang en | Should -Be 'The program a.exe (3 processes) uses about 1.5 GB of private memory; its signature: Signed.'
    }
    It 'returns a text without arguments as it is, and turns \n into a line break' {
        (Get-Text 'gui.q.confirm' 'x' -Lang en) | Should -Match "`n`nx`n`n"
        (Get-Text 'gui.q.confirm' 'C:\new\tools\x' -Lang en) | Should -Match ([regex]::Escape('C:\new\tools\x'))
    }
    It 'shows a missing key instead of an empty string, and falls back to Arabic when only English is missing' {
        Get-Text 'zz.no.such.key' -Lang en | Should -Be '[[zz.no.such.key]]'
        Test-TextKey 'level.high' -Lang en | Should -BeTrue
        Test-TextKey 'zz.no.such.key' -Lang en | Should -BeFalse
    }
    It 'accepts ar / en (also with a region) and detects the Windows UI language otherwise' {
        Resolve-UiLang 'ar' | Should -Be 'ar'
        Resolve-UiLang 'EN' | Should -Be 'en'
        Resolve-UiLang 'ar-SA' | Should -Be 'ar'
        Resolve-UiLang 'en_US' | Should -Be 'en'
    }
    It 'detects Arabic when the Windows UI language is Arabic and English for everything else' -ForEach @(
        @{ Iso = 'ar'; Want = 'ar' }, @{ Iso = 'en'; Want = 'en' }, @{ Iso = 'fr'; Want = 'en' }, @{ Iso = 'ur'; Want = 'en' }
    ) {
        Mock Get-UICulture { [pscustomobject]@{ TwoLetterISOLanguageName = $Iso } }
        Resolve-UiLang '' | Should -Be $Want
        Resolve-UiLang 'xx' | Should -Be $Want
    }
}
