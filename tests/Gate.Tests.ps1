#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# A gate that never fails proves nothing. These tests run tests\Invoke-Checks.ps1 against throw-away mini repositories
# with one planted problem each, and check that it is caught - and that a clean one passes.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $script:Gate = Join-Path $PSScriptRoot 'Invoke-Checks.ps1'
    $script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $script:Utf8Bom = New-Object System.Text.UTF8Encoding($true)

    function New-MiniRepo {
        # a minimal repository that passes the gate, built from the pieces the gate looks at
        $r = New-TempDirectory 'ramdoc-gate'
        foreach ($d in 'src', 'build', 'tests') { New-Item -ItemType Directory -Force -Path (Join-Path $r $d) | Out-Null }
        [IO.File]::WriteAllText((Join-Path $r 'build\VERSION'), "1.0.0`n", $script:Utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $r 'src\ok.ps1'), "Write-Output 'hello'`r`n", $script:Utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $r 'README.md'), "# Example`n`nA harmless readme.`n", $script:Utf8NoBom)
        return $r
    }

    function Invoke-Gate([string]$Repo) {
        return (Invoke-ChildPowerShell -File $script:Gate -ArgumentList @('-Root', $Repo, '-SkipPester', '-SkipAnalyzer', '-SkipCompile') -TimeoutSec 120)
    }

    # fake credentials are assembled at run time so this file itself stays clean for the secret scan
    $script:FakeGitHubToken = 'gh' + 'p_' + ('a1B2c3D4' * 4)
    $script:FakeUser = 'hssh' + '1'
    $script:Marker = 'TO' + 'DO'
}

