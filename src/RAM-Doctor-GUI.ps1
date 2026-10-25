#requires -Version 5.1
<#
.SYNOPSIS
  RAM Doctor - one Windows 11 (Fluent) styled window, in Arabic (right-to-left) or English (left-to-right).
  It only launches the scan / actions scripts and shows their results; it holds no scanning logic of its own.

  Language: -Lang ar|en, otherwise the Windows UI language (Arabic -> ar, everything else -> en). A button in the
  header switches the open window live (text, layout direction and the language of the next scan). Nothing is saved.
  Every text lives in lib\Strings.ps1.

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
    [switch]$ShareForceConfigured,
    [ValidateSet('ar', 'en')][string]$Lang
)

$ErrorActionPreference = 'Continue'
$AppDir = $PSScriptRoot
. (Join-Path $AppDir 'lib\Strings.ps1')   # every user-facing text (ar / en)
. (Join-Path $AppDir 'lib\Store.ps1')     # damage-tolerant reading of the plan, safe removal of temp folders
Set-UiLang $Lang
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

    # ------------------------------------------------------------ language
    # A control whose text is one fixed string-table key is registered here: Apply-Language sets (and later re-sets) it.
    # Texts that depend on state (status line, verdict, button while scanning ...) are rebuilt by Apply-Language itself.
    $script:i18n = New-Object System.Collections.ArrayList
    $script:langTip = New-Object System.Windows.Forms.ToolTip
    function Bind-Text($ctl, [string]$key, [string]$prop = 'Text') { [void]$script:i18n.Add(@{ Ctl = $ctl; Key = $key; Prop = $prop }); $ctl.$prop = (Get-Text $key) }
    function Test-Rtl { return ((Get-UiLang) -eq 'ar') }
    function Get-RtlValue { if (Test-Rtl) { 'Yes' } else { 'No' } }

    # ------------------------------------------------------------ window
    $form = New-Object System.Windows.Forms.Form
    $form.Text = Get-Text 'gui.window.title'
    $form.ClientSize = New-Object System.Drawing.Size(940, 740)
    $form.MinimumSize = New-Object System.Drawing.Size(880, 640)
    $form.StartPosition = 'CenterScreen'
    $form.RightToLeft = Get-RtlValue; $form.RightToLeftLayout = (Test-Rtl)
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
    $hdr = New-Tlp 3 1 $cWin; $hdr.Height = 82
    Add-Col $hdr 'Absolute' 68; Add-Col $hdr 'Percent' 100; Add-Col $hdr 'Absolute' 132; Add-Row $hdr 'Percent' 100
    $badge = New-Object Fluent.FBadge
    $badge.Glyph = Glyph 0xE9D9; $badge.GlyphPx = 26; $badge.Size = New-Object System.Drawing.Size(52, 52); $badge.Radius = 13; $badge.Anchor = 'None'
    $tt = New-Tlp 1 2 $cWin; Add-Col $tt 'Percent' 100; Add-Row $tt 'Percent' 58; Add-Row $tt 'Percent' 42
    $lblTitle = New-Lbl '' (Semi 22) $cText $cWin 'BottomLeft'; Bind-Text $lblTitle 'gui.title'
    $lblSub = New-Lbl '' (Ui 10.5) $cSub $cWin 'TopLeft'   # text: Apply-ShareVisibility (it mentions sharing only when sharing is on)
    $tt.Controls.Add($lblTitle, 0, 0); $tt.Controls.Add($lblSub, 0, 1)
    # language button: it is named after the language it switches TO ("English" in Arabic mode, the Arabic word for Arabic in English mode)
    $btnLang = New-Btn '' 'Subtle' (Glyph 0xE774) 120 34; $btnLang.Anchor = 'None'; $btnLang.Font = Semi 10; Bind-Text $btnLang 'gui.lang.other'
    $hdr.Controls.Add($badge, 0, 0); $hdr.Controls.Add($tt, 1, 0); $hdr.Controls.Add($btnLang, 2, 0)
    Add-Block $hdr 18 4

    # ---- admin banner (only when not elevated)
    $banner = New-Object Fluent.FInfoBar
    $banner.Level = 'Warning'
    $banner.Visible = (-not $CanAct)
    Add-Block $banner 4 10

    # ---- step 1: hero card
    $hero = New-Object Fluent.FCard
    $hero.Height = 156; $hero.Padding = Pad 22 18 22 14
    $ht = New-Tlp 1 4 $cCard
    Add-Col $ht 'Percent' 100; Add-Row $ht 'Absolute' 60; Add-Row $ht 'Absolute' 16; Add-Row $ht 'Absolute' 10; Add-Row $ht 'Percent' 100
    $top = New-Tlp 2 1 $cCard; Add-Col $top 'Percent' 100; Add-Col $top 'Absolute' 210; Add-Row $top 'Percent' 100
    $topText = New-Tlp 1 2 $cCard; Add-Col $topText 'Percent' 100; Add-Row $topText 'Absolute' 30; Add-Row $topText 'Percent' 100
    $lblHeroT = New-Lbl '' (Semi 14) $cText $cCard 'MiddleLeft'; Bind-Text $lblHeroT 'gui.hero.t'
    $lblHeroD = New-Lbl '' (Ui 10) $cSub $cCard 'TopLeft'; Bind-Text $lblHeroD 'gui.hero.d'
    $topText.Controls.Add($lblHeroT, 0, 0); $topText.Controls.Add($lblHeroD, 0, 1)
    $btnScan = New-Btn '' 'Accent' (Glyph 0xE721) 190 42; $btnScan.Anchor = 'None'; $btnScan.Font = Semi 11   # text: Refresh-Buttons
    $top.Controls.Add($topText, 0, 0); $top.Controls.Add($btnScan, 1, 0)
    $bar = New-Object Fluent.FProgress; $bar.Dock = 'Fill'; $bar.Margin = Pad 0 2 0 2
    $lblStatus = New-Lbl '' (Ui 10) $cSub $cCard 'TopLeft'   # text: Set-Status
    $lblStatus.Margin = Pad 0 4 0 0
    $ht.Controls.Add($top, 0, 0); $ht.Controls.Add($bar, 0, 2); $ht.Controls.Add($lblStatus, 0, 3)
    $hero.Controls.Add($ht)
    Add-Block $hero 4 12

    # ---- step 2: verdict + toast + actions
    $info = New-Object Fluent.FInfoBar   # text: Show-Info / Load-Results
    $info.Level = 'Info'
    Add-Block $info 0 12

    $toast = New-Object Fluent.FInfoBar
    $toast.Level = 'Success'; $toast.Visible = $false
    Add-Block $toast 0 12

    $acts = New-Object System.Windows.Forms.FlowLayoutPanel
    $acts.Height = 44; $acts.WrapContents = $false; $acts.BackColor = $cWin; $acts.Visible = $false
    $btnReport = New-Btn '' 'Standard' (Glyph 0xE8A5) 200 40; $btnReport.Margin = Pad 12 0 0 0; Bind-Text $btnReport 'gui.btn.report'
    $btnFolder = New-Btn '' 'Standard' (Glyph 0xE838) 190 40; $btnFolder.Margin = Pad 12 0 0 0; Bind-Text $btnFolder 'gui.btn.folder'
    $btnCopy = New-Btn '' 'Standard' (Glyph 0xE8C8) 200 40; $btnCopy.Margin = Pad 12 0 0 0; Bind-Text $btnCopy 'gui.btn.copy'
    $btnShare = New-Btn '' 'Accent' (Glyph 0xE72D) 200 40; $btnShare.Margin = Pad 12 0 0 0; $btnShare.Visible = $false; Bind-Text $btnShare 'gui.btn.share'
    $acts.Controls.AddRange(@($btnReport, $btnFolder, $btnCopy, $btnShare))
    Add-Block $acts 0 12

    # ---- findings card
    $find = New-Object Fluent.FCard
    $find.Height = 316; $find.Padding = Pad 20 14 20 16; $find.Visible = $false
    $ft = New-Tlp 1 5 $cCard
    Add-Col $ft 'Percent' 100; Add-Row $ft 'Absolute' 34; Add-Row $ft 'Absolute' 196; Add-Row $ft 'Absolute' 12; Add-Row $ft 'Absolute' 44; Add-Row $ft 'Percent' 100
    $fh = New-Tlp 2 1 $cCard; Add-Col $fh 'Percent' 100; Add-Col $fh 'Absolute' 150; Add-Row $fh 'Percent' 100
    $lblFindT = New-Lbl '' (Semi 12.5) $cText $cCard 'MiddleLeft'; Bind-Text $lblFindT 'gui.find.t'
    $lblPick = New-Lbl '' (Ui 10) $cSub $cCard 'MiddleRight'   # text: Refresh-Buttons
    $fh.Controls.Add($lblFindT, 0, 0); $fh.Controls.Add($lblPick, 1, 0)
    $list = New-Object Fluent.FList
    $list.Dock = 'Fill'; $list.RowHeight = 64; $list.Margin = Pad 0 0 0 0; Bind-Text $list 'gui.find.empty' 'EmptyText'
    $fb = New-Tlp 2 1 $cCard; Add-Col $fb 'Absolute' 230; Add-Col $fb 'Percent' 100; Add-Row $fb 'Percent' 100
    $btnQ = New-Btn '' 'Accent' (Glyph 0xEA18) 214 40; $btnQ.Anchor = 'None'; Bind-Text $btnQ 'gui.btn.q'
    $lblQHint = New-Lbl '' (Ui 9.5) $cSub $cCard 'MiddleLeft'; Bind-Text $lblQHint 'gui.find.hint'
    $lblQHint.Margin = Pad 8 0 0 0
    $fb.Controls.Add($btnQ, 0, 0); $fb.Controls.Add($lblQHint, 1, 0)
    $ft.Controls.Add($fh, 0, 0); $ft.Controls.Add($list, 0, 1); $ft.Controls.Add($fb, 0, 3)
    $find.Controls.Add($ft)
    Add-Block $find 0 12

    # ---- "more" card (restore / purge / clean / share account) - collapsible
    $more = New-Object Fluent.FCard
    $more.Padding = Pad 8 8 8 8
    $mt = New-Tlp 1 2 $cCard; Add-Col $mt 'Percent' 100; Add-Row $mt 'Absolute' 48; Add-Row $mt 'AutoSize' 0
    $exMore = New-Object Fluent.FExpander; $exMore.Glyph = Glyph 0xE713; $exMore.Dock = 'Fill'; $exMore.Margin = Pad 0 0 0 0; Bind-Text $exMore 'gui.more.t'
    $moreBody = New-Object System.Windows.Forms.TableLayoutPanel
    $moreBody.Dock = 'Fill'; $moreBody.ColumnCount = 1; $moreBody.AutoSize = $true; $moreBody.AutoSizeMode = 'GrowAndShrink'; $moreBody.BackColor = $cCard; $moreBody.Visible = $false
    Add-Col $moreBody 'Percent' 100
    $mt.Controls.Add($exMore, 0, 0); $mt.Controls.Add($moreBody, 0, 1)
    $more.Controls.Add($mt)
    Add-Block $more 0 12

    function New-SettingRow([string]$glyph, [string]$titleKey, [string]$descKey, $button) {
        $r = New-Tlp 3 1 $cCard; $r.Height = 66; $r.Margin = Pad 0 0 0 0
        Add-Col $r 'Absolute' 52; Add-Col $r 'Percent' 100; Add-Col $r 'Absolute' 176; Add-Row $r 'Percent' 100
        $ic = New-Object Fluent.FBadge; $ic.Filled = $false; $ic.Glyph = $glyph; $ic.GlyphPx = 20; $ic.Size = New-Object System.Drawing.Size(36, 36); $ic.Anchor = 'None'
        $ic.GlyphColor = [Fluent.Theme]::SubText
        $tx = New-Tlp 1 2 $cCard; Add-Col $tx 'Percent' 100; Add-Row $tx 'Percent' 50; Add-Row $tx 'Percent' 50
        $lt = New-Lbl '' (Semi 10.5) $cText $cCard 'BottomLeft'; Bind-Text $lt $titleKey
        $ld = New-Lbl '' (Ui 9.5) $cSub $cCard 'TopLeft'
        if ($descKey) { Bind-Text $ld $descKey }   # the sharing row sets its own description (Apply-ShareVisibility)
        $ld.Name = 'desc'
        $tx.Controls.Add($lt, 0, 0); $tx.Controls.Add($ld, 0, 1)
        $button.Anchor = 'None'; $button.Size = New-Object System.Drawing.Size(160, 34)
        $r.Controls.Add($ic, 0, 0); $r.Controls.Add($tx, 1, 0); $r.Controls.Add($button, 2, 0)
        return $r
    }
    function New-Divider { $d = New-Object System.Windows.Forms.Panel; $d.Height = 1; $d.Dock = 'Fill'; $d.BackColor = $cDiv; $d.Margin = Pad 14 0 14 0; return $d }

    $btnRestore = New-Btn '' 'Standard' (Glyph 0xE7A7) 160 34; Bind-Text $btnRestore 'gui.btn.restore'
    $btnPurge = New-Btn '' 'Danger' (Glyph 0xE74D) 160 34; Bind-Text $btnPurge 'gui.btn.purge'
    $btnClean = New-Btn '' 'Standard' (Glyph 0xE74D) 160 34; Bind-Text $btnClean 'gui.btn.clean'
    $btnShareDel = New-Btn '' 'Danger' '' 160 34; Bind-Text $btnShareDel 'gui.btn.sharedel'
    $rowRestore = New-SettingRow (Glyph 0xE777) 'gui.row.restore.t' 'gui.row.restore.d' $btnRestore
    $rowPurge = New-SettingRow (Glyph 0xE74D) 'gui.row.purge.t' 'gui.row.purge.d' $btnPurge
    $rowClean = New-SettingRow (Glyph 0xE8B7) 'gui.row.clean.t' 'gui.row.clean.d' $btnClean
    $rowShare = New-SettingRow (Glyph 0xE72E) 'gui.row.share.t' '' $btnShareDel
    $divShare = New-Divider
    $divShare.Visible = $false; $rowShare.Visible = $false
    foreach ($c in @($rowRestore, (New-Divider), $rowPurge, (New-Divider), $rowClean, $divShare, $rowShare)) { $c.Dock = 'Fill'; [void]$moreBody.Controls.Add($c) }

    # ---- technical details card (log) - collapsible
    $details = New-Object Fluent.FCard
    $details.Padding = Pad 8 8 8 8
    $dt = New-Tlp 1 2 $cCard; Add-Col $dt 'Percent' 100; Add-Row $dt 'Absolute' 48; Add-Row $dt 'Percent' 100
    $exLog = New-Object Fluent.FExpander; $exLog.Glyph = Glyph 0xE9D9; $exLog.Dock = 'Fill'; $exLog.Margin = Pad 0 0 0 0; Bind-Text $exLog 'gui.details.t'
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
    # The status line and the verdict bar show a string-table key, so they can be re-written when the language changes.
    $script:statusKey = ''; $script:statusArgs = @()
    function Set-Status([string]$key, [int]$pct = -1, [object[]]$fmt = @()) {
        $script:statusKey = $key; $script:statusArgs = $fmt
        $lblStatus.Text = $(if ($key) { Get-Text $key @fmt } else { '' })
        if ($pct -ge 0) { $bar.Value = $pct }
    }
    # what the verdict bar shows: 'keys' = a fixed pair of string-table keys, 'results' = built from the loaded plan (Load-Results)
    $script:infoMode = 'keys'; $script:infoLevel = 'Info'; $script:infoTitleKey = 'gui.info.ready.t'; $script:infoMsgKey = 'gui.info.ready.m'
    function Show-Info([string]$level, [string]$titleKey, [string]$msgKey) {
        $script:infoMode = 'keys'; $script:infoLevel = $level; $script:infoTitleKey = $titleKey; $script:infoMsgKey = $msgKey
        $info.Level = $level; $info.Title = Get-Text $titleKey; $info.Message = Get-Text $msgKey; [void]$info.FitHeight()
    }
    function Get-MsgBoxOptions { if (Test-Rtl) { [System.Windows.Forms.MessageBoxOptions]'RtlReading, RightAlign' } else { [System.Windows.Forms.MessageBoxOptions]0 } }
    function Info-Box([string]$text, [string]$icon = 'Information') {
        if ($Unattended) { Add-Log "[dialog] $text"; return }
        [void][System.Windows.Forms.MessageBox]::Show($form, $text, (Get-Text 'gui.msgbox.title'), 'OK', $icon, 'Button1', (Get-MsgBoxOptions))
    }
    function Confirm-Box([string]$text, [string]$title, [string]$icon = 'Question') {
        if ($Unattended) { Add-Log "[confirm:auto-yes] $title"; return $true }
        return ([System.Windows.Forms.MessageBox]::Show($form, $text, $title, 'YesNo', $icon, 'Button2', (Get-MsgBoxOptions)) -eq 'Yes')
    }
    function Guard([scriptblock]$b) {
        try { & $b } catch {
            Add-Log ('ERROR: ' + $_.Exception.Message)
            Info-Box ((Get-Text 'gui.err.unexpected') + "`n" + $_.Exception.Message) 'Warning'
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
    # The quarantine batches as the actions script sees them (RAM-Doctor-Actions.ps1 -Mode List, one BATCH_JSON line each,
    # newest first). The window never parses manifests itself: a damaged one cannot break it. Refreshed after every action.
    $script:batches = @()
    function Update-Batches {
        $script:batches = @()
        if (-not $CanAct -or -not (Test-Path -LiteralPath (Join-Path $StoreRoot 'Quarantine'))) { return }
        $a = @(('"{0}"' -f $ActionsScript), '-Mode', 'List')
        if ($QuarantineDir) { $a += @('-StoreDir', ('"{0}"' -f $QuarantineDir)) }
        if ($AllowNonAdmin) { $a += '-AllowNonAdmin' }
        $r = Invoke-Cli $a 60
        $found = New-Object System.Collections.ArrayList
        foreach ($line in ($r.Output -split "`r?`n")) {
            if ($line -match '^BATCH_JSON:\s*(\{.*\})\s*$') { try { [void]$found.Add(($Matches[1] | ConvertFrom-Json)) } catch { } }
        }
        $script:batches = @($found)
    }
    function Get-QuarantinedStats {
        $n = 0; $bytes = 0.0
        foreach ($b in @($script:batches | Where-Object { $_.state -ne 'purged' })) { $n += [int]$b.files; $bytes += [double]$b.bytes }
        [pscustomobject]@{ Count = $n; MB = [math]::Round($bytes / 1MB, 1) }
    }
    # last machine-readable line of an actions run: OK [...] | PARTIAL <n> | FAILED <reason> | BUSY | NONE
    function Get-ActionResult([string]$out) {
        $res = ''
        foreach ($line in ($out -split "`r?`n")) { if ($line -match '^RESULT:\s*(.+?)\s*$') { $res = $Matches[1] } }
        return $res
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

    # the scan prints English progress lines; the first marker found in a line picks the status text (string-table key) and the bar position
    $StatusMap = @(
        @('Snapshot #1', 'gui.step.1', 5),
        @('Collecting system facts', 'gui.step.2', 10),
        @('Inventory: processes', 'gui.step.3', 16),
        @('Inventory: services', 'gui.step.4', 26),
        @('Inventory: scheduled tasks', 'gui.step.5', 36),
        @('Inventory: startup', 'gui.step.6', 42),
        @('Inventory: WMI', 'gui.step.7', 46),
        @('Inventory: running kernel drivers', 'gui.step.8', 50),
        @('Hidden-process', 'gui.step.9', 56),
        @('Rating signatures', 'gui.step.10', 62),
        @('Waiting', 'gui.step.11', 82),
        @('Snapshot #2', 'gui.step.12', 87),
        @('Correlating', 'gui.step.13', 91),
        @('Mapping top pool tags', 'gui.step.14', 95),
        @('Collecting Defender', 'gui.step.15', 97)
    )

    # Output files of the child processes (%TEMP%\ramdoctor-<guid>.out/.err). Only files this window created are ever
    # deleted. A file that the child or an antivirus scan still holds is retried a few times, then remembered and swept
    # again by a timer, at the next task and when the window closes.
    $script:tempLeft = New-Object System.Collections.ArrayList
    $script:tempSweep = New-Object System.Windows.Forms.Timer
    $script:tempSweep.Interval = 1000
    function Sweep-TaskFiles {
        foreach ($f in @($script:tempLeft)) {
            try { if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } } catch { }
            if (-not [IO.File]::Exists($f)) { $script:tempLeft.Remove($f) }
        }
        if ($script:tempLeft.Count -eq 0) { $script:tempSweep.Stop() }
    }
    $script:tempSweep.Add_Tick({ Sweep-TaskFiles })
    function Remove-TaskFiles([string[]]$paths) {
        foreach ($f in $paths) {
            if (-not $f) { continue }
            $gone = $false
            for ($i = 0; $i -lt 6 -and -not $gone; $i++) {
                try { if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } } catch { }
                $gone = -not [IO.File]::Exists($f)
                if (-not $gone) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
            }
            if (-not $gone -and -not $script:tempLeft.Contains($f)) { [void]$script:tempLeft.Add($f); $script:tempSweep.Start() }
        }
    }
    # >0 while Invoke-Cli waits for a child (it keeps the window responsive with DoEvents): every button counts as busy then
    $script:cliBusy = 0

    function Refresh-Buttons {
        $procBusy = ($null -ne $script:proc -and -not $script:proc.HasExited)
        $busy = $procBusy -or ($script:cliBusy -gt 0)
        $btnScan.Enabled = (-not $busy)
        $btnScan.Text = $(if ($procBusy -and $script:taskKind -eq 'scan') { Get-Text 'gui.btn.scanning' } else { Get-Text 'gui.btn.scan' })
        $has = ($null -ne $script:current)
        $btnQ.Enabled = ((-not $busy) -and $CanAct -and ($list.CheckedCount -gt 0) -and $has)
        $lblPick.Text = $(if ($list.Items.Count -gt 0) { Get-Text 'gui.find.pick' $list.CheckedCount $list.Items.Count } else { '' })
        $btnLang.Enabled = (-not $busy)   # the language of a running scan / action cannot change halfway
        $btnReport.Enabled = ((-not $busy) -and $has)
        $btnFolder.Enabled = ((-not $busy) -and $has)
        $btnCopy.Enabled = ((-not $busy) -and $has)
        $btnShare.Enabled = ((-not $busy) -and $has)
        $acts.Visible = $has
        $find.Visible = ($list.Items.Count -gt 0)
        $canRestore = (@($script:batches | Where-Object { $_.state -eq 'restorable' }).Count -gt 0)
        $hasFiles = ((Get-QuarantinedStats).Count -gt 0)
        $btnRestore.Enabled = ((-not $busy) -and $CanAct -and $canRestore)
        $btnPurge.Enabled = ((-not $busy) -and $CanAct -and $hasFiles)
        $btnClean.Enabled = (-not $busy)
        $btnShareDel.Enabled = ((-not $busy) -and $script:share.Configured)
    }

    function Start-Task([string]$kind, [string[]]$psArgs, [scriptblock]$onDone) {
        if (($null -ne $script:proc -and -not $script:proc.HasExited) -or $script:cliBusy -gt 0) { Add-Log "[busy] '$kind' ignored: another task is running"; return }
        Sweep-TaskFiles
        $script:taskKind = $kind; $script:onDone = $onDone; $script:lineIdx = 0; $script:tick = 0; $script:lastExit = $null
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
        Sweep-TaskFiles
        $script:cliBusy++
        Refresh-Buttons   # the wait below pumps window messages: nothing else may be started meanwhile
        try {
            foreach ($k in $envVars.Keys) { if ($envVars[$k]) { [Environment]::SetEnvironmentVariable($k, [string]$envVars[$k], 'Process') } }
            try {
                $p = Start-Process -FilePath powershell.exe -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') + $psArgs) -WindowStyle Hidden -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
            } finally {
                foreach ($k in $envVars.Keys) { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
            }
            $null = $p.Handle
            $end = (Get-Date).AddSeconds($timeoutSec)
            while (-not $p.HasExited -and (Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }
            if (-not $p.HasExited) { try { $p.Kill(); [void]$p.WaitForExit(3000) } catch { } }
            $text = Read-Shared $o $true
            $res = [pscustomobject]@{ Output = $text; ExitCode = $(if ($p.HasExited) { $p.ExitCode } else { -1 }) }
        }
        finally {
            Remove-TaskFiles @($o, $e)
            $script:cliBusy--
            Refresh-Buttons
        }
        return $res
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
        $script:lastExit = $script:proc.ExitCode
        Remove-TaskFiles @($script:outFile, $script:errFile)   # leave nothing behind in %TEMP%
        $script:proc = $null
        $cb = $script:onDone; $script:onDone = $null
        Refresh-Buttons
        if ($cb) { Guard $cb }
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({ Guard { Poll-Task } })

    # ------------------------------------------------------------ results
    # One scan of THIS PC, found by its stamp (the scan prints "SCAN_STAMP: yyyyMMdd-HHmmss"; the window builds the file
    # names from its own PC name, so no path has to survive the console code page). Plans of other PCs are never picked:
    # the actions refuse them anyway.
    function Get-ScanResult([string]$stamp) {
        $plan = Join-Path $ReportsDir ('Plan-{0}-{1}.json' -f $env:COMPUTERNAME, $stamp)
        if (-not (Test-Path -LiteralPath $plan -PathType Leaf)) { return $null }
        [pscustomobject]@{ Plan = $plan; Html = (Join-Path $ReportsDir ('RAMDoctor-{0}-{1}.html' -f $env:COMPUTERNAME, $stamp)); Time = (Get-Item -LiteralPath $plan).LastWriteTime; Stamp = $stamp }
    }
    function Get-LatestResults {   # this PC's scans, newest first
        if (-not (Test-Path -LiteralPath $ReportsDir)) { return @() }
        $rx = '^Plan-' + [regex]::Escape($env:COMPUTERNAME) + '-(\d{8}-\d{6})\.json$'
        $stamps = @(Get-ChildItem -LiteralPath $ReportsDir -Filter 'Plan-*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $mt = [regex]::Match($_.Name, $rx); if ($mt.Success) { $mt.Groups[1].Value } } | Sort-Object -Descending)
        return @($stamps | ForEach-Object { Get-ScanResult $_ } | Where-Object { $_ })
    }
    function Get-LatestResult { return (@(Get-LatestResults) | Select-Object -First 1) }

    # Shows a plan. Returns $false (and changes nothing) when the plan cannot be read: a damaged file is set aside by
    # Read-JsonSafe and must never break the window.
    function Load-Results($r, [bool]$previous) {
        $rd = Read-JsonSafe -Path $r.Plan -MaxSchema 1 -Validate { param($x) $x.PSObject.Properties['verdict'] -and $x.PSObject.Properties['suspects'] }
        if ($rd.Status -ne 'Ok' -and $rd.Status -ne 'Recovered') { Add-Log ("[plan] {0}: {1} {2}" -f [IO.Path]::GetFileName($r.Plan), $rd.Status, $rd.Message); return $false }
        $plan = $rd.Data
        $script:current = $r
        $script:currentPlan = $plan
        $script:currentPrev = $previous
        $script:infoMode = 'results'
        $lvlMap = @{ high = 'Error'; med = 'Warning'; low = 'Info'; ok = 'Success' }
        $lv = $lvlMap[[string]$plan.verdict.Level]; if (-not $lv) { $lv = 'Info' }

        $list.Clear()
        $risk = @{ High = (Get-Text 'level.high'); Medium = (Get-Text 'level.med') }
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
        if ($list.Items.Count -gt 0) { $hint = Get-Text 'gui.hint.found' }
        elseif ($kernel.Count -gt 0) { $hint = Get-Text 'gui.hint.kernel' }
        elseif ($obs.Count -gt 0) { $hint = Get-Text 'gui.hint.obs' }
        else { $hint = Get-Text 'gui.hint.none' }
        if ($obs.Count -gt 0) { $hint += "`n" + (Get-Text 'gui.hint.top') + ((@($obs | Select-Object -First 3) | ForEach-Object { $_.Title }) -join '   •   ') }
        if ($lowCount -gt 0) {
            $lowText = switch ($lowCount) { 1 { Get-Text 'gui.low.1' } 2 { Get-Text 'gui.low.2' } default { Get-Text 'gui.low.n' $lowCount } }
            $hint += "`n($lowText)"
        }
        # the texts of a plan keep the language the scan wrote them in (a plan without "lang" comes from the Arabic-only releases)
        $planLang = $(if ($plan.PSObject.Properties['lang'] -and $plan.lang) { [string]$plan.lang } else { 'ar' })
        if ($planLang -ne (Get-UiLang)) { $hint += "`n" + (Get-Text 'gui.note.otherlang') }
        # the findings card grows with its content (1 to 3 rows), no empty space
        $rows = [math]::Min(3, [math]::Max(1, $list.Items.Count))
        $lh = $rows * $list.RowHeight + 4
        $ft.RowStyles[1].Height = $lh
        $find.Height = 14 + 34 + $lh + 12 + 44 + 20
        $pre = if ($previous) { Get-Text 'gui.prev' $r.Time.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) } else { '' }
        $info.Level = $lv
        $info.Title = $pre + [string]$plan.verdict.Headline
        $info.Message = $hint
        [void]$info.FitHeight()
        Refresh-Buttons
        return $true
    }

    function Scan-Done {
        $stamp = ''
        foreach ($line in ($script:lastOutput -split "`r?`n")) { if ($line -match '^SCAN_STAMP:\s*(\d{8}-\d{6})\s*$') { $stamp = $Matches[1] } }
        $r = $(if ($stamp) { Get-ScanResult $stamp } else { $null })
        if (-not $r) {
            Set-Status 'gui.status.noscan' 0
            Info-Box (Get-Text 'gui.box.noscan') 'Warning'
            return
        }
        if (-not (Load-Results $r $false)) {
            Set-Status 'gui.status.noscan' 0
            Info-Box (Get-Text 'store.plan.damaged.m') 'Warning'
            return
        }
        Set-Status 'gui.status.done' 100
    }

    function Count-Problems([string]$out) {
        @($out -split "`r?`n" | Where-Object { $_ -match 'could not|failed|still locked|changed since|refusing|will NOT be moved|ERROR' }).Count
    }

    # ------------------------------------------------------------ copy-summary (always available; nothing leaves the PC)
    function Build-LocalSummary($plan) {
        $L = New-Object System.Collections.Generic.List[string]
        $L.Add((Get-Text 'gui.sum.title'))
        $L.Add((Get-Text 'gui.sum.result') + [string]$plan.verdict.Headline)
        if ($plan.memory) {
            $L.Add((Get-Text 'gui.sum.mem' $plan.memory.UsedGB $plan.memory.TotalGB $plan.memory.NonPagedGB $plan.memory.PagedGB))
        }
        $o = @($plan.observations | Where-Object { $_.Level -in 'high', 'med' } | Select-Object -First 4)
        foreach ($x in $o) { $L.Add('• ' + [string]$x.Title) }
        $s = @($plan.suspects | Where-Object { $_.risk -in 'High', 'Medium' } | Select-Object -First 5)
        if ($s.Count -gt 0) { $L.Add((Get-Text 'gui.sum.sus') + (($s | ForEach-Object { "$($_.name) ($(if ($_.risk -eq 'High') { Get-Text 'level.high' } else { Get-Text 'level.med' }))" }) -join (Get-Text 'gui.sum.sep'))) }
        $L.Add((Get-Text 'gui.sum.nopaths'))
        return ($L -join "`r`n")
    }

    function Copy-Text([string]$text) {
        for ($i = 0; $i -lt 5; $i++) {
            try { [System.Windows.Forms.Clipboard]::SetText($text); return $true } catch { Start-Sleep -Milliseconds 120 }
        }
        return $false
    }

    # The redacted preview/summary files live in %TEMP% only while needed. The share script makes a fresh, randomly named
    # private folder each time (RAM-Doctor-share-<random>) and prints its path; only those folders are removed, without
    # ever following a link. The fixed folder of 1.0.x (RAM-Doctor-share-preview) is cleaned up the same safe way.
    $script:shareDirs = New-Object System.Collections.ArrayList
    function Add-ShareDir([string]$dir) {
        if ($dir -and ([IO.Path]::GetFileName($dir.TrimEnd('\')) -like 'RAM-Doctor-share-*') -and -not $script:shareDirs.Contains($dir)) { [void]$script:shareDirs.Add($dir) }
    }
    function Clear-ShareTemp {
        Add-ShareDir (Join-Path $env:TEMP 'RAM-Doctor-share-preview')
        foreach ($d in @($script:shareDirs)) { if (Remove-StorePrivateDir $d) { $script:shareDirs.Remove($d) } }
    }

    function Finish-Copy([string]$text) {
        Clear-ShareTemp
        if (Copy-Text $text) { Show-Toast 'Success' (Get-Text 'gui.toast.copied.t') (Get-Text 'gui.toast.copied.m') }
        else { Show-Toast 'Warning' (Get-Text 'gui.toast.copyfail.t') (Get-Text 'gui.toast.copyfail.m') }
    }

    function Share-Args([string]$action) {
        $a = @(('"{0}"' -f $ShareScript), '-Action', $action, '-Lang', (Get-UiLang))
        if ($ShareProfileDir) { $a += @('-ProfileDir', ('"{0}"' -f $ShareProfileDir)) }
        if ($ShareEndpoint) { $a += @('-Endpoint', ('"{0}"' -f $ShareEndpoint)) }
        return $a
    }

    # ------------------------------------------------------------ dormant "share with my helper" feature
    # Everything below stays invisible unless RAM-Doctor-Share.ps1 -Action ShowProfile reports endpointConfigured=true.
    function Read-ShareProfile {
        $s = [pscustomobject]@{ Configured = $false; Name = ''; UserId = ''; Helper = ''; EndpointConfigured = $false; Damaged = $false }
        if ($ShareForceConfigured) { $s.EndpointConfigured = $true; $s.Helper = (Get-Text 'gui.helper.demo'); return $s }
        if (-not (Test-Path -LiteralPath $ShareScript)) { return $s }
        try {
            $r = Invoke-Cli (Share-Args 'ShowProfile') 25
            $done = $false
            foreach ($line in ($r.Output -split "`r?`n")) {   # prefer the machine-readable JSON line
                if ($line -match '^PROFILE_JSON:\s*(\{.*\})\s*$') {
                    try {
                        $j = $Matches[1] | ConvertFrom-Json
                        $s.Configured = [bool]$j.configured; $s.Name = [string]$j.name; $s.UserId = [string]$j.userId; $s.Helper = [string]$j.helper; $s.EndpointConfigured = [bool]$j.endpointConfigured
                        $s.Damaged = [bool]($j.PSObject.Properties['damaged'] -and $j.damaged)   # the profile file could not be read: it was set aside
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
        $lblSub.Text = $(if ($on) { Get-Text 'gui.sub.share' } else { Get-Text 'gui.sub' })
        if ($on) {
            $d = $rowShare.Controls | Where-Object { $_ -is [System.Windows.Forms.TableLayoutPanel] } | Select-Object -First 1
            $desc = $d.Controls | Where-Object { $_.Name -eq 'desc' } | Select-Object -First 1
            if ($script:share.Configured) { $desc.Text = ([char]0x202A).ToString() + $script:share.Name + $(if ($script:share.UserId) { '   ·   ' + $script:share.UserId.Substring(0, [Math]::Min(6, $script:share.UserId.Length)) } else { '' }) + ([char]0x202C).ToString() }
            else { $desc.Text = Get-Text 'gui.share.notset' }
        }
        Resize-Cards
        Refresh-Buttons
    }

    function New-Dialog([string]$title, [int]$w, [int]$h) {
        $d = New-Object System.Windows.Forms.Form
        $d.Text = $title; $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.ShowInTaskbar = $false
        $d.StartPosition = 'CenterParent'; $d.ClientSize = New-Object System.Drawing.Size($w, $h)
        $d.RightToLeft = Get-RtlValue; $d.RightToLeftLayout = (Test-Rtl); $d.BackColor = $cWin; $d.Font = Ui 10; $d.Icon = $form.Icon
        $d.Add_Shown({ [Fluent.Win]::StyleWindow($this.Handle, $dark, $cWin, $cText) })
        return $d
    }

    function Show-ProfileDialog {
        if ($Unattended -and $script:TestProfile) { return $script:TestProfile }
        $d = New-Dialog (Get-Text 'gui.profile.title') 540 350
        $t = New-Object System.Windows.Forms.TableLayoutPanel
        $t.Dock = 'Fill'; $t.ColumnCount = 1; $t.BackColor = $cWin; $t.Padding = Pad 28 24 28 18; Add-Col $t 'Percent' 100
        function Add-Dlg($c, [int]$h) { $c.Dock = 'Fill'; $c.Height = $h; $c.Margin = Pad 0 0 0 0; [void]$t.Controls.Add($c) }
        Add-Dlg (New-Lbl (Get-Text 'gui.profile.h') (Semi 15) $cText $cWin 'MiddleLeft') 38
        Add-Dlg (New-Lbl (Get-Text 'gui.profile.p') (Ui 10) $cSub $cWin 'TopLeft') 30
        Add-Dlg (New-Lbl (Get-Text 'gui.profile.user') (Semi 10) $cText $cWin 'BottomLeft') 26
        $fu = New-Object Fluent.FField; $fu.Cue = (Get-Text 'gui.profile.cue'); $fu.MaxLen = 24
        Add-Dlg $fu 44
        $tog = New-Btn (Get-Text 'gui.profile.code.btn') 'Subtle' (Glyph 0xE70D) 190 34
        $tog.Dock = 'None'; $tog.Anchor = 'Top,Right'; $tog.Margin = Pad 0 6 0 0; $tog.Height = 34
        [void]$t.Controls.Add($tog)
        $lblCode = New-Lbl (Get-Text 'gui.profile.code.lbl') (Semi 10) $cText $cWin 'BottomLeft'; Add-Dlg $lblCode 26
        $fc = New-Object Fluent.FField; $fc.Password = $true; Add-Dlg $fc 44
        $lblCode.Visible = $false; $fc.Visible = $false
        $lblErr = New-Lbl '' (Ui 9.5) ([Fluent.Theme]::Danger) $cWin 'MiddleLeft'
        if ($dark) { $lblErr.ForeColor = [System.Drawing.Color]::FromArgb(0xFF, 0x99, 0xA4) }
        Add-Dlg $lblErr 30
        $bt = New-Object System.Windows.Forms.FlowLayoutPanel; $bt.BackColor = $cWin; $bt.WrapContents = $false
        $ok = New-Btn (Get-Text 'gui.btn.save') 'Accent' '' 130 38; $ok.Margin = Pad 10 0 0 0
        $cancel = New-Btn (Get-Text 'gui.btn.cancel') 'Standard' '' 110 38
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
                if ($u.Length -lt 2 -or $u.Length -gt 24) { $lblErr.Text = Get-Text 'gui.profile.err.len'; return }
                if ($u -notmatch '^[\p{L}\p{N}_\-\.]+$') { $lblErr.Text = Get-Text 'gui.profile.err.chars'; return }
                if ($c.Length -gt 0 -and $c.Length -lt 4) { $lblErr.Text = Get-Text 'gui.profile.err.code'; return }
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
        $helper = $script:share.Helper; if (-not $helper) { $helper = Get-Text 'gui.helper.default' }
        $d = New-Dialog (Get-Text 'gui.share.title' $helper) 560 520
        $t = New-Tlp 1 8 $cWin; $t.Padding = Pad 28 22 28 20
        Add-Col $t 'Percent' 100; Add-Row $t 'Absolute' 36; Add-Row $t 'Absolute' 28; Add-Row $t 'Absolute' 150; Add-Row $t 'Absolute' 64; Add-Row $t 'Absolute' 36; Add-Row $t 'Absolute' 40; Add-Row $t 'Absolute' 10; Add-Row $t 'Percent' 100
        $t.Controls.Add((New-Lbl (Get-Text 'gui.share.title' $helper) (Semi 15) $cText $cWin 'MiddleLeft'), 0, 0)
        $t.Controls.Add((New-Lbl (Get-Text 'gui.share.sub' $helper) (Ui 10) $cSub $cWin 'MiddleLeft'), 0, 1)
        $card = New-Object Fluent.FCard; $card.Dock = 'Fill'; $card.Padding = Pad 10 6 10 6; $card.Margin = Pad 0 4 0 8
        $ct = New-Tlp 1 3 $cCard; Add-Col $ct 'Percent' 100
        $names = @(@((Get-Text 'gui.share.f1'), 'summary.md'), @((Get-Text 'gui.share.f2'), 'report.html'), @((Get-Text 'gui.share.f3'), 'plan.json'))
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
        $t.Controls.Add((New-Lbl (Get-Text 'gui.share.redact') (Ui 9.5) $cSub $cWin 'TopLeft'), 0, 3)
        $chk = New-Object Fluent.FCheck; $chk.Text = Get-Text 'gui.share.host'; $chk.Dock = 'Fill'; $chk.Margin = Pad 0 4 0 4
        $t.Controls.Add($chk, 0, 4)
        $prev = New-Btn (Get-Text 'gui.share.preview') 'Subtle' (Glyph 0xE838) 170 36; $prev.Margin = Pad 0 2 0 2
        $t.Controls.Add($prev, 0, 5)
        $bt = New-Object System.Windows.Forms.FlowLayoutPanel; $bt.Dock = 'Fill'; $bt.BackColor = $cWin; $bt.WrapContents = $false
        $send = New-Btn (Get-Text 'gui.btn.send') 'Accent' (Glyph 0xE72D) 140 40; $send.Margin = Pad 10 0 0 0
        $cancel = New-Btn (Get-Text 'gui.btn.cancel') 'Standard' '' 110 40
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
            if ($line -match 'PREVIEW:\s*(.+)$') { $info.Dir = $Matches[1].Trim(); Add-ShareDir $info.Dir }
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
            Set-Status 'gui.status.start' 2
            Start-Task 'scan' @(('"{0}"' -f $ScanScript), '-NoOpen', '-OutDir', ('"{0}"' -f $ReportsDir), '-SampleSeconds', '30', '-Lang', (Get-UiLang)) { Scan-Done }
        } })

    $list.Add_ItemChecked({ Guard { Refresh-Buttons } })

    $btnQ.Add_Click({ Guard {
            $ids = @($list.GetChecked() | ForEach-Object { [int]$_.Tag })
            if ($ids.Count -eq 0) { return }
            $names = (@($list.GetChecked() | ForEach-Object { '•  ' + $_.Name }) -join "`n")
            $ok = Confirm-Box (Get-Text 'gui.q.confirm' $names) (Get-Text 'gui.q.title') 'Question'
            if (-not $ok) { return }
            $argv = @(('"{0}"' -f $ActionsScript), '-Mode', 'Quarantine', '-Plan', ('"{0}"' -f $script:current.Plan), '-Select', ($ids -join ','), '-Yes')
            if ($QuarantineDir) { $argv += @('-StoreDir', ('"{0}"' -f $QuarantineDir)) }
            if ($AllowNonAdmin) { $argv += '-AllowNonAdmin' }
            Set-Status 'gui.status.q' 40
            Start-Task 'quarantine' $argv {
                $out = $script:lastOutput
                $bad = Count-Problems $out
                $res = Get-ActionResult $out
                Update-Batches
                if ($out -match 'Done\. Quarantine batch') {
                    Set-Status 'gui.status.qdone' 100
                    $msg = Get-Text 'gui.q.done.box'
                    if ($bad -gt 0) { $msg += Get-Text 'gui.q.done.bad' $bad }
                    $list.Clear()
                    Show-Info 'Success' 'gui.q.done.t' 'gui.q.done.m'
                    Info-Box $msg
                } elseif ($res -eq 'BUSY') {
                    Set-Status 'store.status.busy' 0
                    Info-Box (Get-Text 'store.busy.box') 'Warning'
                } elseif ($res -like 'FAILED nosave*') {
                    # stopped because the undo record could not be saved: whatever was done is recorded and can be undone
                    Set-Status 'gui.status.qfail' 0
                    Info-Box (Get-Text 'store.q.stopped.box') 'Warning'
                } else {
                    Set-Status 'gui.status.qfail' 0
                    Info-Box (Get-Text 'gui.q.fail.box') 'Warning'
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
                        if ($line -match 'SUMMARY:\s*(.+)$') { $p = $Matches[1].Trim(); Add-ShareDir (Split-Path -Parent $p); if (Test-Path -LiteralPath $p) { $text = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) } }
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
                    $m = if ($r.Output -match 'RESULT:\s*ERROR\s*(.+)') { $Matches[1].Trim() } else { Get-Text 'gui.profile.saveerr' }
                    Show-Toast 'Error' (Get-Text 'gui.toast.profileerr.t') $m; return
                }
                $script:share = Read-ShareProfile; Apply-ShareVisibility
            }
            $pv = Get-PreviewInfo $false
            $choice = Show-ShareDialog $pv
            if (-not $choice) { Clear-ShareTemp; return }
            $a = (Share-Args 'Share') + @('-PlanPath', ('"{0}"' -f $script:current.Plan))
            if ($choice.Include) { $a += '-IncludeHostName' }
            if ($ShareDryRun) { $a += '-DryRun' }
            Set-Status 'gui.status.sending' 60
            Start-Task 'share' $a {
                Clear-ShareTemp
                $helper = $script:share.Helper; if (-not $helper) { $helper = Get-Text 'gui.helper.default' }
                if ($script:lastOutput -match 'RESULT:\s*OK') {
                    Set-Status 'gui.status.sent' 100
                    Show-Toast 'Success' (Get-Text 'gui.toast.sent.t') (Get-Text 'gui.toast.sent.m' $helper)
                } else {
                    $m = if ($script:lastOutput -match 'RESULT:\s*ERROR\s*\S*\s*(.*)') { $Matches[1].Trim() } else { Get-Text 'gui.share.sendfail' }
                    Set-Status 'gui.status.sendfail' 0
                    Show-Toast 'Error' (Get-Text 'gui.toast.sendfail.t') $m
                }
            }
        } })

    $btnShareDel.Add_Click({ Guard {
            if (-not (Confirm-Box (Get-Text 'gui.sharedel.confirm') (Get-Text 'gui.sharedel.title') 'Warning')) { return }
            $r = Invoke-Cli (Share-Args 'DeleteProfile') 30
            $script:share = Read-ShareProfile; Apply-ShareVisibility
            Show-Toast 'Info' (Get-Text 'gui.toast.profiledel.t') (Get-Text 'gui.toast.profiledel.m')
        } })

    $btnRestore.Add_Click({ Guard {
            Update-Batches   # the list printed by the actions script, newest first (by its sequence number, not the clock)
            $b = @($script:batches | Where-Object { $_.state -eq 'restorable' }) | Select-Object -First 1
            if (-not $b) { Refresh-Buttons; Info-Box (Get-Text 'gui.restore.none'); return }
            if (-not (Confirm-Box (Get-Text 'gui.restore.confirm') (Get-Text 'gui.restore.title') 'Question')) { return }
            $argv = @(('"{0}"' -f $ActionsScript), '-Mode', 'Restore', '-Batch', [string]$b.name, '-Yes')
            if ($QuarantineDir) { $argv += @('-StoreDir', ('"{0}"' -f $QuarantineDir)) }
            if ($AllowNonAdmin) { $argv += '-AllowNonAdmin' }
            Set-Status 'gui.status.restoring' 50
            Start-Task 'restore' $argv {
                $res = Get-ActionResult $script:lastOutput
                Update-Batches
                Refresh-Buttons
                if ($res -like 'OK*') { Set-Status 'gui.status.restored' 100; Info-Box (Get-Text 'gui.restore.done.box') }
                elseif ($res -match '^PARTIAL\s+(\d+)') { Set-Status 'restore.status.partial' 0; Info-Box (Get-Text 'restore.partial.box' $Matches[1]) 'Warning' }
                elseif ($res -eq 'BUSY') { Set-Status 'store.status.busy' 0; Info-Box (Get-Text 'store.busy.box') 'Warning' }
                elseif ($res -match '^FAILED (damaged|orphan)') { Set-Status 'gui.status.restorefail' 0; Info-Box (Get-Text 'restore.damaged.box') 'Warning' }
                elseif ($res -eq 'FAILED toonew') { Set-Status 'gui.status.restorefail' 0; Info-Box (Get-Text 'restore.toonew.box') 'Warning' }
                else { Set-Status 'gui.status.restorefail' 0; Info-Box (Get-Text 'gui.restore.fail.box') 'Warning' }
            }
        } })

    $btnPurge.Add_Click({ Guard {
            Update-Batches
            $st = Get-QuarantinedStats
            if ($st.Count -eq 0) { Refresh-Buttons; Info-Box (Get-Text 'gui.purge.none'); return }
            $ok = Confirm-Box (Get-Text 'gui.purge.confirm' $st.Count $st.MB) (Get-Text 'gui.purge.title') 'Warning'
            if (-not $ok) { return }
            $argv = @(('"{0}"' -f $ActionsScript), '-Mode', 'Purge', '-OlderThanDays', '0', '-Yes')
            if ($QuarantineDir) { $argv += @('-StoreDir', ('"{0}"' -f $QuarantineDir)) }
            if ($AllowNonAdmin) { $argv += '-AllowNonAdmin' }
            Set-Status 'gui.status.purging' 50
            Start-Task 'purge' $argv {
                $res = Get-ActionResult $script:lastOutput
                Update-Batches
                Refresh-Buttons
                if ($res -like 'OK*') { Set-Status 'gui.status.purged' 100; Info-Box (Get-Text 'gui.purge.done.box') }
                elseif ($res -eq 'NONE') { Set-Status 'gui.status.ready' 0; Info-Box (Get-Text 'gui.purge.none') }
                elseif ($res -eq 'BUSY') { Set-Status 'store.status.busy' 0; Info-Box (Get-Text 'store.busy.box') 'Warning' }
                else { Set-Status 'store.status.purgefail' 0; Info-Box (Get-Text 'store.purge.fail.box') 'Warning' }
            }
        } })

    $btnClean.Add_Click({ Guard {
            if (-not (Test-Path -LiteralPath $ReportsDir)) { Info-Box (Get-Text 'gui.clean.none'); return }
            $n = @(Get-ChildItem -LiteralPath $ReportsDir -File -ErrorAction SilentlyContinue).Count
            if (-not (Confirm-Box (Get-Text 'gui.clean.confirm' $n) (Get-Text 'gui.clean.title') 'Question')) { return }
            Remove-Item -LiteralPath $ReportsDir -Recurse -Force -ErrorAction SilentlyContinue
            $script:current = $null; $script:currentPlan = $null; $list.Clear(); $toast.Visible = $false
            Show-Info 'Info' 'gui.info.ready.t' 'gui.info.ready.m'
            Set-Status 'gui.status.cleaned' 0
            Refresh-Buttons
        } })

    $btnLang.Add_Click({ Guard { Switch-Language } })

    $form.Add_FormClosing({
            param($s, $e)
            if ($script:cliBusy -gt 0) { $e.Cancel = $true; return }   # a short helper call is still running: it ends within seconds
            if ($script:proc -and -not $script:proc.HasExited) {
                if ($script:taskKind -in 'scan', 'summary') { try { $script:proc.Kill() } catch { } }
                else { $e.Cancel = $true; Info-Box (Get-Text 'gui.closing') 'Warning' }
            }
        })
    $form.Add_FormClosed({
            # last sweep of what this window created: the output files of its child processes and the share previews
            try { Clear-ShareTemp } catch { }
            for ($i = 0; $i -lt 10 -and $script:tempLeft.Count -gt 0; $i++) { Sweep-TaskFiles; if ($script:tempLeft.Count -gt 0) { Start-Sleep -Milliseconds 200 } }
            $script:tempSweep.Stop()
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

    # ------------------------------------------------------------ language switch
    # Applies the current language (Set-UiLang) to the whole open window: direction (RightToLeft + mirrored frame), every
    # registered text, and every text that depends on state (status line, verdict bar, list, buttons). Nothing is stored.
    function Apply-Language {
        $rtl = Test-Rtl
        $form.SuspendLayout()
        $form.RightToLeft = Get-RtlValue
        $form.RightToLeftLayout = $rtl
        $form.Text = Get-Text 'gui.window.title'
        foreach ($b in $script:i18n) { $b.Ctl.($b.Prop) = Get-Text $b.Key }
        $banner.Title = Get-Text 'gui.banner.t'; $banner.Message = Get-Text 'gui.banner.m'
        $script:langTip.SetToolTip($btnLang, (Get-Text 'gui.lang.tip')); $btnLang.AccessibleName = Get-Text 'gui.lang.tip'
        if ($ShareForceConfigured -and $script:share) { $script:share.Helper = Get-Text 'gui.helper.demo' }
        $toast.Visible = $false
        Set-Status $script:statusKey -1 $script:statusArgs
        if ($script:infoMode -eq 'results' -and $script:current) {
            $ids = @($list.GetChecked() | ForEach-Object { [int]$_.Tag })   # keep the user's selection
            [void](Load-Results $script:current $script:currentPrev)
            foreach ($it in $list.Items) { $it.Checked = ($ids -contains [int]$it.Tag) }
            $list.Invalidate()
        } else { Show-Info $script:infoLevel $script:infoTitleKey $script:infoMsgKey }
        $form.ResumeLayout($true)
        if ($form.IsHandleCreated) {   # mirroring the frame re-creates the window: the Windows 11 styling has to be applied again
            [Fluent.Win]::StyleWindow($form.Handle, $dark, $cWin, $cText)
            [Fluent.Win]::SetScrollTheme($page.Handle, $dark)
        }
        Apply-ShareVisibility
    }
    function Switch-Language {
        Set-UiLang $(if ((Get-UiLang) -eq 'ar') { 'en' } else { 'ar' })
        Apply-Language
    }

    # ------------------------------------------------------------ start-up
    $form.Add_Shown({
            Guard {
                [Fluent.Win]::StyleWindow($form.Handle, $dark, $cWin, $cText)
                [Fluent.Win]::SetScrollTheme($page.Handle, $dark)
                $script:share = Read-ShareProfile
                Apply-ShareVisibility
                if ($script:share.Damaged) { Show-Toast 'Warning' (Get-Text 'store.share.damaged.t') (Get-Text 'store.share.damaged.m') }
                Update-Batches
                # the newest readable scan of this PC (a damaged plan is set aside and the one before it is shown)
                $skipped = 0
                foreach ($r in @(Get-LatestResults)) {
                    if (Load-Results $r $true) { Set-Status 'gui.status.last' 0; break }
                    $skipped++
                }
                if ($skipped -gt 0) { Show-Toast 'Warning' (Get-Text 'store.plan.damaged.t') (Get-Text 'store.plan.damaged.m') }
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
    Set-Status 'gui.status.ready' 0
    Show-Info 'Info' 'gui.info.ready.t' 'gui.info.ready.m'
    Apply-Language
    [void]$form.ShowDialog()
}
catch {
    $msg = $_ | Out-String
    try { Add-Content -LiteralPath (Join-Path $env:TEMP 'ramdoctor-gui-error.log') -Value $msg } catch { }
    try { [void][System.Windows.Forms.MessageBox]::Show(((Get-Text 'gui.err.open') + "`n" + $_.Exception.Message), (Get-Text 'gui.msgbox.title'), 'OK', 'Error') } catch { }
}
