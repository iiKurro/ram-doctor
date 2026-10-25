#requires -Version 5.1
<#
.SYNOPSIS
  The ONLY part of RAM Doctor that changes anything. Always explicit, always reversible until Purge.

.DESCRIPTION
  Quarantine : choose suspects from the latest scan plan. For each one it stops the running process,
               disables the startup entries that relaunch it (service / task / Run key / startup folder /
               driver / WMI), and MOVES the file into a quarantine folder renamed *.quar. Nothing is deleted.
  Restore    : undo a quarantine batch exactly (files, services, tasks, Run values, driver start type).
  Purge      : permanently delete the quarantined files (typed confirmation). The only destructive step.
  List       : show quarantine batches.

  Windows / Microsoft-signed files and anything under %WINDIR% are never quarantined.

  SECURITY MODEL (read this before changing anything)
  ---------------------------------------------------
  This script normally runs ELEVATED, and it consumes two kinds of input that a standard user or a
  user-level program may be able to write:
    1. The scan plan (Plan-*.json) lives on the user's Desktop, i.e. it is USER-WRITABLE input to an
       elevated process. That is why nothing in it is trusted: every target is re-verified LIVE right
       before it is touched (canonical local path, SHA-256 of the file, signature, protected locations,
       PID + start time, service/task names without wildcards, Run keys only in the known Run locations).
    2. The quarantine store (C:\ProgramData\RAM-Doctor) holds manifest.json files that Restore/Purge
       act on. When elevated the store root is locked down (inheritance off; FullControl only for SYSTEM
       S-1-5-18 and Administrators S-1-5-32-544, by SID so it works on any Windows language), re-verified
       on every run (not a junction, owner is SYSTEM/Administrators), and a batch folder that is a
       reparse point or owned by anyone else is ignored. Even then Restore/Purge treat the manifest as
       untrusted: stored files must sit directly inside that batch's files\ folder, their SHA-256 must
       match the hash recorded when they were quarantined, restore destinations must be plain local
       drive paths outside protected locations, existing files are never overwritten, and registry /
       service / task restores only touch known, existing, wildcard-free targets.
  Test mode (-AllowNonAdmin with a temp -StoreDir) skips the ACL/owner part (nothing to protect against
  an elevated attacker there) but keeps every path/hash/target check.
#>
[CmdletBinding()]
param(
    [ValidateSet('Quarantine', 'Restore', 'Purge', 'List')][string]$Mode = 'Quarantine',
    [string]$Plan = '',
    [string]$Select = '',          # suspect numbers from the report, e.g. "1,3" (a string on purpose: "-File x -Select 1,2" would otherwise become 12)
    [switch]$IncludeLow,           # also offer low-risk items
    [switch]$Yes,                  # skip the typed confirmations (for scripted use)
    [switch]$NoRestorePoint,
    [string]$Batch = '',           # Restore / Purge: batch folder name; default = ask / latest
    [int]$OlderThanDays = -1,      # Purge: delete every batch older than N days
    [string]$StoreDir = '',        # where quarantine data lives (default C:\ProgramData\RAM-Doctor)
    [switch]$AllowNonAdmin,        # testing only: lets the user-level parts run without elevation
    [switch]$LoadFunctionsOnly     # testing only: define the functions and return (tests/fixtures/Test-ActionsHardening.ps1)
)

