<#
.SYNOPSIS
  End-to-end test of the real GUI (src\RAM-Doctor-GUI.ps1), driven by PerformClick() from inside the window.

.DESCRIPTION
  Flow: scan -> copy summary -> quarantine -> restore -> scan -> quarantine -> purge -> share (dry-run, no network) -> clear reports.
  It compiles a HARMLESS memory-hog exe with a random name in %TEMP%, registers it under HKCU Run, and only ever selects that file.
  The GUI runs with its own private %TEMP% so we can prove nothing is left behind. No UAC prompt: the GUI uses -AllowNonAdmin.
  Needs an interactive desktop and takes about 4-5 minutes (two real scans). Exit code 0 = all checks passed.

  powershell -NoProfile -ExecutionPolicy Bypass -File tests\gui\Flow.Test.ps1
#>
[CmdletBinding()]
param([switch]$KeepWork)

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$gui = Join-Path $repo 'src\RAM-Doctor-GUI.ps1'
# random vowel-free name + digits: looks "random" to the detector (so it is rated High) and cannot collide with anything real
$cons = 'bcdfghjklmnpqrstvwxz'.ToCharArray()
$id = (-join ((1..7) | ForEach-Object { $cons[(Get-Random -Maximum $cons.Length)] })) + (Get-Random -Minimum 100 -Maximum 999)
$work = Join-Path $env:TEMP "ramdoctor-guitest-$id"
$hog = "zz$id"
$hogExe = Join-Path $work "$hog.exe"
$runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runName = "RamDoctorGuiTest-$id"
$result = Join-Path $work 'result.txt'
$utf8 = New-Object System.Text.UTF8Encoding($true)
New-Item -ItemType Directory -Force -Path $work, (Join-Path $work 'tmp'), (Join-Path $work 'reports'), (Join-Path $work 'store'), (Join-Path $work 'profile') | Out-Null
$oldTemp = $env:TEMP; $oldTmp = $env:TMP
$exit = 1

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
    New-ItemProperty -LiteralPath $runKey -Name $runName -Value ('"' + $hogExe + '"') -PropertyType String -Force | Out-Null
    Write-Host "hog: $hog.exe  (run value $runName)"

    # ---- the script that runs INSIDE the GUI process
    $inner = @'
$out = '%RESULT%'
$hog = '%HOG%'; $hogExe = '%HOGEXE%'; $runKey = '%RUNKEY%'; $runName = '%RUNNAME%'; $work = '%WORK%'
function Log2($s) { Add-Content -LiteralPath $out -Value $s -Encoding UTF8 }
function Check([string]$name, $cond) { if ($cond) { Log2 "PASS  $name" } else { Log2 "FAIL  $name" } }
function Wait-Until([scriptblock]$cond, [int]$sec) { $end = (Get-Date).AddSeconds($sec); while ((Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); if (& $cond) { return $true }; Start-Sleep -Milliseconds 150 }; return $false }
function Idle { Wait-Until { $script:proc -eq $null } 300 }
function Hog-State { [pscustomobject]@{ Proc = [bool](Get-Process -Name $hog -ErrorAction SilentlyContinue); Exe = (Test-Path $hogExe); Run = [bool](Get-ItemProperty $runKey -Name $runName -ErrorAction SilentlyContinue) } }
function Only-Hog { foreach ($it in $list.Items) { $it.Checked = ($it.Name -ieq "$hog.exe") }; Refresh-Buttons; $list.Invalidate() }

Log2 '== initial state'
Check 'scan button enabled' $btnScan.Enabled
Check 'copy-summary disabled before a scan' (-not $btnCopy.Enabled)
Check 'findings card hidden before a scan' (-not $find.Visible)

Log2 '== scan #1'
$btnScan.PerformClick()
Check 'scan button disabled while scanning' (-not $btnScan.Enabled)
Check 'scan finished' (Idle)
Check 'results card shows the hog as high risk' (@($list.Items | Where-Object { $_.Name -ieq "$hog.exe" -and $_.Level -eq 2 }).Count -eq 1)
Check 'infobar is Error level' ($info.Level -eq 'Error')
Check 'report/copy buttons enabled' ($btnReport.Enabled -and $btnCopy.Enabled -and $btnFolder.Enabled)
Check 'findings card visible' $find.Visible

