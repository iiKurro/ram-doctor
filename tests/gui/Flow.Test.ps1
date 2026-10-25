<#
.SYNOPSIS
  End-to-end test of the real GUI (src\RAM-Doctor-GUI.ps1), driven by PerformClick() from inside the window, in Arabic and in English.

.DESCRIPTION
  Flow: language and layout direction -> scan -> copy summary -> live language switch (and back) -> quarantine -> restore -> scan ->
  quarantine -> purge -> share (dry-run, no network) -> clear reports.
  It compiles a HARMLESS memory-hog exe with a random name in %TEMP%, registers it under HKCU Run, and only ever selects that file.
  The GUI runs with its own private %TEMP% so we can prove nothing is left behind. No UAC prompt: the GUI uses -AllowNonAdmin.
  Needs an interactive desktop and takes about 4-5 minutes per language (two real scans each). Exit code 0 = all checks passed.

  -Lang ar|en|both   which language(s) to run the window in (default: both, one after the other)

  powershell -NoProfile -ExecutionPolicy Bypass -File tests\gui\Flow.Test.ps1 [-Lang en]
#>
[CmdletBinding()]
param([switch]$KeepWork, [ValidateSet('ar', 'en', 'both')][string]$Lang = 'both')

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$gui = Join-Path $repo 'src\RAM-Doctor-GUI.ps1'
$runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$utf8 = New-Object System.Text.UTF8Encoding($true)

