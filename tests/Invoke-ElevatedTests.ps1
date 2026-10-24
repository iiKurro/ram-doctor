#requires -Version 5.1
<#
.SYNOPSIS
  Runs every test tagged 'Elevated' - the ones that exercise code that only works as an administrator.

.DESCRIPTION
  tests\Elevated.Tests.ps1          locked-down quarantine store, hardened restore / purge, forged manifests, service
                                    start types, the native-helper loader
  tests\Unpacker.Tests.ps1 (part)   the %ProgramData%\RAM-Doctor-run unpack folder of the single-file edition

  On a normal session this script refuses to run (exit code 2): the Pester files themselves skip cleanly, but a CI job
  that silently skips everything would look green, so this runner insists on an administrator session and on a minimum
  number of tests that really ran.

  From an administrator console:
      powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-ElevatedTests.ps1
  The tests create only objects named RamDoctorTestCi-*/RamDoctorCiTest-* and remove them again (see the header of
  tests\Elevated.Tests.ps1 for the safety rules).

  Exit code: 0 = all passed, 1 = a test failed or too few tests ran, 2 = not an administrator session.
#>
[CmdletBinding()]
param(
    [switch]$InstallMissing,
    [string]$ResultsDir = '',
    [int]$MinPassed = 20
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
if (-not (Test-IsElevated)) {
    Write-Host 'These tests need an elevated (administrator) session. Open "Windows PowerShell (Admin)" and run this script again.' -ForegroundColor Red
    exit 2
}
if (-not $ResultsDir) { $ResultsDir = Join-Path ([IO.Path]::GetTempPath()) 'ramdoctor-checks' }
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

# Pester 5.5+ (CI pins an exact version through RAMDOC_PESTER_VERSION)
$wanted = $env:RAMDOC_PESTER_VERSION
$min = [version]'5.5.0'
$pick = { @(Get-Module -ListAvailable -Name Pester | Where-Object { if ($wanted) { $_.Version -eq [version]$wanted } else { $_.Version -ge $min } } | Sort-Object Version -Descending) }
$have = & $pick
if (-not $have -and $InstallMissing) {
    if ($wanted) { Install-Module Pester -RequiredVersion $wanted -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber }
    else { Install-Module Pester -MinimumVersion $min -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber }
    $have = & $pick
}
if (-not $have) { Write-Host 'Pester 5.5 or newer is required (pass -InstallMissing to install it for the current user).' -ForegroundColor Red; exit 1 }
Get-Module Pester | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module Pester -RequiredVersion $have[0].Version -Force

$files = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Filter '*.Tests.ps1' -File | Where-Object { $_.FullName -notmatch '[\\/]gui[\\/]' } | Sort-Object FullName)
$cfg = New-PesterConfiguration
$cfg.Run.Path = [string[]]($files | ForEach-Object { $_.FullName })
$cfg.Run.PassThru = $true
$cfg.Run.Exit = $false
$cfg.Filter.Tag = 'Elevated'
$cfg.Output.Verbosity = 'Detailed'
$cfg.TestResult.Enabled = $true
$cfg.TestResult.OutputFormat = 'NUnitXml'
$cfg.TestResult.OutputPath = (Join-Path $ResultsDir 'pester-elevated.xml')
Write-Host ("Pester {0}, administrator session, tag 'Elevated', {1} test file(s)" -f $have[0].Version, $files.Count)
$res = Invoke-Pester -Configuration $cfg

Write-Host ''
Write-Host ("passed {0}, failed {1}, skipped {2}" -f $res.PassedCount, $res.FailedCount, $res.SkippedCount)
foreach ($s in $res.Skipped) { Write-Host ("  skipped: " + $s.ExpandedPath) -ForegroundColor Yellow }
$bad = ($res.FailedCount -gt 0) -or ($res.FailedContainersCount -gt 0)
if ($bad) { Write-Host 'ELEVATED TESTS FAILED' -ForegroundColor Red; exit 1 }
if ($res.PassedCount -lt $MinPassed) { Write-Host ("only {0} elevated tests passed (expected at least {1}); too much was skipped" -f $res.PassedCount, $MinPassed) -ForegroundColor Red; exit 1 }
Write-Host 'ELEVATED TESTS PASSED' -ForegroundColor Green
exit 0
