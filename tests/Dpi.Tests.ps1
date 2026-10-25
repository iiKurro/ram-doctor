#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Display scaling of the window kit (src\lib\Fluent.cs): the scale helpers, the fonts, the font re-scaling after a monitor
# change and the tour card layout, at 100, 125, 150, 175 and 200 %. Nothing here touches the PC's display settings: the
# kit is told a dpi (Theme.SetDpi) the way the window tells it the dpi of its monitor. The real window at every scale is
# checked by tests\gui\Scale.Test.ps1. ASCII only.

# The -ForEach data has to exist while Pester discovers the tests (BeforeAll runs only later).
BeforeDiscovery {
    $script:Scales = @(@{ Pct = 100; Dpi = 96 }, @{ Pct = 125; Dpi = 120 }, @{ Pct = 150; Dpi = 144 }, @{ Pct = 175; Dpi = 168 }, @{ Pct = 200; Dpi = 192 })
}
BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $script:Root = Get-RepoRoot
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if (-not ('Fluent.Theme' -as [type])) {
        Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing', 'Accessibility' -Language CSharp -TypeDefinition ([IO.File]::ReadAllText((Join-Path $script:Root 'src\lib\Fluent.cs')))
    }
    [Fluent.Theme]::Apply($false, 'default', [System.Drawing.Color]::Empty)
    $script:Scales = @(@{ Pct = 100; Dpi = 96 }, @{ Pct = 125; Dpi = 120 }, @{ Pct = 150; Dpi = 144 }, @{ Pct = 175; Dpi = 168 }, @{ Pct = 200; Dpi = 192 })
}
AfterAll { [Fluent.Theme]::SetDpi(96, 96) }

Describe 'Scale helpers' {
    AfterEach { [Fluent.Theme]::SetDpi(96, 96) }
    It 'at <Pct> % (<Dpi> dpi) every 96-dpi size is multiplied by <Pct> %' -ForEach $script:Scales {
        [Fluent.Theme]::SetDpi($Dpi, 96)
        [Fluent.Theme]::Scale | Should -Be ($Dpi / 96)
        foreach ($v in 1, 2, 4, 6, 14, 16, 20, 34, 48, 64, 384, 940) {
            [Fluent.Theme]::S($v) | Should -Be ([int][Math]::Round($v * $Dpi / 96.0, [MidpointRounding]::AwayFromZero))
            [Fluent.Theme]::Sf($v) | Should -Be ([single]($v * $Dpi / 96.0))
        }
    }
    It 'rounds half pixels away from zero (2 px at 125 % = 3 px, never a gap that vanishes)' {
        [Fluent.Theme]::SetDpi(120, 96)
        [Fluent.Theme]::S(2) | Should -Be 3
        [Fluent.Theme]::S(1) | Should -Be 1
    }
    It 'falls back to 96 dpi for a nonsense value' {
        [Fluent.Theme]::SetDpi(0, 96); [Fluent.Theme]::Scale | Should -Be 1
        [Fluent.Theme]::SetDpi(5000, 96); [Fluent.Theme]::Scale | Should -Be 1
    }
}

Describe 'Fonts follow the dpi' {
    AfterEach { [Fluent.Theme]::SetDpi(96, 96) }
    It 'on a <Pct> % monitor of a 100 % system, point sizes grow by <Pct> % and icon pixels too' -ForEach $script:Scales {
        [Fluent.Theme]::SetDpi($Dpi, 96)
        [Fluent.Theme]::FontScale | Should -Be ($Dpi / 96)
        [Math]::Abs([Fluent.Theme]::UI(10, 'Regular').Size - 10 * $Dpi / 96) | Should -BeLessThan 0.02
        [Math]::Abs([Fluent.Theme]::Semi(13).Size - 13 * $Dpi / 96) | Should -BeLessThan 0.02
        [Fluent.Theme]::Icons(16).Unit | Should -Be 'Pixel'
        [Math]::Abs([Fluent.Theme]::Icons(16).Size - 16 * $Dpi / 96) | Should -BeLessThan 0.02
    }
    It 'when Windows itself runs at <Pct> %, point sizes stay as written (GDI already turns them into the right pixels)' -ForEach $script:Scales {
        [Fluent.Theme]::SetDpi($Dpi, $Dpi)
        [Fluent.Theme]::FontScale | Should -Be 1
        [Fluent.Theme]::UI(10, 'Regular').Size | Should -Be 10
        [Math]::Abs([Fluent.Theme]::Icons(16).Size - 16 * $Dpi / 96) | Should -BeLessThan 0.02 -Because 'icons are drawn in pixels'
    }
    It 'keeps the application icon at its fixed bitmap size' {
        [Fluent.Theme]::SetDpi(192, 96)
        [Fluent.Theme]::IconsPx(34).Size | Should -Be 34
    }
    It 're-scales every font in a window after a monitor change, without scaling an inherited font twice' {
        $p = New-Object System.Windows.Forms.Panel
        $p.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        $inherits = New-Object System.Windows.Forms.Label
        $own = New-Object System.Windows.Forms.Label; $own.Font = New-Object System.Drawing.Font('Segoe UI', 12)
        $p.Controls.Add($inherits); $p.Controls.Add($own)
        [Fluent.Theme]::RescaleFonts($p, 1.5)
        $p.Font.Size | Should -Be 15
        $inherits.Font.Size | Should -Be 15
        $own.Font.Size | Should -Be 18
        $p.Dispose()
    }
}