function Invoke-Flow([string]$flowLang) {
    # random vowel-free name + digits: looks "random" to the detector (so it is rated High) and cannot collide with anything real
    $cons = 'bcdfghjklmnpqrstvwxz'.ToCharArray()
    $id = (-join ((1..7) | ForEach-Object { $cons[(Get-Random -Maximum $cons.Length)] })) + (Get-Random -Minimum 100 -Maximum 999)
    $work = Join-Path $env:TEMP "ramdoctor-guitest-$id"
    $hog = "zz$id"
    $hogExe = Join-Path $work "$hog.exe"
    $runName = "RamDoctorGuiTest-$id"
    $result = Join-Path $work 'result.txt'
    New-Item -ItemType Directory -Force -Path $work, (Join-Path $work 'tmp'), (Join-Path $work 'reports'), (Join-Path $work 'store'), (Join-Path $work 'profile') | Out-Null
    $oldTemp = $env:TEMP; $oldTmp = $env:TMP
    $exit = 1
    Write-Host ("`n===== window language: {0} =====" -f $flowLang) -ForegroundColor Cyan

    try {
        # ---- harmless memory hog (allocates ~300 MB, grows a little, sleeps) + Run-key persistence
        $code = @'
using System; using System.Collections.Generic; using System.Threading;
class P { static void Main() {
  var keep = new List<byte[]>();
  for (int i = 0; i < 12; i++) { var b = new byte[25*1024*1024]; for (int j = 0; j < b.Length; j += 4096) b[j] = 1; keep.Add(b); }
  for (int i = 0; i < 60; i++) { Thread.Sleep(1000); var b = new byte[10*1024*1024]; for (int j = 0; j < b.Length; j += 4096) b[j] = 1; keep.Add(b); }
  Thread.Sleep(900000);
} }
'@
        Add-Type -TypeDefinition $code -OutputAssembly $hogExe -OutputType ConsoleApplication
        Start-Process -FilePath $hogExe -WindowStyle Hidden | Out-Null
        if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey -Force | Out-Null }   # empty profiles (CI runners) have no Run key yet
        New-ItemProperty -LiteralPath $runKey -Name $runName -Value ('"' + $hogExe + '"') -PropertyType String -Force | Out-Null
        Write-Host "hog: $hog.exe  (run value $runName)"

        # ---- the script that runs INSIDE the GUI process
        $inner = @'
$out = '%RESULT%'
$hog = '%HOG%'; $hogExe = '%HOGEXE%'; $runKey = '%RUNKEY%'; $runName = '%RUNNAME%'; $work = '%WORK%'; $flow = '%LANG%'; $probe = '%PROBE%'
function Log2($s) { Add-Content -LiteralPath $out -Value $s -Encoding UTF8 }
function Check([string]$name, $cond) { if ($cond) { Log2 "PASS  $name" } else { Log2 "FAIL  $name" } }
function Wait-Until([scriptblock]$cond, [int]$sec) { $end = (Get-Date).AddSeconds($sec); while ((Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); if (& $cond) { return $true }; Start-Sleep -Milliseconds 150 }; return $false }
function Idle { Wait-Until { $script:proc -eq $null } 300 }
function Hog-State { [pscustomobject]@{ Proc = [bool](Get-Process -Name $hog -ErrorAction SilentlyContinue); Exe = (Test-Path $hogExe); Run = [bool](Get-ItemProperty $runKey -Name $runName -ErrorAction SilentlyContinue) } }
function Only-Hog { foreach ($it in $list.Items) { $it.Checked = ($it.Name -ieq "$hog.exe") }; Refresh-Buttons; $list.Invalidate() }
$arabic = '[؀-ۿ]'
$rtlWant = $(if ($flow -eq 'ar') { 'Yes' } else { 'No' })

# ---- guided tour helpers: keys are POSTED to the window (they must be caught by the tour, never reach the window)
Add-Type -ReferencedAssemblies System.Drawing -Namespace TourT -Name U -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, int m, IntPtr w, IntPtr l); [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(System.Drawing.Point p); [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, int flags); [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern IntPtr GetActiveWindow(); [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);'
# is this window process the one in front? (focus checks only mean something then: the owner may be using another program)
function In-Front { $fp = [uint32]0; [void][TourT.U]::GetWindowThreadProcessId([TourT.U]::GetForegroundWindow(), [ref]$fp); return ($fp -eq $PID) }
# UI Automation looks at a window from another process (never from this UI thread): tests\gui\Uia-Probe.ps1, while this thread keeps pumping
function Run-Probe($hwnd, [string]$invoke = '') {
    $outF = Join-Path $work ('uia-' + [guid]::NewGuid().ToString('N') + '.txt'); $nameF = $outF + '.name'
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $probe), '-Hwnd', $hwnd.ToInt64(), '-Out', ('"{0}"' -f $outF))
    if ($invoke) { [IO.File]::WriteAllText($nameF, $invoke, (New-Object System.Text.UTF8Encoding($false))); $a += @('-InvokeFile', ('"{0}"' -f $nameF)) }
    $pp = Start-Process -FilePath powershell.exe -ArgumentList $a -PassThru -WindowStyle Hidden
    $end = (Get-Date).AddSeconds(60); while (-not $pp.HasExited -and (Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
    if (-not $pp.HasExited) { try { $pp.Kill() } catch { } }
    Pump 200
    $r = @(); if (Test-Path -LiteralPath $outF) { $r = @(Get-Content -LiteralPath $outF -Encoding UTF8) }
    Remove-Item -LiteralPath $outF, $nameF -Force -ErrorAction SilentlyContinue
    return ,$r
}
function Pump([int]$ms = 250) { $end = (Get-Date).AddMilliseconds($ms); do { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 25 } while ((Get-Date) -lt $end) }
function Send-Key($ctl, [int]$vk) { [void][TourT.U]::PostMessage($ctl.Handle, 0x100, [IntPtr]$vk, [IntPtr]0); [void][TourT.U]::PostMessage($ctl.Handle, 0x101, [IntPtr]$vk, [IntPtr]0); Pump 300 }
function Tour-Snapshot([switch]$NoReadyText) {   # everything the tour must leave exactly as it found it (-NoReadyText: the first-use offer goes away on purpose)
    $s = [ordered]@{}
    $s.Bounds = [string]$form.Bounds; $s.State = [string]$form.WindowState; $s.Dir = [string]$form.RightToLeft + [string]$form.RightToLeftLayout; $s.Lang = Get-UiLang
    $s.Scroll = [string]$page.AutoScrollPosition; $s.More = $exMore.Expanded; $s.Log = $exLog.Expanded
    $s.Visible = (@($acts, $find, $toast, $info, $more, $details, $btnShare, $banner, $moreBody, $txtLog) | ForEach-Object { [string]$_.Visible }) -join ','
    $s.Enabled = (@($btnScan, $btnQ, $btnLang, $btnTour, $btnReport, $btnFolder, $btnCopy, $btnShare, $btnRestore, $btnPurge, $btnClean) | ForEach-Object { [string]$_.Enabled }) -join ','
    $s.Texts = @($form.Text, $lblStatus.Text, $info.Title, $(if ($NoReadyText) { '' } else { $info.Message }), $btnScan.Text, $lblSub.Text, $lblPick.Text) -join '|'
    $s.List = '{0}/{1}/{2}' -f $list.Items.Count, $list.CheckedCount, ((@($list.GetChecked()) | ForEach-Object { $_.Name }) -join ';')
    $s.Busy = [string]($null -ne $script:proc); $s.Bar = $bar.Value; $s.Log2 = $txtLog.TextLength
    $s.Files = (@(Get-ChildItem -LiteralPath $work -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'result.txt' } | ForEach-Object { $_.FullName }) | Sort-Object) -join ';'
    $s.Forms = [System.Windows.Forms.Application]::OpenForms.Count
    ($s.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join "`n"
}
function Tour-Diff([string]$a, [string]$b) { (Compare-Object @($a -split "`n") @($b -split "`n") | ForEach-Object { $_.SideIndicator + ' ' + $_.InputObject }) -join ' ; ' }
function Tour-Overlay { if ($script:Tour) { $script:Tour.Overlay } else { $null } }
function Tour-CardOk {   # the card is inside the overlay and, unless it had to sit over a tall control, does not cover the lit control
    $o = Tour-Overlay; if (-not $o) { return $false }
    $c = $o.CardBounds; $area = New-Object System.Drawing.Rectangle(0, 0, $o.ClientSize.Width, $o.ClientSize.Height)
    if (-not $area.Contains($c)) { return $false }
    if ($o.Hole.IsEmpty) { return $true }
    $free = ($c.Bottom -le $o.Hole.Top -or $c.Top -ge $o.Hole.Bottom -or $c.Right -le $o.Hole.Left -or $c.Left -ge $o.Hole.Right)
    $m = [Fluent.Theme]::S(16)
    return ($free -or ($c.Top -le $m -or $c.Bottom -ge $o.ClientSize.Height - $m))
}
function Tour-Walk([string]$label) {   # Next through every step; returns the ids seen and checks each card
    $ids = New-Object System.Collections.Generic.List[string]
    $bad = New-Object System.Collections.Generic.List[string]
    $n = $script:Tour.Steps.Count
    for ($i = 0; $i -lt $n; $i++) {
        $st = $script:Tour.Steps[$script:Tour.Index]; $o = Tour-Overlay
        $ids.Add($st.Id)
        if ($script:Tour.Index -ne $i) { $bad.Add("index $($script:Tour.Index) instead of $i") }
        if (-not (Tour-CardOk)) { $bad.Add("card misplaced at $($st.Id): card=$($o.CardBounds) hole=$($o.Hole) size=$($o.ClientSize)") }
        if (-not $o.Title -or -not $o.Body -or $o.Title -match '\[\[' -or $o.Body -match '\[\[|\{\d\}') { $bad.Add("text missing at $($st.Id)") }
        if ((($o.Title + $o.Body + $o.Note) -match $arabic) -ne ($flow -eq 'ar')) { $bad.Add("wrong language at $($st.Id)") }
        if ($o.Counter -ne (Get-Text 'tour.count' ($i + 1) $n)) { $bad.Add("counter '$($o.Counter)' at $($st.Id)") }
        if ($o.Rtl -ne ($flow -eq 'ar')) { $bad.Add("direction at $($st.Id)") }
        if ($st.Expand -and -not $exMore.Expanded) { $bad.Add('More not opened for its step') }
        if (-not $st.Expand -and $exMore.Expanded) { $bad.Add("More left open at $($st.Id)") }
        if ($i -lt $n - 1) { $o.PerformNext(); Pump 200 }
    }
    Check "$label - every card is complete, in $flow, counted and placed inside the window ($($bad -join ' | '))" ($bad.Count -eq 0)
    return ,$ids
}

Log2 '== initial state'
Check 'scan button enabled' $btnScan.Enabled
Check 'copy-summary disabled before a scan' (-not $btnCopy.Enabled)
Check 'findings card hidden before a scan' (-not $find.Visible)

Log2 '== language and direction'
Check "window language is $flow" ((Get-UiLang) -eq $flow)
Check 'layout direction follows the language (RightToLeft + mirrored frame)' ($form.RightToLeft -eq $rtlWant -and $form.RightToLeftLayout -eq ($flow -eq 'ar'))
Check 'controls inherit the direction' ($btnScan.RightToLeft -eq $rtlWant -and $list.RightToLeft -eq $rtlWant -and $info.RightToLeft -eq $rtlWant)
Check 'the technical log stays left-to-right' ($txtLog.RightToLeft -eq 'No')
Check 'window title and scan button come from the string table' ($form.Text -eq (Get-Text 'gui.window.title') -and $btnScan.Text -eq (Get-Text 'gui.btn.scan'))
Check 'the language button names the other language' ($btnLang.Text -eq (Get-Text 'gui.lang.other') -and $btnLang.Enabled)
Check 'header subtitle is the "sharing is optional" one (forced configured)' ($lblSub.Text -eq (Get-Text 'gui.sub.share'))
Check 'script of the window matches the language (Arabic only in Arabic mode)' ((($form.Text + $lblTitle.Text + $lblSub.Text + $btnScan.Text + $lblStatus.Text + $info.Title + $info.Message) -match $arabic) -eq ($flow -eq 'ar'))

Log2 '== guided tour (first use, before any scan)'
$offer = $script:TourOfferUi
Check 'first use: the "Ready to scan" bar itself offers the tour (one bar, with a Start the tour button and a close button)' ($offer.On -and $offer.Go.Visible -and $offer.Close.Visible -and $offer.Go.Parent -eq $info -and $info.Title -eq (Get-Text 'gui.info.ready.t') -and $info.Message.Contains((Get-Text 'tour.offer.m')))
Check 'the offer text keeps clear of its buttons' ($info.ReserveEnd -ge ($offer.Go.Width + $offer.Close.Width) -and $offer.Go.Bounds.IntersectsWith($offer.Close.Bounds) -eq $false -and (New-Object System.Drawing.Rectangle(0, 0, $info.Width, $info.Height)).Contains($offer.Go.Bounds))
Check 'the header has the tour button, named in the window language' ($btnTour.Visible -and $btnTour.Enabled -and $btnTour.Text -eq (Get-Text 'tour.btn'))
$before = Tour-Snapshot -NoReadyText
$btnScan.Focus() | Out-Null; Pump 100
$front = In-Front
$offer.Go.PerformClick(); Pump 400
$o = Tour-Overlay
Check 'the offer button opens the tour (overlay shown); the offer goes away and the bar says only "Ready to scan" again' ($o -and $o.Visible -and -not $offer.On -and -not $offer.Go.Visible -and $info.Message -eq (Get-Text 'gui.info.ready.m').Replace("`n", "`r`n") -and [System.Windows.Forms.Application]::OpenForms.Count -eq 2)
Check 'the overlay lies exactly over the window content' ($o -and $o.Bounds -eq [Fluent.Win]::ScreenRect($page.Handle))
if ($front) { Check 'the tour card has the keyboard focus while the tour is open (Tab and screen readers reach it)' ($o -and [TourT.U]::GetActiveWindow() -eq $o.Handle -and $o.FocusedButton -eq 'Next') }
else { Log2 'NOTE  keyboard-focus check skipped: another program was in front' }
$u = Run-Probe $o.Handle (Get-Text 'tour.next')
$uButtons = @($u | Where-Object { $_ -match '^Button\|' })
Check "screen readers see the card: its counter, title and text, and Back / Next / Skip as buttons they can press ($($u -join ' ; '))" ((@($u | Where-Object { $_ -like ('Text|' + (Get-Text 'tour.count' 1 11) + '|*') }).Count -eq 1) -and (@($u | Where-Object { $_ -like ('Text|' + (Get-Text 'tour.welcome.t') + '|*') }).Count -ge 1) -and (@($uButtons | Where-Object { $_ -like ('Button|' + (Get-Text 'tour.next') + '|True|True|*') }).Count -eq 1) -and (@($uButtons | Where-Object { $_ -like ('Button|' + (Get-Text 'tour.skip') + '|True|True|*') }).Count -eq 1))
Check 'pressing Next through UI Automation goes to the next step' (($u[-1] -eq ('INVOKED ' + (Get-Text 'tour.next'))) -and $script:Tour.Index -eq 1)
Check 'each step is announced to screen readers' ($o.Spoken -like ((Get-Text 'tour.count' 2 11) + '*') -and $o.Spoken.Contains((Get-Text 'tour.scan.t')))
Show-TourStep 0; Pump 200
$ids = Tour-Walk 'first walk'
Check "the tour covers every part of the window ($($ids -join ','))" (($ids -join ',') -eq 'welcome,scan,progress,verdict,actions,findings,quarantine,more,details,language,help')
$script:Tour.Overlay.PerformBack(); Pump 200; $script:Tour.Overlay.PerformBack(); Pump 200; $script:Tour.Overlay.PerformBack(); Pump 200
Check 'Back goes back step by step (and re-opens "More" for its step)' ($script:Tour.Index -eq 7 -and $exMore.Expanded)
Show-TourStep 4; Pump 200
Check 'before a scan the result buttons are explained on a centred card with a note' ($script:Tour.Steps[4].Id -eq 'actions' -and $o.Hole.IsEmpty -and $o.Note -eq (Get-Text 'tour.acts.later'))
Show-TourStep 1; Pump 200
$c = $o.Hole; $pt = $o.PointToScreen((New-Object System.Drawing.Point(($c.X + [int]($c.Width / 2)), ($c.Y + [int]($c.Height / 2)))))
Check 'the lit "Start scan" button cannot be clicked: the overlay catches clicks there' ((-not $c.IsEmpty) -and [TourT.U]::GetAncestor([TourT.U]::WindowFromPoint($pt), 2) -eq $o.Handle)
$nextKey = $(if ($flow -eq 'ar') { 0x25 } else { 0x27 }); $backKey = $(if ($flow -eq 'ar') { 0x27 } else { 0x25 })
Send-Key $btnScan $nextKey
Check 'the arrow pointing at Next goes on (Right in English, Left in Arabic)' ($script:Tour.Index -eq 2)
Send-Key $btnScan $backKey
Check 'the other arrow goes back' ($script:Tour.Index -eq 1)
Send-Key $btnScan 0x0D
Check 'Enter goes on' ($script:Tour.Index -eq 2)
Send-Key $btnScan 0x20
Check 'Space goes on and does NOT press the focused "Start scan" button' ($script:Tour.Index -eq 3 -and $null -eq $script:proc -and $btnScan.Text -eq (Get-Text 'gui.btn.scan'))
Send-Key $btnScan 0x09
Check 'Tab moves the keyboard focus on the card (Next -> Skip, it wraps in reading order)' ($o.FocusedButton -eq 'Skip')
Send-Key $btnScan 0x09
Check 'Tab again -> Back' ($o.FocusedButton -eq 'Back')
Send-Key $btnScan 0x0D
Check 'Enter presses the focused button (Back), and the focus stays on it for the next press' ($script:Tour.Index -eq 2 -and $o.FocusedButton -eq 'Back')
$sz = $form.ClientSize
$form.ClientSize = New-Object System.Drawing.Size(($sz.Width - 40), ($sz.Height - 60)); Pump 500
Check 'the overlay follows when the window is resized' ($o.Bounds -eq [Fluent.Win]::ScreenRect($page.Handle) -and (Tour-CardOk))
$form.ClientSize = $sz; Pump 400
Send-Key $btnScan 0x1B
Check 'Esc leaves the tour (overlay closed and disposed, nothing left open)' ($null -eq $script:Tour -and $o.IsDisposed -and [System.Windows.Forms.Application]::OpenForms.Count -eq 1)
$after = Tour-Snapshot -NoReadyText
Check "the window is exactly as before the tour, apart from the offer it answered ($(Tour-Diff $before $after))" ($before -eq $after)
if ($front) { Check 'the keyboard focus is back in the window' ([TourT.U]::GetActiveWindow() -eq $form.Handle) }
Check 'no scan was started and nothing was written' ($null -eq $script:proc -and -not (Test-Path (Join-Path $ReportsDir 'Plan-*.json')))
$btnTour.PerformClick(); Pump 400
Check 'the header button opens the tour again' ($null -ne $script:Tour -and (Tour-Overlay).Visible)
$null = Tour-Walk 'second walk'
(Tour-Overlay).PerformNext(); Pump 300
Check 'Done on the last step closes the tour' ($null -eq $script:Tour -and [System.Windows.Forms.Application]::OpenForms.Count -eq 1)
Check 'the window is still unchanged after a full walk' ((Tour-Snapshot -NoReadyText) -eq $after)
Check 'the offer does not come back once the tour was taken' (-not $offer.On -and -not $offer.Go.Visible)
Check "the tour never stopped by itself after an error ('$script:TourLastError')" (-not $script:TourLastError)

Log2 '== scan #1'
$btnScan.PerformClick()
Check 'scan button disabled while scanning' (-not $btnScan.Enabled)
Check 'language button disabled while scanning' (-not $btnLang.Enabled)
Check 'scan finished' (Idle)
Check 'results card shows the hog as high risk' (@($list.Items | Where-Object { $_.Name -ieq "$hog.exe" -and $_.Level -eq 2 }).Count -eq 1)
Check 'infobar is Error level' ($info.Level -eq 'Error')
Check 'report/copy buttons enabled' ($btnReport.Enabled -and $btnCopy.Enabled -and $btnFolder.Enabled)
Check 'findings card visible' $find.Visible
$latest = Get-LatestResult
$planObj = Get-Content -LiteralPath $latest.Plan -Raw -Encoding UTF8 | ConvertFrom-Json
Check "the scan wrote its plan in $flow (lang field)" ($planObj.lang -eq $flow)
$texts = @([string]$planObj.verdict.Headline) + @(@($planObj.suspects) | ForEach-Object { @($_.reasons) }) + @(@($planObj.observations) | ForEach-Object { $_.Title; $_.Body })
Check 'the verdict, the observations and the reasons are in that language' ((($texts -join ' ') -match $arabic) -eq ($flow -eq 'ar'))
$htmlText = [IO.File]::ReadAllText($latest.Html, [Text.Encoding]::UTF8)
Check "the report is <html lang=$flow> with the matching direction" ($htmlText -match ('<html lang="{0}" dir="{1}">' -f $flow, $(if ($flow -eq 'ar') { 'rtl' } else { 'ltr' })))
Check 'the report carries the inert-report marker right after the doctype' ($htmlText -match '(?i)^\s*<!doctype html>\r?\n<!-- ram-doctor-report v\d+\.\d+\.\d+ -->')
Check 'the report has no unresolved string key or placeholder' ($htmlText -notmatch '\[\[[a-z]+\.[A-Za-z0-9.\-]+\]\]' -and $htmlText -notmatch '@@[A-Z]+@@')
Check 'the verdict bar shows the plan headline' ($info.Title -eq [string]$planObj.verdict.Headline)

Log2 '== guided tour (with results)'
Check 'no tour offer once a report exists' (-not $offer.On -and -not $offer.Go.Visible)
$u = Run-Probe $form.Handle
Check "screen readers see the window's controls with their names and roles ($((@($u | Where-Object { $_ -notmatch '^(Pane|Type)' }) | Select-Object -First 30) -join ' ; '))" ((@($u | Where-Object { $_ -like ('Button|' + (Get-Text 'gui.btn.scan') + '|True|True|*') }).Count -eq 1) -and (@($u | Where-Object { $_ -like ('ProgressBar|' + (Get-Text 'gui.a11y.progress') + '|*') }).Count -eq 1) -and (@($u | Where-Object { $_ -like ('Button|' + (Get-Text 'gui.more.t') + '|True|True|*') }).Count -eq 1) -and (@($u | Where-Object { $_ -like ('Image|' + (Get-Text 'gui.title') + '|*') }).Count -eq 1))
Check 'the files in the list are check boxes a screen reader can tick, named after the file and its risk' (@($u | Where-Object { $_ -like ('CheckBox|' + $hog + '.exe, ' + (Get-Text 'level.high') + '*') }).Count -eq 1)
$before = Tour-Snapshot
$btnTour.PerformClick(); Pump 400
$o = Tour-Overlay
$stepIds = @($script:Tour.Steps | ForEach-Object { $_.Id })
function Lit-Contains($ctl) { $h = $o.RectangleToScreen($o.Hole); (-not $o.Hole.IsEmpty) -and $h.Contains([Fluent.Win]::ScreenRect($ctl.Handle)) }
Show-TourStep ([array]::IndexOf($stepIds, 'actions')); Pump 250
Check 'with results the action buttons are lit, with no "appears later" note, and sharing is mentioned (it is on)' ((Lit-Contains $btnCopy) -and (Lit-Contains $btnShare) -and -not $o.Note -and $o.Body.Contains((Get-Text 'gui.btn.share')))
Show-TourStep ([array]::IndexOf($stepIds, 'findings')); Pump 250
Check 'the findings card is scrolled into view and lit' ((Lit-Contains $list) -and (Tour-CardOk))
Show-TourStep ([array]::IndexOf($stepIds, 'quarantine')); Pump 250
Check 'the quarantine button is lit' ((Lit-Contains $btnQ) -and (Tour-CardOk))
Show-TourStep ([array]::IndexOf($stepIds, 'details')); Pump 250
Check 'the technical details card is lit and stays closed' ((Lit-Contains $exLog) -and -not $exLog.Expanded)
$o.PerformSkip(); Pump 300
Check 'Skip closes the tour' ($null -eq $script:Tour -and $o.IsDisposed)
Check "the results, the selection, the scroll position and the window are unchanged ($(Tour-Diff $before (Tour-Snapshot)))" ((Tour-Snapshot) -eq $before)

Log2 '== copy summary'
$btnCopy.PerformClick()
[void](Idle)
Check 'toast shown (Success)' ($toast.Visible -and $toast.Level -eq 'Success')
$clip = ''; try { $clip = [System.Windows.Forms.Clipboard]::GetText() } catch { }
Check 'clipboard has text' ($clip.Length -gt 20)
Check 'clipboard summary is in the window language' ($clip -match [regex]::Escape((Get-Text 'sum.title')))
Check 'clipboard text has no Windows user name' (-not ($clip -match [regex]::Escape($env:USERNAME)))
Check 'clipboard text has no drive path' (-not ($clip -match '[A-Za-z]:\\'))
Check 'share preview temp folders removed' (@(Get-ChildItem $env:TEMP -Directory -Filter 'RAM-Doctor-share-*' -Force -ErrorAction SilentlyContinue).Count -eq 0)

Log2 '== live language switch (no restart, nothing saved)'
$other = $(if ($flow -eq 'ar') { 'en' } else { 'ar' })
$rtlOther = $(if ($other -eq 'ar') { 'Yes' } else { 'No' })
Only-Hog
$itemsBefore = $list.Items.Count; $checkedBefore = $list.CheckedCount
$btnLang.PerformClick()
[System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 500; [System.Windows.Forms.Application]::DoEvents()
Check "the window switched to $other" ((Get-UiLang) -eq $other)
Check 'direction switched with it (form, mirrored frame, children)' ($form.RightToLeft -eq $rtlOther -and $form.RightToLeftLayout -eq ($other -eq 'ar') -and $btnScan.RightToLeft -eq $rtlOther -and $list.RightToLeft -eq $rtlOther)
Check 'static texts switched' ($form.Text -eq (Get-Text 'gui.window.title') -and $btnScan.Text -eq (Get-Text 'gui.btn.scan') -and $btnReport.Text -eq (Get-Text 'gui.btn.report') -and $btnLang.Text -eq (Get-Text 'gui.lang.other'))
Check 'the status line switched' ($lblStatus.Text -eq (Get-Text 'gui.status.done'))
Check 'the risk labels in the list switched' (@($list.Items | Where-Object { $_.Level -eq 2 })[0].Risk -eq (Get-Text 'level.high'))
Check 'the results stayed (same files, same selection)' ($list.Items.Count -eq $itemsBefore -and $list.CheckedCount -eq $checkedBefore -and $find.Visible)
Check 'the scan text keeps its own language and a note says so' ($info.Title -eq [string]$planObj.verdict.Headline -and $info.Message.Contains((Get-Text 'gui.note.otherlang')))
Check 'the window still has a handle and the buttons work' ($form.IsHandleCreated -and $btnScan.Enabled -and $btnQ.Enabled)
$btnLang.PerformClick()
[System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 500; [System.Windows.Forms.Application]::DoEvents()
Check "and back to $flow" ((Get-UiLang) -eq $flow -and $form.RightToLeft -eq $rtlWant -and $form.RightToLeftLayout -eq ($flow -eq 'ar'))
Check 'the note is gone again' (-not $info.Message.Contains((Get-Text 'gui.note.otherlang')))
Check 'the selection survived the round trip' ($list.CheckedCount -eq $checkedBefore)

Log2 '== quarantine #1'
Only-Hog
Check 'exactly one item selected (the hog)' ($list.CheckedCount -eq 1)
Check 'hog alive before' ((Hog-State).Proc)
$btnQ.PerformClick()
Check 'quarantine finished' (Idle)
$s = Hog-State
if ($s.Proc -or $s.Exe) { Log2 ('DIAG quarantine output: ' + ((@($script:lastOutput -split "`r?`n") | Select-Object -Last 45) -join ' | ')) }
Check 'hog process stopped' (-not $s.Proc)
Check 'hog exe moved away' (-not $s.Exe)
Check 'Run value removed' (-not $s.Run)
Check 'verdict now Success' ($info.Level -eq 'Success')
Check 'the verdict bar says "quarantined" in the window language' ($info.Title -eq (Get-Text 'gui.q.done.t'))
Check 'restore + purge enabled' ($btnRestore.Enabled -and $btnPurge.Enabled)

Log2 '== restore'
$btnRestore.PerformClick()
Check 'restore finished' (Idle)
$s = Hog-State
Check 'exe back' $s.Exe
Check 'Run value back' $s.Run
Check 'restore + purge disabled again' ((-not $btnRestore.Enabled) -and (-not $btnPurge.Enabled))

Log2 '== scan #2, quarantine, purge'
$btnScan.PerformClick()
Check 'scan #2 finished' (Idle)
Only-Hog
Check 'only the hog selected' ($list.CheckedCount -eq 1)
$btnQ.PerformClick()
Check 'quarantine #2 finished' (Idle)
$btnPurge.PerformClick()
Check 'purge finished' (Idle)
Check 'no quarantined files left' (@(Get-ChildItem (Join-Path $work 'store') -Recurse -Filter *.quar -ErrorAction SilentlyContinue).Count -eq 0)
Check 'purge disabled afterwards' (-not $btnPurge.Enabled)
Check 'exe really gone' (-not (Test-Path $hogExe))

Log2 '== share (dry-run, no network)'
Check 'share button visible (forced configured)' $btnShare.Visible
if (-not $exMore.Expanded) { $exMore.Toggle() }   # the account row lives in the collapsed "More" section
Check 'account row visible (More expanded)' $rowShare.Visible
Check 'header subtitle mentions optional sharing' ($lblSub.Text -eq (Get-Text 'gui.sub.share'))
$script:TestProfile = @{ Username = 'tester_01'; Code = '' }
$btnShare.PerformClick()
Check 'share task finished' (Idle)
Check 'share toast is Success' ($toast.Visible -and $toast.Level -eq 'Success')
Check 'profile file written to the test profile dir' (@(Get-ChildItem (Join-Path $work 'profile') -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0)
$del = Invoke-Cli (Share-Args 'DeleteProfile') 30
Check 'DeleteProfile OK' ($del.Output -match 'RESULT:\s*OK')
Check 'share preview temp folders removed after sharing' (@(Get-ChildItem $env:TEMP -Directory -Filter 'RAM-Doctor-share-*' -Force -ErrorAction SilentlyContinue).Count -eq 0)

Log2 '== clear reports'
Check 'reports exist before' (Test-Path $ReportsDir)
$btnClean.PerformClick()
Check 'reports folder removed' (-not (Test-Path $ReportsDir))
Check 'action row hidden' (-not $acts.Visible)
Check 'verdict bar back to "ready" in the window language' ($info.Title -eq (Get-Text 'gui.info.ready.t'))

Log2 '== leftovers in the GUI private TEMP'
$left = @()
for ($try = 0; $try -lt 10; $try++) {   # the last task's output file is deleted right after the process exits: allow for that
    $left = @(Get-ChildItem $env:TEMP -Filter 'ramdoctor-*' -Force -ErrorAction SilentlyContinue)
    if (-not $left.Count) { break }
    Start-Sleep -Milliseconds 500; [System.Windows.Forms.Application]::DoEvents()
}
if ($left.Count) { Log2 ('DIAG leftovers: ' + (($left | ForEach-Object { '{0} dir={1} len={2} items={3}' -f $_.Name, $_.PSIsContainer, $_.Length, @(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue).Count }) -join ' ; ')) }
Check ('no ramdoctor-* temp files left (found ' + $left.Count + ')') ($left.Count -eq 0)
Log2 'DONE'
$form.Close()
'@
        $inner = $inner.Replace('%RESULT%', $result).Replace('%HOG%', $hog).Replace('%HOGEXE%', $hogExe).Replace('%RUNKEY%', $runKey).Replace('%RUNNAME%', $runName).Replace('%WORK%', $work).Replace('%PROBE%', (Join-Path $PSScriptRoot 'Uia-Probe.ps1')).Replace('%LANG%', $flowLang)
        $testScript = Join-Path $work 'inner.test.ps1'
        [IO.File]::WriteAllText($testScript, $inner, $utf8)

        # ---- run the GUI with a private TEMP
        $env:TEMP = (Join-Path $work 'tmp'); $env:TMP = $env:TEMP
        $guiArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $gui),
            '-ReportsDir', ('"{0}"' -f (Join-Path $work 'reports')), '-QuarantineDir', ('"{0}"' -f (Join-Path $work 'store')),
            '-AllowNonAdmin', '-Unattended', '-Theme', 'Light', '-Accent', 'default', '-Lang', $flowLang,
            '-ShareForceConfigured', '-ShareDryRun', '-ShareProfileDir', ('"{0}"' -f (Join-Path $work 'profile')),
            '-TestScript', ('"{0}"' -f $testScript))
        $p = Start-Process -FilePath powershell.exe -ArgumentList $guiArgs -PassThru
        $env:TEMP = $oldTemp; $env:TMP = $oldTmp
        Write-Host 'GUI started, running the flow (about 4-5 minutes) ...'
        if (-not $p.WaitForExit(900000)) { try { $p.Kill() } catch { }; Write-Warning 'GUI test timed out and was killed' }

        # ---- report
        Write-Host ''
        if (Test-Path $result) { Get-Content $result -Encoding UTF8 | ForEach-Object { if ($_ -match '^FAIL') { Write-Host $_ -ForegroundColor Red } elseif ($_ -match '^PASS') { Write-Host $_ -ForegroundColor Green } else { Write-Host $_ } } }
        else { Write-Host 'no result file produced' -ForegroundColor Red }
        if (Test-Path ($testScript + '.error.txt')) { Write-Host '--- test script error ---' -ForegroundColor Red; Get-Content ($testScript + '.error.txt') }
        $lines = if (Test-Path $result) { @(Get-Content $result -Encoding UTF8) } else { @() }
        $fail = @($lines | Where-Object { $_ -match '^FAIL' }).Count; $pass = @($lines | Where-Object { $_ -match '^PASS' }).Count
        $done = ($lines -contains 'DONE')
        Write-Host ("`n[{0}] {1} passed, {2} failed{3}" -f $flowLang, $pass, $fail, $(if (-not $done) { ', flow did NOT finish' } else { '' }))
        $exit = $(if ($fail -eq 0 -and $done) { 0 } else { 1 })
    }
    finally {
        $env:TEMP = $oldTemp; $env:TMP = $oldTmp
        Get-Process -Name $hog -ErrorAction SilentlyContinue | Stop-Process -Force
        Remove-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        if (-not $KeepWork) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $exit
}

$langs = $(if ($Lang -eq 'both') { @('en', 'ar') } else { @($Lang) })
$worst = 0
foreach ($l in $langs) { $r = @(Invoke-Flow $l) | Select-Object -Last 1; if ($r -ne 0) { $worst = 1 } }
Write-Host ("`nFlow test: {0}" -f $(if ($worst -eq 0) { 'ALL PASSED (' + ($langs -join ', ') + ')' } else { 'FAILED' })) -ForegroundColor $(if ($worst -eq 0) { 'Green' } else { 'Red' })
exit $worst
