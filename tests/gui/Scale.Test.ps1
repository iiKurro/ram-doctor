<#
.SYNOPSIS
  Display scaling test of the real window (src\RAM-Doctor-GUI.ps1) at 100, 125, 150, 175 and 200 %, in Arabic and English,
  on ANY screen: the window is started with the developer switch -UiScale, which draws it exactly as Windows would at that
  scale (fonts, sizes, custom painting). Nothing on the PC is changed; no display setting is touched.

.DESCRIPTION
  For every language x scale, in two states (first use with the tour offer, and a result with findings and "More" open):
    * no text is cut off: every label's text fits its box (wrapped as the label wraps it), every button's text and icon fit
      the button, expander and check box texts fit;
    * nothing overlaps: no two visible controls in the same container intersect, and no control sticks out of its container;
    * the tour: at every step the card is inside the window, its buttons are inside the card, and it does not cover the lit
      control (unless that control is taller than the window).
  Also, once at the screen's own scale: a monitor change is simulated (WM_DPICHANGED to 144 dpi and back to the start) and
  the window must grow by exactly that factor and come back to its sizes.
  -OutDir keeps a picture of every page and tour card for a human look (default: a temporary folder that is removed).

  powershell -NoProfile -ExecutionPolicy Bypass -File tests\gui\Scale.Test.ps1 [-Lang ar|en|both] [-Scales 100,150] [-OutDir <dir>]
