<#
.SYNOPSIS
  Regenerates docs/assets/gui-*.png from SYNTHETIC data (host "DESKTOP-DEMO", user "Friend") - nothing personal, no real scan.

.DESCRIPTION
  Launches the real GUI (src\RAM-Doctor-GUI.ps1) once per scenario with the developer switches -TestScript / -Theme / -Accent default,
  loads a fake Plan-*.json, resizes the window to fit its content and saves a picture of the real window (Windows 11 title bar included).
  Needs an interactive desktop (it uses CopyFromScreen). The pictures are taken at the screen's native scale.

  powershell -NoProfile -ExecutionPolicy Bypass -File tests\gui\Make-Screenshots.ps1
#>
[CmdletBinding()]
param([string]$OutDir = '', [string]$Work = '', [string[]]$Only = @())

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$gui = Join-Path $repo 'src\RAM-Doctor-GUI.ps1'
if (-not $OutDir) { $OutDir = Join-Path $repo 'docs\assets' }
if (-not $Work) { $Work = Join-Path $env:TEMP ('ramdoctor-shots-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
New-Item -ItemType Directory -Force -Path $OutDir, $Work | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($true)

# ---------------------------------------------------------------- synthetic plans (schema = what RAM-Doctor.ps1 writes)
function New-DemoPlan([string]$dir, [string]$scenario) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $stamp = '20260101-101500'
    $mem = [pscustomobject]@{ TotalGB = 15.9; UsedGB = 14.8; NonPagedGB = 0.9; PagedGB = 0.7 }
    $sus = @(); $obs = @()
    switch ($scenario) {
        'high' {
            $v = [pscustomobject]@{ Level = 'high'; Headline = 'تم رصد مؤشرات تستحق التدقيق العاجل (قد تكون برمجية خبيثة)' }
            $obs = @(
                [pscustomobject]@{ Level = 'high'; Title = 'ملفات عالية الخطورة (1)'; Body = '-' },
                [pscustomobject]@{ Level = 'med'; Title = 'برنامج تتضخّم ذاكرته الآن'; Body = '-' },
                [pscustomobject]@{ Level = 'info'; Title = 'ذاكرة التخزين المؤقت'; Body = '-' })
            $sus = @(
                [pscustomobject]@{ id = 1; risk = 'High'; score = 11; name = 'svch0st.exe'; reasons = @('اسمه (svch0st.exe) يشبه عملية النظام svchost بفارق حرف واحد', 'يعمل من مجلد مؤقت/عام (Temp)') },
                [pscustomobject]@{ id = 2; risk = 'Medium'; score = 6; name = 'updater_x64.exe'; reasons = @('الملف غير موقّع رقميًا', 'يعمل من مجلد بيانات المستخدم (AppData)') },
                [pscustomobject]@{ id = 3; risk = 'Low'; score = 3; name = 'helper.exe'; reasons = @('-') })
        }
        'kernel' {
            $mem = [pscustomobject]@{ TotalGB = 15.9; UsedGB = 14.2; NonPagedGB = 6.4; PagedGB = 1.1 }
            $v = [pscustomobject]@{ Level = 'med'; Headline = 'السبب الأرجح: تسرّب ذاكرة في تعريف (Driver) على مستوى النواة' }
            $obs = @(
                [pscustomobject]@{ Level = 'med'; Title = 'ذاكرة النواة (Non-paged pool) أعلى من المعتاد'; Body = '-' },
                [pscustomobject]@{ Level = 'med'; Title = 'التشغيل السريع (Fast Startup) مفعّل والجهاز شغّال منذ مدة'; Body = '-' })
        }
        default {
            $v = [pscustomobject]@{ Level = 'ok'; Headline = 'لا يوجد تسرّب أو مؤشر خبيث واضح في هذه اللحظة' }
            $obs = @([pscustomobject]@{ Level = 'info'; Title = 'ذاكرة التخزين المؤقت'; Body = '-' })
        }
    }
    $plan = [pscustomobject]@{ tool = 'RAM-Doctor'; version = '1.0.0'; host = 'DESKTOP-DEMO'; created = '2026-01-01 10:15:00'; isAdmin = $true
        report = (Join-Path $dir "RAMDoctor-DESKTOP-DEMO-$stamp.html"); verdict = $v; observations = $obs; memory = $mem; suspects = $sus }
    [IO.File]::WriteAllText((Join-Path $dir "Plan-DESKTOP-DEMO-$stamp.json"), ($plan | ConvertTo-Json -Depth 6), $utf8)
    Set-Content -LiteralPath (Join-Path $dir "RAMDoctor-DESKTOP-DEMO-$stamp.html") -Value '<html></html>'
}
foreach ($s in 'high', 'kernel', 'clean') { New-DemoPlan (Join-Path $Work $s) $s }
New-Item -ItemType Directory -Force -Path (Join-Path $Work 'empty') | Out-Null

# ---------------------------------------------------------------- helpers injected into every test script (they run inside the GUI process)
$common = @'
function Fit-Window {
    $col.PerformLayout()
    $form.ClientSize = New-Object System.Drawing.Size(940, [math]::Min($col.Height + 4, [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height - 80))
    [System.Windows.Forms.Application]::DoEvents()
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
            $fields = @(Find-Fields $f); if ($fields.Count -gt 0) { $fields[0].Value = 'ahmed_92' }
            Save-WindowShot $script:dsPath $f
            $f.Close()
        }
    })
    $script:dsTimer.Start()
    & $show
}
$script:OUT = '%OUT%'
'@

