#requires -Version 5.1
<#
.SYNOPSIS
  RAM Doctor - one friendly Arabic window. It only launches the (already tested) scan / actions scripts
  and shows their results; it holds no scanning logic of its own.

  Developer-only switches (not needed by users):
    -TestScript  run a script file on the UI thread after the window opens (used to take screenshots / run tests)
    -Unattended  skip confirmation dialogs (tests)
    -AllowNonAdmin  let the quarantine buttons work without elevation (tests)
#>
[CmdletBinding()]
param(
    [string]$ReportsDir = '',
    [string]$QuarantineDir = '',
    [string]$TestScript = '',
    [switch]$Unattended,
    [switch]$AllowNonAdmin
)

$ErrorActionPreference = 'Continue'
$AppDir = $PSScriptRoot
$ScanScript = Join-Path $AppDir 'RAM-Doctor.ps1'
$ActionsScript = Join-Path $AppDir 'RAM-Doctor-Actions.ps1'
if (-not $ReportsDir) { $ReportsDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'RAM-Doctor-Reports' }
$StoreRoot = if ($QuarantineDir) { $QuarantineDir } else { Join-Path $env:ProgramData 'RAM-Doctor' }
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$CanAct = ($IsAdmin -or $AllowNonAdmin)

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # ------------------------------------------------------------ look & feel
    function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
    $fBody = New-Object System.Drawing.Font('Segoe UI', 10.5)
    $fBold = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
    $fBig = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $fTitle = New-Object System.Drawing.Font('Segoe UI', 21, [System.Drawing.FontStyle]::Bold)
    $fSmall = New-Object System.Drawing.Font('Segoe UI', 9)
    $fMono = New-Object System.Drawing.Font('Consolas', 9)
    $mbOpts = [System.Windows.Forms.MessageBoxOptions]'RtlReading, RightAlign'

    function New-Btn([string]$text, [string]$bg, [string]$fg = '#FFFFFF') {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
        $b.BackColor = C $bg; $b.ForeColor = C $fg; $b.Font = $fBold; $b.Cursor = 'Hand'
        $b.UseVisualStyleBackColor = $false; $b.Tag = $bg; $b.Dock = 'Fill'; $b.Margin = New-Object System.Windows.Forms.Padding(4)
        return $b
    }
    function Set-Btn($b, [bool]$on) {
        $b.Enabled = $on
        if ($on) { $b.BackColor = C $b.Tag; $b.ForeColor = C '#FFFFFF' } else { $b.BackColor = C '#D5DBE1'; $b.ForeColor = C '#8A96A3' }
    }
    function New-Tlp([int]$cols, [int]$rows) {
        $t = New-Object System.Windows.Forms.TableLayoutPanel
        $t.Dock = 'Fill'; $t.ColumnCount = $cols; $t.RowCount = $rows; $t.Margin = New-Object System.Windows.Forms.Padding(0)
        return $t
    }
    function Add-Row($t, [string]$type, [float]$size) {
        $st = [System.Windows.Forms.SizeType]$type
        [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($st, $size)))
    }
    function Add-Col($t, [string]$type, [float]$size) {
        $st = [System.Windows.Forms.SizeType]$type
        [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle($st, $size)))
    }
    function New-Lbl([string]$text, $font = $fBody, [string]$fg = '#1B2733', [string]$bg = '') {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Font = $font; $l.ForeColor = C $fg; $l.Dock = 'Fill'; $l.AutoSize = $false; $l.Margin = New-Object System.Windows.Forms.Padding(0)
        if ($bg) { $l.BackColor = C $bg }
        return $l
    }
    function New-Group([string]$text) {
        $g = New-Object System.Windows.Forms.GroupBox
        $g.Text = $text; $g.Font = $fBold; $g.ForeColor = C '#0F3D6E'; $g.Dock = 'Fill'; $g.BackColor = C '#FFFFFF'
        $g.Margin = New-Object System.Windows.Forms.Padding(14, 5, 14, 5); $g.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 6)
        return $g
    }

    # ------------------------------------------------------------ form + layout
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'فاحص الذاكرة - RAM Doctor'
    $form.ClientSize = New-Object System.Drawing.Size(960, 760)
    $form.MinimumSize = New-Object System.Drawing.Size(920, 740)
    $form.StartPosition = 'CenterScreen'
    $form.RightToLeft = 'Yes'; $form.RightToLeftLayout = $true
    $form.Font = $fBody; $form.BackColor = C '#F4F6F8'

    $main = New-Tlp 1 6
    Add-Col $main 'Percent' 100
    Add-Row $main 'Absolute' 86      # header
    Add-Row $main 'Absolute' 0       # admin banner (shown only when needed)
    Add-Row $main 'Absolute' 138     # step 1
    Add-Row $main 'Percent' 100      # step 2
    Add-Row $main 'Absolute' 84      # step 3
    Add-Row $main 'Absolute' 118     # details
    $form.Controls.Add($main)

    # header
    $header = New-Tlp 1 2
    $header.BackColor = C '#0F3D6E'
    Add-Col $header 'Percent' 100; Add-Row $header 'Percent' 62; Add-Row $header 'Percent' 38
    $header.Padding = New-Object System.Windows.Forms.Padding(24, 6, 24, 0)
    $lblTitle = New-Lbl 'فاحص الذاكرة  (RAM Doctor)' $fTitle '#FFFFFF' '#0F3D6E'
    $lblSub = New-Lbl 'اعرف سبب امتلاء الذاكرة خلال دقيقة. الفحص آمن ولا يحذف ولا يغيّر شيئًا.' $fBody '#BBD3EE' '#0F3D6E'
    $header.Controls.Add($lblTitle, 0, 0); $header.Controls.Add($lblSub, 0, 1)
    $main.Controls.Add($header, 0, 0)

    # admin banner
    $lblBanner = New-Lbl 'تنبيه: لم تُشغَّل كمدير. أغلق النافذة وافتح الأداة مجددًا ووافق على طلب الصلاحيات (نعم).' $fBold '#7A4B00' '#FFE9B8'
    $lblBanner.TextAlign = 'MiddleCenter'
    $main.Controls.Add($lblBanner, 0, 1)
    if (-not $CanAct) { $main.RowStyles[1].Height = 36 }

    # step 1
    $g1 = New-Group 'الخطوة 1:  افحص جهازك'
    $t1 = New-Tlp 1 3
    Add-Col $t1 'Percent' 100; Add-Row $t1 'Absolute' 52; Add-Row $t1 'Absolute' 22; Add-Row $t1 'Percent' 100
    $btnScan = New-Btn 'ابدأ الفحص الآن' '#1565C0'
    $btnScan.Font = $fBig
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Dock = 'Fill'; $bar.Minimum = 0; $bar.Maximum = 100; $bar.Margin = New-Object System.Windows.Forms.Padding(4, 4, 4, 2)
    $lblStatus = New-Lbl 'جاهز. اضغط «ابدأ الفحص الآن» (يستغرق حوالي دقيقة، لا تغلق النافذة).' $fBody '#4A5A68'
    $lblStatus.Margin = New-Object System.Windows.Forms.Padding(6, 2, 6, 0)
    $t1.Controls.Add($btnScan, 0, 0); $t1.Controls.Add($bar, 0, 1); $t1.Controls.Add($lblStatus, 0, 2)
    $g1.Controls.Add($t1)
    $main.Controls.Add($g1, 0, 2)

    # step 2
    $g2 = New-Group 'الخطوة 2:  النتيجة'
    $t2 = New-Tlp 1 4
    Add-Col $t2 'Percent' 100; Add-Row $t2 'Absolute' 46; Add-Row $t2 'Absolute' 62; Add-Row $t2 'Percent' 100; Add-Row $t2 'Absolute' 52
    $lblVerdict = New-Lbl 'لم يتم الفحص بعد' $fBig '#4A5A68' '#EEF1F4'
    $lblVerdict.TextAlign = 'MiddleCenter'; $lblVerdict.Margin = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
    $lblHint = New-Lbl 'بعد الفحص تظهر هنا النتيجة، وأي ملفات مشبوهة يمكنك عزلها بضغطة واحدة.' $fBody '#33424F'
    $lblHint.Margin = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = 'Fill'; $list.View = 'Details'; $list.CheckBoxes = $true; $list.FullRowSelect = $true; $list.HideSelection = $false; $list.GridLines = $true
    $list.RightToLeft = 'Yes'; $list.RightToLeftLayout = $true; $list.Margin = New-Object System.Windows.Forms.Padding(4)
    [void]$list.Columns.Add('الخطر', 80); [void]$list.Columns.Add('الملف', 230); [void]$list.Columns.Add('لماذا هو مشبوه؟', 480)
    $flow2 = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow2.Dock = 'Fill'; $flow2.Margin = New-Object System.Windows.Forms.Padding(0); $flow2.WrapContents = $false
    $btnQ = New-Btn 'عزل الملفات المحددة (آمن وقابل للتراجع)' '#E65100'; $btnQ.Dock = 'None'; $btnQ.Size = New-Object System.Drawing.Size(380, 44)
    $btnReport = New-Btn 'افتح التقرير الكامل' '#00796B'; $btnReport.Dock = 'None'; $btnReport.Size = New-Object System.Drawing.Size(210, 44)
    $btnFolder = New-Btn 'مكان ملف التقرير (للإرسال)' '#546E7A'; $btnFolder.Dock = 'None'; $btnFolder.Size = New-Object System.Drawing.Size(250, 44)
    $flow2.Controls.AddRange(@($btnQ, $btnReport, $btnFolder))
    $t2.Controls.Add($lblVerdict, 0, 0); $t2.Controls.Add($lblHint, 0, 1); $t2.Controls.Add($list, 0, 2); $t2.Controls.Add($flow2, 0, 3)
    $g2.Controls.Add($t2)
    $main.Controls.Add($g2, 0, 3)

    # step 3
    $g3 = New-Group 'الخطوة 3 (عند الحاجة):  تراجع أو تنظيف'
    $flow3 = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow3.Dock = 'Fill'; $flow3.WrapContents = $false
    $btnRestore = New-Btn 'تراجع عن آخر عزل' '#3949AB'; $btnRestore.Dock = 'None'; $btnRestore.Size = New-Object System.Drawing.Size(230, 42)
    $btnPurge = New-Btn 'احذف الملفات المعزولة نهائيًا' '#B71C1C'; $btnPurge.Dock = 'None'; $btnPurge.Size = New-Object System.Drawing.Size(290, 42)
    $btnClean = New-Btn 'امسح تقارير الأداة من جهازي' '#546E7A'; $btnClean.Dock = 'None'; $btnClean.Size = New-Object System.Drawing.Size(280, 42)
    $flow3.Controls.AddRange(@($btnRestore, $btnPurge, $btnClean))
    $g3.Controls.Add($flow3)
    $main.Controls.Add($g3, 0, 4)

    # details
    $g4 = New-Group 'تفاصيل التنفيذ (للمختصين)'
    $g4.Font = $fSmall
    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.Dock = 'Fill'
    $txtLog.Font = $fMono; $txtLog.RightToLeft = 'No'; $txtLog.BackColor = C '#FAFBFC'
    $g4.Controls.Add($txtLog)
    $main.Controls.Add($g4, 0, 5)

    # ------------------------------------------------------------ helpers
    function Add-Log([string]$s) { $txtLog.AppendText($s + "`r`n") }
    function Set-Status([string]$s, [int]$pct = -1) {
        $lblStatus.Text = $s
        if ($pct -ge 0) { $bar.Value = [math]::Max(0, [math]::Min(100, $pct)) }
    }
    function Info-Box([string]$text, [string]$icon = 'Information') {
        if ($Unattended) { Add-Log "[dialog] $text"; return }
        [void][System.Windows.Forms.MessageBox]::Show($form, $text, 'فاحص الذاكرة', 'OK', $icon, 'Button1', $mbOpts)
    }
    function Confirm-Box([string]$text, [string]$title, [string]$icon = 'Question') {
        if ($Unattended) { Add-Log "[confirm:auto-yes] $title"; return $true }
        $r = [System.Windows.Forms.MessageBox]::Show($form, $text, $title, 'YesNo', $icon, 'Button2', $mbOpts)
        return ($r -eq 'Yes')
    }
    function Guard([scriptblock]$b) {
        try { & $b } catch {
            Add-Log ('ERROR: ' + $_.Exception.Message)
            Info-Box ('حدث خطأ غير متوقع:' + "`n" + $_.Exception.Message) 'Warning'
        }
    }
    function Read-Shared([string]$p) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { return '' }
        try {
            $fs = [System.IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::Default)
            $t = $sr.ReadToEnd(); $sr.Close(); return $t
        } catch { return '' }
    }
    function Get-Batches {
        $q = Join-Path $StoreRoot 'Quarantine'
        if (-not (Test-Path -LiteralPath $q)) { return @() }
        @(Get-ChildItem -LiteralPath $q -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') } | Sort-Object Name -Descending)
    }
    function Get-QuarantinedStats {
        $n = 0; $bytes = 0
        foreach ($b in (Get-Batches)) {
            $fd = Join-Path $b.FullName 'files'
            if (Test-Path -LiteralPath $fd) { $fs = @(Get-ChildItem -LiteralPath $fd -File -Force -ErrorAction SilentlyContinue); $n += $fs.Count; $bytes += ($fs | Measure-Object Length -Sum).Sum }
        }
        [pscustomobject]@{ Count = $n; MB = [math]::Round($bytes / 1MB, 1) }
    }

    # ------------------------------------------------------------ background task runner (child powershell, polled by a timer)
    $script:proc = $null; $script:outFile = ''; $script:errFile = ''; $script:lineIdx = 0; $script:onDone = $null
    $script:taskKind = ''; $script:cap = 5; $script:tick = 0; $script:current = $null; $script:scanStart = Get-Date

    $StatusMap = @(
        @('Snapshot #1', 'جارٍ قياس الذاكرة ...', 5),
        @('Collecting system facts', 'جارٍ قراءة معلومات الجهاز ...', 10),
        @('Inventory: processes', 'جارٍ فحص البرامج الشغّالة ...', 16),
        @('Inventory: services', 'جارٍ فحص الخدمات ...', 26),
        @('Inventory: scheduled tasks', 'جارٍ فحص المهام المجدولة ...', 36),
        @('Inventory: startup', 'جارٍ فحص برامج بدء التشغيل ...', 42),
        @('Inventory: WMI', 'جارٍ فحص الاشتراكات الخفية ...', 46),
        @('Inventory: running kernel drivers', 'جارٍ فحص التعريفات ...', 50),
        @('Hidden-process', 'جارٍ البحث عن عمليات مخفية ...', 56),
        @('Rating signatures', 'جارٍ تحليل الملفات والتواقيع (أطول خطوة) ...', 62),
        @('Waiting', 'جارٍ مراقبة نمو الذاكرة ...', 82),
        @('Snapshot #2', 'جارٍ قياس النمو ...', 87),
        @('Correlating', 'جارٍ ربط النتائج ...', 91),
        @('Mapping top pool tags', 'جارٍ ربط ذاكرة النواة بالتعريفات ...', 95),
        @('Collecting Defender', 'جارٍ جمع الأدلة النهائية ...', 97)
    )

    function Refresh-Buttons {
        $busy = ($script:proc -ne $null -and -not $script:proc.HasExited)
        Set-Btn $btnScan (-not $busy)
        $hasPick = ($list.CheckedItems.Count -gt 0)
        Set-Btn $btnQ ((-not $busy) -and $CanAct -and $hasPick -and $script:current -ne $null)
        Set-Btn $btnReport ((-not $busy) -and $script:current -ne $null)
        Set-Btn $btnFolder ((-not $busy) -and $script:current -ne $null)
        # restore: a batch not yet restored/purged.  purge: only if files are really waiting in quarantine.
        $canRestore = $false
        foreach ($bt in (Get-Batches)) {
            try { $m = Get-Content -LiteralPath (Join-Path $bt.FullName 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json; if (-not $m.purgedAt -and -not $m.restoredAt) { $canRestore = $true; break } } catch { }
        }
        $hasFiles = ((Get-QuarantinedStats).Count -gt 0)
        Set-Btn $btnRestore ((-not $busy) -and $CanAct -and $canRestore)
        Set-Btn $btnPurge ((-not $busy) -and $CanAct -and $hasFiles)
        Set-Btn $btnClean (-not $busy)
    }

    function Start-Task([string]$kind, [string[]]$psArgs, [scriptblock]$onDone) {
        $script:taskKind = $kind; $script:onDone = $onDone; $script:lineIdx = 0; $script:tick = 0
        $id = [guid]::NewGuid().ToString('N')
        $script:outFile = Join-Path $env:TEMP "ramdoctor-$id.out"
        $script:errFile = Join-Path $env:TEMP "ramdoctor-$id.err"
        $argLine = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') + $psArgs
        $script:proc = Start-Process -FilePath powershell.exe -ArgumentList $argLine -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:outFile -RedirectStandardError $script:errFile
        $null = $script:proc.Handle
        Refresh-Buttons
        $timer.Start()
    }

    function Handle-Line([string]$l) {
        if ($l -notmatch '^\[\d\d:\d\d:\d\d\]') { return }   # only the timestamped progress lines
        Add-Log $l
        if ($script:taskKind -eq 'scan') {
            for ($i = 0; $i -lt $StatusMap.Count; $i++) {
                if ($l -like ('*' + $StatusMap[$i][0] + '*')) {
                    Set-Status $StatusMap[$i][1] $StatusMap[$i][2]
                    $script:cap = if ($i + 1 -lt $StatusMap.Count) { $StatusMap[$i + 1][2] - 1 } else { 98 }
                    break
                }
            }
        }
    }

    function Poll-Task {
        if (-not $script:proc) { $timer.Stop(); return }
        $exited = $script:proc.HasExited
        $lines = @((Read-Shared $script:outFile) -split "`r?`n")
        $limit = if ($exited) { $lines.Count } else { $lines.Count - 1 }
        for ($i = $script:lineIdx; $i -lt $limit; $i++) { Handle-Line $lines[$i] }
        if ($limit -gt $script:lineIdx) { $script:lineIdx = $limit }
        if (-not $exited) {
            $script:tick++
            if ($script:taskKind -eq 'scan' -and ($script:tick % 3 -eq 0) -and $bar.Value -lt $script:cap) { $bar.Value = $bar.Value + 1 }
            return
        }
        $timer.Stop()
        $out = Read-Shared $script:outFile
        $err = (Read-Shared $script:errFile).Trim()
        if ($err) { Add-Log ('[stderr] ' + $err.Substring(0, [Math]::Min(600, $err.Length))) }
        $script:lastOutput = $out
        Remove-Item -LiteralPath $script:outFile, $script:errFile -Force -ErrorAction SilentlyContinue   # leave nothing behind in %TEMP%
        $script:proc = $null
        $cb = $script:onDone; $script:onDone = $null
        Refresh-Buttons
        if ($cb) { Guard $cb }
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({ Guard { Poll-Task } })

    # ------------------------------------------------------------ results
    function Get-LatestResult {
        if (-not (Test-Path -LiteralPath $ReportsDir)) { return $null }
        $p = Get-ChildItem -LiteralPath $ReportsDir -Filter 'Plan-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if (-not $p) { return $null }
        $stamp = $p.BaseName.Substring('Plan-'.Length)
        [pscustomobject]@{ Plan = $p.FullName; Html = (Join-Path $ReportsDir "RAMDoctor-$stamp.html"); Time = $p.LastWriteTime }
    }

    function Load-Results($r, [bool]$previous) {
        $plan = Get-Content -LiteralPath $r.Plan -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:current = $r
        $lvl = [string]$plan.verdict.Level
        $colors = @{ high = @('#FDECEA', '#B71C1C'); med = @('#FFF4E0', '#8A5200'); low = @('#E8F1FB', '#0D47A1'); ok = @('#E8F5E9', '#1B5E20') }
        $c = $colors[$lvl]; if (-not $c) { $c = @('#EEF1F4', '#33424F') }
        $lblVerdict.BackColor = C $c[0]; $lblVerdict.ForeColor = C $c[1]
        $pre = if ($previous) { 'آخر فحص (' + $r.Time.ToString('yyyy-MM-dd HH:mm') + '):  ' } else { '' }
        $lblVerdict.Text = $pre + [string]$plan.verdict.Headline

        $list.Items.Clear()
        $risk = @{ High = 'عالٍ'; Medium = 'متوسط' }
        $lowCount = 0
        foreach ($s in @($plan.suspects)) {
            if (-not $s) { continue }
            if ($s.risk -eq 'Low') { $lowCount++; continue }
            $it = New-Object System.Windows.Forms.ListViewItem($risk[[string]$s.risk])
            [void]$it.SubItems.Add([string]$s.name)
            [void]$it.SubItems.Add([string](@($s.reasons)[0]))
            $it.Tag = [int]$s.id
            if ($s.risk -eq 'High') { $it.BackColor = C '#FDECEA'; $it.Checked = $true } else { $it.BackColor = C '#FFF4E0' }
            [void]$list.Items.Add($it)
        }
        $obs = @($plan.observations | Where-Object { $_.Level -in 'high', 'med' })
        $kernel = @($obs | Where-Object { $_.Title -match 'Non-paged|Paged pool' })
        $hint = ''
        if ($list.Items.Count -gt 0) { $hint = 'وُجدت ملفات تستحق المراجعة (الملفات عالية الخطر محددة مسبقًا). افتح التقرير للتأكد ثم اضغط «عزل». العزل ينقل الملف جانبًا ولا يحذفه.' }
        elseif ($kernel.Count -gt 0) { $hint = 'المشكلة غالبًا من تعريف (Driver) في ويندوز وليست ملفًا يُعزل. افتح التقرير: جدول Pool tags يحدد التعريف، ثم حدّثه من موقع الشركة المصنّعة.' }
        elseif ($obs.Count -gt 0) { $hint = 'لا يوجد ملف يُعزل، لكن هناك ملاحظات في التقرير تستحق القراءة.' }
        else { $hint = 'لا يوجد ما يحتاج عزلًا الآن. إن كانت المشكلة موجودة فعلًا فأعد الفحص وهي ظاهرة (الذاكرة ممتلئة).' }
        if ($obs.Count -gt 0) { $hint += "`n" + 'أهم الملاحظات: ' + ((@($obs | Select-Object -First 3) | ForEach-Object { $_.Title }) -join '  •  ') }
        if ($lowCount -gt 0) { $hint += "`n" + "($lowCount عناصر منخفضة الخطورة مذكورة في التقرير فقط)" }
        $lblHint.Text = $hint
        Refresh-Buttons
    }

    function Scan-Done {
        $r = Get-LatestResult
        if (-not $r -or $r.Time -lt $script:scanStart.AddSeconds(-5)) {
            Set-Status 'لم يكتمل الفحص. راجع «تفاصيل التنفيذ» أسفل النافذة.' 0
            Info-Box 'لم يكتمل الفحص. جرّب تشغيل الأداة مجددًا كمدير، وإن تكرر أرسل لقطة من النافذة.' 'Warning'
            return
        }
        Load-Results $r $false
        Set-Status 'اكتمل الفحص. النتيجة في الخطوة ②.' 100
    }

    function Count-Problems([string]$out) {
        @($out -split "`r?`n" | Where-Object { $_ -match 'could not|failed|still locked|changed since|refusing|will NOT be moved|ERROR' }).Count
    }

    # ------------------------------------------------------------ button actions
    $btnScan.Add_Click({ Guard {
            $script:scanStart = Get-Date
            New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null
            $txtLog.Clear(); $script:cap = 5
            Set-Status 'بدأ الفحص ...' 2
            Start-Task 'scan' @(('"{0}"' -f $ScanScript), '-NoOpen', '-OutDir', ('"{0}"' -f $ReportsDir), '-SampleSeconds', '30') { Scan-Done }
        } })

    $list.Add_ItemChecked({ Guard { Refresh-Buttons } })

    $btnQ.Add_Click({ Guard {
            $ids = @($list.CheckedItems | ForEach-Object { [int]$_.Tag })
            if ($ids.Count -eq 0) { return }
            $names = (@($list.CheckedItems | ForEach-Object { '•  ' + $_.SubItems[1].Text }) -join "`n")
            $ok = Confirm-Box ("سيتم إيقاف هذه الملفات وعزلها جانبًا. لن يُحذف شيء ويمكنك التراجع في أي وقت:`n`n$names`n`nهل تريد المتابعة؟") 'تأكيد العزل' 'Question'
            if (-not $ok) { return }
            $argv = @(('"{0}"' -f $ActionsScript), '-Mode', 'Quarantine', '-Plan', ('"{0}"' -f $script:current.Plan), '-Select', ($ids -join ','), '-Yes')
            if ($QuarantineDir) { $argv += @('-StoreDir', ('"{0}"' -f $QuarantineDir)) }
            if ($AllowNonAdmin) { $argv += '-AllowNonAdmin' }
            Set-Status 'جارٍ العزل ...' 40
            Start-Task 'quarantine' $argv {
                $out = $script:lastOutput
                $bad = Count-Problems $out
                if ($out -match 'Done\. Quarantine batch') {
                    Set-Status 'تم العزل.' 100
                    $msg = 'تم العزل. أعد تشغيل الجهاز (Restart) ثم افحص مرة أخرى للتأكد أن الذاكرة رجعت طبيعية.'
                    if ($bad -gt 0) { $msg += "`n`nملاحظة: $bad خطوة لم تكتمل (مثل ملف مقفول). التفاصيل في أسفل النافذة." }
                    $list.Items.Clear(); $lblHint.Text = 'تم العزل. أعد التشغيل ثم افحص من جديد. للتراجع استخدم «تراجع عن آخر عزل».'
                    $script:current = $script:current
                    Info-Box $msg
                } else {
                    Set-Status 'لم يكتمل العزل.' 0
                    Info-Box 'لم يكتمل العزل. التفاصيل في أسفل النافذة.' 'Warning'
                }
                Refresh-Buttons
            }
        } })

    $btnReport.Add_Click({ Guard { if ($script:current -and (Test-Path -LiteralPath $script:current.Html)) { Start-Process -FilePath $script:current.Html } } })
    $btnFolder.Add_Click({ Guard { if ($script:current -and (Test-Path -LiteralPath $script:current.Html)) { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $script:current.Html) } } })

    $btnRestore.Add_Click({ Guard {
            $b = @(Get-Batches | Where-Object { $m = Get-Content (Join-Path $_.FullName 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json; -not $m.purgedAt -and -not $m.restoredAt }) | Select-Object -First 1
            if (-not $b) { Info-Box 'لا توجد عملية عزل سابقة للتراجع عنها.'; return }
            if (-not (Confirm-Box "سيتم إرجاع الملفات والخدمات التي عُزلت في آخر مرة إلى حالتها الأصلية.`n`nهل تريد المتابعة؟" 'تأكيد التراجع' 'Question')) { return }
            $argv = @(('"{0}"' -f $ActionsScript), '-Mode', 'Restore', '-Batch', $b.Name, '-Yes')
            if ($QuarantineDir) { $argv += @('-StoreDir', ('"{0}"' -f $QuarantineDir)) }
            if ($AllowNonAdmin) { $argv += '-AllowNonAdmin' }
            Set-Status 'جارٍ التراجع ...' 50
            Start-Task 'restore' $argv {
                if ($script:lastOutput -match 'Restore finished') { Set-Status 'تم التراجع.' 100; Info-Box 'تم إرجاع كل شيء كما كان. قد تحتاج لإعادة تشغيل الجهاز.' }
                else { Set-Status 'لم يكتمل التراجع.' 0; Info-Box 'لم يكتمل التراجع. التفاصيل في أسفل النافذة.' 'Warning' }
            }
        } })

    $btnPurge.Add_Click({ Guard {
            $st = Get-QuarantinedStats
            if ($st.Count -eq 0) { Info-Box 'لا توجد ملفات معزولة لحذفها.'; return }
            $ok = Confirm-Box ("سيتم حذف {0} ملف ({1} MB) من الحجر نهائيًا.`nلا يمكن استرجاعها بعد ذلك.`n`nهل أنت متأكد؟" -f $st.Count, $st.MB) 'حذف نهائي' 'Warning'
            if (-not $ok) { return }
            $argv = @(('"{0}"' -f $ActionsScript), '-Mode', 'Purge', '-OlderThanDays', '0', '-Yes')
            if ($QuarantineDir) { $argv += @('-StoreDir', ('"{0}"' -f $QuarantineDir)) }
            if ($AllowNonAdmin) { $argv += '-AllowNonAdmin' }
            Set-Status 'جارٍ الحذف ...' 50
            Start-Task 'purge' $argv { Set-Status 'تم الحذف النهائي.' 100; Info-Box 'تم حذف الملفات المعزولة نهائيًا.' }
        } })

    $btnClean.Add_Click({ Guard {
            if (-not (Test-Path -LiteralPath $ReportsDir)) { Info-Box 'لا توجد تقارير محفوظة.'; return }
            $n = @(Get-ChildItem -LiteralPath $ReportsDir -File -ErrorAction SilentlyContinue).Count
            if (-not (Confirm-Box "سيتم حذف مجلد التقارير ($n ملف) من سطح المكتب.`nلن يؤثر ذلك على الملفات المعزولة.`n`nمتأكد؟" 'مسح التقارير' 'Question')) { return }
            Remove-Item -LiteralPath $ReportsDir -Recurse -Force -ErrorAction SilentlyContinue
            $script:current = $null; $list.Items.Clear()
            $lblVerdict.Text = 'لم يتم الفحص بعد'; $lblVerdict.BackColor = C '#EEF1F4'; $lblVerdict.ForeColor = C '#4A5A68'; $lblHint.Text = ''
            Set-Status 'تم مسح التقارير.' 0
            Refresh-Buttons
        } })

    $form.Add_FormClosing({
            param($s, $e)
            if ($script:proc -and -not $script:proc.HasExited) {
                if ($script:taskKind -eq 'scan') { try { $script:proc.Kill() } catch { } }
                else { $e.Cancel = $true; Info-Box 'العملية جارية الآن، انتظر حتى تنتهي ثم أغلق النافذة.' 'Warning' }
            }
        })

    # developer helper: save the window to a PNG (used for the guide's pictures)
    function Save-Shot([string]$path) {
        $bmp = New-Object System.Drawing.Bitmap($main.Width, $main.Height)
        $main.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $main.Width, $main.Height)))
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    }
    function Fit-Columns {
        $w = $list.ClientSize.Width - $list.Columns[0].Width - $list.Columns[1].Width - 6
        $list.Columns[2].Width = [math]::Max(220, $w)
    }
    $list.Add_Resize({ Fit-Columns })

    # ------------------------------------------------------------ start-up
    $form.Add_Shown({
            Guard {
                Fit-Columns
                $r = Get-LatestResult
                if ($r) { Load-Results $r $true; Set-Status 'هذه نتيجة آخر فحص. اضغط «ابدأ الفحص الآن» لفحص جديد.' 0 }
                Refresh-Buttons
                if ($TestScript) {
                    $script:t2 = New-Object System.Windows.Forms.Timer
                    $script:t2.Interval = 700
                    $script:t2.Add_Tick({
                            $script:t2.Stop()
                            try { . $TestScript } catch { Add-Content -LiteralPath ($TestScript + '.error.txt') -Value ($_ | Out-String) }
                        })
                    $script:t2.Start()
                }
            }
        })
    Refresh-Buttons
    [void]$form.ShowDialog()
}
catch {
    $msg = $_ | Out-String
    try { Add-Content -LiteralPath (Join-Path $env:TEMP 'ramdoctor-gui-error.log') -Value $msg } catch { }
    try { [void][System.Windows.Forms.MessageBox]::Show("تعذّر فتح النافذة:`n$($_.Exception.Message)", 'فاحص الذاكرة', 'OK', 'Error') } catch { }
}