#>
[CmdletBinding()]
param([ValidateSet('ar', 'en', 'both')][string]$Lang = 'both', [string]$Scales = '100,125,150,175,200', [string]$OutDir = '')

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$gui = Join-Path $repo 'src\RAM-Doctor-GUI.ps1'
$utf8 = New-Object System.Text.UTF8Encoding($true)
$keep = [bool]$OutDir
$work = Join-Path $env:TEMP ('ramdoctor-scaletest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
if (-not $OutDir) { $OutDir = Join-Path $work 'pictures' }
New-Item -ItemType Directory -Force -Path $work, $OutDir | Out-Null
. (Join-Path $repo 'src\lib\Strings.ps1')

function New-DemoReports([string]$dir, [string]$l) {   # one synthetic result of THIS PC (the window only shows its own PC's plans)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $t = { param([string]$k) Get-Text $k @args -Lang $l }
    $stamp = '20260101-101500'
    $sus = @(
        [pscustomobject]@{ id = 1; risk = 'High'; score = 11; name = 'svch0st.exe'; reasons = @((& $t 'sig.lookalike' 'svch0st.exe' 'svchost')) },
        [pscustomobject]@{ id = 2; risk = 'Medium'; score = 6; name = 'updater_x64.exe'; reasons = @((& $t 'sig.unsigned')) })
    $plan = [pscustomobject]@{ tool = 'RAM-Doctor'; version = '1.0.0'; lang = $l; host = 'DESKTOP-DEMO'; created = '2026-01-01 10:15:00'; isAdmin = $true
        report = 'x'; verdict = [pscustomobject]@{ Level = 'high'; Headline = (& $t 'verdict.urgent') }
        observations = @([pscustomobject]@{ Level = 'high'; Title = (& $t 'obs.high.t' 1); Body = '-' }, [pscustomobject]@{ Level = 'med'; Title = (& $t 'obs.grower.t'); Body = '-' })
        memory = [pscustomobject]@{ TotalGB = 15.9; UsedGB = 14.8; NonPagedGB = 0.9; PagedGB = 0.7 }; suspects = $sus }
    [IO.File]::WriteAllText((Join-Path $dir "Plan-$($env:COMPUTERNAME)-$stamp.json"), ($plan | ConvertTo-Json -Depth 6), $utf8)
    Set-Content -LiteralPath (Join-Path $dir "RAMDoctor-$($env:COMPUTERNAME)-$stamp.html") -Value '<html></html>'
}

# ---------------------------------------------------------------- the checks that run INSIDE the window process
$inner = @'
$out = '%RESULT%'; $pics = '%PICS%'; $tag = '%TAG%'; $state = '%STATE%'; $simulate = %SIM%
function Log2($s) { Add-Content -LiteralPath $out -Value $s -Encoding UTF8 }
function Check([string]$name, $cond) { if ($cond) { Log2 "PASS  [$tag] $name" } else { Log2 "FAIL  [$tag] $name" } }
function Pump([int]$ms = 200) { $end = (Get-Date).AddMilliseconds($ms); do { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 } while ((Get-Date) -lt $end) }

function Get-LayoutProblems {
    $bad = New-Object System.Collections.Generic.List[string]
    $flags = [System.Windows.Forms.TextFormatFlags]'WordBreak, TextBoxControl, NoPrefix'
    $walk = {
        param($c)
        $kids = @($c.Controls | Where-Object { $_.Visible })
        foreach ($k in $kids) {
            $name = '{0}[{1}]' -f $k.GetType().Name, ($k.Text -replace '\s+', ' ').Substring(0, [Math]::Min(28, ($k.Text -replace '\s+', ' ').Length))
            if ($k -is [System.Windows.Forms.Label] -and $k.Text) {
                $need = [System.Windows.Forms.TextRenderer]::MeasureText($k.Text, $k.Font, (New-Object System.Drawing.Size([Math]::Max(1, $k.ClientSize.Width), 100000)), $flags).Height
                if ($need -gt $k.ClientSize.Height + 2) { $bad.Add("cut text: $name needs $need px, has $($k.ClientSize.Height)") }
            }
            if ($k -is [Fluent.FButton] -and $k.Text) { $w = $k.ContentWidth(); if ($w -gt $k.Width + 1) { $bad.Add("button too narrow: $name needs $w, has $($k.Width)") } }
            if ($k -is [Fluent.FExpander]) {
                $avail = $k.Width - 2 * (S 14) - (S 36) - (S 32)
                $w = [System.Windows.Forms.TextRenderer]::MeasureText($k.Text, $k.Font).Width
                if ($w -gt $avail + 1) { $bad.Add("expander text cut: $name needs $w, has $avail") }
            }
            if ($k -is [Fluent.FInfoBar]) { $h = $k.Height; [void]$k.FitHeight(); if ($k.Height -gt $h + 1) { $bad.Add("info bar too low: $name") } }
            # inside its container (a scrolling page may be taller than its window)
            if ($c -ne $page) {
                $cr = $c.ClientRectangle
                if ($k.Left -lt -1 -or $k.Top -lt -1 -or $k.Right -gt $cr.Width + 1 -or $k.Bottom -gt $cr.Height + 1) { $bad.Add("outside its container: $name $($k.Bounds) in $($cr.Size) of $($c.GetType().Name)") }
            }
            & $walk $k
        }
        for ($i = 0; $i -lt $kids.Count; $i++) {
            for ($j = $i + 1; $j -lt $kids.Count; $j++) {
                if ($kids[$i].Bounds.IntersectsWith($kids[$j].Bounds)) { $bad.Add("overlap in $($c.GetType().Name): $($kids[$i].GetType().Name)[$($kids[$i].Text)] / $($kids[$j].GetType().Name)[$($kids[$j].Text)]") }
            }
        }
    }
    & $walk $form
    return ,$bad
}

try {
    $col.PerformLayout()
    $form.ClientSize = New-Object System.Drawing.Size((S 940), (S 740))
    Pump 300
    Check "the window is drawn at the requested scale ($([Fluent.Theme]::Scale))" ([Math]::Abs([Fluent.Theme]::Scale - %SCALE% / 100.0) -lt 0.01 -or $simulate)
    if ($state -eq 'results') {
        [void](Load-Results (Get-LatestResult) $false); Set-Status 'gui.status.done' 100
        if (-not $exMore.Expanded) { $exMore.Toggle() }
        Pump 300
        Check 'the findings list is there' ($list.Items.Count -eq 2 -and $find.Visible)
    } else {
        Check 'first use: the ready bar offers the tour' ($script:TourOfferUi.On -and $script:TourOfferUi.Go.Visible)
    }
    $p = Get-LayoutProblems
    Check ("nothing is cut off, overlaps or sticks out ({0})" -f ($p -join ' | ')) ($p.Count -eq 0)
    Save-Shot (Join-Path $pics "$tag-page.png")

    if ($simulate) {
        # a monitor with another scale: WM_DPICHANGED to 144 dpi, then back. The window must grow by exactly 1.5 and come back.
        Add-Type -Namespace ScaleT -Name U -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);'
        $d0 = [Fluent.Theme]::Dpi
        $w0 = $btnScan.Width; $h0 = $hdr.Height; $f0 = $btnScan.Font.Size; $c0 = $form.ClientSize
        $send = { param([int]$dpi)
            $fb = $form.Bounds; $k = $dpi / [double][Fluent.Theme]::Dpi
            $r = [Runtime.InteropServices.Marshal]::AllocHGlobal(16)
            try {
                [Runtime.InteropServices.Marshal]::WriteInt32($r, 0, $fb.Left); [Runtime.InteropServices.Marshal]::WriteInt32($r, 4, $fb.Top)
                [Runtime.InteropServices.Marshal]::WriteInt32($r, 8, $fb.Left + [int]($fb.Width * $k)); [Runtime.InteropServices.Marshal]::WriteInt32($r, 12, $fb.Top + [int]($fb.Height * $k))
                [void][ScaleT.U]::SendMessage($form.Handle, 0x02E0, [IntPtr]($dpi -bor ($dpi -shl 16)), $r)
            } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($r) }
            Pump 400
        }
        & $send 144
        $k = 144 / $d0
        Check ("moved to a 150 % monitor: sizes x{0:0.##} (scan button {1} -> {2}, header {3} -> {4})" -f $k, $w0, $btnScan.Width, $h0, $hdr.Height) ([Math]::Abs($btnScan.Width - $w0 * $k) -le 2 -and [Math]::Abs($hdr.Height - $h0 * $k) -le 2 -and [Fluent.Theme]::Dpi -eq 144)
        Check ("... and fonts x{0:0.##} ({1} -> {2})" -f $k, $f0, $btnScan.Font.Size) ([Math]::Abs($btnScan.Font.Size - $f0 * $k) -lt 0.2)
        $p = Get-LayoutProblems
        Check ("... nothing cut off or overlapping there either ({0})" -f ($p -join ' | ')) ($p.Count -eq 0)
        & $send $d0
        Check ("and back: the same sizes again (scan button {0}, header {1}, font {2})" -f $btnScan.Width, $hdr.Height, $btnScan.Font.Size) ([Math]::Abs($btnScan.Width - $w0) -le 2 -and [Math]::Abs($hdr.Height - $h0) -le 2 -and [Math]::Abs($btnScan.Font.Size - $f0) -lt 0.2 -and [Fluent.Theme]::Dpi -eq $d0)
    }

    # the tour at this scale
    $script:TourNoAnimation = $true
    Start-Tour; Pump 200
    $bad = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $script:Tour.Steps.Count; $i++) {
        Show-TourStep $i; Pump 120
        $o = $script:Tour.Overlay; $id = $script:Tour.Steps[$i].Id
        $c = $o.CardBounds; $area = New-Object System.Drawing.Rectangle(0, 0, $o.ClientSize.Width, $o.ClientSize.Height)
        if (-not $area.Contains($c)) { $bad.Add("$id card outside the window $c in $($area.Size)") }
        foreach ($b in @($o.NextBounds, $o.BackBounds, $o.SkipBounds)) { if (-not $b.IsEmpty -and -not $c.Contains($b)) { $bad.Add("$id button outside the card") } }
        if (-not $o.Hole.IsEmpty) {
            $free = ($c.Bottom -le $o.Hole.Top -or $c.Top -ge $o.Hole.Bottom -or $c.Right -le $o.Hole.Left -or $c.Left -ge $o.Hole.Right)
            $m = [Fluent.Theme]::S(16)
            if (-not $free -and -not ($c.Top -le $m -or $c.Bottom -ge $o.ClientSize.Height - $m)) { $bad.Add("$id card covers the lit control") }
        }
        if ($id -in 'scan', 'findings', 'help') {
            try { Save-WindowShot (Join-Path $pics "$tag-tour-$id.png") } catch { }
        }
    }
    Stop-Tour
    Check ("the tour card fits at every step ({0})" -f ($bad -join ' | ')) ($bad.Count -eq 0)
    Check "the tour never stopped after an error ('$script:TourLastError')" (-not $script:TourLastError)
} catch { Log2 ("FAIL  [$tag] error: " + $_.Exception.Message + ' ' + $_.InvocationInfo.PositionMessage) }
Log2 "DONE [$tag]"
$form.Close()
'@