$scenarios = @(
    @{ Name = 'gui-light'; Reports = 'high'; Theme = 'Light'; Extra = @(); Body = @'
Load-Results (Get-LatestResult) $false
Set-Status 'اكتمل الفحص. النتيجة أعلاه.' 100
Fit-Window
Save-WindowShot (Join-Path $script:OUT 'gui-light.png')
'@ },
    @{ Name = 'gui-dark'; Reports = 'high'; Theme = 'Dark'; Extra = @(); Body = @'
Load-Results (Get-LatestResult) $false
Set-Status 'اكتمل الفحص. النتيجة أعلاه.' 100
Fit-Window
Save-WindowShot (Join-Path $script:OUT 'gui-dark.png')
'@ },
    @{ Name = 'gui-progress'; Reports = 'empty'; Theme = 'Light'; Extra = @(); Body = @'
$btnScan.Enabled = $false; $btnScan.Text = 'جارٍ الفحص ...'
$bar.Value = 46
Set-Status 'جارٍ فحص التعريفات ...' 46
$info.Level = 'Info'; $info.Title = 'الفحص شغّال الآن'; $info.Message = 'نراقب الذاكرة والتعريفات والبرامج الشغّالة. لا تغلق النافذة، تنتهي خلال دقيقة تقريبًا.'
[void]$info.FitHeight()
Fit-Window
Save-WindowShot (Join-Path $script:OUT 'gui-progress.png')
'@ },
    @{ Name = 'gui-clean'; Reports = 'clean'; Theme = 'Light'; Extra = @(); Body = @'
Load-Results (Get-LatestResult) $false
Set-Status 'اكتمل الفحص. النتيجة أعلاه.' 100
Fit-Window
Save-WindowShot (Join-Path $script:OUT 'gui-clean.png')
'@ },
    @{ Name = 'gui-kernel'; Reports = 'kernel'; Theme = 'Light'; Extra = @(); Body = @'
Load-Results (Get-LatestResult) $false
Set-Status 'اكتمل الفحص. النتيجة أعلاه.' 100
Fit-Window
Save-WindowShot (Join-Path $script:OUT 'gui-kernel.png')
'@ },
    @{ Name = 'gui-more'; Reports = 'clean'; Theme = 'Light'; Extra = @('-ShareForceConfigured'); Body = @'
Load-Results (Get-LatestResult) $false
Set-Status 'اكتمل الفحص. النتيجة أعلاه.' 100
$script:share = [pscustomobject]@{ Configured = $true; Name = 'ahmed_92'; UserId = 'a1b2c3d4e5'; Helper = 'مساعدي'; EndpointConfigured = $true }
Apply-ShareVisibility
$exMore.Expanded = $true; Resize-Cards
Fit-Window
Save-WindowShot (Join-Path $script:OUT 'gui-more.png')
'@ },
    @{ Name = 'gui-share'; Reports = 'high'; Theme = 'Light'; Extra = @('-ShareForceConfigured'); Body = @'
Load-Results (Get-LatestResult) $false
$script:share = [pscustomobject]@{ Configured = $true; Name = 'ahmed_92'; UserId = 'a1b2c3d4e5'; Helper = 'مساعدي'; EndpointConfigured = $true }
Apply-ShareVisibility
$pv = @{ Dir = $env:TEMP; Sizes = @{ 'summary.md' = '3'; 'report.html' = '31'; 'plan.json' = '14' } }
Dialog-Shot { [void](Show-ShareDialog $pv) } (Join-Path $script:OUT 'gui-share.png')
'@ },
    @{ Name = 'gui-profile'; Reports = 'high'; Theme = 'Light'; Extra = @('-ShareForceConfigured'); Body = @'
Load-Results (Get-LatestResult) $false
Dialog-Shot { [void](Show-ProfileDialog) } (Join-Path $script:OUT 'gui-profile.png')
'@ }
)

foreach ($s in $scenarios) {
    if ($Only.Count -gt 0 -and $Only -notcontains $s.Name) { continue }
    Write-Host ("  {0} ..." -f $s.Name)
    $ts = Join-Path $Work ($s.Name + '.test.ps1')
    $body = ($common.Replace('%OUT%', $OutDir)) + "`r`n" + $s.Body + "`r`n" + '$form.Close()' + "`r`n"
    [IO.File]::WriteAllText($ts, $body, $utf8)
    Remove-Item -LiteralPath ($ts + '.error.txt') -ErrorAction SilentlyContinue
    $guiArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $gui), '-ReportsDir', ('"{0}"' -f (Join-Path $Work $s.Reports)),
        '-QuarantineDir', ('"{0}"' -f (Join-Path $Work 'store')), '-AllowNonAdmin', '-Theme', $s.Theme, '-Accent', 'default', '-TestScript', ('"{0}"' -f $ts)) + $s.Extra
    $p = Start-Process -FilePath powershell.exe -ArgumentList $guiArgs -PassThru
    if (-not $p.WaitForExit(90000)) { try { $p.Kill() } catch { }; Write-Warning "$($s.Name): GUI did not close in time" }
    if (Test-Path ($ts + '.error.txt')) { Write-Warning "$($s.Name): test script error"; Get-Content ($ts + '.error.txt') }
}
Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Done. Pictures are in $OutDir"