Describe 'The tour card at every scale' {
    BeforeAll {
        function Get-CardAt([int]$dpi, [bool]$rtl) {
            [Fluent.Theme]::SetDpi($dpi, 96)
            $o = New-Object Fluent.FCoach
            $o.Title = 'Keep or send the result'; $o.Body = ('Open the full report, open the folder that holds it, or copy a short summary without personal details to paste into a chat.')
            $o.Note = 'These buttons appear after a scan.'; $o.Counter = 'Step 5 of 11'; $o.StepIndex = 4; $o.StepCount = 11
            $o.NextText = 'Next'; $o.BackText = 'Back'; $o.SkipText = 'Skip tour'; $o.Rtl = $rtl; $o.CanBack = $true
            $size = $o.MeasureCard()
            $r = [pscustomobject]@{ Size = $size; Next = $o.NextBounds; Back = $o.BackBounds; Skip = $o.SkipBounds }
            $o.Dispose()
            return $r
        }
    }
    AfterEach { [Fluent.Theme]::SetDpi(96, 96) }
    It 'at <Pct> % the card is <Pct> % as wide, and its buttons sit inside it without touching each other' -ForEach $script:Scales {
        foreach ($rtl in $false, $true) {
            $c = Get-CardAt $Dpi $rtl
            $c.Size.Width | Should -Be ([int][Math]::Round(384 * $Dpi / 96.0, [MidpointRounding]::AwayFromZero))
            $card = New-Object System.Drawing.Rectangle(0, 0, $c.Size.Width, $c.Size.Height)
            foreach ($b in $c.Next, $c.Back, $c.Skip) { $card.Contains($b) | Should -BeTrue }
            $c.Next.IntersectsWith($c.Back) | Should -BeFalse
            $c.Back.IntersectsWith($c.Skip) | Should -BeFalse
            if ($rtl) { $c.Next.X | Should -BeLessThan $c.Back.X -Because 'right-to-left: Next is on the left' }
            else { $c.Next.X | Should -BeGreaterThan $c.Back.X }
        }
    }
    It 'grows in proportion with the scale (no fixed pixel left behind)' {
        $base = Get-CardAt 96 $false
        foreach ($s in $script:Scales) {
            $c = Get-CardAt $s.Dpi $false
            $k = $s.Dpi / 96.0
            ($c.Size.Height / ($base.Size.Height * $k)) | Should -BeGreaterThan 0.85
            ($c.Size.Height / ($base.Size.Height * $k)) | Should -BeLessThan 1.15
            ($c.Next.Height / ($base.Next.Height * $k)) | Should -BeGreaterThan 0.95
        }
    }
}

Describe 'Display awareness' {
    It 'the window makes the process dpi-aware before it builds anything, and reacts to monitor changes' {
        $gui = [IO.File]::ReadAllText((Join-Path $script:Root 'src\RAM-Doctor-GUI.ps1'))
        $enable = $gui.IndexOf('[Fluent.Dpi]::Enable()')
        $enable | Should -BeGreaterThan 0
        $enable | Should -BeLessThan $gui.IndexOf('New-Object System.Windows.Forms.Form') -Because 'the awareness has to be set before the first window exists'
        $gui | Should -Match 'Fluent\.DpiWatcher'
        $gui | Should -Match 'function Set-WindowDpi'
        $gui | Should -Match 'Initialize-WindowScale'
    }
    It 'asks Windows for Per-Monitor V2 first, then per-monitor, then system awareness' {
        $cs = [IO.File]::ReadAllText((Join-Path $script:Root 'src\lib\Fluent.cs'))
        $a = $cs.IndexOf('if (SetProcessDpiAwarenessContext(new IntPtr(-4)))'); $b = $cs.IndexOf('if (SetProcessDpiAwareness(2) == 0)'); $c = $cs.IndexOf('if (SetProcessDPIAware())')
        $a | Should -BeGreaterThan 0
        $a | Should -BeLessThan $b
        $b | Should -BeLessThan $c
    }
    It 'reports the system dpi' { [Fluent.Dpi]::ForSystem() | Should -BeGreaterOrEqual 96 }
}