$langs = $(if ($Lang -eq 'both') { @('en', 'ar') } else { @($Lang) })
$scaleList = @($Scales -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
$runs = New-Object System.Collections.Generic.List[object]
foreach ($l in $langs) {
    foreach ($s in $scaleList) { foreach ($st in 'first', 'results') { $runs.Add(@{ Lang = $l; Scale = $s; State = $st; Sim = $false }) } }
    $runs.Add(@{ Lang = $l; Scale = 0; State = 'results'; Sim = $true })   # the screen's own scale, plus a simulated monitor change
}
$result = Join-Path $work 'result.txt'
$fails = 0; $done = 0
foreach ($r in $runs) {
    $tag = '{0}-{1}-{2}' -f $r.Lang, $(if ($r.Sim) { 'screen' } else { $r.Scale }), $r.State
    $rep = Join-Path $work ("reports-$tag")
    if ($r.State -eq 'results') { New-DemoReports $rep $r.Lang } else { New-Item -ItemType Directory -Force -Path $rep | Out-Null }
    $ts = Join-Path $work "$tag.ps1"
    [IO.File]::WriteAllText($ts, $inner.Replace('%RESULT%', $result).Replace('%PICS%', $OutDir).Replace('%TAG%', $tag).Replace('%STATE%', $r.State).Replace('%SCALE%', [string]$r.Scale).Replace('%SIM%', $(if ($r.Sim) { '$true' } else { '$false' })), $utf8)
    $theme = $(if ($r.Lang -eq 'ar') { 'Light' } else { 'Dark' })   # both themes are covered across the languages
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $gui), '-ReportsDir', ('"{0}"' -f $rep), '-QuarantineDir', ('"{0}"' -f (Join-Path $work 'store')),
        '-AllowNonAdmin', '-Unattended', '-Theme', $theme, '-Accent', 'default', '-Lang', $r.Lang, '-ShareForceConfigured', '-TestScript', ('"{0}"' -f $ts))
    if (-not $r.Sim) { $a += @('-UiScale', $r.Scale) }
    $p = Start-Process -FilePath powershell.exe -ArgumentList $a -PassThru
    if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch { }; Add-Content -LiteralPath $result -Value "FAIL  [$tag] the window did not close in time" -Encoding UTF8 }
    if (Test-Path ($ts + '.error.txt')) { Add-Content -LiteralPath $result -Value ("FAIL  [$tag] test script error: " + (Get-Content ($ts + '.error.txt') -Raw)) -Encoding UTF8 }
}
$lines = @(Get-Content -LiteralPath $result -Encoding UTF8 -ErrorAction SilentlyContinue)
foreach ($l in $lines) { if ($l -match '^FAIL') { Write-Host $l -ForegroundColor Red; $fails++ } elseif ($l -match '^PASS') { Write-Host $l -ForegroundColor Green } elseif ($l -match '^DONE') { $done++ } }
$expected = $runs.Count
Write-Host ("`nScale test: {0} passed, {1} failed, {2}/{3} runs finished" -f @($lines | Where-Object { $_ -match '^PASS' }).Count, $fails, $done, $expected) -ForegroundColor $(if ($fails -eq 0 -and $done -eq $expected) { 'Green' } else { 'Red' })
if ($keep) { Write-Host "Pictures: $OutDir" }
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
exit $(if ($fails -eq 0 -and $done -eq $expected) { 0 } else { 1 })
