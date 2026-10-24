#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# The HTML report is what a user e-mails to a helper, so it has to be inert (no active content) and well-formed.
# The synthetic data and the detailed safety assertions live in tests\fixtures (written together with the report);
# this file runs them as part of the normal test run.

BeforeDiscovery {
    $script:HaveFixtures = (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'fixtures\Demo-ReportData.ps1')) -and
    (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'fixtures\Test-ReportSafety.ps1'))
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $script:Root = Get-RepoRoot
}

Describe 'HTML report' -Skip:(-not $script:HaveFixtures) {

    It 'passes the inert-report safety contract for every scenario, including a hostile one (fixtures\Test-ReportSafety.ps1)' {
        $r = Invoke-ChildPowerShell -File (Join-Path $PSScriptRoot 'fixtures\Test-ReportSafety.ps1') -TimeoutSec 300
        $r.TimedOut | Should -BeFalse
        $r.ExitCode | Should -Be 0 -Because ($r.StdOut + $r.StdErr)
    }

    It 'renders a complete HTML document for each demo scenario' {
        . (Join-Path $script:Root 'src\lib\Report.ps1')
        . (Join-Path $PSScriptRoot 'fixtures\Demo-ReportData.ps1')
        foreach ($scenario in 'leak', 'miner', 'clean') {
            $html = New-RamReportHtml (Get-DemoReportData -Scenario $scenario)
            $html | Should -Match '(?i)^\s*<!doctype html' -Because $scenario
            $html | Should -Match '(?i)</html>\s*$' -Because $scenario
            $html | Should -Match 'dir="rtl"' -Because "${scenario}: the report is right-to-left Arabic"
            $html.Length | Should -BeGreaterThan 4000 -Because $scenario
            $html.Length | Should -BeLessThan 600000 -Because "${scenario}: a report must stay a light file"
        }
    }
}
