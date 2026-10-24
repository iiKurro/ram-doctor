# Developer/test helper: runs the REAL unpack command of a built single-file edition (not a re-implementation),
# in "unpack only" mode (RAMDOC_UNPACK_ONLY=1: unpack, print the folder, do not start the window, do not delete),
# and optionally compares the unpacked files with the sources.
# It needs the TEST variant (Build-SingleFile.ps1 -DevHooks): the release file has no environment hooks, so no
# unpack-only mode. Both variants unpack the same payload and share the same unpack code (Build -Verify checks that).
#
#   $r = .\build\Expand-SingleFile.ps1 -Bat dist\RAM-Doctor.devhooks.bat -SourceRoot . -Cleanup
#   $r.Dest, $r.Mode, $r.Files, $r.Problems, $r.ExitCode
#
# -Mode Auto   secure folder (%ProgramData%\RAM-Doctor-run\<random>, administrators only) when this session is elevated,
#              the temp folder otherwise - exactly what the .bat decides for a real user
#      Temp    force the temp folder (a private TEMP is created for it; works everywhere)
#      Secure  force the secure folder (needs an elevated session)
# -Cleanup     delete the unpacked folder (and the private TEMP) before returning
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Bat,
    [string]$SourceRoot = '',
    [ValidateSet('Auto', 'Temp', 'Secure')][string]$Mode = 'Auto',
    [string]$PrivateTemp = '',
    [switch]$Cleanup,
    [int]$TimeoutSec = 90
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BuildCommon.ps1')

$Bat = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Bat)
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Mode -eq 'Auto') { $Mode = if ($elevated) { 'Secure' } else { 'Temp' } }
if ($Mode -eq 'Secure' -and -not $elevated) { throw 'Secure mode needs an elevated session (it unpacks into %ProgramData%).' }
$envMode = if ($Mode -eq 'Secure') { 'secure' } else { 'temp' }

# the header is plain text: rebuild the PowerShell command from its  set "P1=..."  pieces and the final  -Command "%P1% ..."  line
$lines = @(Get-Content -LiteralPath $Bat -Encoding UTF8 -TotalCount 80)
$pieces = @{}
$cmdLine = $null
foreach ($l in $lines) {
    if ($l -match '^set "(P\d+)=(.*)"\s*$') { $pieces[$Matches[1]] = $Matches[2] }
    elseif ($l -match '^"?[^"]*powershell\.exe"?\s.*-Command "(%P1%.*)"\s*$') { $cmdLine = $Matches[1] }
}
if (-not $cmdLine -or $pieces.Count -lt 3) { throw "No unpack command found in the header of $Bat" }
$inner = [regex]::Replace($cmdLine, '%(P\d+)%', { param($m) $pieces[$m.Groups[1].Value] })
if ($inner.Contains('"')) { throw 'The unpack command must not contain double quotes (cmd would mangle them).' }
# The release file has no unpack-only mode on purpose (no environment hooks). Tests use the -DevHooks variant, whose
# payload is byte-identical (Build-SingleFile.ps1 -Verify checks that).
if (-not $inner.Contains('RAMDOC_UNPACK_ONLY')) { throw "$Bat has no unpack-only mode: it is a release build. Build the test variant with  Build-SingleFile.ps1 -DevHooks  and expand that one." }

# the temp-folder variant needs a TEMP we can inspect and delete afterwards
$tempRoot = $null
if ($Mode -eq 'Temp') {
    $tempRoot = if ($PrivateTemp) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PrivateTemp) } else { Join-Path ([IO.Path]::GetTempPath()) ('ramdoc-expand-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $inner + '"'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.EnvironmentVariables['SELF'] = $Bat                 # the variables the .bat sets before running the command
$psi.EnvironmentVariables['RAMDOC_MODE'] = $envMode
$psi.EnvironmentVariables['RAMDOC_UNPACK_ONLY'] = '1'
if ($tempRoot) { $psi.EnvironmentVariables['TEMP'] = $tempRoot; $psi.EnvironmentVariables['TMP'] = $tempRoot }
$p = [System.Diagnostics.Process]::Start($psi)
$so = $p.StandardOutput.ReadToEndAsync()
$se = $p.StandardError.ReadToEndAsync()
if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { } ; throw "Unpacker timed out after $TimeoutSec s" }
$p.WaitForExit()

$dest = $null
if ($so.Result -match '(?m)^RAMDOC-WORK=(.+?)\s*$') { $dest = $Matches[1] }
$problems = New-Object System.Collections.Generic.List[string]
if ($p.ExitCode -ne 0) { $problems.Add("unpacker exit code $($p.ExitCode): $($se.Result.Trim())") }
if (-not $dest -or -not (Test-Path -LiteralPath $dest)) { $problems.Add('the unpacker did not report an existing folder') }

$extracted = @()
if ($dest -and (Test-Path -LiteralPath $dest)) {
    $extracted = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($dest.TrimEnd('\').Length + 1) })
    if ($SourceRoot) {
        $SourceRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourceRoot)
        $expected = Get-PackFiles -Root $SourceRoot
        foreach ($rel in $expected) {
            $got = Join-Path $dest $rel
            if (-not (Test-Path -LiteralPath $got)) { $problems.Add("missing after unpack: $rel"); continue }
            $a = [IO.File]::ReadAllBytes($got)
            $b = Get-ExpectedUnpackedBytes -Path (Join-Path $SourceRoot $rel)
            $same = ($a.Length -eq $b.Length)
            if ($same) { for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { $same = $false; break } } }
            if (-not $same) { $problems.Add("content differs from source: $rel") }
        }
        foreach ($x in $extracted) { if ($expected -notcontains $x) { $problems.Add("unexpected extra file: $x") } }
    }
}

$result = [pscustomobject]@{
    Dest = $dest; Mode = $Mode; ExitCode = $p.ExitCode; Files = $extracted; Problems = @($problems)
    StdOut = $so.Result; StdErr = $se.Result; TempRoot = $tempRoot
}
if ($Cleanup) {
    if ($dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
    if ($tempRoot -and -not $PrivateTemp) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
$result
