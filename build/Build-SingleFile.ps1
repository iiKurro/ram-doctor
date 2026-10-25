# Developer tool: packs src\ into ONE self-extracting file.
#
#   .\build\Build-SingleFile.ps1                  RELEASE build   dist\RAM-Doctor.bat (+ dist\SHA256SUMS.txt)   <- what users get
#   .\build\Build-SingleFile.ps1 -DevHooks        TEST build      dist\RAM-Doctor.devhooks.bat                   <- tests only, never published
#   .\build\Build-SingleFile.ps1 -Version 1.2.3   override the stamped version (default: build\VERSION)
#   .\build\Build-SingleFile.ps1 -Verify          also check the result (see below)
#
# The .bat is plain text and readable on purpose (no base64, no Invoke-Expression, no hidden window): a tool that
# looks for suspicious things should itself be easy to inspect, and opaque droppers are what antivirus flags.
# What the RELEASE file does when double-clicked:
#   ask for admin rights -> unpack the readable scripts into a folder that ONLY administrators can write to
#   (%ProgramData%\RAM-Doctor-run\<random>, created atomically with a locked ACL, verified before anything runs from it)
#   -> open the window -> delete that folder when the window is closed.
#
# NO ENVIRONMENT-CONTROLLED BEHAVIOUR in the release file: it runs elevated, and any variable a normal program can set
# (RAMDOC_GUI_ARGS, RAMDOC_NOELEVATE, ...) would let it steer an elevated process. The test hooks exist only in the
# -DevHooks variant, which has a different name, shows "TEST BUILD - not for distribution", and is never uploaded.
# Both variants carry byte-identical payloads; the headers differ only in the mode switch and the window launch line.
#
# The output is deterministic (no timestamps, fixed file order, CRLF) so the same sources always give the same SHA-256.
#
# -Verify (release):  no RAMDOC_ hook / -TestScript pass-through / extra environment read in the header (and no unknown
#                     RAMDOC_ name in the payload); payload identical to the test variant; the test variant unpacks to
#                     files byte-identical to the sources.
# -Verify (-DevHooks): the test variant unpacks to files byte-identical to the sources and carries the banner.
[CmdletBinding()]
param(
    [string]$OutFile = '',
    [string]$Version = '',
    [switch]$DevHooks,
    [switch]$Verify,
    [switch]$NoChecksum
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BuildCommon.ps1')

$root = Split-Path $PSScriptRoot -Parent
$releaseName = 'RAM-Doctor.bat'
$devName = 'RAM-Doctor.devhooks.bat'
if (-not $OutFile) {
    $dist = Join-Path $root 'dist'
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    $OutFile = Join-Path $dist $(if ($DevHooks) { $devName } else { $releaseName })
}
$OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
if ($DevHooks -and (Split-Path -Leaf $OutFile) -ieq $releaseName) { throw "Refusing to write the test build as '$releaseName': a build with test hooks must never look like the release file." }
$outDir = Split-Path -Parent $OutFile
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

if (-not $Version) {
    $vf = Join-Path $PSScriptRoot 'VERSION'
    if (Test-Path -LiteralPath $vf) { $Version = ([IO.File]::ReadAllText($vf)).Trim() } else { $Version = '0.0.0-dev' }
}
if ($Version -notmatch '^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$') { throw "Invalid version '$Version' (expected x.y.z)" }

$files = Get-PackFiles -Root $root

# ------------------------------------------------------------------------------------------------------------------
# The PowerShell command of the header, as readable steps P1..P6 (cmd.exe glues them together on one command line).
# Rules for every piece:
#   * no double quote (use [char]34) and no percent sign: inside the quotes of  set "..."  and  -Command "..."  everything
#     else (| & < > ^ ( ) ; ,) is literal, but those two would be expanded or would end the string
#   * every piece stays well under cmd's 8191-character line limit
# ------------------------------------------------------------------------------------------------------------------
# P1  setup: the only two accounts that may touch the unpack folder, by SID (works on every Windows language)
$P1 = @'
$ErrorActionPreference='Stop'; $q=[char]34; $rc=0; $w=$null; $sys='S-1-5-18'; $adm='S-1-5-32-544'; $trusted=@($sys,$adm);
'@
# P2  an ACL with inheritance switched off and full control for SYSTEM + Administrators only
$P2 = @'
function New-LockedAcl($o){ $s=New-Object Security.AccessControl.DirectorySecurity; $s.SetAccessRuleProtection($true,$false); foreach($x in $trusted){ $r=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($x)),'FullControl','ContainerInherit,ObjectInherit','None','Allow'); $s.AddAccessRule($r) }; if($o){ $s.SetOwner((New-Object Security.Principal.SecurityIdentifier($adm))) }; return $s };
'@
# P3  create a folder ALREADY locked (atomic), and check a folder afterwards: not a junction, owned by SYSTEM/Administrators,
#     inheritance off, no allow-rule for anybody else
$P3 = @'
function New-LockedDir($d){ try{ [void][IO.Directory]::CreateDirectory($d,(New-LockedAcl $true)) } catch { [void][IO.Directory]::CreateDirectory($d,(New-LockedAcl $false)) } }; function Test-LockedDir($d){ $i=New-Object IO.DirectoryInfo($d); if(-not $i.Exists){return $false}; if($i.Attributes -band [IO.FileAttributes]::ReparsePoint){return $false}; $a=$i.GetAccessControl(); if($trusted -notcontains $a.GetOwner([Security.Principal.SecurityIdentifier]).Value){return $false}; if(-not $a.AreAccessRulesProtected){return $false}; foreach($r in $a.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){ if($r.AccessControlType -eq 'Allow' -and $trusted -notcontains $r.IdentityReference.Value){return $false} }; return $true }; function Test-InUse($d){ $k=Join-Path $d 'in-use.lock'; if(-not (Test-Path -LiteralPath $k)){return $false}; try{ [IO.File]::Delete($k); return $false } catch { return $true } };
'@
# P4  pick the unpack folder (and remove leftovers older than a day, unless a running copy still holds their in-use.lock);
#     the secure folder must pass Test-LockedDir or we stop.
#     $secure is shared by both variants, so the test build exercises exactly the release code.
$secure = @'
$par=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'RAM-Doctor-run'; if(-not (Test-Path -LiteralPath $par)){ New-LockedDir $par }; if(-not (Test-LockedDir $par)){ throw 'the run folder is not locked down' }; foreach($d in Get-ChildItem -LiteralPath $par -Directory -Force){ if($d.LastWriteTime -lt $cut -and -not ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not (Test-InUse $d.FullName)){ Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue } }; $w=Join-Path $par ([guid]::NewGuid().ToString('N')); New-LockedDir $w; if(-not (Test-LockedDir $w)){ throw 'the unpack folder is not locked down' }
'@
$tempFolder = @'
foreach($d in Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'RAM-Doctor-run-*' -ErrorAction SilentlyContinue){ if($d.LastWriteTime -lt $cut -and -not (Test-InUse $d.FullName)){ Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue } }; $w=Join-Path $env:TEMP ('RAM-Doctor-run-'+[guid]::NewGuid().ToString('N').Substring(0,8)); [void][IO.Directory]::CreateDirectory($w)
'@
$P4release = 'try{ $cut=(Get-Date).AddDays(-1); ' + $secure.Trim() + ';'
$P4dev = 'try{ $cut=(Get-Date).AddDays(-1); if($env:RAMDOC_MODE -eq ''secure''){ ' + $secure.Trim() + ' } else { ' + $tempFolder.Trim() + ' };'
# P5  write every file found below this header into that folder (each one UTF-8 with BOM, as Windows PowerShell 5.1 needs)
$P5 = @'
$t=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8); foreach($m in [regex]::Matches($t,'(?ms)^#@@FILE (.+?)\r?\n(.*?)(?=^#@@FILE |\z)')){ $p=[IO.Path]::GetFullPath((Join-Path $w $m.Groups[1].Value.Trim())); if(-not $p.StartsWith($w+'\',[StringComparison]::OrdinalIgnoreCase)){ throw 'unexpected path in the package' }; [void][IO.Directory]::CreateDirectory((Split-Path $p)); [IO.File]::WriteAllText($p,$m.Groups[2].Value,(New-Object Text.UTF8Encoding($true))) }; $g=Join-Path $w 'src\RAM-Doctor-GUI.ps1'; if(-not (Test-Path -LiteralPath $g)){ throw 'the window script is missing' };
'@
# P6  run the window from there and wait for it, holding in-use.lock open meanwhile (so another start never sweeps a folder
#     that is still in use, however long the window stays open); always delete the folder afterwards
$P6release = @'
$lk=[IO.File]::Open((Join-Path $w 'in-use.lock'),'OpenOrCreate','ReadWrite','Read'); $a='-NoProfile -ExecutionPolicy Bypass -STA -File '+$q+$g+$q; [void](Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $a -NoNewWindow -Wait) } catch { [Console]::Error.WriteLine('Could not unpack RAM Doctor: '+$_.Exception.Message); $rc=90 } finally { if($lk){ $lk.Dispose() }; if($w){ Remove-Item -LiteralPath $w -Recurse -Force -ErrorAction SilentlyContinue } }; exit $rc
'@
$P6dev = @'
if($env:RAMDOC_UNPACK_ONLY){ [Console]::Out.WriteLine('RAMDOC-WORK='+$w) } else { $lk=[IO.File]::Open((Join-Path $w 'in-use.lock'),'OpenOrCreate','ReadWrite','Read'); $a='-NoProfile -ExecutionPolicy Bypass -STA -File '+$q+$g+$q+' '+$env:RAMDOC_GUI_ARGS; [void](Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $a -NoNewWindow -Wait) } } catch { [Console]::Error.WriteLine('Could not unpack RAM Doctor: '+$_.Exception.Message); $rc=90 } finally { if($lk){ $lk.Dispose() }; if($w -and -not $env:RAMDOC_UNPACK_ONLY){ Remove-Item -LiteralPath $w -Recurse -Force -ErrorAction SilentlyContinue } }; exit $rc
'@

function New-Header([bool]$Dev) {
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('@echo off')
    if ($Dev) {
        $l.Add('rem  TEST BUILD - not for distribution. This variant honours RAMDOC_* environment hooks (RAMDOC_NOELEVATE, RAMDOC_GUI_ARGS,')
        $l.Add('rem  RAMDOC_UNPACK_ONLY) so that the automated tests can drive it. The release file has no such hooks.')
    }
    $l.Add('rem  RAM Doctor {{VERSION}} - one-file edition.  Plain text: open it in Notepad to read exactly what it does.')
    $l.Add('rem  It unpacks the scripts below into a folder that only administrators can write to, opens the window,')
    $l.Add('rem  and removes the folder when you close it. It does not install anything, does not start with Windows,')
    $l.Add('rem  and sends nothing over the network unless you press Share and confirm.')
    $l.Add('rem  Copyright (c) 2026 7san. All rights reserved. Free for personal use, do not modify or sell:')
    $l.Add('rem  read the licence at https://github.com/iiKurro/ram-doctor/blob/main/LICENSE')
    if (-not $Dev) { $l.Add('rem  It reads no settings from the environment: nothing outside this file changes what it does.') }
    $l.Add('setlocal')
    if ($Dev) { $l.Add('echo TEST BUILD - not for distribution') }
    $l.Add('set "SELF=%~f0"')
    $l.Add('rem  Never run anything found in the current folder (Downloads may hold a planted "powershell.exe"): work from System32')
    $l.Add('rem  and call every tool by its full path.')
    $l.Add('cd /d "%SystemRoot%\System32"')
    $l.Add('if /i "%~1"=="min" goto :started')
    $l.Add('start "" /min "%SystemRoot%\System32\cmd.exe" /c ""%SELF%" min"')
    $l.Add('exit /b')
    $l.Add(':started')
    if ($Dev) {
        $l.Add('rem  RAMDOC_MODE=secure -> unpack into the administrators-only folder.  "temp" is only for tests on a non-admin session.')
        $l.Add('set "RAMDOC_MODE=secure"')
        $l.Add('"%SystemRoot%\System32\net.exe" session >nul 2>&1')
        $l.Add('if not errorlevel 1 goto :admin')
        $l.Add('if not defined RAMDOC_NOELEVATE goto :elevate')
        $l.Add('set "RAMDOC_MODE=temp"')
        $l.Add('goto :admin')
        $l.Add(':elevate')
    } else {
        $l.Add('"%SystemRoot%\System32\net.exe" session >nul 2>&1')
        $l.Add('if not errorlevel 1 goto :admin')
    }
    $l.Add('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "Start-Process -FilePath $env:SELF -ArgumentList ''min'' -Verb RunAs -WindowStyle Minimized"')
    $l.Add('exit /b')
    $l.Add(':admin')
    $l.Add('rem  The next lines are ONE PowerShell command, written as readable steps (cmd glues %P1% ... %P6% together below).')
    $l.Add('rem  P1  setup: the only two accounts that may touch the unpack folder, by SID (works on every Windows language)')
    $l.Add('set "P1=' + $P1.Trim() + '"')
    $l.Add('rem  P2  an ACL with inheritance switched off and full control for SYSTEM + Administrators only')
    $l.Add('set "P2=' + $P2.Trim() + '"')
    $l.Add('rem  P3  create a folder ALREADY locked (atomic, no window in which anyone else can write), and check a folder afterwards:')
    $l.Add('rem      not a junction, owned by SYSTEM/Administrators, inheritance off, no allow-rule for anybody else')
    $l.Add('set "P3=' + $P3.Trim() + '"')
    $l.Add('rem  P4  pick the unpack folder (and remove leftovers older than a day that no running copy holds); it must pass Test-LockedDir or we stop')
    $l.Add('set "P4=' + $(if ($Dev) { $P4dev } else { $P4release }) + '"')
    $l.Add('rem  P5  write every file found below this header into that folder (each one UTF-8 with BOM, as Windows PowerShell 5.1 needs)')
    $l.Add('set "P5=' + $P5.Trim() + '"')
    $l.Add('rem  P6  run the window from there and wait for it (in-use.lock stays open meanwhile); always delete the folder afterwards')
    $l.Add('set "P6=' + $(if ($Dev) { $P6dev.Trim() } else { $P6release.Trim() }) + '"')
    $l.Add('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "%P1% %P2% %P3% %P4% %P5% %P6%"')
    $l.Add('if "%errorlevel%"=="90" goto :failed')
    $l.Add('exit /b')
    $l.Add(':failed')
    $l.Add('echo Could not unpack RAM Doctor. Make sure the file is not blocked or damaged, then try again.')
    $l.Add('pause')
    $l.Add('exit /b 1')
    return (($l -join "`r`n") + "`r`n")
}

function New-SingleFileText([bool]$Dev) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((New-Header $Dev).Replace('{{VERSION}}', $Version)).Append("`r`n")
    foreach ($f in $files) {
        $text = Get-PackText -Path (Join-Path $root $f)
        if ($text -match '(?m)^#@@FILE ') { throw "$f contains a line starting with '#@@FILE ', which would break the unpacker" }
        [void]$sb.Append("#@@FILE $f`r`n").Append($text)
    }
    return $sb.ToString()
}
function Write-NoBom([string]$Path, [string]$Text) {
    # No BOM: cmd must see '@echo off' as the very first bytes.
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

Write-NoBom $OutFile (New-SingleFileText $DevHooks.IsPresent)
$hash = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not $NoChecksum -and -not $DevHooks) {
    $sumFile = Join-Path $outDir 'SHA256SUMS.txt'
    # "sha256sum -c" format: <hash><two spaces><name>, LF line ending, no BOM.
    [IO.File]::WriteAllText($sumFile, ("{0}  {1}`n" -f $hash, (Split-Path -Leaf $OutFile)), (New-Object System.Text.UTF8Encoding($false)))
}

