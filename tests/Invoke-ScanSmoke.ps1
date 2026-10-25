#requires -Version 5.1
<#
.SYNOPSIS
  End-to-end smoke test of the SHIPPED artifact: check dist\RAM-Doctor.bat, unpack the same payload, run a real (read-only)
  scan with the unpacked scripts, and check what it wrote.

.DESCRIPTION
  1. the release file has no environment hooks and its payload is byte-identical to the test build used below
  2. unpacks that payload with the exact unpack command (test variant, Build-SingleFile.ps1 -DevHooks; it is built into a temp
     folder, never into dist\) and compares every file with its source
  3. runs src\RAM-Doctor.ps1 -NoOpen -SampleSeconds <n> -OutDir <temp> -Lang <en|ar>   (no admin needed; GitHub runners are admin
     anyway). By default one scan is run in English and one in Arabic (-Lang en|ar|both).
  4. asserts: exit code 0, plain-ASCII console, a report (.html) and a plan (.json) were written, the plan satisfies the plan
     contract and records its language, the report is a real HTML page with the matching lang/dir, and the footprint is light
  Nothing is changed on the machine; everything is written to a temp folder that is removed afterwards.

  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-ScanSmoke.ps1 [-Bat dist\RAM-Doctor.bat]
#>
[CmdletBinding()]
param(
    [string]$Bat = '',
    [int]$SampleSeconds = 5,
    [int]$TimeoutSec = 900,
    [switch]$KeepFiles,
    [ValidateSet('ar', 'en', 'both')][string]$Lang = 'both'   # language(s) of the real scan(s); the default runs one scan in each
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
$root = Get-RepoRoot
$onGitHub = [bool]$env:GITHUB_ACTIONS
$failures = New-Object System.Collections.Generic.List[string]
function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  ok    $what" -ForegroundColor Green }
    else { $failures.Add($what); Write-Host "  FAIL  $what" -ForegroundColor Red; if ($onGitHub) { Write-Host "::error::scan smoke test: $what" } }
}