$ErrorActionPreference = 'Continue'
$ToolVersion = '1.0.1'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }
$WinDir = $env:SystemRoot.TrimEnd('\')
$WinDirL = $WinDir.ToLowerInvariant()
$DataRoot = if ($StoreDir) { $StoreDir.TrimEnd('\') } else { Join-Path $env:ProgramData 'RAM-Doctor' }
$QRoot = Join-Path $DataRoot 'Quarantine'
$Stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', $Inv)     # invariant: Arabic/Saudi cultures would otherwise give Hijri years
$LogFile = Join-Path $DataRoot "actions-$Stamp.log"
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$SelectIds = @($Select -split '[,;\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:Hardened = $IsAdmin          # ACL / owner enforcement only matters when we are the elevated side
$script:RedCount = 0                 # number of error-coloured log lines (decides whether a restore fully succeeded)

$SidSystem = 'S-1-5-18'
$SidAdmins = 'S-1-5-32-544'
$SidTrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$TrustedOwners = @($SidSystem, $SidAdmins, $SidTrustedInstaller)

# processes that must never be killed from here (killing them blue-screens or logs the user out);
# a masquerader with one of these names OUTSIDE %WINDIR% is not covered by this list.
$CriticalProcNames = @('csrss', 'wininit', 'winlogon', 'smss', 'lsass', 'services', 'system', 'registry', 'memory compression', 'lsm', 'svchost', 'dwm', 'fontdrvhost', 'audiodg', 'msmpeng', 'securityhealthservice')
# essential Windows services that are never disabled even if a plan asks for it
$EssentialServices = @('RpcSs', 'RpcEptMapper', 'DcomLaunch', 'PlugPlay', 'Power', 'SamSs', 'EventLog', 'Winmgmt', 'BFE', 'mpssvc', 'WinDefend', 'CryptSvc', 'TrustedInstaller',
    'Dhcp', 'Dnscache', 'gpsvc', 'Schedule', 'ProfSvc', 'UserManager', 'StateRepository', 'LSM', 'SystemEventsBroker', 'TimeBrokerSvc', 'BrokerInfrastructure',
    'CoreMessagingRegistrar', 'nsi', 'wscsvc', 'Wcmsvc', 'netprofm', 'NlaSvc', 'LanmanWorkstation', 'KeyIso', 'sppsvc', 'WpnService', 'Themes', 'Audiosrv', 'AudioEndpointBuilder')
$RunLocRegex = '^(HKLM:\\SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Run(Once)?|HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run(Once)?|Registry::HKEY_USERS\\S-1-5-21-[0-9-]+\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run(Once)?)$'
$StartupRegex = '^[A-Za-z]:\\(ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\StartUp|Users\\[^\\]+\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup)\\[^\\]+$'
$WmiConsumerClasses = @('CommandLineEventConsumer', 'ActiveScriptEventConsumer', 'NTEventLogEventConsumer', 'LogFileEventConsumer', 'SMTPEventConsumer')

# ------------------------------------------------------------------------------------------ logging
function Log([string]$m, [string]$color = '') {
    if ($color -eq 'Red') { $script:RedCount++ }
    $line = '[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss', $Inv), $m
    if ($color) { Write-Host $line -ForegroundColor $color } else { Write-Host $line }
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}
function IsoDate($d) { if ($d) { ([datetime]$d).ToString('yyyy-MM-dd HH:mm:ss', $Inv) } else { '' } }

# ------------------------------------------------------------------------------------------ path safety
function Get-FullPathSafe([string]$p) {
    try { if ([string]::IsNullOrWhiteSpace($p)) { return $null }; return [IO.Path]::GetFullPath($p) } catch { return $null }
}

# plain, canonical, rooted LOCAL drive path ("C:\dir\file"): no UNC (\\server\x), no device/extended paths (\\?\ \\.\),
# no relative paths, no alternate data streams, no wildcards, no ".." segments.
function Test-LocalDrivePath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    if ($p -notmatch '^[A-Za-z]:\\') { return $false }
    if ($p.Substring(2) -match '[:*?"<>|]') { return $false }
    if ($p -match '(^|\\)\.\.?(\\|$)') { return $false }
    $full = Get-FullPathSafe $p
    if (-not $full) { return $false }
    if ($full -ieq $p) { return $true }
    # .NET expands 8.3 short names (C:\Users\NAME~1\...\Temp is how %TEMP% is very often spelled), so the
    # normalised and the given path may differ ONLY in such segments - that is still a plain local path.
    $sa = $full -split '\\'; $sb = $p -split '\\'
    if ($sa.Count -ne $sb.Count) { return $false }
    for ($i = 0; $i -lt $sa.Count; $i++) {
        if ($sa[$i] -ieq $sb[$i]) { continue }
        if ($sb[$i] -match '^[^~\\/:*?"<>|.]{1,6}~\d{1,6}(\.[^.~]{0,3})?$') { continue }
        return $false
    }
    return $true
}

function Test-ProtectedPath([string]$p) {
    if (-not $p) { return $false }
    $l = (Get-FullPathSafe $p)
    if (-not $l) { return $true }                    # cannot be normalised -> treat as protected
    $l = $l.ToLowerInvariant()
    if ($l -eq $WinDirL -or $l.StartsWith($WinDirL + '\')) { return $true }
    $guard = @("$env:ProgramFiles\Windows Defender", "${env:ProgramFiles(x86)}\Windows Defender", "$env:ProgramData\Microsoft\Windows Defender",
        "$env:ProgramFiles\WindowsApps\Microsoft.", $Root, $DataRoot)
    foreach ($g in $guard) {
        if (-not $g) { continue }
        $gl = ([string]$g).ToLowerInvariant().TrimEnd('\')
        if ($l -eq $gl -or $l.StartsWith($gl + '\') -or ($gl.EndsWith('.') -and $l.StartsWith($gl))) { return $true }
    }
    return $false
}

function Test-IsReparse([string]$p) {
    try { $i = Get-Item -LiteralPath $p -Force -ErrorAction Stop; return [bool]($i.Attributes -band [IO.FileAttributes]::ReparsePoint) } catch { return $false }
}

# every existing ancestor of $path must be a real folder, or a junction/symlink whose target is a plain, unprotected local path
function Test-AncestorsSafe([string]$path) {
    $dir = Split-Path -Parent $path
    $chain = @()
    while ($dir -and $dir.Length -gt 3) { $chain += $dir; $dir = Split-Path -Parent $dir }
    foreach ($a in $chain) {
        if (-not (Test-Path -LiteralPath $a)) { continue }
        $item = Get-Item -LiteralPath $a -Force -ErrorAction SilentlyContinue
        # only real junctions / symlinks redirect a path; other reparse points (OneDrive/cloud placeholders, dedup...) do not
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and @('Junction', 'SymbolicLink') -contains [string]$item.LinkType) {
            $t = @($item.Target)[0]
            if (-not $t -or -not (Test-LocalDrivePath ([string]$t)) -or (Test-ProtectedPath ([string]$t))) { return $false }
        }
    }
    return $true
}

# $path must sit DIRECTLY inside $dir (flat store layout), after normalisation
function Test-DirectlyInside([string]$path, [string]$dir) {
    $fp = Get-FullPathSafe $path; $fd = Get-FullPathSafe $dir
    if (-not $fp -or -not $fd) { return $false }
    return ((Split-Path -Parent $fp) -ieq $fd.TrimEnd('\'))
}

function Test-MicrosoftSigned([string]$p) {
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $p -ErrorAction Stop
        return ($s.Status -eq 'Valid' -and $s.SignerCertificate -and $s.SignerCertificate.Subject -match 'O=Microsoft (Corporation|Windows)')
    } catch { return $false }
}

# Moves without ever overwriting (File.Move throws if the destination exists). Retries only for locked sources.
function Move-NoOverwrite([string]$src, [string]$dst) {
    for ($i = 0; $i -lt 4; $i++) {
        if (Test-Path -LiteralPath $dst) { return $false }
        try { [IO.File]::Move($src, $dst); return $true } catch { Start-Sleep -Milliseconds 700 }
    }
    return $false
}
function Get-FreeName([string]$dst) {
    if (-not (Test-Path -LiteralPath $dst)) { return $dst }
    for ($n = 1; $n -le 50; $n++) { $c = if ($n -eq 1) { "$dst.restored" } else { "$dst.restored$n" }; if (-not (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}
function Get-Sha256([string]$p) { try { return (Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return '' } }

# ------------------------------------------------------------------------------------------ names / registry targets
# service, driver and task names go into sc.exe / registry paths / cmdlets that accept wildcards: allow only plain names
function Test-SafeServiceName([string]$n) { return ($n -match '^[A-Za-z0-9_][A-Za-z0-9_.\-@ ]{0,255}$') }
function Test-SafeTaskName([string]$n) { return ($n -and $n -notmatch '[\\/*?\[\]:"<>|]' -and $n.Length -le 255) }
function Test-SafeTaskPath([string]$p) { return ($p -match '^\\([^\\/*?\[\]:"<>|]+\\)*$') }

function Open-RegKey([string]$psPath, [bool]$writable) {
    $p = $psPath -replace '^Registry::', ''
    $p = $p -replace '^HKLM:', 'HKEY_LOCAL_MACHINE' -replace '^HKCU:', 'HKEY_CURRENT_USER'
    $parts = $p -split '\\', 2
    if ($parts.Count -lt 2) { return $null }
    $hive = switch ($parts[0]) {
        'HKEY_LOCAL_MACHINE' { [Microsoft.Win32.Registry]::LocalMachine }
        'HKEY_CURRENT_USER' { [Microsoft.Win32.Registry]::CurrentUser }
        'HKEY_USERS' { [Microsoft.Win32.Registry]::Users }
        default { $null }
    }
    if (-not $hive) { return $null }
    return $hive.OpenSubKey($parts[1], $writable)
}

function Get-StartCode([string]$name) {
    if (-not (Test-SafeServiceName $name)) { return $null }
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
    try {
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
        return [pscustomobject]@{ Start = [int]$p.Start; Delayed = [int]$p.DelayedAutostart }
    } catch { return $null }
}
function Set-StartCode([string]$name, [int]$start, [int]$delayed) {
    if (-not (Test-SafeServiceName $name)) { return $false }
    $arg = switch ($start) { 0 { 'boot' } 1 { 'system' } 2 { if ($delayed -eq 1) { 'delayed-auto' } else { 'auto' } } 3 { 'demand' } default { 'disabled' } }
    $null = & sc.exe config $name start= $arg 2>&1
    return ($LASTEXITCODE -eq 0)
}

# ------------------------------------------------------------------------------------------ store security
function Get-OwnerSid([string]$p) {
    try { $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop; return $item.GetAccessControl().GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { return '' }
}

# Is the store root locked down? (not a junction, trusted owner, inheritance off, only SYSTEM + Administrators have allow-ACEs)
function Test-StoreRootSecure([string]$dir) {
    $r = [pscustomobject]@{ Secure = $false; Reason = '' }
    try {
        $di = New-Object IO.DirectoryInfo($dir)
        if (-not $di.Exists) { $r.Reason = 'folder does not exist'; return $r }
        if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { $r.Reason = 'folder is a reparse point / junction'; return $r }
        $acl = $di.GetAccessControl()
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($TrustedOwners -notcontains $owner) { $r.Reason = "owner is $owner (not SYSTEM/Administrators)"; return $r }
        if (-not $acl.AreAccessRulesProtected) { $r.Reason = 'inherited permissions are still enabled'; return $r }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            if (@($SidSystem, $SidAdmins) -notcontains $rule.IdentityReference.Value) { $r.Reason = "unexpected access rule for $($rule.IdentityReference.Value)"; return $r }
        }
        $r.Secure = $true
    } catch { $r.Reason = "cannot read permissions: $($_.Exception.Message)" }
    return $r
}

function New-StoreSecurity([bool]$WithOwner = $true) {
    $sec = New-Object Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)          # no inheritance, drop inherited ACEs
    $inh = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in @($SidSystem, $SidAdmins)) {
        $id = New-Object Security.Principal.SecurityIdentifier($sid)
        $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id, [Security.AccessControl.FileSystemRights]::FullControl, $inh, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
    }
    if ($WithOwner) { try { $sec.SetOwner((New-Object Security.Principal.SecurityIdentifier($SidAdmins))) } catch { } }
    return $sec
}
function Protect-StoreRoot([string]$dir) {
    $di = New-Object IO.DirectoryInfo($dir)
    # owner = Administrators needs a privilege that only an elevated token has; without it still apply the DACL
    try { $di.SetAccessControl((New-StoreSecurity $true)) } catch { $di.SetAccessControl((New-StoreSecurity $false)) }
}

# Creates (atomically locked down) or verifies/repairs the store root. Returns $false when it cannot be trusted.
function Initialize-StoreRoot {
    try {
        if (-not $script:Hardened) { [void][IO.Directory]::CreateDirectory($QRoot); return $true }     # test mode
        if (Test-Path -LiteralPath $DataRoot) {
            $chk = Test-StoreRootSecure $DataRoot
            if (-not $chk.Secure) {
                if ($chk.Reason -match 'reparse|owner is') {
                    # a folder somebody else created/owns (or a junction): never reuse its content, move it aside
                    $aside = "$DataRoot.untrusted-$Stamp"
                    try { [IO.Directory]::Move($DataRoot, $aside); Log "Existing store folder was not trustworthy ($($chk.Reason)); moved to $aside" 'Yellow' }
                    catch { Log "refusing to use $DataRoot ($($chk.Reason)) and could not move it aside: $($_.Exception.Message)" 'Red'; return $false }
                } else {
                    Log "Store folder permissions were too open ($($chk.Reason)) - locking it down." 'Yellow'
                    Protect-StoreRoot $DataRoot
                }
            }
        }
        if (-not (Test-Path -LiteralPath $DataRoot)) { [void][IO.Directory]::CreateDirectory($DataRoot, (New-StoreSecurity)) }   # created already locked down
        $chk = Test-StoreRootSecure $DataRoot
        if (-not $chk.Secure -and $chk.Reason -match 'owner is') { try { Protect-StoreRoot $DataRoot } catch { }; $chk = Test-StoreRootSecure $DataRoot }   # one more try at making Administrators the owner
        if (-not $chk.Secure) { Log "refusing to use the quarantine store: $($chk.Reason)" 'Red'; return $false }
        [void][IO.Directory]::CreateDirectory($QRoot)
        if (Test-IsReparse $QRoot) { Log 'refusing to use the quarantine store: Quarantine folder is a reparse point' 'Red'; return $false }
        return $true
    } catch { Log "refusing to use the quarantine store: $($_.Exception.Message)" 'Red'; return $false }
}

# a batch folder is trusted when it is a real folder (not a junction) and owned by SYSTEM / Administrators
function Test-BatchTrusted([string]$dir) {
    if (Test-IsReparse $dir) { return $false }
    $fd = Join-Path $dir 'files'
    if ((Test-Path -LiteralPath $fd) -and (Test-IsReparse $fd)) { return $false }
    $mf = Join-Path $dir 'manifest.json'
    if (Test-IsReparse $mf) { return $false }
    if ($script:Hardened) { foreach ($p in @($dir, $mf)) { if ($TrustedOwners -notcontains (Get-OwnerSid $p)) { return $false } } }
    return $true
}

function Save-Manifest($manifest, [string]$dir) {
    [IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 10), $Utf8Bom)
}
function Get-Batches {
    if (-not (Test-Path -LiteralPath $QRoot)) { return @() }
    $out = New-Object System.Collections.ArrayList
    foreach ($d in @(Get-ChildItem -LiteralPath $QRoot -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'manifest.json') -PathType Leaf)) { continue }
        if (-not (Test-BatchTrusted $d.FullName)) { Log "ignoring untrusted batch folder '$($d.Name)' (reparse point or not owned by SYSTEM/Administrators)" 'Yellow'; continue }
        [void]$out.Add($d)
    }
    return @($out)
}
function Read-Manifest([string]$dir) {
    try {
        $m = Get-Content -LiteralPath (Join-Path $dir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $m) { return $null }
        return $m
    } catch { return $null }
}

function Select-Batch {
    $all = @(Get-Batches)
    if ($all.Count -eq 0) { Log 'No quarantine batches found.' 'Yellow'; return $null }
    if ($Batch) { $m = $all | Where-Object { $_.Name -eq $Batch } | Select-Object -First 1; if (-not $m) { Log "Batch '$Batch' not found (or not trusted)." 'Red' }; return $m }
    if ($all.Count -eq 1 -or $Yes) { return $all[0] }
    for ($i = 0; $i -lt $all.Count; $i++) { $mm = Read-Manifest $all[$i].FullName; Write-Host ("  [{0}] {1}  ({2} item(s){3})" -f ($i + 1), $all[$i].Name, @($mm.entries).Count, $(if ($mm.purgedAt) { ', purged' } else { '' })) }
    $a = Read-Host 'Choose batch number (Enter = latest)'
    if (-not $a) { return $all[0] }
    $idx = 0; if ([int]::TryParse($a, [ref]$idx) -and $idx -ge 1 -and $idx -le $all.Count) { return $all[$idx - 1] }
    return $null
}

# ------------------------------------------------------------------------------------------ hardened restore helpers
function Restore-StoredFile($op, [string]$batchDir) {
    $filesDir = Join-Path $batchDir 'files'
    $stored = [string]$op.stored
    if (-not $stored -or -not (Test-DirectlyInside $stored $filesDir) -or ([IO.Path]::GetFileName($stored) -notmatch '^\d{3}_.+\.quar$')) {
        Log "refusing to restore: stored file is not directly inside this batch's files folder ($stored)" 'Red'; return
    }
    if (-not (Test-Path -LiteralPath $stored -PathType Leaf)) { Log "   stored file missing: $stored" 'Yellow'; return }
    if (Test-IsReparse $stored) { Log "refusing to restore: stored file is a reparse point ($stored)" 'Red'; return }
    $want = if ($op.storedSha256) { [string]$op.storedSha256 } elseif ($op.sha256) { [string]$op.sha256 } else { '' }
    if (-not $want) { Log "refusing to restore: no SHA-256 was recorded for $([IO.Path]::GetFileName($stored))" 'Red'; return }
    $have = Get-Sha256 $stored
    if (-not $have -or $have -ine $want) { Log "refusing to restore: stored file does not match the SHA-256 recorded at quarantine time ($([IO.Path]::GetFileName($stored)))" 'Red'; return }
    $dst = [string]$op.original
    if (-not (Test-LocalDrivePath $dst)) { Log "refusing to restore: destination is not a plain local drive path ($dst)" 'Red'; return }
    if ($op.type -eq 'MoveStartupFile' -and $dst -notmatch $StartupRegex) { Log "refusing to restore: startup shortcut destination is not a Startup folder ($dst)" 'Red'; return }
    if (Test-ProtectedPath $dst) { Log "refusing to restore: destination is in a protected location ($dst)" 'Red'; return }
    if (-not (Test-AncestorsSafe $dst)) { Log "refusing to restore: destination path passes through a junction/symlink ($dst)" 'Red'; return }
    $final = Get-FreeName $dst
    if (-not $final) { Log "refusing to restore: could not find a free file name next to $dst" 'Red'; return }
    if ($final -ne $dst) { Log "   original path is occupied (never overwritten), restoring as $final" 'Yellow' }
    try { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $final)) } catch { Log "could not create folder for $final" 'Red'; return }
    if (Move-NoOverwrite $stored $final) { Log "   file restored: $final" 'Green' } else { Log "   could not restore $final" 'Red' }
}

function Restore-StartType($op) {
    $name = [string]$op.name
    if (-not (Test-SafeServiceName $name)) { Log "refusing to restore start type: unsafe service/driver name '$name'" 'Red'; return }
    if (-not (Get-StartCode $name)) { Log "   $name no longer exists; nothing to restore" 'Yellow'; return }
    $ps = -1; $pd = -1
    if (-not [int]::TryParse([string]$op.prevStart, [ref]$ps) -or @(2, 3, 4) -notcontains $ps) { Log "refusing to restore start type of ${name}: value '$($op.prevStart)' is not allowed" 'Red'; return }
    if (-not [int]::TryParse([string]$op.prevDelayed, [ref]$pd) -or @(0, 1) -notcontains $pd) { $pd = 0 }
    if (Set-StartCode $name $ps $pd) { Log "   $($op.type) undone: $name start=$ps" 'Green' } else { Log "   failed to restore start type of $name" 'Red' }
}

function Restore-Task($op) {
    $tp = [string]$op.taskPath; $tn = [string]$op.taskName
    if (-not (Test-SafeTaskPath $tp) -or -not (Test-SafeTaskName $tn)) { Log "refusing to re-enable task: unsafe name '$tp$tn'" 'Red'; return }
    try {
        $t = @(Get-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction Stop)
        if ($t.Count -ne 1) { Log "refusing to re-enable task '$tp$tn': it does not match exactly one task" 'Red'; return }
        if ($t[0].State -ne 'Disabled') { Log "   task '$tn' is not disabled; left as is" 'Yellow'; return }
        Enable-ScheduledTask -InputObject $t[0] -ErrorAction Stop | Out-Null
        Log "   task re-enabled: $tn" 'Green'
    } catch { Log "task restore failed: $($_.Exception.Message)" 'Red' }
}

function Restore-RunValue($op) {
    $loc = [string]$op.location; $name = [string]$op.name; $kind = [string]$op.kind
    if ($loc -notmatch $RunLocRegex) { Log "refusing to restore Run value: '$loc' is not a known Run key" 'Red'; return }
    if (@('String', 'ExpandString') -notcontains $kind) { Log "refusing to restore Run value '$name': kind '$kind' is not allowed" 'Red'; return }
    if (-not $name -or $name.Length -gt 255 -or $name -match '[\x00-\x1f]') { Log 'refusing to restore Run value: unsafe value name' 'Red'; return }
    try {
        $key = Open-RegKey $loc $true
        if (-not $key) { Log "could not open $loc" 'Red'; return }
        try {
            if ($null -ne $key.GetValue($name)) { Log "   Run value '$name' already exists; not overwritten" 'Yellow'; return }
            $key.SetValue($name, [string]$op.value, [Microsoft.Win32.RegistryValueKind]$kind)
            Log "   Run value restored: $name" 'Green'
        } finally { $key.Close() }
    } catch { Log "Run value restore failed: $($_.Exception.Message)" 'Red' }
}

# deletes the quarantined files of one batch; never follows junctions/symlinks
function Remove-BatchFiles([string]$batchDir) {
    $fd = Join-Path $batchDir 'files'
    if (-not (Test-Path -LiteralPath $fd)) { return }
    if (Test-IsReparse $fd) { Log "refusing to purge: files folder of $batchDir is a reparse point" 'Red'; return }
    foreach ($f in @(Get-ChildItem -LiteralPath $fd -Force -ErrorAction SilentlyContinue)) {
        if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { Log "refusing to delete reparse point '$($f.Name)'" 'Red'; continue }
        if ($f.PSIsContainer) { Log "refusing to delete unexpected folder '$($f.Name)'" 'Red'; continue }
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { Log "could not delete '$($f.Name)': $($_.Exception.Message)" 'Red' }
    }
    try { [IO.Directory]::Delete($fd) } catch { }      # only succeeds when empty
}

if ($LoadFunctionsOnly) { return }

# ================================================================================ start
if (-not $IsAdmin -and -not $AllowNonAdmin) { Write-Host 'This needs administrator rights. Run RAM-Doctor.bat (it asks for administrator rights automatically).' -ForegroundColor Red; exit 1 }
if (-not $IsAdmin) { Write-Host 'WARNING: not elevated - service/driver/system-wide changes will fail (testing mode).' -ForegroundColor Yellow }
if (-not (Initialize-StoreRoot)) { Write-Host 'The quarantine store could not be secured, so nothing was done.' -ForegroundColor Red; exit 1 }

# ================================================================ LIST
if ($Mode -eq 'List') {
    $all = @(Get-Batches)
    if ($all.Count -eq 0) { Write-Host 'No quarantine batches.'; exit 0 }
    foreach ($b in $all) {
        $mm = Read-Manifest $b.FullName
        if (-not $mm) { Write-Host ("{0}   (unreadable manifest)" -f $b.Name); continue }
        Write-Host ("{0}   {1} item(s)   {2}" -f $b.Name, @($mm.entries).Count, $(if ($mm.purgedAt) { "PURGED $($mm.purgedAt)" } else { 'restorable' }))
        foreach ($e in @($mm.entries)) { Write-Host ("    #{0} {1}  [{2}]" -f $e.id, $e.name, $e.risk) }
    }
    exit 0
}

# ================================================================ RESTORE
if ($Mode -eq 'Restore') {
    $b = Select-Batch
    if (-not $b) { exit 1 }
    $mm = Read-Manifest $b.FullName
    if (-not $mm) { Log "refusing to restore: manifest of $($b.Name) is unreadable" 'Red'; exit 1 }
    if ($mm.purgedAt) { Log 'This batch was purged; nothing left to restore.' 'Yellow'; exit 1 }
    if ($mm.restoredAt) { Log "This batch was already restored on $($mm.restoredAt)." 'Yellow'; exit 0 }
    Log "Restoring batch $($b.Name) ..." 'Cyan'
    foreach ($e in @($mm.entries)) {
        Log "-- #$($e.id) $($e.name)"
        $rev = @($e.ops); [array]::Reverse($rev)   # undo in the opposite order of how it was done
        foreach ($op in $rev) {
            if ($op.status -ne 'done') { continue }
            switch ([string]$op.type) {
                'QuarantineFile' { Restore-StoredFile $op $b.FullName }
                'MoveStartupFile' { Restore-StoredFile $op $b.FullName }
                'DisableService' { Restore-StartType $op }
                'DisableDriver' { Restore-StartType $op }
                'DisableTask' { Restore-Task $op }
                'RemoveRunValue' { Restore-RunValue $op }
                'RemoveWmi' { Log "   WMI subscription '$($op.name)' cannot be auto-restored; its original definition is saved in manifest.json" 'Yellow' }
                'StopProcess' { }
                default { Log "   ignoring unknown operation type '$($op.type)'" 'Yellow' }
            }
        }
    }
    if ($script:RedCount -eq 0) {   # fully restored: remember it so the batch is not offered for restore again
        $mm | Add-Member -NotePropertyName restoredAt -NotePropertyValue (IsoDate (Get-Date)) -Force
        Save-Manifest $mm $b.FullName
    }
    Log 'Restore finished. A reboot may be needed for service/driver changes.' 'Cyan'
    exit 0
}

# ================================================================ PURGE
if ($Mode -eq 'Purge') {
    $targets = @()
    if ($OlderThanDays -ge 0) { $targets = @(Get-Batches | Where-Object { ((Get-Date) - $_.CreationTime).TotalDays -ge $OlderThanDays }) }
    else { $one = Select-Batch; if ($one) { $targets = @($one) } }
    if ($targets.Count -eq 0) { Log 'Nothing to purge.'; exit 0 }
    $totalBytes = 0; $count = 0
    foreach ($t in $targets) {
        $fd = Join-Path $t.FullName 'files'
        if ((Test-Path -LiteralPath $fd) -and -not (Test-IsReparse $fd)) { $fs = @(Get-ChildItem -LiteralPath $fd -File -Force -ErrorAction SilentlyContinue); $count += $fs.Count; $totalBytes += ($fs | Measure-Object Length -Sum).Sum }
    }
    Write-Host ("About to PERMANENTLY delete {0} quarantined file(s), {1} MB, from {2} batch(es). This cannot be undone." -f $count, [math]::Round($totalBytes / 1MB, 1), $targets.Count) -ForegroundColor Red
    if (-not $Yes) { if ((Read-Host "Type DELETE to confirm") -cne 'DELETE') { Log 'Cancelled.'; exit 0 } }
    foreach ($t in $targets) {
        $before = $script:RedCount
        Remove-BatchFiles $t.FullName
        $mm = Read-Manifest $t.FullName
        if (-not $mm) { Log "refusing to update the manifest of $($t.Name): unreadable" 'Red'; continue }
        if ($script:RedCount -eq $before) {
            $mm | Add-Member -NotePropertyName purgedAt -NotePropertyValue (IsoDate (Get-Date)) -Force
            Save-Manifest $mm $t.FullName
            Log "Purged batch $($t.Name)" 'Green'
        } else { Log "Batch $($t.Name) was NOT fully purged (see messages above)" 'Yellow' }
    }
    exit 0
}

# ================================================================ QUARANTINE
# ---- locate and validate the plan (user-writable input: see SECURITY MODEL above)
if (-not $Plan) {
    $dirs = @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'RAM-Doctor-Reports'))
    $cand = foreach ($d in $dirs) { if (Test-Path -LiteralPath $d) { Get-ChildItem -LiteralPath $d -Filter 'Plan-*.json' -File } }
    $latest = $cand | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { Log 'No plan found. Run the scan first.' 'Red'; exit 1 }
    $Plan = $latest.FullName
}
Log "Using plan: $Plan"
try { $planData = Get-Content -LiteralPath $Plan -Raw -Encoding UTF8 | ConvertFrom-Json }   # (not $plan: PowerShell variables are case-insensitive and $Plan is the typed [string] parameter)
catch { Log "refusing to use the plan: it is not valid JSON ($($_.Exception.Message))" 'Red'; exit 1 }
if (-not $planData -or -not $planData.suspects) { Log 'The plan has no suspects. Nothing to do.' 'Yellow'; exit 0 }
if ($planData.host -ne $env:COMPUTERNAME) { Log "Plan belongs to '$($planData.host)', this PC is '$($env:COMPUTERNAME)'. Refusing." 'Red'; exit 1 }
$ageH = 0; try { $ageH = ((Get-Date) - [datetime]$planData.created).TotalHours } catch { }
if ($ageH -gt 24) { Log ("Plan is {0:N0} h old; every item is re-verified live before anything is touched." -f $ageH) 'Yellow' }

$cands = @($planData.suspects | Where-Object { $_.risk -in 'High', 'Medium' -or ($IncludeLow -and $_.risk -eq 'Low') } | Sort-Object id)
if ($cands.Count -eq 0) { Log 'The scan found nothing at High/Medium risk. Nothing to do.' 'Green'; exit 0 }

Write-Host ''
Write-Host '================ Candidates ================' -ForegroundColor Cyan
foreach ($c in $cands) {
    $col = switch ($c.risk) { 'High' { 'Red' } 'Medium' { 'Yellow' } default { 'Gray' } }
    Write-Host ("[#{0}] {1,-6} score {2,-3} {3}" -f $c.id, ([string]$c.risk).ToUpper(), $c.score, $c.name) -ForegroundColor $col
    Write-Host ("      path : {0}" -f $c.path)
    Write-Host ("      trust: {0} {1}" -f $c.trust, $c.publisher)
    foreach ($r in @($c.reasons | Select-Object -First 3)) { Write-Host ("      - {0}" -f $r) }
    $what = New-Object System.Collections.Generic.List[string]
    if (@($c.procs).Count) { $what.Add("stop $(@($c.procs).Count) process(es)") }
    if (@($c.services).Count) { $what.Add("disable $(@($c.services).Count) service(s)") }
    if (@($c.tasks).Count) { $what.Add("disable $(@($c.tasks).Count) task(s)") }
    if (@($c.autoruns).Count) { $what.Add("remove $(@($c.autoruns).Count) startup entr(y/ies)") }
    if (@($c.drivers).Count) { $what.Add("disable driver at next boot") }
    if (@($c.wmi).Count) { $what.Add("remove WMI subscription") }
    if ($c.fileExists -and -not $c.protectedFile) { $what.Add('move file to quarantine') } elseif ($c.protectedFile) { $what.Add('(system file: never moved)') }
    Write-Host ("      will : {0}" -f ($what -join ', ')) -ForegroundColor DarkCyan
}
Write-Host ''

# ---- selection
$chosen = @()
if ($SelectIds.Count -gt 0) { $chosen = @($cands | Where-Object { $SelectIds -contains $_.id }) }
else {
    $a = Read-Host "Enter numbers to quarantine (e.g. 1,3), H = all High, M = all High+Medium, Enter = cancel"
    if (-not $a) { Log 'Cancelled - nothing changed.'; exit 0 }
    switch -Regex ($a.Trim()) {
        '^[Hh]$' { $chosen = @($cands | Where-Object risk -eq 'High') }
        '^[Mm]$' { $chosen = @($cands | Where-Object { $_.risk -in 'High', 'Medium' }) }
        default {
            $ids = @(); foreach ($t in ($a -split '[,\s]+')) { $n = 0; if ([int]::TryParse($t, [ref]$n)) { $ids += $n } }
            $chosen = @($cands | Where-Object { $ids -contains $_.id })
        }
    }
}
if ($chosen.Count -eq 0) { Log 'No valid selection - nothing changed.' 'Yellow'; exit 0 }
Write-Host ('Selected: ' + (($chosen | ForEach-Object { "#$($_.id) $($_.name)" }) -join ', ')) -ForegroundColor Cyan
Write-Host 'Nothing is deleted. Files are moved to quarantine and can be restored from the app (Restore).' -ForegroundColor Cyan
if (-not $Yes) { if ((Read-Host 'Type YES to proceed') -cne 'YES') { Log 'Cancelled - nothing changed.'; exit 0 } }

# ---- safety net
if (-not $NoRestorePoint) {
    try { Checkpoint-Computer -Description 'RAM-Doctor before quarantine' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; Log 'System restore point created.' 'Green' }
    catch { Log "No restore point created (System Protection off, or one was made in the last 24h): $($_.Exception.Message)" 'Yellow' }
}

$batchName = $Stamp; $bn = 2
while (Test-Path -LiteralPath (Join-Path $QRoot $batchName)) { $batchName = "$Stamp-$bn"; $bn++ }    # two runs in the same second must not share a batch
$batchDir = Join-Path $QRoot $batchName
$filesDir = Join-Path $batchDir 'files'
[void][IO.Directory]::CreateDirectory($filesDir)
$manifest = [pscustomobject]@{ batch = $batchName; version = $ToolVersion; created = (IsoDate (Get-Date)); host = $env:COMPUTERNAME; plan = $Plan; entries = @() }
$entries = New-Object System.Collections.ArrayList

foreach ($s in $chosen) {
    Log "=== #$($s.id) $($s.name) [$($s.risk)] ===" 'Cyan'
    $ops = New-Object System.Collections.ArrayList
    function AddOp([hashtable]$h) { [void]$ops.Add([pscustomobject]$h) }

    # ---- 0) validate + re-verify the target live (never trust the plan)
    $path = [string]$s.path
    $exists = $false; $moveFile = $false; $skipAll = $false
    if ($path) {
        if (-not (Test-LocalDrivePath $path)) { Log "   refusing: '$path' is not a plain local drive path - skipping this item" 'Red'; continue }
        $path = Get-FullPathSafe $path    # long form: 8.3 short names (VICTIM~1.EXE) are expanded so the REAL file name is recorded and restored
        $exists = (Test-Path -LiteralPath $path -PathType Leaf)
    }
    $moveFile = $exists -and -not $s.protectedFile
    if ($exists) {
        $curHash = Get-Sha256 $path
        if ($moveFile -and -not $s.sha256) { Log '   refusing: the plan has no SHA-256 for this file, so it cannot be verified - skipping this item. Re-run the scan.' 'Red'; $skipAll = $true }
        elseif ($s.sha256 -and $curHash -and $curHash -ine $s.sha256) { Log '   file changed since the scan (hash mismatch) - skipping this item for safety. Re-run the scan.' 'Red'; $skipAll = $true }
        if ($moveFile -and (Test-ProtectedPath $path)) { Log '   path is in a protected location - file will NOT be moved.' 'Yellow'; $moveFile = $false }
        if ($moveFile -and (Test-MicrosoftSigned $path)) { Log '   file is Microsoft-signed - file will NOT be moved.' 'Yellow'; $moveFile = $false }
        if ($moveFile -and (Test-IsReparse $path)) { Log '   file is a link (reparse point) - file will NOT be moved.' 'Yellow'; $moveFile = $false }
    }
    if ($skipAll) { continue }

    # ---- 1) stop processes (PID + start-time guard against PID reuse; never the critical Windows processes)
    $toKill = New-Object System.Collections.Generic.List[int]
    $cands2 = New-Object System.Collections.ArrayList
    foreach ($p in @($s.procs)) {
        $procId = 0
        if (-not [int]::TryParse([string]$p.pid, [ref]$procId) -or $procId -le 4) { continue }
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        $okStart = $true
        if ($p.start) { try { $okStart = [math]::Abs(($proc.StartTime - [datetime]$p.start).TotalSeconds) -le 3 } catch { $okStart = $false } }
        if ($okStart) { [void]$cands2.Add($proc) }
    }
    if ($moveFile) {   # also catch copies respawned after the scan
        foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
            try { if ($proc.Path -and ((Get-FullPathSafe $proc.Path) -ieq $path) -and -not ($cands2 | Where-Object { $_.Id -eq $proc.Id })) { [void]$cands2.Add($proc) } } catch { }
        }
    }
    foreach ($proc in $cands2) {
        $pname = $proc.ProcessName.ToLowerInvariant(); $ppath = ''
        try { $ppath = [string]$proc.Path } catch { }
        if ($CriticalProcNames -contains $pname -and (-not $ppath -or $ppath.ToLowerInvariant().StartsWith($WinDirL + '\'))) {
            Log "   refusing to stop critical Windows process $($proc.ProcessName) (PID $($proc.Id))" 'Yellow'; continue
        }
        if (-not $toKill.Contains($proc.Id)) { $toKill.Add($proc.Id) }
    }
    foreach ($procId in $toKill) {
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
            Wait-Process -Id $procId -Timeout 5 -ErrorAction SilentlyContinue   # let the kernel finish tearing it down before we touch its file
            Log "   stopped process $procId" 'Green'; AddOp @{ type = 'StopProcess'; pid = $procId; status = 'done' }
        }
        catch { Log "   could not stop process ${procId}: $($_.Exception.Message)" 'Red'; AddOp @{ type = 'StopProcess'; pid = $procId; status = 'failed'; note = $_.Exception.Message } }
    }

    # ---- 2) services (plain names only: Stop-Service/sc.exe would treat '*' or '\\host' specially)
    foreach ($sv in @($s.services)) {
        $sn = [string]$sv.name
        if (-not (Test-SafeServiceName $sn)) { Log "   refusing: unsafe service name '$sn'" 'Red'; continue }
        if ($EssentialServices -contains $sn) { Log "   refusing to disable essential Windows service $sn" 'Yellow'; continue }
        $code = Get-StartCode $sn
        if (-not $code) { Log "   service $sn not found" 'Yellow'; continue }
        try { Stop-Service -Name $sn -Force -ErrorAction SilentlyContinue } catch { }
        if (Set-StartCode $sn 4 0) { Log "   service disabled: $sn" 'Green'; AddOp @{ type = 'DisableService'; name = $sn; prevStart = $code.Start; prevDelayed = $code.Delayed; status = 'done' } }
        else { Log "   failed to disable service $sn" 'Red'; AddOp @{ type = 'DisableService'; name = $sn; status = 'failed' } }
    }

    # ---- 3) drivers: only 3rd-party, non-boot, non-Microsoft
    foreach ($dv in @($s.drivers)) {
        $dn = [string]$dv.name
        if (-not (Test-SafeServiceName $dn)) { Log "   refusing: unsafe driver name '$dn'" 'Red'; continue }
        $code = Get-StartCode $dn
        if (-not $code) { continue }
        if ($code.Start -le 1) { Log "   driver $dn is boot/system-start: refusing to disable (could stop Windows booting)" 'Yellow'; continue }
        if ($path -and ((Test-ProtectedPath $path) -or (Test-MicrosoftSigned $path))) { Log "   driver $dn is a Windows/Microsoft driver: refusing" 'Yellow'; continue }
        if (Set-StartCode $dn 4 0) { Log "   driver disabled (takes effect at next boot): $dn" 'Green'; AddOp @{ type = 'DisableDriver'; name = $dn; prevStart = $code.Start; prevDelayed = $code.Delayed; status = 'done' } }
        else { Log "   failed to disable driver $dn" 'Red' }
    }

    # ---- 4) scheduled tasks (exact match only)
    foreach ($t in @($s.tasks)) {
        $tp = [string]$t.taskPath; $tn = [string]$t.taskName
        if (-not (Test-SafeTaskPath $tp) -or -not (Test-SafeTaskName $tn)) { Log "   refusing: unsafe task name '$tp$tn'" 'Red'; continue }
        try {
            $found = @(Get-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction Stop)
            if ($found.Count -ne 1) { Log "   refusing: '$tp$tn' does not match exactly one task" 'Red'; continue }
            Disable-ScheduledTask -InputObject $found[0] -ErrorAction Stop | Out-Null
            Log "   task disabled: $tp$tn" 'Green'; AddOp @{ type = 'DisableTask'; taskPath = $tp; taskName = $tn; status = 'done' }
        } catch { Log "   could not disable task ${tn}: $($_.Exception.Message)" 'Red' }
    }

    # ---- 5) startup entries (only the known Run keys / Startup folders)
    foreach ($r in @($s.autoruns)) {
        if ($r.via -eq 'Registry') {
            $loc = [string]$r.location; $rn = [string]$r.name
            if ($loc -notmatch $RunLocRegex) { Log "   refusing: '$loc' is not a known Run key" 'Red'; continue }
            try {
                $key = Open-RegKey $loc $true
                if (-not $key) { Log "   could not open $loc" 'Red'; continue }
                try {
                    $curExp = $key.GetValue($rn)
                    if ($null -eq $curExp) { Log "   Run value '$rn' not found" 'Yellow'; continue }
                    if ([string]$curExp -ne [string]$r.value) { Log "   Run value '$rn' changed since the scan - left alone" 'Yellow'; continue }
                    $kind = $key.GetValueKind($rn).ToString()
                    if (@('String', 'ExpandString') -notcontains $kind) { Log "   Run value '$rn' has an unexpected type ($kind) - left alone" 'Yellow'; continue }
                    $raw = $key.GetValue($rn, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $key.DeleteValue($rn)
                    Log "   startup value removed: $rn" 'Green'
                    AddOp @{ type = 'RemoveRunValue'; location = $loc; name = $rn; value = [string]$raw; kind = $kind; status = 'done' }
                } finally { $key.Close() }
            } catch { Log "   could not remove Run value '${rn}': $($_.Exception.Message)" 'Red' }
        } elseif ($r.via -eq 'StartupFolder' -and $r.file) {
            $sf = [string]$r.file
            if (-not (Test-LocalDrivePath $sf) -or $sf -notmatch $StartupRegex) { Log "   refusing: '$sf' is not a file in a Startup folder" 'Red'; continue }
            if (-not (Test-Path -LiteralPath $sf -PathType Leaf) -or (Test-IsReparse $sf)) { continue }
            $stored = Join-Path $filesDir ('{0:D3}_startup_{1}.quar' -f [int]$s.id, (Split-Path $sf -Leaf))
            $sha = Get-Sha256 $sf
            if (Move-NoOverwrite $sf $stored) { Log "   startup shortcut moved: $sf" 'Green'; AddOp @{ type = 'MoveStartupFile'; original = $sf; stored = $stored; storedSha256 = $sha; status = 'done' } }
            else { Log "   could not move startup file $sf" 'Red' }
        }
    }

    # ---- 6) WMI subscriptions (definition saved so a human can recreate it)
    foreach ($w in @($s.wmi)) {
        $wc = [string]$w.class
        if ($WmiConsumerClasses -notcontains $wc) { Log "   refusing: '$wc' is not a WMI event-consumer class" 'Red'; continue }
        try {
            $ns = 'root\subscription'
            $cons = @(Get-CimInstance -Namespace $ns -ClassName $wc -ErrorAction Stop | Where-Object { $_.Name -eq [string]$w.name })
            $saved = $cons | ForEach-Object { $h = @{}; foreach ($pp in $_.CimInstanceProperties) { $h[$pp.Name] = [string]$pp.Value }; $h }
            foreach ($bnd in @(Get-CimInstance -Namespace $ns -ClassName __FilterToConsumerBinding -ErrorAction SilentlyContinue | Where-Object { $_.Consumer.Name -eq [string]$w.name })) { Remove-CimInstance -InputObject $bnd -ErrorAction SilentlyContinue }
            foreach ($c in $cons) { Remove-CimInstance -InputObject $c -ErrorAction Stop }
            Log "   WMI consumer removed: $($w.name)" 'Green'
            AddOp @{ type = 'RemoveWmi'; class = $wc; name = [string]$w.name; definition = $saved; status = 'done' }
        } catch { Log "   could not remove WMI consumer $($w.name): $($_.Exception.Message)" 'Red' }
    }

    # ---- 7) finally the file itself
    if ($moveFile) {
        $stored = Join-Path $filesDir ('{0:D3}_{1}.quar' -f [int]$s.id, (Split-Path $path -Leaf))
        if (Move-NoOverwrite $path $stored) {
            $storedSha = Get-Sha256 $stored
            Log "   file quarantined -> $stored" 'Green'
            AddOp @{ type = 'QuarantineFile'; original = $path; stored = $stored; sha256 = $s.sha256; storedSha256 = $storedSha; status = 'done' }
        } else {
            Log '   file is still locked and could not be moved (try again after a reboot, or in Safe Mode).' 'Red'
            AddOp @{ type = 'QuarantineFile'; original = $path; status = 'failed'; note = 'locked' }
        }
    }

    [void]$entries.Add([pscustomobject]@{ id = $s.id; name = $s.name; risk = $s.risk; path = $path; sha256 = $s.sha256; ops = @($ops) })
    $manifest.entries = @($entries)
    Save-Manifest $manifest $batchDir
}

$manifest.entries = @($entries)
if ($entries.Count -eq 0) {
    # nothing was done: do not leave an empty batch behind
    try { [IO.Directory]::Delete($filesDir); Remove-Item -LiteralPath (Join-Path $batchDir 'manifest.json') -Force -ErrorAction SilentlyContinue; [IO.Directory]::Delete($batchDir) } catch { }
    Write-Host ''
    Log 'No item was changed.' 'Yellow'
    exit 0
}
Save-Manifest $manifest $batchDir
Write-Host ''
Log "Done. Quarantine batch: $batchDir" 'Cyan'
Log 'Restart the PC, then scan again to confirm the memory problem is gone.' 'Cyan'
Log 'Undo: Restore (in the app).      Delete for good: Purge (in the app).' 'Cyan'