$len = (Get-Item -LiteralPath $OutFile).Length
Write-Host ("Built {0}  v{1}  {2}  ({3:N1} KB, {4} files inside)" -f $OutFile, $Version, $(if ($DevHooks) { 'TEST BUILD (environment hooks, not for distribution)' } else { 'RELEASE' }), ($len / 1KB), $files.Count)
Write-Host ("SHA-256 {0}" -f $hash)

if ($Verify) {
    $expand = Join-Path $PSScriptRoot 'Expand-SingleFile.ps1'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ramdoc-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        if ($DevHooks) {
            $top = (Get-Content -LiteralPath $OutFile -TotalCount 4) -join "`n"
            if ((Split-Path -Leaf $OutFile) -ieq $releaseName -or $top -notmatch 'TEST BUILD - not for distribution') { throw 'Verify FAILED: the test build lacks its "TEST BUILD - not for distribution" banner.' }
            $devFile = $OutFile
        } else {
            # 1) the release file steers nothing from the environment
            $bad = @(Get-ReleaseHygieneProblems -Path $OutFile)
            if ($bad.Count -gt 0) { throw ("Verify FAILED: the release build has environment-controlled behaviour:`n  " + ($bad -join "`n  ")) }
            # 2) it carries exactly the payload the tests run against
            $devFile = Join-Path $tmp $devName
            Write-NoBom $devFile (New-SingleFileText $true)
            $a = Split-SingleFile -Path $OutFile; $b = Split-SingleFile -Path $devFile
            if ($a.Payload -cne $b.Payload) { throw 'Verify FAILED: the release payload differs from the test-build payload.' }
            Write-Host 'Verify OK: no environment hooks in the release header; payload identical to the test build.'
        }
        # 3) the (test) variant unpacks to files byte-identical to the sources
        $r = & $expand -Bat $devFile -SourceRoot $root -Cleanup
        if ($r.ExitCode -ne 0 -or $r.Problems.Count -gt 0) { throw ("Verify FAILED:`n  " + ($r.Problems -join "`n  ") + "`n  " + $r.StdErr) }
        Write-Host ("Verify OK ({0} mode): {1} files unpacked byte-identical to their sources (BOM + CRLF normalized)." -f $r.Mode, $r.Files.Count)
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
