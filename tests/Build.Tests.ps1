#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Structure, reproducibility and - above all - the security shape of the single-file edition built by
# build\Build-SingleFile.ps1. Two variants exist:
#   RELEASE   RAM-Doctor.bat           what users get. It runs ELEVATED, so NOTHING in it may be steered by the environment.
#   TEST      RAM-Doctor.devhooks.bat  same payload, plus RAMDOC_* hooks so that tests can drive it. Never published.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $script:Root = Get-RepoRoot
    . (Join-Path $script:Root 'build\BuildCommon.ps1')
    $script:Build = Join-Path $script:Root 'build\Build-SingleFile.ps1'
    $script:Out = New-TempDirectory 'ramdoc-build'
    $script:Bat = Join-Path $script:Out 'rel\RAM-Doctor.bat'
    $script:DevBat = Join-Path $script:Out 'dev\RAM-Doctor.devhooks.bat'
    $null = & $script:Build -OutFile $script:Bat -Version 9.9.9 6>$null
    $null = & $script:Build -OutFile $script:DevBat -Version 9.9.9 -DevHooks 6>$null
    $script:Bytes = [IO.File]::ReadAllBytes($script:Bat)
    $script:Text = [Text.Encoding]::UTF8.GetString($script:Bytes)
    $parts = Split-SingleFile -Path $script:Bat
    $script:Header = $parts.Header
    $script:Payload = $parts.Payload
    $devParts = Split-SingleFile -Path $script:DevBat
    $script:DevHeader = $devParts.Header
    $script:DevPayload = $devParts.Payload

    function Get-SecureLogic([string]$P4) {
        # the folder-creation logic that both variants must share: from "$par=" to the last "locked down' }"
        $i = $P4.IndexOf('$par=')
        $j = $P4.LastIndexOf("the unpack folder is not locked down' }")
        if ($i -lt 0 -or $j -lt 0) { return '' }
        return $P4.Substring($i, $j - $i + "the unpack folder is not locked down' }".Length)
    }
    function New-Tampered([string]$Name, [scriptblock]$Edit) {
        # a copy of the release file with something planted in it
        $p = Join-Path $script:Out ('tampered-' + $Name + '.bat')
        $t = & $Edit $script:Text
        [IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
        return $p
    }
}

