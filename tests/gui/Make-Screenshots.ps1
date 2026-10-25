<#
.SYNOPSIS
  Regenerates the pictures used by the README and the website (docs/assets/gui-*.png, report-sample*.png) from SYNTHETIC data
  (host "DESKTOP-DEMO", user "Friend") - nothing personal, no real scan. One run = one language.

.DESCRIPTION
  GUI pictures: launches the real window (src\RAM-Doctor-GUI.ps1) once per scenario with the developer switches
  -TestScript / -Theme / -Accent default / -Lang, loads a fake Plan-*.json, resizes the window to fit its content and saves a
  picture of the real window (Windows 11 title bar included). Needs an interactive desktop (it uses CopyFromScreen); the
  pictures are taken at the screen's native scale.

  Report pictures (report-sample, report-sample-dark): renders the demo report (tests\fixtures\Demo-ReportData.ps1) with the
  real src\lib\Report.ps1 and photographs it with a headless Edge / Chrome (1280 x 1232). Skipped with a warning when neither
  browser is installed.

  -Lang ar   Arabic, right-to-left (the default); pictures go to docs\assets
  -Lang en   English, left-to-right; pictures go to docs\assets\en
  -Only      a subset, e.g. -Only gui-light,report-sample
  -Dark      the dark-theme variants of the window and tour pictures (<name>-dark.png); the website shows them in dark mode

  Tour pictures (scenarios tour, tour-banner): every step of the guided tour (lib\Tour.ps1), cut to the card and the control it
  lights up, as <OutDir>\tour\NN-<step>.png, the whole window at the first step (tour-window.png) and the first-use banner
  (00-banner.png). The website's illustrated guide (docs\guide.html) shows them.

  powershell -NoProfile -ExecutionPolicy Bypass -File tests\gui\Make-Screenshots.ps1 -Lang en
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [string]$Work = '',
    [string[]]$Only = @(),   # several names: one string with commas also works (-Only tour,tour-banner under powershell -File)
    [switch]$Dark,           # the dark variants: every picture but gui-light / gui-dark again, in the dark theme, named <name>-dark.png
    [ValidateSet('ar', 'en')][string]$Lang = 'ar'
)

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$gui = Join-Path $repo 'src\RAM-Doctor-GUI.ps1'
if (-not $OutDir) { $OutDir = Join-Path $repo $(if ($Lang -eq 'en') { 'docs\assets\en' } else { 'docs\assets' }) }
if (-not $Work) { $Work = Join-Path $env:TEMP ('ramdoctor-shots-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
New-Item -ItemType Directory -Force -Path $OutDir, $Work | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($true)
. (Join-Path $repo 'src\lib\Strings.ps1')
$demoUser = $(if ($Lang -eq 'en') { 'alex_92' } else { 'ahmed_92' })   # the user name typed into the "profile" picture

# ---------------------------------------------------------------- synthetic plans (schema = what RAM-Doctor.ps1 writes; texts from the same string table)
function New-DemoPlan([string]$dir, [string]$scenario) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $stamp = '20260101-101500'
    $mem = [pscustomobject]@{ TotalGB = 15.9; UsedGB = 14.8; NonPagedGB = 0.9; PagedGB = 0.7 }
    $sus = @(); $obs = @()
    $t = { param([string]$k) Get-Text $k @args -Lang $Lang }
    switch ($scenario) {
        'high' {
            $v = [pscustomobject]@{ Level = 'high'; Headline = (& $t 'verdict.urgent') }
            $obs = @(
                [pscustomobject]@{ Level = 'high'; Title = (& $t 'obs.high.t' 1); Body = '-' },
                [pscustomobject]@{ Level = 'med'; Title = (& $t 'obs.grower.t'); Body = '-' },
                [pscustomobject]@{ Level = 'info'; Title = (& $t 'obs.standby.t'); Body = '-' })
            $sus = @(
                [pscustomobject]@{ id = 1; risk = 'High'; score = 11; name = 'svch0st.exe'; reasons = @((& $t 'sig.lookalike' 'svch0st.exe' 'svchost'), (& $t 'sig.zone.temp' 'Temp')) },
                [pscustomobject]@{ id = 2; risk = 'Medium'; score = 6; name = 'updater_x64.exe'; reasons = @((& $t 'sig.unsigned'), (& $t 'sig.zone.data' 'AppData')) },
                [pscustomobject]@{ id = 3; risk = 'Low'; score = 3; name = 'helper.exe'; reasons = @('-') })
        }
        'kernel' {
            $mem = [pscustomobject]@{ TotalGB = 15.9; UsedGB = 14.2; NonPagedGB = 6.4; PagedGB = 1.1 }
            $v = [pscustomobject]@{ Level = 'med'; Headline = (& $t 'verdict.driver') }
            $obs = @(
                [pscustomobject]@{ Level = 'med'; Title = (& $t 'obs.npp.med.t'); Body = '-' },
                [pscustomobject]@{ Level = 'med'; Title = (& $t 'obs.fast.t'); Body = '-' })
        }
        default {
            $v = [pscustomobject]@{ Level = 'ok'; Headline = (& $t 'verdict.ok') }
            $obs = @([pscustomobject]@{ Level = 'info'; Title = (& $t 'obs.standby.t'); Body = '-' })
        }
    }
    $plan = [pscustomobject]@{ tool = 'RAM-Doctor'; version = '1.0.0'; lang = $Lang; host = 'DESKTOP-DEMO'; created = '2026-01-01 10:15:00'; isAdmin = $true
        report = (Join-Path $dir "RAMDoctor-DESKTOP-DEMO-$stamp.html"); verdict = $v; observations = $obs; memory = $mem; suspects = $sus }
    # the window only shows plans of the PC it runs on, so the FILE names carry this PC's name (never shown in a picture)
    [IO.File]::WriteAllText((Join-Path $dir "Plan-$($env:COMPUTERNAME)-$stamp.json"), ($plan | ConvertTo-Json -Depth 6), $utf8)
    Set-Content -LiteralPath (Join-Path $dir "RAMDoctor-$($env:COMPUTERNAME)-$stamp.html") -Value '<html></html>'
}
foreach ($s in 'high', 'kernel', 'clean') { New-DemoPlan (Join-Path $Work $s) $s }
New-Item -ItemType Directory -Force -Path (Join-Path $Work 'empty') | Out-Null

# ---------------------------------------------------------------- helpers injected into every test script (they run inside the GUI process)
$common = @'
# A window that is not the foreground window draws grey caption buttons; make sure the picture shows the active look.
Add-Type -Namespace Shot -Name U -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p); [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f); [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();'
function Force-Foreground($f) {
    for ($try = 0; $try -lt 12; $try++) {
        $p = [uint32]0; $fg = [Shot.U]::GetForegroundWindow(); $t1 = [Shot.U]::GetWindowThreadProcessId($fg, [ref]$p); $t2 = [Shot.U]::GetCurrentThreadId()
        [void][Shot.U]::AttachThreadInput($t2, $t1, $true); [void][Shot.U]::SetForegroundWindow($f.Handle); [void][Shot.U]::AttachThreadInput($t2, $t1, $false)
        [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 250; [System.Windows.Forms.Application]::DoEvents()
        if ([Shot.U]::GetForegroundWindow() -eq $f.Handle) { break }
    }
}
function Fit-Window {
    if ($form.WindowState -ne 'Normal') { $form.WindowState = 'Normal' }   # a minimised or maximised window cannot be photographed
    $col.PerformLayout()
    $form.ClientSize = New-Object System.Drawing.Size((S 940), [math]::Min($col.Height + 4, [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height - 80))
    [System.Windows.Forms.Application]::DoEvents()
    Force-Foreground $form
}
function Find-Fields($c) { foreach ($k in $c.Controls) { if ($k -is [Fluent.FField]) { $k }; Find-Fields $k } }
function Dialog-Shot([scriptblock]$show, [string]$path) {
    $script:dsPath = $path
    $script:dsTimer = New-Object System.Windows.Forms.Timer
    $script:dsTimer.Interval = 1200
    $script:dsTimer.Add_Tick({
        $script:dsTimer.Stop()
        $f = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_ -ne $form })[0]   # ActiveForm is null when the process is not in the foreground
        if ($f) {
            $fields = @(Find-Fields $f); if ($fields.Count -gt 0) { $fields[0].Value = '%USER%' }
            Force-Foreground $f
            Save-WindowShot $script:dsPath $f
            $f.Close()
        }
    })
    $script:dsTimer.Start()
    & $show
}
$script:OUT = '%OUT%'
$script:SUF = '%SUF%'   # '' or '-dark'
$script:DemoShare = [pscustomobject]@{ Configured = $true; Name = '%USER%'; UserId = 'a1b2c3d4e5'; Helper = (Get-Text 'gui.helper.demo'); EndpointConfigured = $true }
# a picture of the part of the window around the tour card and the lit control (the guide shows them at 1:1)
function Save-Crop([string]$path, [System.Drawing.Rectangle]$r) {
    $tmp = Join-Path $env:TEMP ('ramdoctor-shot-' + [guid]::NewGuid().ToString('N') + '.png')
    Save-WindowShot $tmp
    $img = [System.Drawing.Bitmap]::FromFile($tmp)
    try {
        $r = [System.Drawing.Rectangle]::Intersect($r, (New-Object System.Drawing.Rectangle(0, 0, $img.Width, $img.Height)))
        $part = $img.Clone($r, $img.PixelFormat)
        $part.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $part.Dispose()
    } finally { $img.Dispose(); Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
function Save-TourShot([string]$path) {
    $o = $script:Tour.Overlay
    $frame = [Fluent.Win]::FrameBounds($form.Handle)
    $r = $o.CardBounds
    $pad = 28
    if (-not $o.Hole.IsEmpty) { $r = [System.Drawing.Rectangle]::Union($r, $o.Hole) } else { $pad = 56 }
    $r = [System.Drawing.Rectangle]::Inflate($r, $pad, $pad)
    Save-Crop $path (New-Object System.Drawing.Rectangle(($r.X + $o.Left - $frame.X), ($r.Y + $o.Top - $frame.Y), $r.Width, $r.Height))
}
'@

$scenarios = @(
    @{ Name = 'gui-light'; Reports = 'high'; Theme = 'Light'; Extra = @(); Body = @'
Load-Results (Get-LatestResult) $false
Set-Status 'gui.status.done' 100
Fit-Window
Save-WindowShot (Join-Path $script:OUT 'gui-light.png')
'@ },
    @{ Name = 'gui-dark'; Reports = 'high'; Theme = 'Dark'; Extra = @(); Body = @'
Load-Results (Get-LatestResult) $false
Set-Status 'gui.status.done' 100
Fit-Window
Save-WindowShot (Join-Path $script:OUT 'gui-dark.png')
'@ },
    @{ Name = 'gui-progress'; Reports = 'empty'; Theme = 'Light'; Extra = @(); Body = @'
Hide-TourOffer   # a real scan hides the first-use offer
$btnScan.Enabled = $false; $btnScan.Text = Get-Text 'gui.btn.scanning'
$bar.Value = 46
Set-Status 'gui.step.8' 46
Show-Info 'Info' 'gui.info.scanning.t' 'gui.info.scanning.m'
Fit-Window
Save-WindowShot (Join-Path $script:OUT ('gui-progress' + $script:SUF + '.png'))
'@ },
    @{ Name = 'gui-clean'; Reports = 'clean'; Theme = 'Light'; Extra = @(); Body = @'
Load-Results (Get-LatestResult) $false
Set-Status 'gui.status.done' 100
Fit-Window
Save-WindowShot (Join-Path $script:OUT ('gui-clean' + $script:SUF + '.png'))
'@ },
    @{ Name = 'gui-kernel'; Reports = 'kernel'; Theme = 'Light'; Extra = @(); Body = @'
Load-Results (Get-LatestResult) $false
Set-Status 'gui.status.done' 100
Fit-Window
Save-WindowShot (Join-Path $script:OUT ('gui-kernel' + $script:SUF + '.png'))
'@ },
    @{ Name = 'gui-more'; Reports = 'clean'; Theme = 'Light'; Extra = @('-ShareForceConfigured'); Body = @'
Load-Results (Get-LatestResult) $false
Set-Status 'gui.status.done' 100
$script:share = $script:DemoShare
Apply-ShareVisibility
$exMore.Expanded = $true; Resize-Cards
Fit-Window
Save-WindowShot (Join-Path $script:OUT ('gui-more' + $script:SUF + '.png'))
'@ },
    @{ Name = 'gui-share'; Reports = 'high'; Theme = 'Light'; Extra = @('-ShareForceConfigured'); Body = @'
Load-Results (Get-LatestResult) $false
$script:share = $script:DemoShare
Apply-ShareVisibility
$pv = @{ Dir = $env:TEMP; Sizes = @{ 'summary.md' = '3'; 'report.html' = '31'; 'plan.json' = '14' } }
Dialog-Shot { [void](Show-ShareDialog $pv) } (Join-Path $script:OUT ('gui-share' + $script:SUF + '.png'))
'@ },
    @{ Name = 'gui-profile'; Reports = 'high'; Theme = 'Light'; Extra = @('-ShareForceConfigured'); Body = @'
Load-Results (Get-LatestResult) $false
Dialog-Shot { [void](Show-ProfileDialog) } (Join-Path $script:OUT ('gui-profile' + $script:SUF + '.png'))
'@ },
    # the guided tour: every step (card + lit control) for the illustrated guide (docs/guide.html), plus the whole window
    @{ Name = 'tour'; Reports = 'high'; Theme = 'Light'; Extra = @('-ShareForceConfigured'); Body = @'
Load-Results (Get-LatestResult) $false
Set-Status 'gui.status.done' 100
Fit-Window
$dir = Join-Path $script:OUT 'tour'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
$script:TourNoAnimation = $true
Start-Tour
for ($i = 0; $i -lt $script:Tour.Steps.Count; $i++) {
    Show-TourStep $i
    [System.Windows.Forms.Application]::DoEvents()
    if ($i -eq 0) { Save-WindowShot (Join-Path $dir ('tour-window' + $script:SUF + '.png')) }
    Save-TourShot (Join-Path $dir ('{0:00}-{1}{2}.png' -f ($i + 1), $script:Tour.Steps[$i].Id, $script:SUF))
}
Stop-Tour
'@ },
    # first use: the top of the window, where the "Ready to scan" bar offers the tour
    @{ Name = 'tour-banner'; Reports = 'empty'; Theme = 'Light'; Extra = @(); Body = @'
Fit-Window
$dir = Join-Path $script:OUT 'tour'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
$frame = [Fluent.Win]::FrameBounds($form.Handle)
$r = [Fluent.Win]::ScreenRect($info.Handle)
Save-Crop (Join-Path $dir ('00-banner' + $script:SUF + '.png')) (New-Object System.Drawing.Rectangle(0, 0, $frame.Width, ($r.Bottom - $frame.Y + (S 16))))
'@ }
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$suffix = $(if ($Dark) { '-dark' } else { '' })
foreach ($s in $scenarios) {
    if ($Only.Count -gt 0 -and $Only -notcontains $s.Name) { continue }
    if ($Dark -and $s.Name -in 'gui-light', 'gui-dark') { continue }   # that pair is already light + dark
    $theme = $(if ($Dark) { 'Dark' } else { $s.Theme })
    Write-Host ("  {0} ({1}) ..." -f $s.Name, $Lang)
    # Park the mouse at the right edge of the PRIMARY screen first: the window opens on the screen that holds the pointer
    # (CenterScreen), and a pointer resting over the title bar would pop up the Windows 11 snap-layout flyout into the picture.
    $prim = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(($prim.Right - 3), [int]($prim.Top + $prim.Height / 2))
    $ts = Join-Path $Work ($s.Name + '.test.ps1')
    $body = ($common.Replace('%OUT%', $OutDir).Replace('%USER%', $demoUser).Replace('%SUF%', $suffix)) + "`r`n" + $s.Body + "`r`n" + '$form.Close()' + "`r`n"
    [IO.File]::WriteAllText($ts, $body, $utf8)
    Remove-Item -LiteralPath ($ts + '.error.txt') -ErrorAction SilentlyContinue
    $guiArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $gui), '-ReportsDir', ('"{0}"' -f (Join-Path $Work $s.Reports)),
        '-QuarantineDir', ('"{0}"' -f (Join-Path $Work 'store')), '-AllowNonAdmin', '-Theme', $theme, '-Accent', 'default', '-Lang', $Lang, '-TestScript', ('"{0}"' -f $ts)) + $s.Extra
    $p = Start-Process -FilePath powershell.exe -ArgumentList $guiArgs -PassThru
    if (-not $p.WaitForExit(90000)) { try { $p.Kill() } catch { }; Write-Warning "$($s.Name): GUI did not close in time" }
    if (Test-Path ($ts + '.error.txt')) { Write-Warning "$($s.Name): test script error"; Get-Content ($ts + '.error.txt') }
}

# ---------------------------------------------------------------- the report, photographed with a headless browser
$reportShots = @(@{ Name = 'report-sample'; Theme = 'light' }, @{ Name = 'report-sample-dark'; Theme = 'dark' })
$want = @($reportShots | Where-Object { -not $Dark -and ($Only.Count -eq 0 -or $Only -contains $_.Name) })   # report-sample-dark is already the dark one
if ($want.Count -gt 0) {
    $browser = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $browser) { Write-Warning 'No Edge or Chrome found: the report pictures were skipped.' }
    else {
        . (Join-Path $repo 'src\lib\Report.ps1')
        . (Join-Path $repo 'tests\fixtures\Demo-ReportData.ps1')
        $html = New-RamReportHtml (Get-DemoReportData -Scenario leak -Lang $Lang)
        $open = $(if ($Lang -eq 'en') { '<html lang="en" dir="ltr">' } else { '<html lang="ar" dir="rtl">' })
        foreach ($r in $want) {
            Write-Host ("  {0} ({1}) ..." -f $r.Name, $Lang)
            $page = Join-Path $Work ($r.Name + '.html')
            [IO.File]::WriteAllText($page, $html.Replace($open, $open.Replace('>', (' data-theme="{0}">' -f $r.Theme))), $utf8)
            $png = Join-Path $OutDir ($r.Name + '.png')
            Remove-Item -LiteralPath $png -ErrorAction SilentlyContinue
            $bargs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--disable-extensions', ('--user-data-dir="{0}"' -f (Join-Path $Work 'browser')),
                '--window-size=1280,1232', '--force-device-scale-factor=1', ('--screenshot="{0}"' -f $png), ('"{0}"' -f ([Uri]$page).AbsoluteUri))
            $bp = Start-Process -FilePath $browser -ArgumentList $bargs -PassThru -WindowStyle Hidden
            if (-not $bp.WaitForExit(60000)) { try { $bp.Kill() } catch { }; Write-Warning "$($r.Name): the browser did not finish in time" }
            if (-not (Test-Path -LiteralPath $png)) { Write-Warning "$($r.Name): no picture was written" }
        }
    }
}
Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Done. Pictures are in $OutDir"
