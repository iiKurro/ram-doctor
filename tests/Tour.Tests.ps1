#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# The guided tour (src\lib\Tour.ps1): its pure parts - the step list, which steps apply, the card texts, the keys, where the
# card goes, how far the page scrolls and the first-run check. The real window with the overlay is driven by
# tests\gui\Flow.Test.ps1 (open, walk every step, back, skip, window unchanged). ASCII only.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $script:Root = Get-RepoRoot
    Add-Type -AssemblyName System.Drawing
    . (Join-Path $script:Root 'src\lib\Strings.ps1')
    . (Join-Path $script:Root 'src\lib\Tour.ps1')
    $script:Steps = @(Get-TourSteps)
    $script:Gui = [IO.File]::ReadAllText((Join-Path $script:Root 'src\RAM-Doctor-GUI.ps1'))
    function New-Rect([int]$x, [int]$y, [int]$w, [int]$h) { New-Object System.Drawing.Rectangle($x, $y, $w, $h) }
    function New-Size([int]$w, [int]$h) { New-Object System.Drawing.Size($w, $h) }
    function Get-Step([string]$id) { $script:Steps | Where-Object { $_.Id -eq $id } | Select-Object -First 1 }
}

Describe 'Tour: the steps' {
    It 'walks through every main part of the window, in reading order' {
        ($script:Steps | ForEach-Object { $_.Id }) -join ',' | Should -Be 'welcome,admin,scan,progress,verdict,actions,findings,quarantine,more,details,language,help'
    }
    It 'has unique ids and an icon on every card' {
        @($script:Steps.Id | Select-Object -Unique).Count | Should -Be $script:Steps.Count
        @($script:Steps | Where-Object { $_.Glyph -lt 0xE000 -or $_.Glyph -gt 0xF8FF }) | Should -BeNullOrEmpty
    }
    It 'lights up only controls that the window really has' {
        $names = @($script:Steps | ForEach-Object { $_.Targets; if ($_.Expand) { $_.Expand } } | Select-Object -Unique)
        $names.Count | Should -BeGreaterThan 10
        foreach ($n in $names) { $script:Gui | Should -Match ('(?m)^\s*\$' + [regex]::Escape($n) + '\s*=') -Because "the tour lights up `$$n" }
    }
    It 'starts with a card of its own and ends on the button that opens it again' {
        $script:Steps[0].Targets | Should -BeNullOrEmpty
        ($script:Steps[-1].Targets -join ',') | Should -Be 'btnTour'
    }
    It 'opens only the "More" section, and only for its own step' {
        (@($script:Steps | Where-Object { $_.Expand }).Id -join ',') | Should -Be 'more'
        (Get-Step 'more').Expand | Should -Be 'exMore'
    }
    It 'asks for texts that exist in both languages' {
        foreach ($s in $script:Steps) {
            $keys = @($s.Title, $s.Body, $s.Later) + @($s.BodyArgs) + $(if ($s.Extra) { @($s.Extra.Key) + @($s.Extra.Args) } else { @() })
            foreach ($k in @($keys | Where-Object { $_ })) {
                foreach ($l in 'ar', 'en') { Test-TextKey $k -Lang $l | Should -BeTrue -Because "$($s.Id) uses $k ($l)" }
            }
        }
    }
    It 'gives every card a short title and one to three sentences, with every placeholder filled, in both languages' -ForEach @(@{ L = 'en' }, @{ L = 'ar' }) {
        $was = Get-UiLang
        try {
            Set-UiLang $L
            foreach ($s in $script:Steps) {
                $t = Get-TourStepText $s @{ share = $true; admin = $true } $false
                $t.Title | Should -Not -BeNullOrEmpty
                ($t.Title + $t.Body + $t.Note) | Should -Not -Match '\{\d+\}|\[\['
                $t.Title.Length | Should -BeLessThan 40 -Because "$($s.Id): a title is a few words"
                $t.Body.Length | Should -BeLessThan 260 -Because "$($s.Id): a card stays short"
                if ($L -eq 'en') { @([regex]::Matches($t.Body, '[.?!](\s|$)')).Count | Should -BeLessOrEqual 4 -Because "$($s.Id): plain, short sentences" }
            }
        } finally { Set-UiLang $was }
    }
}

