<#
  The window must survive a language switch, the way a user does it: the click handler RETURNS and the window keeps
  running afterwards. (Flow.Test drives everything from inside one handler while pumping messages itself, which hid
  that a modal loop ended as soon as the switch re-created the window: in 1.1.0 and 1.1.1 the window vanished.)

  Opens the real window (it needs a desktop session: CI runs it, do not run it while you use the PC), switches the
  language three times with pauses in between, then closes it. Run:
  powershell -NoProfile -ExecutionPolicy Bypass -File tests\gui\LangSwitch.Test.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$gui = Join-Path $repo 'src\RAM-Doctor-GUI.ps1'
$worst = 0

foreach ($start in 'en', 'ar') {
    $work = Join-Path ([IO.Path]::GetTempPath()) ('ramdoctor-langtest-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    New-Item -ItemType Directory -Path "$work\reports", "$work\store", "$work\profile" | Out-Null
    $log = Join-Path $work 'steps.log'
    $inner = Join-Path $work 'inner.test.ps1'
    $body = @'
$log = '__LOG__'
$form.Add_FormClosed({ Add-Content $log 'CLOSED' })
$script:lsStep = 0
$script:lsTimer = New-Object System.Windows.Forms.Timer
$script:lsTimer.Interval = 1500
$script:lsTimer.Add_Tick({
    $script:lsStep++
    $state = 'lang=' + (Get-UiLang) + ' visible=' + $form.Visible + ' mirrored=' + $form.RightToLeftLayout
    if ($script:lsStep -le 3) { Add-Content $log ('step ' + $script:lsStep + ': ' + $state); $btnLang.PerformClick() }
    else { Add-Content $log ('final: ' + $state); $script:lsTimer.Stop(); $form.Close() }
})
$script:lsTimer.Start()
'@
    $body.Replace('__LOG__', $log) | Set-Content -LiteralPath $inner -Encoding UTF8
    $guiArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $gui),
        '-ReportsDir', ('"{0}\reports"' -f $work), '-QuarantineDir', ('"{0}\store"' -f $work), '-ShareProfileDir', ('"{0}\profile"' -f $work),
        '-AllowNonAdmin', '-Unattended', '-Theme', 'Light', '-Accent', 'default', '-Lang', $start, '-TestScript', ('"{0}"' -f $inner))
    $p = Start-Process -FilePath powershell.exe -ArgumentList $guiArgs -PassThru
    $ended = $p.WaitForExit(90000)
    if (-not $ended) { try { $p.Kill() } catch { } }
    $lines = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log })
    $other = $(if ($start -eq 'en') { 'ar' } else { 'en' })
    $checks = @(
        @{ Name = 'the window opened and the test ran'; Ok = ($lines.Count -gt 0) }
        @{ Name = "still open after the 1st switch, now in $other"; Ok = [bool]($lines -match "^step 2: lang=$other visible=True") }
        @{ Name = "still open after the 2nd switch, back in $start"; Ok = [bool]($lines -match "^step 3: lang=$start visible=True") }
        @{ Name = "still open after the 3rd switch, in $other"; Ok = [bool]($lines -match "^final: lang=$other visible=True") }
        @{ Name = 'the frame is mirrored exactly in Arabic'; Ok = (@($lines -match '^(step|final)' | Where-Object { ($_ -match 'lang=ar') -ne ($_ -match 'mirrored=True') }).Count -eq 0) }
        @{ Name = 'it closed only when asked, and the process ended'; Ok = ($ended -and $lines.Count -gt 0 -and $lines[-1] -eq 'CLOSED') }
    )
    Write-Host "[$start] start language"
    foreach ($c in $checks) { Write-Host ('{0}  {1}' -f $(if ($c.Ok) { 'PASS' } else { 'FAIL' }), $c.Name); if (-not $c.Ok) { $worst = 1 } }
    if ($worst) { Write-Host ('log: ' + ($lines -join ' | ')); if (Test-Path "$inner.error.txt") { Get-Content "$inner.error.txt" | Write-Host } }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host $(if ($worst) { 'Language switch test: FAILED' } else { 'Language switch test: passed' })
exit $worst
