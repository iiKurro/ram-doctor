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
            foreach ($scenario in 'leak', 'miner', 'clean', 'hidden') {
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

Describe 'HTML report: why Task Manager does not show the memory' -Skip:(-not $script:HaveFixtures) {
    BeforeAll {
        . (Join-Path $script:Root 'src\lib\Report.ps1')
        . (Join-Path $PSScriptRoot 'fixtures\Demo-ReportData.ps1')
        # the card: from its opening tag to the end of its section
        function Get-Card([string]$html) { $m = [regex]::Match($html, "(?s)<section id='taskmgr'.*?</section>"); if ($m.Success) { $m.Value } else { '' } }
    }

    It 'shows the card near the top, after the summary and before the memory tiles, in <Lang>' -ForEach @(@{ Lang = 'en' }, @{ Lang = 'ar' }) {
        $html = New-RamReportHtml (Get-DemoReportData -Scenario hidden -Lang $Lang)
        $card = Get-Card $html
        $card | Should -Not -BeNullOrEmpty
        $html.IndexOf("id='taskmgr'") | Should -BeGreaterThan $html.IndexOf("id='overview'")
        $html.IndexOf("id='taskmgr'") | Should -BeLessThan $html.IndexOf("class='kpis'")
        $html | Should -Match "<a href='#taskmgr'>"
        $card | Should -Match ([regex]::Escape((Get-Text 'rpt.tm.h' -Lang $Lang)))
        # the numbers of the friend scan: 8.56 private, 9.63 not shown, then the parts
        foreach ($n in '8.56', '18.19', '9.63', '4.47', '2.26', '2.07', '0.83', '12.91', '9.88') { $card | Should -Match ([regex]::Escape($n)) -Because "$Lang card shows $n" }
        foreach ($k in 'rpt.tm.private', 'rpt.tm.shared', 'rpt.tm.drivers', 'rpt.tm.kernel', 'rpt.tm.system') {
            $card | Should -Match ([regex]::Escape([Net.WebUtility]::HtmlEncode((Get-Text $k -Lang $Lang)).Split(' ')[0])) -Because "$Lang card names the part $k"
        }
        $card | Should -Match "class='stack' role='img'"                       # the stacked bar
        $card | Should -Match 'brave\.exe'                                       # the biggest shared-memory user
        $card | Should -Match 'Parsec Virtual Display Adapter'                   # a driver-reserved candidate
        $card | Should -Not -Match ([regex]::Escape((Get-Text 'rpt.tm.unexpl' -Lang $Lang)))   # nothing unexplained: no empty row
        ($card -match '[؀-ۿ]') | Should -Be ($Lang -eq 'ar')
    }

    It 'adds the shared column to the consumers table (<Lang>)' -ForEach @(@{ Lang = 'en' }, @{ Lang = 'ar' }) {
        $html = New-RamReportHtml (Get-DemoReportData -Scenario hidden -Lang $Lang)
        $html | Should -Match ([regex]::Escape("<th class='num'>$(Get-Text 'rpt.th.shared' -Lang $Lang)</th>"))
        $html | Should -Match "<td class='mono'>brave\.exe</td><td class='num'>32</td>.*?<td class='num'>5240</td>"
        $html | Should -Match ([regex]::Escape((Get-Text 'rpt.cons.shared' -Lang $Lang).Substring(0, 20)))
    }

    It 'the corrected "not attributed" tile shows the driver reservation the old formula hid' {
        $html = New-RamReportHtml (Get-DemoReportData -Scenario hidden -Lang en)
        $html | Should -Match ([regex]::Escape((Get-Text 'rpt.kpi.unacc' -Lang en)) + '</div><div class=''kpi-v''><bdi dir=''ltr''>2\.26')
        $html | Should -Match 'of which reserved by drivers'
        $html | Should -Match 'Not attributed = Driver-reserved'
    }

    It 'says so when the driver reservations could not be measured (no administrator rights)' {
        $d = Get-DemoReportData -Scenario hidden -Lang en
        $d.Memory.DriverReservedKnown = $false
        (Get-Card (New-RamReportHtml $d)) | Should -Match ([regex]::Escape((Get-Text 'rpt.tm.drivers.unknown' -Lang en).Substring(0, 30)))
    }

    It 'shows the unexplained part only when there is one' {
        $d = Get-DemoReportData -Scenario hidden -Lang en
        $d.Memory.UnexplainedGB = 1.5
        (Get-Card (New-RamReportHtml $d)) | Should -Match ([regex]::Escape((Get-Text 'rpt.tm.unexpl' -Lang en)))
    }

    It 'renders data of older scans (no breakdown) as before: no card, no shared column, the old formula' {
        $d = Get-DemoReportData -Scenario hidden -Lang en
        foreach ($p in 'HiddenGB', 'SharedUniqueGB', 'DriverReservedGB', 'DriverReservedKnown', 'DriverReservedGrowthMB', 'KernelPoolsGB', 'SystemOtherGB', 'UnexplainedGB', 'UnattributedGB', 'TopShared', 'DriverReservedCandidates') { $d.Memory.PSObject.Properties.Remove($p) }
        foreach ($r in $d.ByProgram) { $r.PSObject.Properties.Remove('sharedMB') }
        $html = New-RamReportHtml $d
        $html | Should -Not -Match "id='taskmgr'"
        $html | Should -Not -Match "href='#taskmgr'"
        $html | Should -Not -Match ([regex]::Escape((Get-Text 'rpt.th.shared' -Lang en)))
        $html | Should -Match 'Unaccounted = Used'
        $html | Should -Match '(?i)</html>\s*$'
    }
}
