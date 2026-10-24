#requires -Version 5.1
<#
.SYNOPSIS
  RAM Doctor - one Windows 11 (Fluent) styled Arabic window. It only launches the scan / actions scripts
  and shows their results; it holds no scanning logic of its own.

  Developer-only switches (not needed by users):
    -TestScript   run a script file on the UI thread after the window opens (screenshots / tests)
    -Unattended   skip confirmation dialogs (tests)
    -AllowNonAdmin  let the quarantine buttons work without elevation (tests)
    -Theme Auto|Light|Dark   Auto follows the Windows app theme
    -Accent ''|default|#RRGGBB   '' = derive from the Windows accent colour, default = Windows blue
    -ShareProfileDir / -ShareEndpoint / -ShareDryRun / -ShareForceConfigured   exercise the (dormant) share UI in tests
#>
[CmdletBinding()]
param(
    [string]$ReportsDir = '',
    [string]$QuarantineDir = '',
    [string]$TestScript = '',
    [switch]$Unattended,
    [switch]$AllowNonAdmin,
    [ValidateSet('Auto', 'Light', 'Dark')][string]$Theme = 'Auto',
    [string]$Accent = '',
    [string]$ShareProfileDir = '',
    [string]$ShareEndpoint = '',
    [switch]$ShareDryRun,
    [switch]$ShareForceConfigured
)