Log2 '== copy summary'
$btnCopy.PerformClick()
[void](Idle)
Check 'toast shown (Success)' ($toast.Visible -and $toast.Level -eq 'Success')
$clip = ''; try { $clip = [System.Windows.Forms.Clipboard]::GetText() } catch { }
Check 'clipboard has text' ($clip.Length -gt 20)
Check 'clipboard text has no Windows user name' (-not ($clip -match [regex]::Escape($env:USERNAME)))
Check 'clipboard text has no drive path' (-not ($clip -match '[A-Za-z]:\\'))
Check 'share preview temp folder removed' (-not (Test-Path (Join-Path $env:TEMP 'RAM-Doctor-share-preview')))

Log2 '== quarantine #1'
Only-Hog
Check 'exactly one item selected (the hog)' ($list.CheckedCount -eq 1)
Check 'hog alive before' ((Hog-State).Proc)
$btnQ.PerformClick()
Check 'quarantine finished' (Idle)
$s = Hog-State
Check 'hog process stopped' (-not $s.Proc)
Check 'hog exe moved away' (-not $s.Exe)
Check 'Run value removed' (-not $s.Run)
Check 'verdict now Success' ($info.Level -eq 'Success')
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
Check 'header subtitle mentions optional sharing' ($lblSub.Text -match 'اختيارية')
$script:TestProfile = @{ Username = 'tester_01'; Code = '' }
$btnShare.PerformClick()
Check 'share task finished' (Idle)
Check 'share toast is Success' ($toast.Visible -and $toast.Level -eq 'Success')
Check 'profile file written to the test profile dir' (@(Get-ChildItem (Join-Path $work 'profile') -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0)
$del = Invoke-Cli (Share-Args 'DeleteProfile') 30
Check 'DeleteProfile OK' ($del.Output -match 'RESULT:\s*OK')
Check 'share preview temp folder removed after sharing' (-not (Test-Path (Join-Path $env:TEMP 'RAM-Doctor-share-preview')))

Log2 '== clear reports'
Check 'reports exist before' (Test-Path $ReportsDir)
$btnClean.PerformClick()
Check 'reports folder removed' (-not (Test-Path $ReportsDir))
Check 'action row hidden' (-not $acts.Visible)

Log2 '== leftovers in the GUI private TEMP'
$left = @(Get-ChildItem $env:TEMP -Filter 'ramdoctor-*' -ErrorAction SilentlyContinue)
Check ('no ramdoctor-* temp files left (found ' + $left.Count + ')') ($left.Count -eq 0)
Log2 'DONE'
$form.Close()
'@
    $inner = $inner.Replace('%RESULT%', $result).Replace('%HOG%', $hog).Replace('%HOGEXE%', $hogExe).Replace('%RUNKEY%', $runKey).Replace('%RUNNAME%', $runName).Replace('%WORK%', $work)
    $testScript = Join-Path $work 'inner.test.ps1'
    [IO.File]::WriteAllText($testScript, $inner, $utf8)

    # ---- run the GUI with a private TEMP
    $env:TEMP = (Join-Path $work 'tmp'); $env:TMP = $env:TEMP
    $guiArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $gui),
        '-ReportsDir', ('"{0}"' -f (Join-Path $work 'reports')), '-QuarantineDir', ('"{0}"' -f (Join-Path $work 'store')),
        '-AllowNonAdmin', '-Unattended', '-Theme', 'Light', '-Accent', 'default',
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
    Write-Host ("`n{0} passed, {1} failed{2}" -f $pass, $fail, $(if (-not $done) { ', flow did NOT finish' } else { '' }))
    $exit = $(if ($fail -eq 0 -and $done) { 0 } else { 1 })
}
finally {
    $env:TEMP = $oldTemp; $env:TMP = $oldTmp
    Get-Process -Name $hog -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    if (-not $KeepWork) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $exit