Describe 'Tour: which steps apply' {
    It 'leaves out the administrator step when the warning bar is not shown' {
        $sel = @(Select-TourSteps $script:Steps @{ admin = $false; share = $true })
        $sel.Id | Should -Not -Contain 'admin'
        $sel.Count | Should -Be ($script:Steps.Count - 1)
    }
    It 'explains the warning bar right after the welcome when it is shown' {
        $sel = @(Select-TourSteps $script:Steps @{ admin = $true })
        $sel.Count | Should -Be $script:Steps.Count
        $sel[1].Id | Should -Be 'admin'
    }
    It 'treats a missing state as "nothing special"' {
        @(Select-TourSteps $script:Steps $null).Id | Should -Not -Contain 'admin'
        @(Select-TourSteps $script:Steps @{}).Count | Should -Be ($script:Steps.Count - 1)
    }
}

Describe 'Tour: card texts' {
    It 'mentions "Share with my helper" only when sharing is switched on' -ForEach @(@{ L = 'en' }, @{ L = 'ar' }) {
        $s = Get-Step 'actions'
        $share = Get-Text 'gui.btn.share' -Lang $L
        $was = Get-UiLang
        try {
            Set-UiLang $L
            (Get-TourStepText $s @{ share = $true }).Body | Should -Match ([regex]::Escape($share))
            (Get-TourStepText $s @{ share = $false }).Body | Should -Not -Match ([regex]::Escape($share))
        } finally { Set-UiLang $was }
    }
    It 'adds the "appears after a scan" note only when the part is not on screen' {
        $s = Get-Step 'actions'
        (Get-TourStepText $s @{} $true).Note | Should -BeNullOrEmpty
        (Get-TourStepText $s @{} $false).Note | Should -Be (Get-Text 'tour.acts.later')
        (Get-TourStepText (Get-Step 'scan') @{} $false).Note | Should -BeNullOrEmpty -Because 'the scan button is always there'
    }
    It 'quotes the real button and label names, so the tour never drifts from the window' -ForEach @(@{ L = 'en' }, @{ L = 'ar' }) {
        $was = Get-UiLang
        try {
            Set-UiLang $L
            (Get-TourStepText (Get-Step 'scan') @{}).Body | Should -Match ([regex]::Escape((Get-Text 'gui.btn.scan')))
            (Get-TourStepText (Get-Step 'quarantine') @{}).Body | Should -Match ([regex]::Escape((Get-Text 'gui.btn.q')))
            $f = (Get-TourStepText (Get-Step 'findings') @{}).Body
            $f | Should -Match ([regex]::Escape((Get-Text 'level.high'))); $f | Should -Match ([regex]::Escape((Get-Text 'level.med')))
            $m = (Get-TourStepText (Get-Step 'more') @{}).Body
            foreach ($k in 'gui.btn.restore', 'gui.btn.purge', 'gui.btn.clean') { $m | Should -Match ([regex]::Escape((Get-Text $k))) }
            (Get-TourStepText (Get-Step 'help') @{}).Body | Should -Match ([regex]::Escape((Get-Text 'gui.btn.copy')))
        } finally { Set-UiLang $was }
    }
    It 'has an English counter and Arabic counter with the same numbers' {
        Get-Text 'tour.count' 2 11 -Lang en | Should -Be 'Step 2 of 11'
        Get-Text 'tour.count' 2 11 -Lang ar | Should -Match '2.*11'
    }
}

Describe 'Tour: keys' {
    It '<Key> (<Dir>) -> <Want>' -ForEach @(
        @{ Key = 'Return'; Rtl = $false; Dir = 'ltr'; Want = 'next' }, @{ Key = 'Enter'; Rtl = $true; Dir = 'rtl'; Want = 'next' },
        @{ Key = 'Space'; Rtl = $false; Dir = 'ltr'; Want = 'next' }, @{ Key = 'PageDown'; Rtl = $false; Dir = 'ltr'; Want = 'next' },
        @{ Key = 'Right'; Rtl = $false; Dir = 'ltr'; Want = 'next' }, @{ Key = 'Left'; Rtl = $false; Dir = 'ltr'; Want = 'back' },
        @{ Key = 'Left'; Rtl = $true; Dir = 'rtl'; Want = 'next' }, @{ Key = 'Right'; Rtl = $true; Dir = 'rtl'; Want = 'back' },
        @{ Key = 'Back'; Rtl = $false; Dir = 'ltr'; Want = 'back' }, @{ Key = 'PageUp'; Rtl = $true; Dir = 'rtl'; Want = 'back' },
        @{ Key = 'Escape'; Rtl = $false; Dir = 'ltr'; Want = 'skip' }, @{ Key = 'Escape'; Rtl = $true; Dir = 'rtl'; Want = 'skip' },
        @{ Key = 'Tab'; Rtl = $false; Dir = 'ltr'; Want = '' }, @{ Key = 'A'; Rtl = $true; Dir = 'rtl'; Want = '' }, @{ Key = ''; Rtl = $false; Dir = 'ltr'; Want = '' }
    ) {
        Get-TourKeyAction $Key $Rtl | Should -Be $Want
    }
}