if (-not $Bat) {
    $Bat = Join-Path $root 'dist\RAM-Doctor.bat'
    if (-not (Test-Path -LiteralPath $Bat)) { Write-Host 'dist\RAM-Doctor.bat not found, building it first ...'; & (Join-Path $root 'build\Build-SingleFile.ps1') | Out-Host }
}
$Bat = (Resolve-Path -LiteralPath $Bat).Path
$work = New-TempDirectory 'ramdoc-smoke'
. (Join-Path $root 'build\BuildCommon.ps1')
$u = $null
try {
    Write-Host "Smoke test of $Bat   (the release file)"
    Write-Host '1) the release file has no environment hooks, and carries exactly the payload that is tested'
    $bad = @(Get-ReleaseHygieneProblems -Path $Bat)
    Check ($bad.Count -eq 0) ('release header: no RAMDOC_ hook, no -TestScript pass-through, no extra environment reads' + $(if ($bad.Count) { ': ' + ($bad -join '; ') } else { '' }))
    # The release file cannot be driven headless (that would need hooks), so the TEST variant is built from the same
    # sources - never into dist\ - and its payload is compared byte for byte with the release file's.
    $devBat = Join-Path $work 'RAM-Doctor.devhooks.bat'
    $null = & (Join-Path $root 'build\Build-SingleFile.ps1') -OutFile $devBat -DevHooks 6>$null
    Check ((Split-SingleFile -Path $Bat).Payload -ceq (Split-SingleFile -Path $devBat).Payload) 'release payload is byte-identical to the test build the smoke test unpacks'

    Write-Host '2) unpack it'
    $u = & (Join-Path $root 'build\Expand-SingleFile.ps1') -Bat $devBat -SourceRoot $root -PrivateTemp (Join-Path $work 'tmp')   # secure folder on an administrator session (CI), temp folder otherwise
    Check ($u.ExitCode -eq 0) ('unpacker exits with 0 (' + $u.Mode + ' mode)')
    Check ($u.Problems.Count -eq 0) ('every unpacked file matches its source' + $(if ($u.Problems.Count) { ': ' + ($u.Problems -join '; ') } else { '' }))

    foreach ($sl in @($(if ($Lang -eq 'both') { 'en', 'ar' } else { $Lang }))) {
        Write-Host "3) run a real scan in language '$sl' (-SampleSeconds $SampleSeconds)"
        $out = Join-Path $work "out-$sl"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-ChildPowerShell -File (Join-Path $u.Dest 'src\RAM-Doctor.ps1') -ArgumentList @('-NoOpen', '-SampleSeconds', $SampleSeconds, '-OutDir', $out, '-Lang', $sl) -TimeoutSec $TimeoutSec
        Write-Host ("   finished in {0:N0} s" -f $sw.Elapsed.TotalSeconds)
        Check (-not $r.TimedOut) "[$sl] scan finished within the time limit"
        Check ($r.ExitCode -eq 0) ("[$sl] scan exits with 0 (got $($r.ExitCode))")
        Check ($r.StdOut -match '(?m)^\[\d\d:\d\d:\d\d\] ') "[$sl] scan prints timestamped progress lines (the window parses them)"
        Check ($r.StdOut -notmatch '\[\[[a-z]+\.[A-Za-z0-9.\-]+\]\]') "[$sl] console output has no unresolved text key"
        if ($r.ExitCode -ne 0) { Write-Host ($r.StdErr -split "`r?`n" | Select-Object -First 10 | Out-String) }

        Write-Host "4) check what it wrote [$sl]"
        $plans = @(Get-ChildItem -LiteralPath $out -Filter 'Plan-*.json' -File -ErrorAction SilentlyContinue)
        $htmls = @(Get-ChildItem -LiteralPath $out -Filter 'RAMDoctor-*.html' -File -ErrorAction SilentlyContinue)
        Check ($plans.Count -eq 1) "[$sl] exactly one plan file (found $($plans.Count))"
        Check ($htmls.Count -eq 1) "[$sl] exactly one report file (found $($htmls.Count))"
        if ($plans.Count -ge 1) {
            $plan = $null
            try { $plan = Get-Content -LiteralPath $plans[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json; Check $true "[$sl] plan parses as JSON" } catch { Check $false ("[$sl] plan parses as JSON: " + $_.Exception.Message) }
            if ($plan) {
                $v = @(Test-RamPlan -Plan $plan)
                Check ($v.Count -eq 0) ("[$sl] plan satisfies the plan contract" + $(if ($v.Count) { ': ' + ($v | Select-Object -First 5) -join '; ' } else { '' }))
                Check ($plan.host -eq $env:COMPUTERNAME) "[$sl] plan is stamped with this computer name"
                Check ($plan.lang -eq $sl) "[$sl] plan records the language it was written in"
                Check ((([string]$plan.verdict.Headline) -match '[\u0600-\u06FF]') -eq ($sl -eq 'ar')) "[$sl] the verdict is written in that language"
            }
        }
        if ($htmls.Count -ge 1) {
            $html = [IO.File]::ReadAllText($htmls[0].FullName, [Text.Encoding]::UTF8)
            Check ($html -match '(?i)<!doctype html') "[$sl] report is an HTML document"
            Check ($html -match ('<html lang="{0}" dir="{1}">' -f $sl, $(if ($sl -eq 'ar') { 'rtl' } else { 'ltr' }))) "[$sl] report has the matching lang and direction"
            Check ($html -notmatch '(?i)<script[^>]+src\s*=') "[$sl] report loads no external script"
        }
        $all = @(Get-ChildItem -LiteralPath $out -Recurse -File -ErrorAction SilentlyContinue)
        $bytes = ($all | Measure-Object Length -Sum).Sum
        Check ($all.Count -le 3) "[$sl] light footprint: $($all.Count) file(s) written (limit 3)"
        Check ($bytes -lt 1MB) ("[$sl] light footprint: {0:N0} KB written (limit 1024 KB)" -f ($bytes / 1KB))
    }
}
finally {
    if ($u -and $u.Dest -and -not $KeepFiles) { Remove-TreeForce -Path $u.Dest }
    if ($KeepFiles) { Write-Host "kept: $work" } else { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($failures.Count) { Write-Host ("SMOKE TEST FAILED: {0} problem(s)" -f $failures.Count) -ForegroundColor Red; exit 1 }
Write-Host 'SMOKE TEST PASSED' -ForegroundColor Green
exit 0