AfterAll {
    if ($script:Out) { Remove-Item -LiteralPath $script:Out -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Single-file builder - RELEASE variant' {

    Context 'header (the part cmd.exe actually executes)' {
        It 'starts with "@echo off" and has no BOM' {
            $script:Bytes[0..9] | ForEach-Object { [char]$_ } | Should -Be ('@echo off'.ToCharArray() + [char]13)
        }

        It 'is pure ASCII' {
            @($script:Header.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
        }

        It 'uses CRLF line endings only (no bare LF)' {
            ([regex]::Matches($script:Header, "(?<!`r)`n")).Count | Should -Be 0
        }

        It 'stamps the requested version' {
            $script:Header | Should -Match 'rem\s+RAM Doctor 9\.9\.9 - one-file edition'
        }

        It 'declares what it does, in plain words, for anyone who opens it in Notepad' {
            $script:Header | Should -Match 'does not install anything'
            $script:Header | Should -Match 'sends nothing over the network'
            $script:Header | Should -Match 'reads no settings from the environment'
        }

        It 'carries the copyright and licence notice, so a copy passed around on its own still says who owns it' {
            $script:Header | Should -Match 'rem\s+Copyright \(c\) 2026 7san\. All rights reserved\.'
            $script:Header | Should -Match 'github\.com/iiKurro/ram-doctor/blob/main/LICENSE'
        }

        It 'contains nothing an antivirus would read as an obfuscated dropper' {
            $script:Header | Should -Not -Match 'Invoke-Expression|\biex\b|FromBase64String|-EncodedCommand|-enc\b|WindowStyle Hidden|DownloadString|Net\.WebClient'
        }

        It 'keeps every piece of the unpack command free of characters cmd.exe would rewrite inside quotes (double quote, percent)' {
            $h = Get-HeaderPieces -Bat $script:Bat
            $h.Final | Should -Not -BeNullOrEmpty
            $h.Pieces.Count | Should -Be 6
            foreach ($k in $h.Pieces.Keys) {
                $h.Pieces[$k] | Should -Not -Match '["%]' -Because $k
                $h.Pieces[$k].Length | Should -BeLessThan 2000 -Because "$k must stay far below cmd's 8191-character line limit"
            }
        }

        It 'glues P1..P6 in order, and the whole command line fits cmd.exe (8191 characters)' {
            $h = Get-HeaderPieces -Bat $script:Bat
            $h.Final | Should -Be '%P1% %P2% %P3% %P4% %P5% %P6%'
            $total = (1..6 | ForEach-Object { $h.Pieces["P$_"].Length } | Measure-Object -Sum).Sum + 200
            $total | Should -BeLessThan 7500
        }

        It 'calls every tool by its full path and never runs from the current folder (no planted powershell.exe / net.exe / cmd.exe)' {
            $code = @(($script:Header -split "`r`n") | Where-Object { $_ -and $_ -notmatch '^(rem|set |:|@echo|setlocal|if |exit|echo|pause|cd /d|goto)' })
            $code.Count | Should -BeGreaterThan 2
            foreach ($l in $code) { $l | Should -Match '^("?%SystemRoot%\\System32\\|start "" /min "%SystemRoot%\\System32\\)' -Because $l }
            $script:Header | Should -Match '(?m)^cd /d "%SystemRoot%\\System32"'
        }

        It 'unpacks into an administrators-only folder under ProgramData, locked by SID with inheritance off, verified before use' {
            $h = Get-HeaderPieces -Bat $script:Bat
            $all = ($h.Pieces.Values -join ' ')
            $all | Should -Match 'CommonApplicationData'
            $all | Should -Match 'RAM-Doctor-run'
            $all | Should -Match 'S-1-5-18'          # SYSTEM
            $all | Should -Match 'S-1-5-32-544'      # Administrators
            $all | Should -Match 'SetAccessRuleProtection\(\$true,\$false\)'                   # inheritance off, inherited rules dropped
            $all | Should -Match '\[IO\.Directory\]::CreateDirectory\(\$d,\(New-LockedAcl'     # created already locked: atomic
            $all | Should -Match 'Test-LockedDir \$w'                                          # verified before anything is run from it
            $all | Should -Match 'ReparsePoint'                                                # junction check
        }

        It 'removes the unpack folder in a finally block and sweeps leftovers older than a day' {
            $h = Get-HeaderPieces -Bat $script:Bat
            $h.Pieces['P6'] | Should -Match 'finally \{ if\(\$w\)\{ Remove-Item -LiteralPath \$w -Recurse'
            $h.Pieces['P4'] | Should -Match 'AddDays\(-1\)'
        }

        It 'starts the window with FIXED arguments: nothing from outside is appended to its command line' {
            $h = Get-HeaderPieces -Bat $script:Bat
            $h.Pieces['P6'] | Should -Match '^\$a=''-NoProfile -ExecutionPolicy Bypass -STA -File ''\+\$q\+\$g\+\$q;'
            $h.Pieces['P6'] | Should -Not -Match '\$a=.*\$env:'
            $script:Header | Should -Not -Match '%\*|%2|%3'      # no pass-through of the command line either
        }

        It 'jumps over the payload: the last header statement is an exit' {
            $last = ($script:Header.TrimEnd() -split "`r`n")[-1]
            $last | Should -Match '^exit /b'
        }
    }

    Context 'no environment-controlled behaviour (the file runs elevated)' {
        It 'contains no RAMDOC_ hook, no -TestScript, no test banner, no "if defined" in its header' {
            $script:Header | Should -Not -Match '(?i)RAMDOC_'
            $script:Header | Should -Not -Match '(?i)TestScript|GUI_ARGS|UNPACK_ONLY|NOELEVATE|DevHooks|TEST BUILD'
            $script:Header | Should -Not -Match '(?im)^\s*if\s+(not\s+)?defined\b'
        }

        It 'passes the release hygiene check (the same one Build -Verify and Invoke-Checks run)' {
            @(Get-ReleaseHygieneProblems -Path $script:Bat) | Should -BeNullOrEmpty
        }

        It 'reads no user-controllable environment value in its elevation path: PowerShell reads $env:SELF only, and SELF is set by the file itself from %~f0' {
            $envReads = @([regex]::Matches($script:Header, '\$env:([A-Za-z_][A-Za-z0-9_]*)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $envReads | Should -Be @('SELF')
            $script:Header | Should -Match '(?m)^set "SELF=%~f0"\r?$'
            @(($script:Header -split "`r`n") | Where-Object { $_ -match '^set ' -and $_ -notmatch '^set "P\d=' }) | Should -Be @('set "SELF=%~f0"')
            $script:Header | Should -Not -Match '(?i)GetEnvironmentVariable|ExpandEnvironmentVariables|Get-ChildItem\s+env:'
        }

        It 'lets cmd.exe expand only %SELF%, %SystemRoot% (to call tools by full path), %P1%..%P6%, %errorlevel%, %~f0 and %~1' {
            $executed = (($script:Header -split "`r`n") | Where-Object { $_ -notmatch '^\s*rem(\s|$)' }) -join "`n"
            $vars = @([regex]::Matches($executed, '%([A-Za-z0-9_]+)%') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $vars | Should -Be @('errorlevel', 'P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'SELF', 'SystemRoot' | Sort-Object)
            $mods = @([regex]::Matches($executed, '%~[A-Za-z0-9]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
            $mods | Should -Be @('%~1', '%~f0')
        }

        It 'does not accept the unpack folder from outside: the PowerShell pieces never read TEMP, TMP, PATH or any RAMDOC_ value' {
            $h = Get-HeaderPieces -Bat $script:Bat
            ($h.Pieces.Values -join ' ') | Should -Not -Match '\$env:(TEMP|TMP|PATH|ProgramData|SystemRoot|windir|RAMDOC_\w+)'
        }

        It 'has no unpack-only mode, and Expand-SingleFile refuses to use it' {
            { & (Join-Path $script:Root 'build\Expand-SingleFile.ps1') -Bat $script:Bat } | Should -Throw '*release build*'
        }

        It 'the hygiene check catches each kind of planted hook (<Case>)' -ForEach @(
            @{ Case = 'RAMDOC_ variable in the header'; Plant = { param($t) $t.Replace('setlocal', "setlocal`r`nset `"RAMDOC_X=1`"") } }
            @{ Case = 'extra PowerShell environment read'; Plant = { param($t) $t.Replace('$q=[char]34;', '$q=[char]34; $x=$env:TEMP;') } }
            @{ Case = 'extra cmd.exe variable expansion'; Plant = { param($t) $t.Replace('if /i "%~1"=="min" goto :started', "if /i `"%~1`"==`"min`" goto :started`r`nset `"Z=%TEMP%`"") } }
            @{ Case = '-TestScript pass-through'; Plant = { param($t) $t.Replace('goto :started', 'goto :started -TestScript') } }
            @{ Case = '"if defined" environment branch'; Plant = { param($t) $t.Replace(':started', ":started`r`nif defined SOMETHING goto :admin") } }
            @{ Case = 'environment API in the header'; Plant = { param($t) $t.Replace('$trusted=@($sys,$adm);', '$trusted=@($sys,$adm); [Environment]::GetEnvironmentVariable(''X'');') } }
            @{ Case = 'unknown RAMDOC_ name in the packed scripts'; Plant = { param($t) $t + "`r`n# RAMDOC_GUI_ARGS`r`n" } }
        ) {
            $p = New-Tampered ($Case -replace '[^A-Za-z0-9]', '') $Plant
            @(Get-ReleaseHygieneProblems -Path $p).Count | Should -BeGreaterThan 0 -Because $Case
        }

        It 'the hygiene check still accepts the sharing secrets the window hands to its own child process (RAMDOC_SHARE_NAME / RAMDOC_SHARE_CODE)' {
            $p = New-Tampered 'sharenames' { param($t) $t + "`r`n# RAMDOC_SHARE_NAME RAMDOC_SHARE_CODE`r`n" }
            @(Get-ReleaseHygieneProblems -Path $p) | Should -BeNullOrEmpty
        }
    }

    Context 'payload' {
        It 'embeds every packable file under src\, entry window first, each exactly once' {
            $expected = @(Get-PackFiles -Root $script:Root)
            $markers = @([regex]::Matches($script:Text, '(?m)^#@@FILE (.+?)\r?$') | ForEach-Object { $_.Groups[1].Value })
            $markers | Should -Be $expected
            $markers[0] | Should -Be 'src\RAM-Doctor-GUI.ps1'
            @($markers | Select-Object -Unique).Count | Should -Be $markers.Count
        }

        It 'covers the core scripts' {
            $markers = @([regex]::Matches($script:Text, '(?m)^#@@FILE (.+?)\r?$') | ForEach-Object { $_.Groups[1].Value })
            foreach ($f in 'src\RAM-Doctor.ps1', 'src\RAM-Doctor-Actions.ps1', 'src\lib\Report.ps1', 'src\lib\Store.ps1', 'src\lib\Native.cs') { $markers | Should -Contain $f }
        }

        It 'has a sane size (a few hundred KB at most: it is meant to be a light download)' {
            $script:Bytes.Length | Should -BeGreaterThan (50KB)
            $script:Bytes.Length | Should -BeLessThan (800KB)
        }

        It 'is valid UTF-8 end to end' {
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            { $strict.GetString($script:Bytes) } | Should -Not -Throw
        }
    }

    Context 'reproducibility and integrity' {
        It 'produces byte-identical output for the same sources (deterministic)' {
            $b = Join-Path $script:Out 'again\RAM-Doctor.bat'
            $null = & $script:Build -OutFile $b -Version 9.9.9 -NoChecksum 6>$null
            (Get-FileHash $b -Algorithm SHA256).Hash | Should -Be (Get-FileHash $script:Bat -Algorithm SHA256).Hash
        }

        It 'writes SHA256SUMS.txt in sha256sum format that matches the file' {
            $sums = Join-Path $script:Out 'rel\SHA256SUMS.txt'
            Test-Path $sums | Should -BeTrue
            $raw = [IO.File]::ReadAllText($sums)
            $raw | Should -Match '^[0-9a-f]{64}  RAM-Doctor\.bat\n$'
            $raw.Substring(0, 64) | Should -Be (Get-FileHash $script:Bat -Algorithm SHA256).Hash.ToLowerInvariant()
        }

        It 'passes its own -Verify (hygiene, payload identical to the test build, unpack byte-identical to the sources)' {
            $b = Join-Path $script:Out 'verify\RAM-Doctor.bat'
            { & $script:Build -OutFile $b -Version 9.9.9 -Verify 6>$null } | Should -Not -Throw
        }

        It 'rejects a malformed version' {
            $b = Join-Path $script:Out 'badver\RAM-Doctor.bat'
            { & $script:Build -OutFile $b -Version 'not-a-version' } | Should -Throw
        }

        It 'reads the default version from build\VERSION' {
            $v = ([IO.File]::ReadAllText((Join-Path $script:Root 'build\VERSION'))).Trim()
            $v | Should -Match '^\d+\.\d+\.\d+$'
            $b = Join-Path $script:Out 'defver\RAM-Doctor.bat'
            $null = & $script:Build -OutFile $b -NoChecksum 6>$null
            (Get-Content -LiteralPath $b -TotalCount 2)[1] | Should -Match ([regex]::Escape("RAM Doctor $v"))
        }
    }
}

Describe 'Single-file builder - TEST variant (-DevHooks)' {

    It 'announces itself: banner in the first lines and when run, never the release name' {
        $top = (Get-Content -LiteralPath $script:DevBat -TotalCount 4) -join "`n"
        $top | Should -Match 'TEST BUILD - not for distribution'
        $script:DevHeader | Should -Match '(?m)^echo TEST BUILD - not for distribution'
        (Split-Path -Leaf $script:DevBat) | Should -Be 'RAM-Doctor.devhooks.bat'
    }

    It 'refuses to be written under the release name' {
        { & $script:Build -OutFile (Join-Path $script:Out 'bad\RAM-Doctor.bat') -DevHooks } | Should -Throw '*Refusing*'
    }

    It 'keeps the hooks the tests need: RAMDOC_MODE / RAMDOC_NOELEVATE / RAMDOC_GUI_ARGS / RAMDOC_UNPACK_ONLY' {
        foreach ($k in 'RAMDOC_MODE', 'RAMDOC_NOELEVATE', 'RAMDOC_GUI_ARGS', 'RAMDOC_UNPACK_ONLY') { $script:DevHeader | Should -Match $k }
    }

    It 'is flagged by the release hygiene check (so a test build can never be mistaken for the release)' {
        @(Get-ReleaseHygieneProblems -Path $script:DevBat).Count | Should -BeGreaterThan 3
    }

    It 'does not write a SHA256SUMS.txt next to it' {
        Test-Path (Join-Path $script:Out 'dev\SHA256SUMS.txt') | Should -BeFalse
    }

    It 'passes its own -Verify' {
        $b = Join-Path $script:Out 'devverify\RAM-Doctor.devhooks.bat'
        { & $script:Build -OutFile $b -Version 9.9.9 -DevHooks -Verify 6>$null } | Should -Not -Throw
    }
}

Describe 'RELEASE and TEST variants stay in step' {

    It 'carry byte-identical payloads, so what the tests unpack is exactly what users unpack' {
        $script:DevPayload | Should -BeExactly $script:Payload
    }

    It 'share the setup, ACL and extraction pieces (P1, P2, P3, P5) verbatim' {
        $r = Get-HeaderPieces -Bat $script:Bat
        $d = Get-HeaderPieces -Bat $script:DevBat
        foreach ($k in 'P1', 'P2', 'P3', 'P5') { $d.Pieces[$k] | Should -BeExactly $r.Pieces[$k] -Because $k }
    }

    It 'share the secure-folder logic of P4 verbatim: the test build exercises exactly the release code' {
        $r = Get-SecureLogic (Get-HeaderPieces -Bat $script:Bat).Pieces['P4']
        $d = Get-SecureLogic (Get-HeaderPieces -Bat $script:DevBat).Pieces['P4']
        $r | Should -Not -BeNullOrEmpty
        $d | Should -BeExactly $r
    }

    It 'differ only where they must: the mode switch (dev) and the window launch line (dev appends hook arguments)' {
        $r = Get-HeaderPieces -Bat $script:Bat
        $d = Get-HeaderPieces -Bat $script:DevBat
        $r.Pieces['P4'] | Should -Not -Match 'RAMDOC_'
        $d.Pieces['P4'] | Should -Match 'RAMDOC_MODE'
        $r.Pieces['P6'] | Should -Not -Match 'RAMDOC_'
        $d.Pieces['P6'] | Should -Match 'RAMDOC_GUI_ARGS'
    }
}