Describe 'Tour: where the card goes' {
    BeforeAll { $script:Area = New-Size 940 740; $script:Card = New-Size 384 200 }
    It 'centres the card when nothing is lit' {
        $p = Get-TourCardPlacement ([System.Drawing.Rectangle]::Empty) $script:Area $script:Card $false 14 16
        $p.Side | Should -Be 'center'; $p.X | Should -Be 278; $p.Y | Should -Be 270
    }
    It 'puts it below the control and lines it up with its left edge in English' {
        $p = Get-TourCardPlacement (New-Rect 100 100 200 40) $script:Area $script:Card $false 14 16
        $p.Side | Should -Be 'below'; $p.X | Should -Be 100; $p.Y | Should -Be 154
    }
    It 'lines it up with the right edge in Arabic (mirrored)' {
        $p = Get-TourCardPlacement (New-Rect 500 100 300 40) $script:Area $script:Card $true 14 16
        $p.Side | Should -Be 'below'; ($p.X + $script:Card.Width) | Should -Be 800
    }
    It 'goes above when there is no room below' {
        $p = Get-TourCardPlacement (New-Rect 100 600 200 40) $script:Area $script:Card $false 14 16
        $p.Side | Should -Be 'above'; $p.Y | Should -Be (600 - 14 - 200)
    }
    It 'goes beside a tall narrow control, on the reading-end side first' {
        $hole = New-Rect 300 40 120 660
        (Get-TourCardPlacement $hole $script:Area $script:Card $false 14 16).Side | Should -Be 'right'
        (Get-TourCardPlacement $hole $script:Area $script:Card $true 14 16).Side | Should -Be 'right' -Because 'there is no room on the left'
        $hole2 = New-Rect 480 40 120 660
        (Get-TourCardPlacement $hole2 $script:Area $script:Card $true 14 16).Side | Should -Be 'left'
    }
    It 'covers as little as possible of a control that fills the window' {
        $top = Get-TourCardPlacement (New-Rect 18 200 904 500) $script:Area $script:Card $false 14 16
        $top.Side | Should -Be 'over'; $top.Y | Should -Be 16 -Because 'there is more free room above the control'
        $bottom = Get-TourCardPlacement (New-Rect 18 20 904 560) $script:Area $script:Card $false 14 16
        $bottom.Side | Should -Be 'over'; $bottom.Y | Should -Be (740 - 16 - 200)
    }
    It 'always keeps the card inside the window, in both directions and at any size' {
        $rnd = New-Object System.Random 4242
        for ($i = 0; $i -lt 400; $i++) {
            $area = New-Size ($rnd.Next(500, 2600)) ($rnd.Next(400, 1500))
            $card = New-Size ([Math]::Min($area.Width - 48, $rnd.Next(260, 480))) ([Math]::Min($area.Height - 48, $rnd.Next(150, 300)))   # the window never makes a card wider than itself
            $w = $rnd.Next(10, $area.Width); $h = $rnd.Next(10, $area.Height)
            $hole = New-Rect ($rnd.Next(0, $area.Width - $w + 1)) ($rnd.Next(0, $area.Height - $h + 1)) $w $h
            $rtl = ($rnd.Next(0, 2) -eq 1)
            $p = Get-TourCardPlacement $hole $area $card $rtl 14 16
            $p.X | Should -BeGreaterOrEqual 16
            $p.Y | Should -BeGreaterOrEqual 16
            ($p.X + $card.Width) | Should -BeLessOrEqual ($area.Width - 16)
            ($p.Y + $card.Height) | Should -BeLessOrEqual ($area.Height - 16)
            if ($p.Side -in 'below', 'above', 'left', 'right') {
                $c = New-Rect $p.X $p.Y $card.Width $card.Height
                $c.IntersectsWith($hole) | Should -BeFalse -Because "side $($p.Side) must not cover the lit control"
            }
        }
    }
    It 'scales with the dpi (all distances are given by the caller)' {
        $p = Get-TourCardPlacement (New-Rect 200 200 300 80) (New-Size 1880 1480) (New-Size 768 400) $false 28 32
        $p.Side | Should -Be 'below'; $p.Y | Should -Be 308; $p.X | Should -Be 200
    }
}

