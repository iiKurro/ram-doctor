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

    It 'renders a complete HTML document for each demo scenario, in Arabic (right-to-left) and English (left-to-right)' {
        . (Join-Path $script:Root 'src\lib\Report.ps1')
        . (Join-Path $PSScriptRoot 'fixtures\Demo-ReportData.ps1')
        foreach ($lang in 'ar', 'en') {
            $dir = $(if ($lang -eq 'ar') { 'rtl' } else { 'ltr' })
            foreach ($scenario in 'leak', 'miner', 'clean') {
                $html = New-RamReportHtml (Get-DemoReportData -Scenario $scenario -Lang $lang)
                $html | Should -Match '(?i)^\s*<!doctype html' -Because "$scenario/$lang"
                $html | Should -Match '(?i)</html>\s*$' -Because "$scenario/$lang"
                $html | Should -Match ('<html lang="{0}" dir="{1}">' -f $lang, $dir) -Because "${scenario}/${lang}: lang and direction follow the language"
                ($html -match '[؀-ۿ]') | Should -Be ($lang -eq 'ar') -Because "${scenario}/${lang}: Arabic text only in the Arabic report"
                $html.Length | Should -BeGreaterThan 4000 -Because "$scenario/$lang"
                $html.Length | Should -BeLessThan 600000 -Because "${scenario}/${lang}: a report must stay a light file"
            }
        }
    }

    It 'data without a language (older code) renders as the Arabic report it used to be' {
        . (Join-Path $script:Root 'src\lib\Report.ps1')
        . (Join-Path $PSScriptRoot 'fixtures\Demo-ReportData.ps1')
        $d = Get-DemoReportData -Scenario clean -Lang ar
        $d.PSObject.Properties.Remove('Lang')
        (New-RamReportHtml $d) | Should -Match '<html lang="ar" dir="rtl">'
    }

    It 'leaves the language of the caller alone after rendering' {
        . (Join-Path $script:Root 'src\lib\Report.ps1')
        . (Join-Path $PSScriptRoot 'fixtures\Demo-ReportData.ps1')
        Set-UiLang 'ar'
        [void](New-RamReportHtml (Get-DemoReportData -Scenario clean -Lang en))
        Get-UiLang | Should -Be 'ar'
    }
}