$ErrorActionPreference = 'Continue'
$AppDir = $PSScriptRoot
$ScanScript = Join-Path $AppDir 'RAM-Doctor.ps1'
$ActionsScript = Join-Path $AppDir 'RAM-Doctor-Actions.ps1'
$ShareScript = Join-Path $AppDir 'RAM-Doctor-Share.ps1'
if (-not $ReportsDir) { $ReportsDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'RAM-Doctor-Reports' }
$StoreRoot = if ($QuarantineDir) { $QuarantineDir } else { Join-Path $env:ProgramData 'RAM-Doctor' }
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$CanAct = ($IsAdmin -or $AllowNonAdmin)

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    if (-not ('Fluent.Theme' -as [type])) {
        Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -Language CSharp -TypeDefinition ([IO.File]::ReadAllText((Join-Path $AppDir 'lib\Fluent.cs')))
    }

    # ------------------------------------------------------------ theme (dark/light + Windows accent colour)
    $dark = $false
    if ($Theme -eq 'Dark') { $dark = $true }
    elseif ($Theme -eq 'Auto') {
        try { $dark = ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch { $dark = $false }
    }
    $accentMode = 'default'; $accentColor = [System.Drawing.Color]::Empty
    if ($Accent -match '^#?([0-9a-fA-F]{6})$') {
        $accentMode = 'custom'; $accentColor = [System.Drawing.ColorTranslator]::FromHtml('#' + $Matches[1])
    } elseif ($Accent -ne 'default') {
        try {
            $raw = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -ErrorAction Stop).AccentColor
            if ($null -ne $raw) {
                $v = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$raw), 0)   # ABGR
                $accentColor = [System.Drawing.Color]::FromArgb([int]($v -band 0xFF), [int](($v -shr 8) -band 0xFF), [int](($v -shr 16) -band 0xFF))
                $accentMode = 'system'
            }
        } catch { }
    }
    [Fluent.Theme]::Apply($dark, $accentMode, $accentColor)
    $cWin = [Fluent.Theme]::Window; $cCard = [Fluent.Theme]::Card; $cText = [Fluent.Theme]::Text; $cSub = [Fluent.Theme]::SubText
    $cDiv = [Fluent.Theme]::Divider; $cField = [Fluent.Theme]::Field

    function Ui([double]$pt, [string]$style = 'Regular') { [Fluent.Theme]::UI([single]$pt, [System.Drawing.FontStyle]$style) }
    function Semi([double]$pt) { [Fluent.Theme]::Semi([single]$pt) }
    function Glyph([int]$code) { [string][char]$code }
    function Pad([int]$l, [int]$t, [int]$r, [int]$b) { New-Object System.Windows.Forms.Padding($l, $t, $r, $b) }

    function New-Tlp([int]$cols, [int]$rows, $bg) {
        $t = New-Object System.Windows.Forms.TableLayoutPanel
        $t.Dock = 'Fill'; $t.ColumnCount = $cols; $t.RowCount = $rows; $t.Margin = Pad 0 0 0 0; $t.BackColor = $bg
        return $t
    }
    function Add-Row($t, [string]$type, [float]$size) { [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]$type, $size))) }
    function Add-Col($t, [string]$type, [float]$size) { [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]$type, $size))) }
    function New-Lbl([string]$text, $font, $color, $bg, [string]$align = 'TopLeft') {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.BackColor = $bg; $l.AutoSize = $false; $l.Dock = 'Fill'
        $l.Margin = Pad 0 0 0 0; $l.TextAlign = $align; $l.UseMnemonic = $false
        return $l
    }
    function New-Btn([string]$text, [string]$kind, [string]$glyph, [int]$w, [int]$h = 38) {
        $b = New-Object Fluent.FButton
        $b.Text = $text; $b.Kind = $kind; $b.Glyph = $glyph; $b.Size = New-Object System.Drawing.Size($w, $h); $b.Margin = Pad 0 0 0 0
        return $b
    }

    # ------------------------------------------------------------ window
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'فاحص الذاكرة - RAM Doctor'
    $form.ClientSize = New-Object System.Drawing.Size(940, 740)
    $form.MinimumSize = New-Object System.Drawing.Size(880, 640)
    $form.StartPosition = 'CenterScreen'
    $form.RightToLeft = 'Yes'; $form.RightToLeftLayout = $true
    $form.Font = Ui 10; $form.BackColor = $cWin
    try { $form.Icon = [Fluent.Win]::MakeIcon([Fluent.Theme]::Accent, [Fluent.Theme]::AccentText, (Glyph 0xE9D9)) } catch { }

    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = 'Fill'; $page.AutoScroll = $true; $page.BackColor = $cWin
    $col = New-Object System.Windows.Forms.TableLayoutPanel
    $col.Dock = 'Top'; $col.AutoSize = $true; $col.AutoSizeMode = 'GrowAndShrink'; $col.ColumnCount = 1; $col.BackColor = $cWin
    Add-Col $col 'Percent' 100
    $page.Controls.Add($col); $form.Controls.Add($page)
    function Add-Block($ctl, [int]$top = 0, [int]$bottom = 12) { $ctl.Dock = 'Fill'; $ctl.Margin = Pad 24 $top 24 $bottom; [void]$col.Controls.Add($ctl) }

    # ---- header
    $hdr = New-Tlp 2 1 $cWin; $hdr.Height = 82
    Add-Col $hdr 'Absolute' 68; Add-Col $hdr 'Percent' 100; Add-Row $hdr 'Percent' 100
    $badge = New-Object Fluent.FBadge
    $badge.Glyph = Glyph 0xE9D9; $badge.GlyphPx = 26; $badge.Size = New-Object System.Drawing.Size(52, 52); $badge.Radius = 13; $badge.Anchor = 'None'
    $tt = New-Tlp 1 2 $cWin; Add-Col $tt 'Percent' 100; Add-Row $tt 'Percent' 58; Add-Row $tt 'Percent' 42
    $lblTitle = New-Lbl 'فاحص الذاكرة' (Semi 22) $cText $cWin 'BottomLeft'
    $lblSub = New-Lbl 'اعرف سبب امتلاء الذاكرة (RAM) خلال دقيقة. الفحص آمن ولا يتصل بالإنترنت.' (Ui 10.5) $cSub $cWin 'TopLeft'
    $tt.Controls.Add($lblTitle, 0, 0); $tt.Controls.Add($lblSub, 0, 1)
    $hdr.Controls.Add($badge, 0, 0); $hdr.Controls.Add($tt, 1, 0)
    Add-Block $hdr 18 4

    # ---- admin banner (only when not elevated)
    $banner = New-Object Fluent.FInfoBar
    $banner.Level = 'Warning'; $banner.Title = 'لم تُشغَّل الأداة كمدير'; $banner.Message = 'أغلق النافذة وافتحها مجددًا ووافق على طلب الصلاحيات (نعم)، وإلا لن تعمل أزرار العزل والتراجع.'
    $banner.Visible = (-not $CanAct)
    Add-Block $banner 4 10

    # ---- step 1: hero card
    $hero = New-Object Fluent.FCard
    $hero.Height = 156; $hero.Padding = Pad 22 18 22 14
    $ht = New-Tlp 1 4 $cCard
    Add-Col $ht 'Percent' 100; Add-Row $ht 'Absolute' 60; Add-Row $ht 'Absolute' 16; Add-Row $ht 'Absolute' 10; Add-Row $ht 'Percent' 100
    $top = New-Tlp 2 1 $cCard; Add-Col $top 'Percent' 100; Add-Col $top 'Absolute' 210; Add-Row $top 'Percent' 100
    $topText = New-Tlp 1 2 $cCard; Add-Col $topText 'Percent' 100; Add-Row $topText 'Absolute' 30; Add-Row $topText 'Percent' 100
    $lblHeroT = New-Lbl 'افحص جهازك' (Semi 14) $cText $cCard 'MiddleLeft'
    $lblHeroD = New-Lbl 'يستغرق حوالي دقيقة. الفحص لا يحذف ولا يغيّر شيئًا، ولا تغلق النافذة أثناءه.' (Ui 10) $cSub $cCard 'TopLeft'
    $topText.Controls.Add($lblHeroT, 0, 0); $topText.Controls.Add($lblHeroD, 0, 1)
    $btnScan = New-Btn 'ابدأ الفحص' 'Accent' (Glyph 0xE721) 190 42; $btnScan.Anchor = 'None'; $btnScan.Font = Semi 11
    $top.Controls.Add($topText, 0, 0); $top.Controls.Add($btnScan, 1, 0)
    $bar = New-Object Fluent.FProgress; $bar.Dock = 'Fill'; $bar.Margin = Pad 0 2 0 2
    $lblStatus = New-Lbl 'جاهز. اضغط «ابدأ الفحص» عندما تكون المشكلة ظاهرة (الذاكرة ممتلئة).' (Ui 10) $cSub $cCard 'TopLeft'
    $lblStatus.Margin = Pad 0 4 0 0
    $ht.Controls.Add($top, 0, 0); $ht.Controls.Add($bar, 0, 2); $ht.Controls.Add($lblStatus, 0, 3)
    $hero.Controls.Add($ht)
    Add-Block $hero 4 12

    # ---- step 2: verdict + toast + actions
    $info = New-Object Fluent.FInfoBar
    $info.Level = 'Info'; $info.Title = 'جاهز للفحص'
    $info.Message = 'بعد الفحص تظهر هنا النتيجة، وأي ملفات مشبوهة يمكنك عزلها بضغطة واحدة.'
    Add-Block $info 0 12

    $toast = New-Object Fluent.FInfoBar
    $toast.Level = 'Success'; $toast.Visible = $false
    Add-Block $toast 0 12

    $acts = New-Object System.Windows.Forms.FlowLayoutPanel
    $acts.Height = 44; $acts.WrapContents = $false; $acts.BackColor = $cWin; $acts.Visible = $false
    $btnReport = New-Btn 'افتح التقرير الكامل' 'Standard' (Glyph 0xE8A5) 200 40; $btnReport.Margin = Pad 12 0 0 0
    $btnFolder = New-Btn 'مكان ملف التقرير' 'Standard' (Glyph 0xE838) 190 40; $btnFolder.Margin = Pad 12 0 0 0
    $btnCopy = New-Btn 'نسخ ملخص للإرسال' 'Standard' (Glyph 0xE8C8) 200 40; $btnCopy.Margin = Pad 12 0 0 0
    $btnShare = New-Btn 'مشاركة مع مساعدي' 'Accent' (Glyph 0xE72D) 200 40; $btnShare.Margin = Pad 12 0 0 0; $btnShare.Visible = $false
    $acts.Controls.AddRange(@($btnReport, $btnFolder, $btnCopy, $btnShare))
    Add-Block $acts 0 12

    # ---- findings card
    $find = New-Object Fluent.FCard
    $find.Height = 316; $find.Padding = Pad 20 14 20 16; $find.Visible = $false
    $ft = New-Tlp 1 5 $cCard
    Add-Col $ft 'Percent' 100; Add-Row $ft 'Absolute' 34; Add-Row $ft 'Absolute' 196; Add-Row $ft 'Absolute' 12; Add-Row $ft 'Absolute' 44; Add-Row $ft 'Percent' 100
    $fh = New-Tlp 2 1 $cCard; Add-Col $fh 'Percent' 100; Add-Col $fh 'Absolute' 150; Add-Row $fh 'Percent' 100
    $lblFindT = New-Lbl 'ملفات تستحق المراجعة' (Semi 12.5) $cText $cCard 'MiddleLeft'
    $lblPick = New-Lbl '' (Ui 10) $cSub $cCard 'MiddleRight'
    $fh.Controls.Add($lblFindT, 0, 0); $fh.Controls.Add($lblPick, 1, 0)
    $list = New-Object Fluent.FList
    $list.Dock = 'Fill'; $list.RowHeight = 64; $list.EmptyText = 'لا توجد ملفات مشبوهة'; $list.Margin = Pad 0 0 0 0
    $fb = New-Tlp 2 1 $cCard; Add-Col $fb 'Absolute' 230; Add-Col $fb 'Percent' 100; Add-Row $fb 'Percent' 100
    $btnQ = New-Btn 'عزل الملفات المحددة' 'Accent' (Glyph 0xEA18) 214 40; $btnQ.Anchor = 'None'
    $lblQHint = New-Lbl 'العزل ينقل الملف جانبًا ولا يحذفه، ويمكنك التراجع عنه في أي وقت.' (Ui 9.5) $cSub $cCard 'MiddleLeft'
    $lblQHint.Margin = Pad 8 0 0 0
    $fb.Controls.Add($btnQ, 0, 0); $fb.Controls.Add($lblQHint, 1, 0)
    $ft.Controls.Add($fh, 0, 0); $ft.Controls.Add($list, 0, 1); $ft.Controls.Add($fb, 0, 3)
    $find.Controls.Add($ft)
    Add-Block $find 0 12

    # ---- "more" card (restore / purge / clean / share account) - collapsible
    $more = New-Object Fluent.FCard
    $more.Padding = Pad 8 8 8 8
    $mt = New-Tlp 1 2 $cCard; Add-Col $mt 'Percent' 100; Add-Row $mt 'Absolute' 48; Add-Row $mt 'AutoSize' 0
    $exMore = New-Object Fluent.FExpander; $exMore.Text = 'المزيد: تراجع وحذف وتنظيف'; $exMore.Glyph = Glyph 0xE713; $exMore.Dock = 'Fill'; $exMore.Margin = Pad 0 0 0 0
    $moreBody = New-Object System.Windows.Forms.TableLayoutPanel
    $moreBody.Dock = 'Fill'; $moreBody.ColumnCount = 1; $moreBody.AutoSize = $true; $moreBody.AutoSizeMode = 'GrowAndShrink'; $moreBody.BackColor = $cCard; $moreBody.Visible = $false
    Add-Col $moreBody 'Percent' 100
    $mt.Controls.Add($exMore, 0, 0); $mt.Controls.Add($moreBody, 0, 1)
    $more.Controls.Add($mt)
    Add-Block $more 0 12

    function New-SettingRow([string]$glyph, [string]$title, [string]$desc, $button) {
        $r = New-Tlp 3 1 $cCard; $r.Height = 66; $r.Margin = Pad 0 0 0 0
        Add-Col $r 'Absolute' 52; Add-Col $r 'Percent' 100; Add-Col $r 'Absolute' 176; Add-Row $r 'Percent' 100
        $ic = New-Object Fluent.FBadge; $ic.Filled = $false; $ic.Glyph = $glyph; $ic.GlyphPx = 20; $ic.Size = New-Object System.Drawing.Size(36, 36); $ic.Anchor = 'None'
        $ic.GlyphColor = [Fluent.Theme]::SubText
        $tx = New-Tlp 1 2 $cCard; Add-Col $tx 'Percent' 100; Add-Row $tx 'Percent' 50; Add-Row $tx 'Percent' 50
        $lt = New-Lbl $title (Semi 10.5) $cText $cCard 'BottomLeft'
        $ld = New-Lbl $desc (Ui 9.5) $cSub $cCard 'TopLeft'
        $ld.Name = 'desc'
        $tx.Controls.Add($lt, 0, 0); $tx.Controls.Add($ld, 0, 1)
        $button.Anchor = 'None'; $button.Size = New-Object System.Drawing.Size(160, 34)
        $r.Controls.Add($ic, 0, 0); $r.Controls.Add($tx, 1, 0); $r.Controls.Add($button, 2, 0)
        return $r
    }
    function New-Divider { $d = New-Object System.Windows.Forms.Panel; $d.Height = 1; $d.Dock = 'Fill'; $d.BackColor = $cDiv; $d.Margin = Pad 14 0 14 0; return $d }

    $btnRestore = New-Btn 'تراجع' 'Standard' (Glyph 0xE7A7) 160 34
    $btnPurge = New-Btn 'حذف نهائي' 'Danger' (Glyph 0xE74D) 160 34
    $btnClean = New-Btn 'مسح التقارير' 'Standard' (Glyph 0xE74D) 160 34
    $btnShareDel = New-Btn 'حذف ملفي الشخصي' 'Danger' '' 160 34
    $rowRestore = New-SettingRow (Glyph 0xE777) 'تراجع عن آخر عزل' 'يُرجع الملفات والخدمات التي عُزلت إلى حالتها الأصلية.' $btnRestore
    $rowPurge = New-SettingRow (Glyph 0xE74D) 'حذف الملفات المعزولة نهائيًا' 'لا يمكن التراجع بعد ذلك.' $btnPurge
    $rowClean = New-SettingRow (Glyph 0xE8B7) 'مسح تقارير الأداة من جهازك' 'يحذف مجلد التقارير من سطح المكتب، ولا يؤثر على الملفات المعزولة.' $btnClean
    $rowShare = New-SettingRow (Glyph 0xE72E) 'حسابي للمشاركة' 'غير مُعدّ بعد' $btnShareDel
    $divShare = New-Divider
    $divShare.Visible = $false; $rowShare.Visible = $false
    foreach ($c in @($rowRestore, (New-Divider), $rowPurge, (New-Divider), $rowClean, $divShare, $rowShare)) { $c.Dock = 'Fill'; [void]$moreBody.Controls.Add($c) }

    # ---- technical details card (log) - collapsible
    $details = New-Object Fluent.FCard
    $details.Padding = Pad 8 8 8 8
    $dt = New-Tlp 1 2 $cCard; Add-Col $dt 'Percent' 100; Add-Row $dt 'Absolute' 48; Add-Row $dt 'Percent' 100
    $exLog = New-Object Fluent.FExpander; $exLog.Text = 'التفاصيل التقنية (للمختصين)'; $exLog.Glyph = Glyph 0xE9D9; $exLog.Dock = 'Fill'; $exLog.Margin = Pad 0 0 0 0
    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.Dock = 'Fill'; $txtLog.BorderStyle = 'None'
    $txtLog.Font = [Fluent.Theme]::Mono(9); $txtLog.RightToLeft = 'No'; $txtLog.BackColor = $cField; $txtLog.ForeColor = $cText; $txtLog.Margin = Pad 8 4 8 8; $txtLog.Visible = $false
    $dt.Controls.Add($exLog, 0, 0); $dt.Controls.Add($txtLog, 0, 1)
    $details.Controls.Add($dt)
    Add-Block $details 0 24

    function Resize-Cards {
        $more.Height = 8 + 8 + 48 + $(if ($exMore.Expanded) { $moreBody.PreferredSize.Height + 4 } else { 0 })
        $moreBody.Visible = $exMore.Expanded
        $details.Height = 8 + 8 + 48 + $(if ($exLog.Expanded) { 150 } else { 0 })
        $txtLog.Visible = $exLog.Expanded
    }
    Resize-Cards
    $exMore.Add_Toggled({ Resize-Cards })
    $exLog.Add_Toggled({ Resize-Cards })

    # ------------------------------------------------------------ helpers
    function Add-Log([string]$s) { $txtLog.AppendText($s + "`r`n") }
    function Set-Status([string]$s, [int]$pct = -1) { $lblStatus.Text = $s; if ($pct -ge 0) { $bar.Value = $pct } }
    $mbOpts = [System.Windows.Forms.MessageBoxOptions]'RtlReading, RightAlign'
    function Info-Box([string]$text, [string]$icon = 'Information') {
        if ($Unattended) { Add-Log "[dialog] $text"; return }
        [void][System.Windows.Forms.MessageBox]::Show($form, $text, 'فاحص الذاكرة', 'OK', $icon, 'Button1', $mbOpts)
    }
    function Confirm-Box([string]$text, [string]$title, [string]$icon = 'Question') {
        if ($Unattended) { Add-Log "[confirm:auto-yes] $title"; return $true }
        return ([System.Windows.Forms.MessageBox]::Show($form, $text, $title, 'YesNo', $icon, 'Button2', $mbOpts) -eq 'Yes')
    }
    function Guard([scriptblock]$b) {
        try { & $b } catch {
            Add-Log ('ERROR: ' + $_.Exception.Message)
            Info-Box ('حدث خطأ غير متوقع:' + "`n" + $_.Exception.Message) 'Warning'
        }
    }
    function Read-Shared([string]$p, [bool]$utf8 = $false) {   # scan/actions print ASCII (console code page); the share CLI prints UTF-8 (Arabic)
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { return '' }
        try {
            $fs = [System.IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
            $enc = if ($utf8) { New-Object System.Text.UTF8Encoding($false) } else { [System.Text.Encoding]::Default }
            $sr = New-Object System.IO.StreamReader($fs, $enc)
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

    # small notification under the verdict (auto-hides)
    $script:toastTimer = New-Object System.Windows.Forms.Timer
    $script:toastTimer.Interval = 9000
    $script:toastTimer.Add_Tick({ $script:toastTimer.Stop(); $toast.Visible = $false })
    function Show-Toast([string]$level, [string]$title, [string]$msg) {
        $toast.Level = $level; $toast.Title = $title; $toast.Message = $msg; $toast.Visible = $true
        [void]$toast.FitHeight()
        $script:toastTimer.Stop(); $script:toastTimer.Start()
    }

    # ------------------------------------------------------------ background task runner (child powershell, polled by a timer)
    $script:proc = $null; $script:outFile = ''; $script:errFile = ''; $script:lineIdx = 0; $script:onDone = $null
    $script:taskKind = ''; $script:cap = 5; $script:tick = 0; $script:current = $null; $script:scanStart = Get-Date; $script:lastOutput = ''
    $script:share = [pscustomobject]@{ Configured = $false; Name = ''; UserId = ''; Helper = ''; EndpointConfigured = $false }

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
        $busy = ($null -ne $script:proc -and -not $script:proc.HasExited)
        $btnScan.Enabled = (-not $busy)
        $btnScan.Text = $(if ($busy -and $script:taskKind -eq 'scan') { 'جارٍ الفحص ...' } else { 'ابدأ الفحص' })
        $has = ($null -ne $script:current)
        $btnQ.Enabled = ((-not $busy) -and $CanAct -and ($list.CheckedCount -gt 0) -and $has)
        $lblPick.Text = $(if ($list.Items.Count -gt 0) { 'محدد ' + $list.CheckedCount + ' من ' + $list.Items.Count } else { '' })
        $btnReport.Enabled = ((-not $busy) -and $has)
        $btnFolder.Enabled = ((-not $busy) -and $has)
        $btnCopy.Enabled = ((-not $busy) -and $has)
        $btnShare.Enabled = ((-not $busy) -and $has)
        $acts.Visible = $has
        $find.Visible = ($list.Items.Count -gt 0)
        $canRestore = $false
        foreach ($bt in (Get-Batches)) {
            try { $m = Get-Content -LiteralPath (Join-Path $bt.FullName 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json; if (-not $m.purgedAt -and -not $m.restoredAt) { $canRestore = $true; break } } catch { }
        }
        $hasFiles = ((Get-QuarantinedStats).Count -gt 0)
        $btnRestore.Enabled = ((-not $busy) -and $CanAct -and $canRestore)
        $btnPurge.Enabled = ((-not $busy) -and $CanAct -and $hasFiles)
        $btnClean.Enabled = (-not $busy)
        $btnShareDel.Enabled = ((-not $busy) -and $script:share.Configured)
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

    # short synchronous CLI call (keeps the UI alive while waiting)
    # $envVars: process-scope variables handed to the child only (used for the profile name / invite code so they never
    # appear on a command line); they are removed from this process right after the child has started.
    function Invoke-Cli([string[]]$psArgs, [int]$timeoutSec = 40, [hashtable]$envVars = @{}) {
        $id = [guid]::NewGuid().ToString('N')
        $o = Join-Path $env:TEMP "ramdoctor-$id.out"; $e = Join-Path $env:TEMP "ramdoctor-$id.err"
        foreach ($k in $envVars.Keys) { if ($envVars[$k]) { [Environment]::SetEnvironmentVariable($k, [string]$envVars[$k], 'Process') } }
        try {
            $p = Start-Process -FilePath powershell.exe -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') + $psArgs) -WindowStyle Hidden -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
        } finally {
            foreach ($k in $envVars.Keys) { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
        }
        $null = $p.Handle
        $end = (Get-Date).AddSeconds($timeoutSec)
        while (-not $p.HasExited -and (Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }
        if (-not $p.HasExited) { try { $p.Kill() } catch { } }
        $text = Read-Shared $o $true
        Remove-Item -LiteralPath $o, $e -Force -ErrorAction SilentlyContinue
        [pscustomobject]@{ Output = $text; ExitCode = $(if ($p.HasExited) { $p.ExitCode } else { -1 }) }
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
        $u8 = ($script:taskKind -in 'summary', 'share')
        $lines = @((Read-Shared $script:outFile $u8) -split "`r?`n")
        $limit = if ($exited) { $lines.Count } else { $lines.Count - 1 }
        for ($i = $script:lineIdx; $i -lt $limit; $i++) { Handle-Line $lines[$i] }
        if ($limit -gt $script:lineIdx) { $script:lineIdx = $limit }
        if (-not $exited) {
            $script:tick++
            if ($script:taskKind -eq 'scan' -and ($script:tick % 3 -eq 0) -and $bar.Value -lt $script:cap) { $bar.Value = $bar.Value + 1 }
            return
        }
        $timer.Stop()
        $out = Read-Shared $script:outFile $u8
        $err = (Read-Shared $script:errFile $u8).Trim()
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
        $script:currentPlan = $plan
        $lvlMap = @{ high = 'Error'; med = 'Warning'; low = 'Info'; ok = 'Success' }
        $lv = $lvlMap[[string]$plan.verdict.Level]; if (-not $lv) { $lv = 'Info' }

        $list.Clear()
        $risk = @{ High = 'عالٍ'; Medium = 'متوسط' }
        $lowCount = 0
        foreach ($s in @($plan.suspects)) {
            if (-not $s) { continue }
            if ($s.risk -eq 'Low') { $lowCount++; continue }
            $it = New-Object Fluent.FItem
            $it.Name = [string]$s.name; $it.Reason = [string](@($s.reasons)[0]); $it.Risk = $risk[[string]$s.risk]
            $it.Level = $(if ($s.risk -eq 'High') { 2 } else { 1 }); $it.Tag = [int]$s.id; $it.Checked = ($s.risk -eq 'High')
            $list.Add($it)
        }
        $obs = @($plan.observations | Where-Object { $_.Level -in 'high', 'med' })
        $kernel = @($obs | Where-Object { $_.Title -match 'Non-paged|Paged pool' })
        if ($list.Items.Count -gt 0) { $hint = 'وُجدت ملفات تستحق المراجعة (الملفات عالية الخطر محددة مسبقًا). افتح التقرير للتأكد ثم اضغط «عزل».' }
        elseif ($kernel.Count -gt 0) { $hint = 'المشكلة غالبًا من تعريف (Driver) في ويندوز وليست ملفًا يُعزل. افتح التقرير: جدول Pool tags يحدد التعريف، ثم حدّثه من موقع الشركة المصنّعة.' }
        elseif ($obs.Count -gt 0) { $hint = 'لا يوجد ملف يُعزل، لكن هناك ملاحظات في التقرير تستحق القراءة.' }
        else { $hint = 'لا يوجد ما يحتاج عزلًا الآن. إن كانت المشكلة موجودة فعلًا فأعد الفحص وهي ظاهرة (الذاكرة ممتلئة).' }
        if ($obs.Count -gt 0) { $hint += "`n" + 'أهم الملاحظات:  ' + ((@($obs | Select-Object -First 3) | ForEach-Object { $_.Title }) -join '   •   ') }
        if ($lowCount -gt 0) {
            $lowText = switch ($lowCount) { 1 { 'عنصر واحد منخفض الخطورة مذكور في التقرير فقط' } 2 { 'عنصران منخفضا الخطورة مذكوران في التقرير فقط' } default { "$lowCount عناصر منخفضة الخطورة مذكورة في التقرير فقط" } }
            $hint += "`n($lowText)"
        }
        # the findings card grows with its content (1 to 3 rows), no empty space
        $rows = [math]::Min(3, [math]::Max(1, $list.Items.Count))
        $lh = $rows * $list.RowHeight + 4
        $ft.RowStyles[1].Height = $lh
        $find.Height = 14 + 34 + $lh + 12 + 44 + 20
        $pre = if ($previous) { 'آخر فحص (' + $r.Time.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) + '):  ' } else { '' }
        $info.Level = $lv
        $info.Title = $pre + [string]$plan.verdict.Headline
        $info.Message = $hint
        [void]$info.FitHeight()
        Refresh-Buttons
    }

    function Scan-Done {
        $r = Get-LatestResult
        if (-not $r -or $r.Time -lt $script:scanStart.AddSeconds(-5)) {
            Set-Status 'لم يكتمل الفحص. راجع «التفاصيل التقنية» أسفل النافذة.' 0
            Info-Box 'لم يكتمل الفحص. جرّب تشغيل الأداة مجددًا كمدير، وإن تكرر أرسل لقطة من النافذة.' 'Warning'
            return
        }
        Load-Results $r $false
        Set-Status 'اكتمل الفحص. النتيجة أعلاه.' 100
    }

    function Count-Problems([string]$out) {
        @($out -split "`r?`n" | Where-Object { $_ -match 'could not|failed|still locked|changed since|refusing|will NOT be moved|ERROR' }).Count
    }

    # ------------------------------------------------------------ copy-summary (always available; nothing leaves the PC)
    function Build-LocalSummary($plan) {
        $L = New-Object System.Collections.Generic.List[string]
        $L.Add('ملخص فحص RAM Doctor')
        $L.Add('النتيجة: ' + [string]$plan.verdict.Headline)
        if ($plan.memory) {
            $L.Add(('الذاكرة: مستخدم {0} من {1} GB | Non-paged {2} GB | Paged {3} GB' -f $plan.memory.UsedGB, $plan.memory.TotalGB, $plan.memory.NonPagedGB, $plan.memory.PagedGB))
        }
        $o = @($plan.observations | Where-Object { $_.Level -in 'high', 'med' } | Select-Object -First 4)
        foreach ($x in $o) { $L.Add('• ' + [string]$x.Title) }
        $s = @($plan.suspects | Where-Object { $_.risk -in 'High', 'Medium' } | Select-Object -First 5)
        if ($s.Count -gt 0) { $L.Add('ملفات مشبوهة: ' + (($s | ForEach-Object { "$($_.name) ($(if ($_.risk -eq 'High') { 'عالٍ' } else { 'متوسط' }))" }) -join ' ، ')) }
        $L.Add('(بدون مسارات أو أسماء مستخدمين)')
        return ($L -join "`r`n")
    }

    function Copy-Text([string]$text) {
        for ($i = 0; $i -lt 5; $i++) {
            try { [System.Windows.Forms.Clipboard]::SetText($text); return $true } catch { Start-Sleep -Milliseconds 120 }
        }
        return $false
    }

    # the redacted preview/summary files live in %TEMP% only while needed - remove them as soon as we are done
    function Clear-ShareTemp { try { Remove-Item -LiteralPath (Join-Path $env:TEMP 'RAM-Doctor-share-preview') -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

    function Finish-Copy([string]$text) {
        Clear-ShareTemp
        if (Copy-Text $text) { Show-Toast 'Success' 'تم النسخ' 'الصقه في واتساب أو أي محادثة.' }
        else { Show-Toast 'Warning' 'تعذّر النسخ' 'جرّب مرة ثانية، أو أرسل ملف التقرير يدويًا.' }
    }

    function Share-Args([string]$action) {
        $a = @(('"{0}"' -f $ShareScript), '-Action', $action)
        if ($ShareProfileDir) { $a += @('-ProfileDir', ('"{0}"' -f $ShareProfileDir)) }
        if ($ShareEndpoint) { $a += @('-Endpoint', ('"{0}"' -f $ShareEndpoint)) }
        return $a
    }

    # ------------------------------------------------------------ dormant "share with my helper" feature
    # Everything below stays invisible unless RAM-Doctor-Share.ps1 -Action ShowProfile reports endpointConfigured=true.
    function Read-ShareProfile {
        $s = [pscustomobject]@{ Configured = $false; Name = ''; UserId = ''; Helper = ''; EndpointConfigured = $false }
        if ($ShareForceConfigured) { $s.EndpointConfigured = $true; $s.Helper = 'مساعدي'; return $s }
        if (-not (Test-Path -LiteralPath $ShareScript)) { return $s }
        try {
            $r = Invoke-Cli (Share-Args 'ShowProfile') 25
            $done = $false
            foreach ($line in ($r.Output -split "`r?`n")) {   # prefer the machine-readable JSON line
                if ($line -match '^PROFILE_JSON:\s*(\{.*\})\s*$') {
                    try {
                        $j = $Matches[1] | ConvertFrom-Json
                        $s.Configured = [bool]$j.configured; $s.Name = [string]$j.name; $s.UserId = [string]$j.userId; $s.Helper = [string]$j.helper; $s.EndpointConfigured = [bool]$j.endpointConfigured
                        $done = $true
                    } catch { }
                }
            }
            if (-not $done) {
                foreach ($line in ($r.Output -split "`r?`n")) {
                    if ($line -match 'PROFILE:\s*configured=(\w+)\s+name=(.*?)\s+userId=(\S*)\s+helper=(.*?)\s+endpointConfigured=(\w+)') {
                        $s.Configured = ($Matches[1] -eq 'true'); $s.Name = $Matches[2]; $s.UserId = $Matches[3]; $s.Helper = $Matches[4]; $s.EndpointConfigured = ($Matches[5] -eq 'true')
                    }
                }
            }
        } catch { }
        return $s
    }

    function Apply-ShareVisibility {
        $on = [bool]$script:share.EndpointConfigured
        $btnShare.Visible = $on; $rowShare.Visible = $on; $divShare.Visible = $on
        $lblSub.Text = $(if ($on) { 'اعرف سبب امتلاء الذاكرة (RAM) خلال دقيقة. الفحص آمن ولا يتصل بالإنترنت. المشاركة اختيارية وبضغطة زر.' } else { 'اعرف سبب امتلاء الذاكرة (RAM) خلال دقيقة. الفحص آمن ولا يتصل بالإنترنت.' })
        if ($on) {
            $d = $rowShare.Controls | Where-Object { $_ -is [System.Windows.Forms.TableLayoutPanel] } | Select-Object -First 1
            $desc = $d.Controls | Where-Object { $_.Name -eq 'desc' } | Select-Object -First 1
            if ($script:share.Configured) { $desc.Text = ([char]0x202A).ToString() + $script:share.Name + $(if ($script:share.UserId) { '   ·   ' + $script:share.UserId.Substring(0, [Math]::Min(6, $script:share.UserId.Length)) } else { '' }) + ([char]0x202C).ToString() }
            else { $desc.Text = 'غير مُعدّ بعد' }
        }
        Resize-Cards
        Refresh-Buttons
    }

    function New-Dialog([string]$title, [int]$w, [int]$h) {
        $d = New-Object System.Windows.Forms.Form
        $d.Text = $title; $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.ShowInTaskbar = $false
        $d.StartPosition = 'CenterParent'; $d.ClientSize = New-Object System.Drawing.Size($w, $h)
        $d.RightToLeft = 'Yes'; $d.RightToLeftLayout = $true; $d.BackColor = $cWin; $d.Font = Ui 10; $d.Icon = $form.Icon
        $d.Add_Shown({ [Fluent.Win]::StyleWindow($this.Handle, $dark, $cWin, $cText) })
        return $d
    }

    function Show-ProfileDialog {
        if ($Unattended -and $script:TestProfile) { return $script:TestProfile }
        $d = New-Dialog 'ملفي الشخصي للمشاركة' 540 350
        $t = New-Object System.Windows.Forms.TableLayoutPanel
        $t.Dock = 'Fill'; $t.ColumnCount = 1; $t.BackColor = $cWin; $t.Padding = Pad 28 24 28 18; Add-Col $t 'Percent' 100
        function Add-Dlg($c, [int]$h) { $c.Dock = 'Fill'; $c.Height = $h; $c.Margin = Pad 0 0 0 0; [void]$t.Controls.Add($c) }
        Add-Dlg (New-Lbl 'إعداد المشاركة (مرة واحدة)' (Semi 15) $cText $cWin 'MiddleLeft') 38
        Add-Dlg (New-Lbl 'اختر اسم مستخدم يبقى ثابتًا ويظهر لمساعدك.' (Ui 10) $cSub $cWin 'TopLeft') 30
        Add-Dlg (New-Lbl 'اسم المستخدم' (Semi 10) $cText $cWin 'BottomLeft') 26
        $fu = New-Object Fluent.FField; $fu.Cue = 'مثال: ahmed_92'; $fu.MaxLen = 24
        Add-Dlg $fu 44
        $tog = New-Btn 'رمز دعوة (اختياري)' 'Subtle' (Glyph 0xE70D) 190 34
        $tog.Dock = 'None'; $tog.Anchor = 'Top,Right'; $tog.Margin = Pad 0 6 0 0; $tog.Height = 34
        [void]$t.Controls.Add($tog)
        $lblCode = New-Lbl 'رمز الدعوة (اختياري)' (Semi 10) $cText $cWin 'BottomLeft'; Add-Dlg $lblCode 26
        $fc = New-Object Fluent.FField; $fc.Password = $true; Add-Dlg $fc 44
        $lblCode.Visible = $false; $fc.Visible = $false
        $lblErr = New-Lbl '' (Ui 9.5) ([Fluent.Theme]::Danger) $cWin 'MiddleLeft'
        if ($dark) { $lblErr.ForeColor = [System.Drawing.Color]::FromArgb(0xFF, 0x99, 0xA4) }
        Add-Dlg $lblErr 30
        $bt = New-Object System.Windows.Forms.FlowLayoutPanel; $bt.BackColor = $cWin; $bt.WrapContents = $false
        $ok = New-Btn 'حفظ' 'Accent' '' 130 38; $ok.Margin = Pad 10 0 0 0
        $cancel = New-Btn 'إلغاء' 'Standard' '' 110 38
        $bt.Controls.AddRange(@($ok, $cancel))
        Add-Dlg $bt 46
        $d.Controls.Add($t)
        $d.Tag = $null
        $tog.Add_Click({
                $show = -not $fc.Visible
                $fc.Visible = $show; $lblCode.Visible = $show
                $tog.Glyph = $(if ($show) { Glyph 0xE70E } else { Glyph 0xE70D })
                $d.ClientSize = New-Object System.Drawing.Size(540, $(if ($show) { 420 } else { 350 }))
            })
        $ok.Add_Click({
                $u = $fu.Value.Trim(); $c = $fc.Value.Trim()
                if ($u.Length -lt 2 -or $u.Length -gt 24) { $lblErr.Text = 'اسم المستخدم يجب أن يكون بين 2 و24 حرفًا.'; return }
                if ($u -notmatch '^[\p{L}\p{N}_\-\.]+$') { $lblErr.Text = 'استخدم حروفًا وأرقامًا و _ - . فقط (بدون مسافات).'; return }
                if ($c.Length -gt 0 -and $c.Length -lt 4) { $lblErr.Text = 'رمز الدعوة قصير جدًا. اتركه فارغًا إن لم يكن لديك رمز.'; return }
                $d.Tag = @{ Username = $u; Code = $c }
                $d.DialogResult = 'OK'
            })
        $cancel.Add_Click({ $d.DialogResult = 'Cancel' })
        $d.AcceptButton = $null
        $res = $d.ShowDialog($form)
        $val = $d.Tag
        $d.Dispose()
        if ($res -eq 'OK') { return $val } else { return $null }
    }

    function Show-ShareDialog($previewInfo) {
        if ($Unattended) { return @{ Include = $false } }
        $helper = $script:share.Helper; if (-not $helper) { $helper = 'مساعدك' }
        $d = New-Dialog ('مشاركة النتيجة مع ' + $helper) 560 520
        $t = New-Tlp 1 8 $cWin; $t.Padding = Pad 28 22 28 20
        Add-Col $t 'Percent' 100; Add-Row $t 'Absolute' 36; Add-Row $t 'Absolute' 28; Add-Row $t 'Absolute' 150; Add-Row $t 'Absolute' 64; Add-Row $t 'Absolute' 36; Add-Row $t 'Absolute' 40; Add-Row $t 'Absolute' 10; Add-Row $t 'Percent' 100
        $t.Controls.Add((New-Lbl ('مشاركة النتيجة مع ' + $helper) (Semi 15) $cText $cWin 'MiddleLeft'), 0, 0)
        $t.Controls.Add((New-Lbl ('سيُرسل ما يلي فقط، إلى المستودع الخاص لـ ' + $helper + ':') (Ui 10) $cSub $cWin 'MiddleLeft'), 0, 1)
        $card = New-Object Fluent.FCard; $card.Dock = 'Fill'; $card.Padding = Pad 10 6 10 6; $card.Margin = Pad 0 4 0 8
        $ct = New-Tlp 1 3 $cCard; Add-Col $ct 'Percent' 100
        $names = @(@('ملخص النتيجة', 'summary.md'), @('التقرير الكامل', 'report.html'), @('خطة الفحص', 'plan.json'))
        foreach ($n in $names) {
            Add-Row $ct 'Percent' 33.3
            $r = New-Tlp 3 1 $cCard; Add-Col $r 'Absolute' 36; Add-Col $r 'Percent' 100; Add-Col $r 'Absolute' 90
            $ic = New-Object Fluent.FBadge; $ic.Filled = $false; $ic.Glyph = (Glyph 0xE8A5); $ic.GlyphPx = 18; $ic.Size = New-Object System.Drawing.Size(28, 28); $ic.Anchor = 'None'; $ic.GlyphColor = $cSub
            $nm = New-Lbl ($n[0] + '  (' + $n[1] + ')') (Ui 10) $cText $cCard 'MiddleLeft'
            $kb = ''; if ($previewInfo -and $previewInfo.Sizes.ContainsKey($n[1])) { $kb = ([char]0x202A).ToString() + [string]$previewInfo.Sizes[$n[1]] + ' KB' + ([char]0x202C).ToString() }   # LRE..PDF keeps "3 KB" in reading order
            $sz = New-Lbl $kb (Ui 10) $cSub $cCard 'MiddleRight'
            $r.Controls.Add($ic, 0, 0); $r.Controls.Add($nm, 1, 0); $r.Controls.Add($sz, 2, 0)
            [void]$ct.Controls.Add($r)
        }
        $card.Controls.Add($ct)
        $t.Controls.Add($card, 0, 2)
        $t.Controls.Add((New-Lbl 'تُحذف تلقائيًا من الملفات: اسم مستخدم ويندوز، اسم الجهاز، البريد الإلكتروني، وأي مفاتيح أو أسرار. لا يُرسل شيء غير ما فوق.' (Ui 9.5) $cSub $cWin 'TopLeft'), 0, 3)
        $chk = New-Object Fluent.FCheck; $chk.Text = 'تضمين اسم جهازي'; $chk.Dock = 'Fill'; $chk.Margin = Pad 0 4 0 4
        $t.Controls.Add($chk, 0, 4)
        $prev = New-Btn 'معاينة الملفات' 'Subtle' (Glyph 0xE838) 170 36; $prev.Margin = Pad 0 2 0 2
        $t.Controls.Add($prev, 0, 5)
        $bt = New-Object System.Windows.Forms.FlowLayoutPanel; $bt.Dock = 'Fill'; $bt.BackColor = $cWin; $bt.WrapContents = $false
        $send = New-Btn 'إرسال' 'Accent' (Glyph 0xE72D) 140 40; $send.Margin = Pad 10 0 0 0
        $cancel = New-Btn 'إلغاء' 'Standard' '' 110 40
        $bt.Controls.AddRange(@($send, $cancel))
        $t.Controls.Add($bt, 0, 7)
        $d.Controls.Add($t)
        $prev.Add_Click({ if ($previewInfo -and $previewInfo.Dir -and (Test-Path -LiteralPath $previewInfo.Dir)) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $previewInfo.Dir) } })
        $send.Add_Click({ $d.DialogResult = 'OK' })
        $cancel.Add_Click({ $d.DialogResult = 'Cancel' })
        $res = $d.ShowDialog($form)
        $inc = $chk.Checked
        $d.Dispose()
        if ($res -eq 'OK') { return @{ Include = $inc } } else { return $null }
    }

    function Get-PreviewInfo([bool]$includeHost) {
        $a = (Share-Args 'Preview') + @('-PlanPath', ('"{0}"' -f $script:current.Plan))
        if ($includeHost) { $a += '-IncludeHostName' }
        $r = Invoke-Cli $a 40
        $info = @{ Dir = ''; Sizes = @{} }
        foreach ($line in ($r.Output -split "`r?`n")) {
            if ($line -match 'PREVIEW:\s*(.+)$') { $info.Dir = $Matches[1].Trim() }
            elseif ($line -match 'FILES:\s*(.+)$') {
                foreach ($m in [regex]::Matches($Matches[1], '([\w\.\-]+)=([\d\.,]+)')) { $info.Sizes[$m.Groups[1].Value] = $m.Groups[2].Value }
            }
        }
        return $info
    }

    # ------------------------------------------------------------ button actions
    $btnScan.Add_Click({ Guard {
            $script:scanStart = Get-Date
            New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null
            $txtLog.Clear(); $script:cap = 5
            $toast.Visible = $false
            Set-Status 'بدأ الفحص ...' 2
            Start-Task 'scan' @(('"{0}"' -f $ScanScript), '-NoOpen', '-OutDir', ('"{0}"' -f $ReportsDir), '-SampleSeconds', '30') { Scan-Done }
        } })

    $list.Add_ItemChecked({ Guard { Refresh-Buttons } })

    $btnQ.Add_Click({ Guard {
            $ids = @($list.GetChecked() | ForEach-Object { [int]$_.Tag })
            if ($ids.Count -eq 0) { return }
            $names = (@($list.GetChecked() | ForEach-Object { '•  ' + $_.Name }) -join "`n")
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
                    if ($bad -gt 0) { $msg += "`n`nملاحظة: $bad خطوة لم تكتمل (مثل ملف مقفول). التفاصيل في «التفاصيل التقنية»." }
                    $list.Clear()
                    $info.Level = 'Success'; $info.Title = 'تم العزل'; $info.Message = 'أعد تشغيل الجهاز ثم افحص من جديد. للتراجع افتح «المزيد» واختر «تراجع عن آخر عزل».'
                    [void]$info.FitHeight()
                    Info-Box $msg
                } else {
                    Set-Status 'لم يكتمل العزل.' 0
                    Info-Box 'لم يكتمل العزل. التفاصيل في «التفاصيل التقنية».' 'Warning'
                }
                Refresh-Buttons
            }
        } })

    $btnReport.Add_Click({ Guard { if ($script:current -and (Test-Path -LiteralPath $script:current.Html)) { Start-Process -FilePath $script:current.Html } } })
    $btnFolder.Add_Click({ Guard { if ($script:current -and (Test-Path -LiteralPath $script:current.Html)) { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $script:current.Html) } } })

    $btnCopy.Add_Click({ Guard {
            if (-not $script:current) { return }
            if (Test-Path -LiteralPath $ShareScript) {
                Start-Task 'summary' ((Share-Args 'Summary') + @('-PlanPath', ('"{0}"' -f $script:current.Plan))) {
                    $text = ''
                    foreach ($line in ($script:lastOutput -split "`r?`n")) {
                        if ($line -match 'SUMMARY:\s*(.+)$') { $p = $Matches[1].Trim(); if (Test-Path -LiteralPath $p) { $text = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) } }
                    }
                    if (-not $text) { Add-Log '[summary] helper script gave no file - using the built-in summary'; $text = Build-LocalSummary $script:currentPlan }
                    Finish-Copy $text
                }
            } else {
                Finish-Copy (Build-LocalSummary $script:currentPlan)
            }
        } })

    $btnShare.Add_Click({ Guard {
            if (-not $script:current) { return }
            if (-not $script:share.Configured) {
                $prof = Show-ProfileDialog
                if (-not $prof) { return }
                # name + optional invite code travel in process-scope environment variables, never on a command line or in the log
                $r = Invoke-Cli (Share-Args 'SaveProfile') 40 @{ RAMDOC_SHARE_NAME = $prof.Username; RAMDOC_SHARE_CODE = $prof.Code }
                if ($r.Output -notmatch 'RESULT:\s*OK') {
                    $m = if ($r.Output -match 'RESULT:\s*ERROR\s*(.+)') { $Matches[1].Trim() } else { 'تعذّر حفظ الملف الشخصي.' }
                    Show-Toast 'Error' 'لم يُحفظ الملف الشخصي' $m; return
                }
                $script:share = Read-ShareProfile; Apply-ShareVisibility
            }
            $pv = Get-PreviewInfo $false
            $choice = Show-ShareDialog $pv
            if (-not $choice) { Clear-ShareTemp; return }
            $a = (Share-Args 'Share') + @('-PlanPath', ('"{0}"' -f $script:current.Plan))
            if ($choice.Include) { $a += '-IncludeHostName' }
            if ($ShareDryRun) { $a += '-DryRun' }
            Set-Status 'جارٍ الإرسال ...' 60
            Start-Task 'share' $a {
                Clear-ShareTemp
                $helper = $script:share.Helper; if (-not $helper) { $helper = 'مساعدك' }
                if ($script:lastOutput -match 'RESULT:\s*OK') {
                    Set-Status 'تم الإرسال.' 100
                    Show-Toast 'Success' 'تم الإرسال ✓' ('يقدر ' + $helper + ' يشوف التقرير الآن.')
                } else {
                    $m = if ($script:lastOutput -match 'RESULT:\s*ERROR\s*\S*\s*(.*)') { $Matches[1].Trim() } else { 'حدث خطأ أثناء الإرسال.' }
                    Set-Status 'لم يكتمل الإرسال.' 0
                    Show-Toast 'Error' 'لم يكتمل الإرسال' $m
                }
            }
        } })

    $btnShareDel.Add_Click({ Guard {
            if (-not (Confirm-Box "سيتم حذف ملفك الشخصي للمشاركة (الاسم ورمز الدعوة) من هذا الجهاز.`nالاسم الذي اخترته ثابت، وإن أعدت الإعداد قد تحتاج رمز دعوة جديدًا.`n`nمتأكد؟" 'حذف الملف الشخصي' 'Warning')) { return }
            $r = Invoke-Cli (Share-Args 'DeleteProfile') 30
            $script:share = Read-ShareProfile; Apply-ShareVisibility
            Show-Toast 'Info' 'تم حذف ملفك الشخصي' 'يمكنك إعداده من جديد عند المشاركة التالية.'
        } })

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
                else { Set-Status 'لم يكتمل التراجع.' 0; Info-Box 'لم يكتمل التراجع. التفاصيل في «التفاصيل التقنية».' 'Warning' }
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
            $script:current = $null; $script:currentPlan = $null; $list.Clear(); $toast.Visible = $false
            $info.Level = 'Info'; $info.Title = 'جاهز للفحص'; $info.Message = 'بعد الفحص تظهر هنا النتيجة، وأي ملفات مشبوهة يمكنك عزلها بضغطة واحدة.'
            [void]$info.FitHeight()
            Set-Status 'تم مسح التقارير.' 0
            Refresh-Buttons
        } })

    $form.Add_FormClosing({
            param($s, $e)
            if ($script:proc -and -not $script:proc.HasExited) {
                if ($script:taskKind -in 'scan', 'summary') { try { $script:proc.Kill() } catch { } }
                else { $e.Cancel = $true; Info-Box 'العملية جارية الآن، انتظر حتى تنتهي ثم أغلق النافذة.' 'Warning' }
            }
        })

    # ------------------------------------------------------------ developer helpers (screenshots / tests)
    function Save-Shot([string]$path) {   # the whole scrollable page as it renders (no window frame)
        $col.PerformLayout()
        $bmp = New-Object System.Drawing.Bitmap($col.Width, $col.Height)
        $col.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $col.Width, $col.Height)))
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    }
    function Save-WindowShot([string]$path, $frm = $null) {   # the real window incl. Windows 11 title bar, corners made transparent
        if (-not $frm) { $frm = $form }
        $prevTop = $frm.TopMost
        $frm.TopMost = $true; $frm.Activate(); $frm.BringToFront()   # nothing else may cover the window while we copy the screen
        [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 600; [System.Windows.Forms.Application]::DoEvents()
        $r = [Fluent.Win]::FrameBounds($frm.Handle)
        if ($r.IsEmpty) { $r = $frm.Bounds }
        $wa = [System.Windows.Forms.Screen]::FromHandle($frm.Handle).WorkingArea
        if ($r.Bottom -gt $wa.Bottom -or $r.Right -gt $wa.Right -or $r.Left -lt $wa.Left -or $r.Top -lt $wa.Top) {
            $frm.TopMost = $prevTop
            throw 'Refusing to capture: the window is not fully inside the work area (the picture would include the taskbar).'
        }
        $src = New-Object System.Drawing.Bitmap($r.Width, $r.Height)
        $g = [System.Drawing.Graphics]::FromImage($src); $g.CopyFromScreen($r.Location, [System.Drawing.Point]::Empty, $r.Size); $g.Dispose()
        $out = New-Object System.Drawing.Bitmap($r.Width, $r.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g2 = [System.Drawing.Graphics]::FromImage($out); $g2.SmoothingMode = 'AntiAlias'
        $gp = [Fluent.Theme]::RoundRect((New-Object System.Drawing.RectangleF(0, 0, $r.Width, $r.Height)), 9)
        $g2.SetClip($gp); $g2.DrawImage($src, 0, 0); $g2.Dispose()
        $out.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $out.Dispose(); $src.Dispose(); $gp.Dispose()
        $frm.TopMost = $prevTop
    }

    # ------------------------------------------------------------ start-up
    $form.Add_Shown({
            Guard {
                [Fluent.Win]::StyleWindow($form.Handle, $dark, $cWin, $cText)
                [Fluent.Win]::SetScrollTheme($page.Handle, $dark)
                $script:share = Read-ShareProfile
                Apply-ShareVisibility
                $r = Get-LatestResult
                if ($r) { Load-Results $r $true; Set-Status 'هذه نتيجة آخر فحص. اضغط «ابدأ الفحص» لفحص جديد.' 0 }
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