Describe 'Tour: scrolling the target into view' {
    It 'does not scroll when the control and the card below it are visible' { Get-TourScrollDelta 100 150 700 200 14 16 | Should -Be 0 }
    It 'does not scroll when the card fits above a visible control' { Get-TourScrollDelta 400 600 650 200 14 16 | Should -Be 0 }
    It 'scrolls down just enough for a control cut off at the bottom and its card' { Get-TourScrollDelta 650 720 700 200 14 16 | Should -Be (720 + 14 + 200 + 16 - 700) }
    It 'scrolls up to a control above the visible part' { Get-TourScrollDelta -300 -250 700 200 14 16 | Should -Be (-316) }
    It 'brings a control that is taller than the window to the top' { Get-TourScrollDelta 900 1700 700 200 14 16 | Should -Be 884 }
    It 'leaves a fully visible tall control alone (the card then goes beside or over it)' { Get-TourScrollDelta 20 650 700 200 14 16 | Should -Be 0 }
}

Describe 'Tour: first use' {
    It 'is the first use when the reports folder does not exist' { Test-TourFirstRun (Join-Path $TestDrive 'nope') | Should -BeTrue }
    It 'is the first use when the folder has no report and no plan' {
        $d = Join-Path $TestDrive 'empty'; New-Item -ItemType Directory -Force -Path $d | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'notes.txt') -Value 'x'
        Test-TourFirstRun $d | Should -BeTrue
    }
    It 'is not the first use once a report or a plan exists' -ForEach @(@{ F = 'RAMDoctor-DESKTOP-DEMO-20260101-101500.html' }, @{ F = 'Plan-DESKTOP-DEMO-20260101-101500.json' }) {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $d | Out-Null
        Set-Content -LiteralPath (Join-Path $d $F) -Value '{}'
        Test-TourFirstRun $d | Should -BeFalse
    }
    It 'treats an empty path as the first use' { Test-TourFirstRun '' | Should -BeTrue }
}

Describe 'Tour: wiring and hygiene' {
    It 'is UTF-8 with BOM and has no user-facing literal (no Arabic, every text from the string table)' {
        $p = Join-Path $script:Root 'src\lib\Tour.ps1'
        $b = [IO.File]::ReadAllBytes($p)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeTrue
        [IO.File]::ReadAllText($p) | Should -Not -Match '[\u0600-\u06FF]'
    }
    It 'is loaded and wired by the window: header button, first-run banner, Connect-Tour' {
        $script:Gui | Should -Match ([regex]::Escape(". (Join-Path `$AppDir 'lib\Tour.ps1')"))
        $script:Gui | Should -Match '\$btnTour\s*=\s*New-Btn'
        $script:Gui | Should -Match '\$tourBar\s*=\s*New-TourBanner'
        $script:Gui | Should -Match 'Test-TourFirstRun \$ReportsDir'
        $script:Gui | Should -Match '(?m)^\s*Connect-Tour\s*$'
    }
    It 'never starts a scan, an action or a child process, and writes no file' {
        $t = [IO.File]::ReadAllText((Join-Path $script:Root 'src\lib\Tour.ps1'))
        foreach ($bad in 'Start-Task', 'Invoke-Cli', 'Start-Process', 'PerformClick', 'Set-Content', 'Out-File', 'Add-Content', 'New-Item', 'WriteAll', 'Remove-Item', 'Registry', 'HKCU:', 'Invoke-Expression') {
            $t | Should -Not -Match ([regex]::Escape($bad)) -Because "the tour must not use $bad"
        }
    }
}