Describe 'Invoke-Checks gate' {

    It 'passes a clean repository' {
        $r = New-MiniRepo
        try {
            $o = Invoke-Gate $r
            $o.ExitCode | Should -Be 0 -Because ($o.StdOut + $o.StdErr)
        }
        finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'catches: <Case>' -ForEach @(
        @{ Case = 'Arabic text in a .ps1 without a BOM'; Expect = 'BOM'
            Plant = { param($r, $s) [IO.File]::WriteAllText((Join-Path $r 'src\arabic.ps1'), "Write-Output '$([char]0x0645)$([char]0x0631)$([char]0x062D)$([char]0x0628)$([char]0x0627)'`r`n", $s.NoBom) } }
        @{ Case = 'a .bat with LF line endings'; Expect = 'CRLF'
            Plant = { param($r, $s) [IO.File]::WriteAllText((Join-Path $r 'run.bat'), "@echo off`necho hi`n", $s.NoBom) } }
        @{ Case = 'a PowerShell syntax error'; Expect = 'parse|Unexpected|Missing'
            Plant = { param($r, $s) [IO.File]::WriteAllText((Join-Path $r 'src\broken.ps1'), "function {{{ ( `r`n", $s.NoBom) } }
        @{ Case = 'a GitHub token'; Expect = 'GitHub token'
            Plant = { param($r, $s) [IO.File]::WriteAllText((Join-Path $r 'notes.md'), "token: $($s.Token)`n", $s.NoBom) } }
        @{ Case = 'a private key block'; Expect = 'private key'
            Plant = { param($r, $s) [IO.File]::WriteAllText((Join-Path $r 'key.txt'), ('-----BEGIN ' + 'PRIVATE KEY-----' + "`n"), $s.NoBom) } }
        @{ Case = 'a Cloudflare token assignment'; Expect = 'Cloudflare'
            Plant = { param($r, $s) [IO.File]::WriteAllText((Join-Path $r 'env.txt'), ('CLOUDFLARE_API_' + 'TOKEN=' + ('Ab1_' * 10) + "`n"), $s.NoBom) } }
        @{ Case = 'a personal user name'; Expect = 'user name'
            Plant = { param($r, $s) [IO.File]::WriteAllText((Join-Path $r 'README.md'), "see C:\Users\$($s.User)\x`n", $s.NoBom) } }
        @{ Case = 'a Google Drive path'; Expect = 'Google Drive'
            Plant = { param($r, $s) [IO.File]::WriteAllText((Join-Path $r 'docs.md'), ('G:\My ' + "Drive\x`n"), $s.NoBom) } }
        @{ Case = 'an unfinished-work marker'; Expect = 'unfinished'
            Plant = { param($r, $s) [IO.File]::WriteAllText((Join-Path $r 'src\later.ps1'), "# $($s.Marker): later`r`n", $s.NoBom) } }
        @{ Case = 'a tab in a workflow file'; Expect = 'TAB'
            Plant = { param($r, $s) New-Item -ItemType Directory -Force -Path (Join-Path $r '.github\workflows') | Out-Null; [IO.File]::WriteAllText((Join-Path $r '.github\workflows\x.yml'), "name: x`non:`n`tpush:`n", $s.NoBom) } }
        @{ Case = 'a share.config.json without maxBytes'; Expect = 'maxBytes'
            Plant = { param($r, $s) [IO.File]::WriteAllText((Join-Path $r 'src\share.config.json'), '{ "endpoint": "", "helperName": "x" }', $s.NoBom) } }
        @{ Case = 'a bad build\VERSION'; Expect = 'VERSION'
            Plant = { param($r, $s) [IO.File]::WriteAllText((Join-Path $r 'build\VERSION'), "one.two`n", $s.NoBom) } }
    ) {
        $r = New-MiniRepo
        try {
            & $Plant $r @{ NoBom = $script:Utf8NoBom; Token = $script:FakeGitHubToken; User = $script:FakeUser; Marker = $script:Marker }
            $o = Invoke-Gate $r
            $o.ExitCode | Should -Be 1 -Because "the gate must reject: $Case"
            ($o.StdOut + $o.StdErr) | Should -Match $Expect
        }
        finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'lets a deliberately fake token through when its line says allow-secret-scan' {
        $r = New-MiniRepo
        try {
            [IO.File]::WriteAllText((Join-Path $r 'fixture.md'), "token: $script:FakeGitHubToken  allow-secret-scan`n", $script:Utf8NoBom)
            (Invoke-Gate $r).ExitCode | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts a share.config.json with an empty endpoint (the helper fills it in later)' {
        $r = New-MiniRepo
        try {
            [IO.File]::WriteAllText((Join-Path $r 'src\share.config.json'), '{ "endpoint": "", "helperName": "Helper", "maxBytes": 524288 }', $script:Utf8NoBom)
            (Invoke-Gate $r).ExitCode | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'ignores generated folders (dist, node_modules, .git)' {
        $r = New-MiniRepo
        try {
            foreach ($d in 'dist', 'node_modules\pkg', '.git') {
                New-Item -ItemType Directory -Force -Path (Join-Path $r $d) | Out-Null
                [IO.File]::WriteAllText((Join-Path $r "$d\junk.txt"), "token: $script:FakeGitHubToken`n", $script:Utf8NoBom)
            }
            (Invoke-Gate $r).ExitCode | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-Checks gate: the release file and the release workflow' {
    BeforeAll {
        $script:RealBuild = Join-Path (Get-RepoRoot) 'build'
        function New-BuildableMiniRepo([string]$GuiText = "# window script`r`n") {
            # a mini repository that contains the REAL builder, so the gate can build a release file from it
            $r = New-MiniRepo
            New-Item -ItemType Directory -Force -Path (Join-Path $r 'build') | Out-Null
            foreach ($n in 'Build-SingleFile.ps1', 'BuildCommon.ps1') { Copy-Item -LiteralPath (Join-Path $script:RealBuild $n) -Destination (Join-Path $r "build\$n") }
            [IO.File]::WriteAllText((Join-Path $r 'src\RAM-Doctor-GUI.ps1'), $GuiText, $script:Utf8NoBom)
            return $r
        }
        function Set-ReleaseYml([string]$Repo, [string]$Text) {
            New-Item -ItemType Directory -Force -Path (Join-Path $Repo '.github\workflows') | Out-Null
            [IO.File]::WriteAllText((Join-Path $Repo '.github\workflows\release.yml'), $Text, $script:Utf8NoBom)
        }
        $script:GoodRelease = "name: Release`njobs:`n  release:`n    runs-on: windows-latest`n    steps:`n      - run: |`n          & .\build\Build-SingleFile.ps1 -Version 1.0.0 -Verify`n          gh release create v1.0.0 dist/RAM-Doctor.bat dist/SHA256SUMS.txt`n"
    }

    It 'builds the release file from the tree and accepts it when it has no environment hooks' {
        $r = New-BuildableMiniRepo
        try {
            $o = Invoke-Gate $r
            $o.ExitCode | Should -Be 0 -Because ($o.StdOut + $o.StdErr)
            $o.StdOut | Should -Match 'Release file has no environment hooks'
        }
        finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects a release whose packed scripts introduce a RAMDOC_ hook (here: RAMDOC_GUI_ARGS)' {
        $r = New-BuildableMiniRepo -GuiText ("# window script`r`n`$x = `$env:RAMDOC_GUI_ARGS`r`n")
        try {
            $o = Invoke-Gate $r
            $o.ExitCode | Should -Be 1
            ($o.StdOut + $o.StdErr) | Should -Match 'RAMDOC_GUI_ARGS'
        }
        finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts the release workflow that builds without -DevHooks and publishes only the two release files' {
        $r = New-MiniRepo
        try { Set-ReleaseYml $r $script:GoodRelease; $o = Invoke-Gate $r; $o.ExitCode | Should -Be 0 -Because ($o.StdOut + $o.StdErr); $o.StdOut | Should -Match 'Workflows keep the test build out of releases' }
        finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects a release workflow that builds with -DevHooks' {
        $r = New-MiniRepo
        try { Set-ReleaseYml $r ($script:GoodRelease.Replace('-Verify', '-Verify -DevHooks')); $o = Invoke-Gate $r; $o.ExitCode | Should -Be 1; ($o.StdOut + $o.StdErr) | Should -Match 'test build' }
        finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects a release workflow that publishes the test build or any other file from dist/' {
        $r = New-MiniRepo
        try { Set-ReleaseYml $r ($script:GoodRelease.Replace('dist/SHA256SUMS.txt', 'dist/SHA256SUMS.txt dist/RAM-Doctor.extra.bat')); $o = Invoke-Gate $r; $o.ExitCode | Should -Be 1; ($o.StdOut + $o.StdErr) | Should -Match 'only dist/RAM-Doctor.bat and dist/SHA256SUMS.txt' }
        finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects a workflow that uploads the test build as an artifact' {
        $r = New-MiniRepo
        try {
            Set-ReleaseYml $r $script:GoodRelease
            [IO.File]::WriteAllText((Join-Path $r '.github\workflows\ci.yml'), "name: CI`njobs:`n  b:`n    runs-on: windows-latest`n    steps:`n      - uses: actions/upload-artifact@v4`n        with:`n          name: x`n          path: dist/RAM-Doctor.devhooks.bat`n", $script:Utf8NoBom)
            $o = Invoke-Gate $r
            $o.ExitCode | Should -Be 1
            ($o.StdOut + $o.StdErr) | Should -Match 'uploads the test build'
        }
        finally { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }
}