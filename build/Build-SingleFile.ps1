# Developer tool: packs src\ into ONE self-extracting file, dist\RAM-Doctor.bat.
#
# The .bat is plain text and readable on purpose (no base64, no Invoke-Expression, no hidden window): a tool that
# looks for suspicious things should itself be easy to inspect, and opaque droppers are what antivirus flags.
# What the .bat does when double-clicked:  ask for admin rights -> unpack the readable scripts into
# %TEMP%\RAM-Doctor-run-xxxx -> open the window -> delete that folder when the window is closed.
[CmdletBinding()]
param([string]$OutFile = '')

$root = Split-Path $PSScriptRoot -Parent
$app = Join-Path $root 'src'
if (-not $OutFile) { New-Item -ItemType Directory -Force -Path (Join-Path $root 'dist') | Out-Null; $OutFile = Join-Path $root 'dist\RAM-Doctor.bat' }

$files = @('src\RAM-Doctor-GUI.ps1', 'src\RAM-Doctor.ps1', 'src\RAM-Doctor-Actions.ps1', 'src\lib\Report.ps1', 'src\lib\Native.cs', 'src\lib\Fluent.cs')

$header = @'
@echo off
rem  RAM Doctor - one-file edition.  Plain text: open it in Notepad to read exactly what it does.
rem  It unpacks the scripts below into a temp folder, opens the window, and removes the folder when you close it.
rem  It does not install anything, does not start with Windows, and sends nothing over the network.
setlocal
set "SELF=%~f0"
if /i "%~1"=="min" goto :started
start "" /min cmd /c ""%SELF%" min"
exit /b
:started
net session >nul 2>&1
if not errorlevel 1 goto :admin
if defined RAMDOC_NOELEVATE goto :admin
powershell -NoProfile -Command "Start-Process -FilePath $env:SELF -ArgumentList 'min' -Verb RunAs -WindowStyle Minimized"
exit /b
:admin
set "WORK=%TEMP%\RAM-Doctor-run-%RANDOM%%RANDOM%"
mkdir "%WORK%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8); foreach($m in [regex]::Matches($t,'(?ms)^#@@FILE (.+?)\r?\n(.*?)(?=^#@@FILE |\z)')){ $p=Join-Path $env:WORK $m.Groups[1].Value.Trim(); New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; [IO.File]::WriteAllText($p,$m.Groups[2].Value,(New-Object Text.UTF8Encoding($true))) }"
if not exist "%WORK%\src\RAM-Doctor-GUI.ps1" goto :failed
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%WORK%\src\RAM-Doctor-GUI.ps1" %RAMDOC_GUI_ARGS%
rmdir /s /q "%WORK%" >nul 2>&1
exit /b
:failed
echo Could not unpack RAM Doctor. Make sure the file is not blocked or damaged, then try again.
pause
exit /b 1
'@

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append(($header -replace "`r?`n", "`r`n")).Append("`r`n")
foreach ($f in $files) {
    $text = [IO.File]::ReadAllText((Join-Path $root $f), [Text.Encoding]::UTF8)   # strips the BOM; the unpacker adds it back
    $text = $text -replace "`r?`n", "`r`n"
    if (-not $text.EndsWith("`r`n")) { $text += "`r`n" }
    [void]$sb.Append("#@@FILE $f`r`n").Append($text)
}
[IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))   # no BOM: cmd must see '@echo off' first
$len = (Get-Item -LiteralPath $OutFile).Length
"Built {0}  ({1:N1} KB, {2} files inside)" -f $OutFile, ($len / 1KB), $files.Count
