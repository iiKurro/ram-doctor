# Cross-component contract: what the PRODUCT renders and the share client uploads must be accepted by the RELAY's validator.
# Each side has its own tests with its own samples; this is the one place where the real report meets the real checker
# (the first live upload failed exactly here: the relay mistook CSS "scroll-behavior" for the legacy "behavior:" property).
# Needs Node.js (preinstalled on the CI runners); skipped when it is not available.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'src\lib\Report.ps1')
    . (Join-Path $repo 'src\lib\Share.ps1')
    . (Join-Path $repo 'tests\fixtures\Demo-ReportData.ps1')
    . (Join-Path $repo 'tests\share\Fixtures.ps1')
    $script:Node = Get-Command node -ErrorAction SilentlyContinue
    $script:LibUrl = ([Uri](Join-Path $repo 'server\worker\src\lib.js')).AbsoluteUri
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('ramdoc-contract-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Work | Out-Null
}

AfterAll {
    if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Report and relay contract' {
    It 'the relay accepts the redacted report.html of the "<Scenario>" scenario' -ForEach @(
        @{ Scenario = 'leak' }, @{ Scenario = 'miner' }, @{ Scenario = 'clean' }
    ) {
        if (-not $script:Node) { Set-ItResult -Skipped -Because 'Node.js is not installed'; return }
        $dir = Join-Path $script:Work $Scenario
        New-Item -ItemType Directory -Path $dir | Out-Null
        $files = New-TestPlanFiles -Dir $dir -Stamp '20260101-120000'
        # swap the fixture's placeholder page for a REAL report rendered by the product
        $html = New-RamReportHtml (Get-DemoReportData -Scenario $Scenario)
        [IO.File]::WriteAllText($files.Html, $html, (New-Object Text.UTF8Encoding($true)))
        $profile0 = [pscustomobject]@{ displayName = 'Friend'; userId = '0123abcd' }
        $bundle = New-ShareBundle -PlanPath $files.Plan -Profile $profile0
        $uploaded = ($bundle.Files | Where-Object { $_.name -eq 'report.html' }).content
        $page = Join-Path $dir 'uploaded.html'
        [IO.File]::WriteAllText($page, $uploaded, (New-Object Text.UTF8Encoding($false)))
        $probe = Join-Path $dir 'check.mjs'
        $js = "import { readFileSync } from 'node:fs';`n" +
        "import { checkReportHtml } from '$($script:LibUrl)';`n" +
        "const r = checkReportHtml(readFileSync(process.argv[2], 'utf8'));`n" +
        "console.log(JSON.stringify(r));`n" +
        "process.exit(r.ok ? 0 : 1);`n"
        [IO.File]::WriteAllText($probe, $js, (New-Object Text.UTF8Encoding($false)))
        $out = & node $probe $page 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because "the relay refused the report: $out"
        $out | Should -Match '"ok":true'
    }
}

Describe 'Version consistency' {
    It 'the version written by hand in the scripts equals build/VERSION' {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $want = (Get-Content -LiteralPath (Join-Path $repoRoot 'build\VERSION') -Raw).Trim()
        foreach ($pair in @(
                @{ File = 'src\RAM-Doctor.ps1'; Rx = '\$ToolVersion\s*=\s*''([^'']+)''' },
                @{ File = 'src\RAM-Doctor-Actions.ps1'; Rx = '\$ToolVersion\s*=\s*''([^'']+)''' },
                @{ File = 'src\lib\Share.ps1'; Rx = '\$script:ShareToolVersion\s*=\s*''([^'']+)''' })) {
            $text = Get-Content -LiteralPath (Join-Path $repoRoot $pair.File) -Raw
            $m = [regex]::Match($text, $pair.Rx)
            $m.Success | Should -BeTrue -Because "$($pair.File) must declare its version"
            $m.Groups[1].Value | Should -Be $want -Because "$($pair.File) says $($m.Groups[1].Value) but build/VERSION is $want"
        }
    }
}
