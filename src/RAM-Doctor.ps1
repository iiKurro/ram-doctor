#requires -Version 5.1
<#
.SYNOPSIS
  RAM Doctor - triage for "RAM is full but Task Manager shows nothing".

.DESCRIPTION
  READ-ONLY. Collects memory / kernel pool / process / startup / driver evidence, writes an HTML
  report (Arabic or English, see -Lang) + a JSON action plan. It never kills, deletes or changes anything.
  Acting on the findings is a separate, explicit step: RAM-Doctor-Actions.ps1.
  The tool makes no network connections and nothing is sent anywhere.

  Output (two small files per scan, the 3 newest scans are kept):
    RAMDoctor-<PC>-<stamp>.html   the report (self-contained, inert: see src/lib/Report.ps1)
    Plan-<PC>-<stamp>.json        the action plan read by RAM-Doctor-Actions.ps1 and the GUI
                                  (schema: verdict, observations, memory, suspects, created, host, report - only ever ADD fields)
  -KeepRawJson additionally writes the full raw data as RAMDoctor-<PC>-<stamp>.json.

  Language: every text the scan produces (observations, verdict, reasons, the report) is written in ONE language,
  chosen with -Lang ar|en and otherwise from the Windows UI language (Arabic -> ar, everything else -> en). The
  plan gets an additive "lang" field. All strings live in lib\Strings.ps1. Console output is always English ASCII.

  Designed for PCs that are short of RAM: no big collections are kept, files are hashed only for suspects,
  and the peak working set of this process is printed at the end.

  NOTE: the plan on the Desktop is user-writable input for the elevated Actions script, which re-verifies
  every target live (see the SECURITY MODEL in RAM-Doctor-Actions.ps1).
#>
[CmdletBinding()]
param(
    [int]$SampleSeconds = 30,   # minimum observation window for "what is growing right now"
    [string]$OutDir = '',
    [switch]$NoOpen,
    [switch]$KeepRawJson,           # also save the full raw data as .json (for technicians; off by default to stay light)
    [double]$ThresholdScale = 1.0,  # <1 = more sensitive (kernel-pool / unaccounted-memory alarms trigger earlier)
    [ValidateSet('ar', 'en')][string]$Lang   # language of the texts and the report; default = Windows UI language
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
# polite by design: this tool runs on PCs that are already struggling, so it must never make them feel slower
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
$ToolVersion = '1.1.3'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$WinDir = $env:SystemRoot.TrimEnd('\')
$WinDirL = $WinDir.ToLowerInvariant()
$Warnings = New-Object System.Collections.Generic.List[string]
. (Join-Path $Root 'lib\Strings.ps1')   # every user-facing text (ar / en)
Set-UiLang $Lang

function Say([string]$m) { Write-Host ('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss', $Inv), $m) }
# memory checkpoints, printed only with -Verbose (keeps the tool honest about its own footprint)
# Phase boundary: collect the garbage left by the previous inventory, hand idle resident pages back to the OS
# (they remain reclaimable standby pages) and log the footprint.
function Phase([string]$label) {
    [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
    if ($script:NativeOk) { [RamDoc.Native]::TrimWorkingSet() }
    Mem $label
}
function Mem([string]$label) {
    if ($VerbosePreference -ne 'Continue') { return }
    $p = [Diagnostics.Process]::GetCurrentProcess()
    Write-Verbose ('MEM {0,-24} ws={1,4} MB  peakWS={2,4} MB  private={3,4} MB  peakCommit={4,4} MB  managed={5,4} MB' -f $label, [int]($p.WorkingSet64 / 1MB), [int]($p.PeakWorkingSet64 / 1MB), [int]($p.PrivateMemorySize64 / 1MB), [int]($p.PeakPagedMemorySize64 / 1MB), [int]([GC]::GetTotalMemory($false) / 1MB))
}
function Warn([string]$m) { $Warnings.Add($m); Write-Host ('   ! ' + $m) -ForegroundColor Yellow }
function ToGB([double]$b) { [math]::Round($b / 1GB, 2) }
function ToMB([double]$b) { [math]::Round($b / 1MB, 0) }
function Num($x) { ([double]$x).ToString('0.##', $Inv) }
function IsoDate($d) { if ($d) { ([datetime]$d).ToString('yyyy-MM-dd HH:mm:ss', $Inv) } else { '' } }

# ---------------------------------------------------------------- native helper (loaded FIRST, so every later phase can trim)
# Add-Type compiles INSIDE this process and costs ~30 MB of working set. Instead the small helper is compiled once per
# run by csc.exe in a child process (it exits right away), loaded from bytes and the temp DLL is deleted.
# Add-Type stays as the fallback when csc.exe is not available.
function Import-Native {
    if ('RamDoc.Native' -as [type]) { return $true }
    $src = Join-Path $Root 'lib\Native.cs'
    try {
        $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
        if (Test-Path -LiteralPath $csc) {
            # This process is usually ELEVATED and loads what csc writes, so the work folder must not be writable by a
            # user-level program (it could swap the DLL before we read it): when elevated it is created atomically with
            # an ACL that only gives SYSTEM and Administrators access (by SID, locale independent).
            $work = Join-Path $env:TEMP ('RamDoctor-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
            if ($IsAdmin) {
                $sec = New-Object Security.AccessControl.DirectorySecurity
                $sec.SetAccessRuleProtection($true, $false)
                foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
                    $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
                }
                [void][IO.Directory]::CreateDirectory($work, $sec)
            } else { [void][IO.Directory]::CreateDirectory($work) }
            try {
                $dll = Join-Path $work 'native.dll'
                $cp = Start-Process -FilePath $csc -ArgumentList @('/nologo', '/target:library', '/optimize+', '/debug-', ('/out:"{0}"' -f $dll), ('"{0}"' -f $src)) -WindowStyle Hidden -PassThru -Wait
                if ($cp.ExitCode -eq 0 -and (Test-Path -LiteralPath $dll)) {
                    [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))
                    if ('RamDoc.Native' -as [type]) { return $true }
                }
            } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
    Add-Type -TypeDefinition (Get-Content -LiteralPath $src -Raw) -Language CSharp -ErrorAction Stop
    return $true
}
$NativeOk = $false
try { $NativeOk = Import-Native } catch { Warn "Native helper failed to load (pool tags / hidden-process check disabled): $($_.Exception.Message)" }
if ($NativeOk) { try { [RamDoc.Native]::LowerIoAndMemoryPriority() } catch { } }
if ($NativeOk) { [RamDoc.Native]::TrimWorkingSet() }   # drop the compile/parse leftovers right away
Mem 'native loaded'
Mem 'boot'
# Explicit imports: if PowerShell has to AUTO-discover these modules it scans every installed module first and
# that alone costs ~40 MB of working set. (ScheduledTasks is imported right before it is needed.)
foreach ($mod in 'CimCmdlets', 'Microsoft.PowerShell.Security') {
    try { Import-Module -Name (Join-Path $PSHOME "Modules\$mod\$mod.psd1") -ErrorAction Stop -Verbose:$false } catch { }
}
Mem 'modules imported'
. (Join-Path $Root 'lib\Report.ps1')
. (Join-Path $Root 'lib\Store.ps1')    # crash-safe output files (.tmp + rename) and the reports-folder lock

# ---------------------------------------------------------------- output folder
$desktop = [Environment]::GetFolderPath('Desktop'); if (-not $desktop) { $desktop = $env:TEMP }   # services / odd profiles have no Desktop
if (-not $OutDir) { $OutDir = Join-Path $desktop 'RAM-Doctor-Reports' }   # one small, easy-to-find folder
try {
    [void][IO.Directory]::CreateDirectory($OutDir)
    $probe = Join-Path $OutDir '.write-test'
    Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force
} catch {
    $OutDir = Join-Path $desktop 'RAM-Doctor-Reports'
    [void][IO.Directory]::CreateDirectory($OutDir)
}
$Stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', $Inv)     # invariant culture: ar-SA would otherwise stamp Hijri years (1448...)
$HostName = $env:COMPUTERNAME

Say "RAM Doctor $ToolVersion  (admin: $IsAdmin)  - read-only scan, nothing will be changed"
if (-not $IsAdmin) { Warn 'Not running as administrator: results for protected processes / other users may be incomplete. Run the tool as administrator for the full picture.' }

# ---------------------------------------------------------------- native helper


# ---------------------------------------------------------------- generic helpers
$SigCache = @{}
function Get-SigInfo([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return [pscustomobject]@{ Status = 'NoPath'; Publisher = ''; Trust = 'Unknown' } }
    $key = $Path.ToLowerInvariant()
    if ($SigCache.ContainsKey($key)) { return $SigCache[$key] }
    $status = 'Missing'; $pub = ''; $isMs = $false
    if (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue) {
        try {
            $s = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
            $status = [string]$s.Status
            if ($s.SignerCertificate) {
                $subj = $s.SignerCertificate.Subject
                if ($subj -match 'CN=("[^"]+"|[^,]+)') { $pub = $Matches[1].Trim('"') } else { $pub = $subj }
                if ($status -eq 'Valid' -and $subj -match 'O=Microsoft (Corporation|Windows)') { $isMs = $true }
            }
            # release the native certificate handles right away instead of waiting for the finalizer thread
            foreach ($c in @($s.SignerCertificate, $s.TimeStamperCertificate)) { if ($c) { try { $c.Dispose() } catch { } } }
        } catch { $status = 'Error' }
    }
    $trust = switch ($status) {
        'Valid' {
            if ($isMs) { if ($key.StartsWith($WinDirL + '\')) { 'OS' } else { 'MS' } } else { 'Signed' }
        }
        'NotSigned' { 'Unsigned' }
        'HashMismatch' { 'Tampered' }
        'NotSupportedFileFormat' { 'Script' }
        'Missing' { 'Missing' }
        default { 'Untrusted' }
    }
    $r = [pscustomobject]@{ Status = $status; Publisher = $pub; Trust = $trust }
    $SigCache[$key] = $r
    return $r
}

$MetaCache = @{}
function Get-HasVersionInfo([string]$Path) {
    if (-not $Path) { return $false }
    $k = $Path.ToLowerInvariant()
    if ($MetaCache.ContainsKey($k)) { return $MetaCache[$k] }
    $r = $false
    try { $vi = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).VersionInfo; $r = [bool]($vi.CompanyName -and $vi.FileDescription -and $vi.ProductName) } catch { }
    $MetaCache[$k] = $r
    return $r
}

function Resolve-ExePath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $p = [Environment]::ExpandEnvironmentVariables($p.Trim().Trim('"'))
    if ($p.StartsWith('\??\')) { $p = $p.Substring(4) }
    if ($p -match '^\\SystemRoot\\(.*)$') { return (Join-Path $WinDir $Matches[1]) }
    if ([IO.Path]::IsPathRooted($p)) { return $p }
    $c = Get-Command $p -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $p
}

function Get-ExePathFromCommand([string]$cmd) {
    if ([string]::IsNullOrWhiteSpace($cmd)) { return '' }
    $c = [Environment]::ExpandEnvironmentVariables($cmd.Trim())
    if ($c -match '^"([^"]+)"') { return (Resolve-ExePath $Matches[1]) }
    if ($c -match '^(.+?\.(?:exe|sys|dll|bat|cmd|ps1|vbs|js|scr|com|msi|cpl))(\s|$)') { return (Resolve-ExePath $Matches[1]) }
    return (Resolve-ExePath (($c -split '\s+')[0]))
}

function Get-PathZone([string]$p) {
    if (-not $p) { return 'Unknown' }
    $l = $p.ToLowerInvariant()
    if ($l.StartsWith($WinDirL + '\temp\')) { return 'Temp' }
    if ($l.StartsWith($WinDirL + '\')) { return 'Windows' }
    if ($l -match '\\appdata\\local\\temp\\' -or $l -match '\\temp\\') { return 'Temp' }
    if ($l -match '\\users\\public\\' -or $l -match '\$recycle\.bin' -or $l -match '\\perflogs\\') { return 'Public' }
    if ($l -match '\\downloads\\') { return 'Downloads' }
    if ($l -match '\\appdata\\local\\programs\\') { return 'UserPrograms' }   # standard per-user install dir
    if ($l -match '\\appdata\\') { return 'AppData' }
    if ($l -match '\\programdata\\') { return 'ProgramData' }
    if ($l -match '^[a-z]:\\program files') { return 'ProgramFiles' }
    return 'Other'
}

function Test-OneEdit([string]$a, [string]$b) {
    if ($a -eq $b) { return $false }
    $la = $a.Length; $lb = $b.Length
    if ([math]::Abs($la - $lb) -gt 1) { return $false }
    $i = 0; $j = 0; $edits = 0
    while ($i -lt $la -and $j -lt $lb) {
        if ($a[$i] -eq $b[$j]) { $i++; $j++; continue }
        $edits++
        if ($edits -gt 1) { return $false }
        if ($la -eq $lb) { $i++; $j++ } elseif ($la -gt $lb) { $i++ } else { $j++ }
    }
    $edits += ($la - $i) + ($lb - $j)
    return ($edits -le 1)
}

function Test-RandomName([string]$n) {
    $b = [IO.Path]::GetFileNameWithoutExtension($n).ToLowerInvariant()
    if ($b.Length -lt 7 -or $b -notmatch '^[a-z0-9_\-]+$') { return $false }
    if ($b -match '^[a-f0-9]{8,}$') { return $true }
    $letters = ($b -replace '[^a-z]', '')
    if ($letters.Length -ge 6) {
        $vowels = ($letters -replace '[^aeiou]', '').Length
        if (($vowels / [double]$letters.Length) -lt 0.18) { return $true }
    }
    $digits = ($b -replace '[^0-9]', '').Length
    if ($b -match '^[a-z0-9]{10,}$' -and $digits -ge 3 -and $letters.Length -ge 3) { return $true }
    return $false
}

$CriticalNames = @('svchost', 'lsass', 'csrss', 'smss', 'wininit', 'services', 'winlogon', 'explorer', 'taskhostw', 'dllhost',
    'conhost', 'spoolsv', 'runtimebroker', 'searchindexer', 'wmiprvse', 'fontdrvhost', 'sihost', 'ctfmon', 'audiodg', 'dwm',
    'lsm', 'taskmgr', 'userinit', 'regsvr32', 'rundll32', 'cmd', 'powershell', 'wscript', 'cscript', 'mshta')
$Scripters = @('powershell', 'pwsh', 'wscript', 'cscript', 'mshta', 'rundll32', 'regsvr32', 'wmic', 'curl', 'bitsadmin', 'certutil')
$MinerRegex = '(?i)xmrig|minerd|cpuminer|cgminer|bfgminer|nicehash|ethminer|nbminer|phoenixminer|lolminer|gminer|--donate-level|stratum\+(tcp|ssl)|cryptonight|randomx|minexmr|supportxmr|nanopool|2miners|f2pool|hiveon|unmineable|-o\s+\S+:\d{4,5}\s+-u\s'
$EncodedRegex = '(?i)(\s-e(nc|ncodedcommand)?\s+[A-Za-z0-9+/=]{20,})|frombase64string|downloadstring|downloadfile|invoke-expression|\biex\s*[\(\$"'']|invoke-webrequest|\biwr\s|net\.webclient|start-bitstransfer'
$LolbinRegex = '(?i)\b(mshta|regsvr32|certutil|bitsadmin|msiexec)\b.*(https?://|-urlcache|/transfer|scrobj)'
$MiningPorts = @(3333, 4444, 5555, 7777, 14433, 14444, 45560, 45700)
$PseudoProcs = @('System', 'Registry', 'Memory Compression', 'Secure System', 'vmmem', 'vmmemWSL', 'MemCompression')

# Turns a (path, command line) pair into a list of reasons it looks wrong. Pure scoring, no side effects.
function Get-Signals {
    param([string]$Path, [string]$Cmd, [string]$Name, [string]$Kind)
    $sigs = New-Object System.Collections.ArrayList
    $add = { param($k, $pts, $txt) [void]$sigs.Add([pscustomobject]@{ Key = $k; Points = $pts; Text = $txt }) }
    $sig = Get-SigInfo $Path
    $zone = Get-PathZone $Path
    $trusted = ($sig.Trust -eq 'OS' -or $sig.Trust -eq 'MS')
    $leaf = if ($Path) { [IO.Path]::GetFileName($Path) } else { $Name }
    $base = ([IO.Path]::GetFileNameWithoutExtension($leaf)).ToLowerInvariant()
    $weak = ($sig.Trust -in 'Unsigned', 'Untrusted', 'Tampered', 'Script', 'Missing')

    # A running process whose file is gone is a classic "delete after launch" trick; a dangling
    # autorun/service entry for an uninstalled program is just clutter and is not scored.
    if ($Kind -eq 'Process' -and $Path -and [IO.Path]::IsPathRooted($Path) -and $sig.Trust -eq 'Missing') {
        & $add 'missing' 5 (Get-Text 'sig.missing')
    }
    if ($sig.Trust -eq 'Unsigned') { & $add 'unsigned' 2 (Get-Text 'sig.unsigned') }
    if ($sig.Trust -eq 'Untrusted') { & $add 'untrusted' 3 (Get-Text 'sig.untrusted' $sig.Status) }
    if ($sig.Trust -eq 'Tampered') { & $add 'tampered' 8 (Get-Text 'sig.tampered') }
    if ($weak -and $sig.Trust -ne 'Missing' -and $zone -in 'Temp', 'Public', 'Downloads') {
        & $add 'zone' 3 (Get-Text 'sig.zone.temp' $zone)
    } elseif ($weak -and $sig.Trust -ne 'Missing' -and $zone -in 'AppData', 'ProgramData') {
        & $add 'zone' 2 (Get-Text 'sig.zone.data' $zone)
    } elseif ($weak -and $sig.Trust -ne 'Missing' -and $zone -eq 'UserPrograms') {
        & $add 'zone' 1 (Get-Text 'sig.zone.userprog')
    } elseif ($sig.Trust -eq 'Signed' -and $zone -in 'Temp', 'Public') {
        & $add 'zone' 2 (Get-Text 'sig.zone.signedtemp' $zone)
    }
    if ($weak -and $leaf -and (Test-RandomName $leaf)) { & $add 'random' 2 (Get-Text 'sig.random') }
    if ($weak -and $sig.Trust -ne 'Missing' -and (Get-HasVersionInfo $Path)) { & $add 'verinfo' -1 (Get-Text 'sig.verinfo') }

    # '\' matters: "C:\Windows Update\svchost.exe" or "C:\Windows.old\..." must NOT count as inside C:\Windows
    if (-not $trusted -and $base -in $CriticalNames -and $Path -and -not $Path.StartsWith($WinDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
        & $add 'masq' 8 (Get-Text 'sig.masq' $leaf)
    } elseif (-not $trusted -and $base.Length -ge 5) {
        foreach ($c in $CriticalNames) {
            if ($c.Length -ge 5 -and (Test-OneEdit $base $c)) { & $add 'lookalike' 7 (Get-Text 'sig.lookalike' $leaf $c); break }
        }
    }

    if ($Cmd) {
        # Many legitimate apps launch PowerShell/cmd with odd arguments, so a one-off running process
        # weighs less than the same command wired into startup (task / autorun / service / WMI).
        $running = ($Kind -eq 'Process')
        $hostIsScripter = ($base -in $Scripters)
        if ($Cmd -match $MinerRegex) { & $add 'miner' 8 (Get-Text 'sig.miner') }
        if ($Cmd -match $EncodedRegex) { & $add 'encoded' $(if ($running) { 3 } else { 6 }) (Get-Text 'sig.encoded') }
        if ($Cmd -match $LolbinRegex) { & $add 'lolbin' $(if ($running) { 6 } else { 7 }) (Get-Text 'sig.lolbin') }
        if ($hostIsScripter -and $Cmd -match 'https?://') { & $add 'urlcmd' $(if ($running) { 1 } else { 3 }) (Get-Text 'sig.urlcmd') }
        if ($hostIsScripter -and $Cmd -match '(?i)\\(temp|appdata|programdata|users\\public)\\') { & $add 'argpath' $(if ($running) { 1 } else { 3 }) (Get-Text 'sig.argpath') }
    }
    return [pscustomobject]@{ Signals = $sigs; Sig = $sig; Zone = $zone }
}

# ---------------------------------------------------------------- memory counters (locale independent: WMI)
function Get-MemCounters {
    $os = Get-CimInstance Win32_OperatingSystem -Property TotalVisibleMemorySize
    $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -Property AvailableBytes, FreeAndZeroPageListBytes, StandbyCacheNormalPriorityBytes, StandbyCacheReserveBytes, StandbyCacheCoreBytes, ModifiedPageListBytes, PoolNonpagedBytes, PoolPagedBytes, PoolPagedResidentBytes, CommittedBytes, CommitLimit, SystemCacheResidentBytes, SystemDriverResidentBytes
    [pscustomobject]@{
        TotalBytes = [int64]$os.TotalVisibleMemorySize * 1KB
        AvailBytes = [int64]$m.AvailableBytes
        FreeBytes = [int64]$m.FreeAndZeroPageListBytes
        StandbyBytes = [int64]$m.StandbyCacheNormalPriorityBytes + [int64]$m.StandbyCacheReserveBytes + [int64]$m.StandbyCacheCoreBytes
        ModifiedBytes = [int64]$m.ModifiedPageListBytes
        NonPaged = [int64]$m.PoolNonpagedBytes
        Paged = [int64]$m.PoolPagedBytes
        PagedResident = [int64]$m.PoolPagedResidentBytes
        Committed = [int64]$m.CommittedBytes
        CommitLimit = [int64]$m.CommitLimit
        CacheResident = [int64]$m.SystemCacheResidentBytes
        DriverResident = [int64]$m.SystemDriverResidentBytes
        Time = Get-Date
    }
}

function Get-ProcPerf {
    $h = @{}
    foreach ($r in (Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Property Name, IDProcess, WorkingSetPrivate, WorkingSet, PrivateBytes, HandleCount)) {
        # keep four numbers per process instead of the whole CIM object
        if ($r.Name -ne '_Total' -and $r.Name -ne 'Idle' -and [int]$r.IDProcess -gt 0) {
            $h[[int]$r.IDProcess] = [pscustomobject]@{ WorkingSetPrivate = [int64]$r.WorkingSetPrivate; WorkingSet = [int64]$r.WorkingSet; PrivateBytes = [int64]$r.PrivateBytes; HandleCount = [int]$r.HandleCount }
        }
    }
    return $h
}

function Get-PoolSnapshot {
    if (-not $NativeOk) { return $null }
    try {
        $rows = [RamDoc.Native]::GetPoolTags()
        if ($rows.Count -eq 0) { return $null }
        # pool tags are case-sensitive ('ConT' is not 'cont'): an ordinary @{} would merge different tags
        $h = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        foreach ($r in $rows) {
            if ($h.ContainsKey($r.Tag)) { $h[$r.Tag].NonPagedUsed += $r.NonPagedUsed; $h[$r.Tag].PagedUsed += $r.PagedUsed }
            else { $h[$r.Tag] = $r }
        }
        return $h
    } catch { return $null }
}

# pool tag -> string-table key of its description (lib\Strings.ps1); the text is looked up in the scan language.
# Tags are case-sensitive, so both tables compare ordinally ('ConT' and 'Cont' are listed separately on purpose).
$KnownTagKeys = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
foreach ($pair in @(
        @('File', 'tag.file'), @('MmCa', 'tag.mmca'), @('Thre', 'tag.thre'), @('Proc', 'tag.proc'), @('Toke', 'tag.toke'), @('ALPC', 'tag.alpc'),
        @('Even', 'tag.even'), @('EtwB', 'tag.etwb'), @('Irp ', 'tag.irp'), @('Mdl ', 'tag.mdl'), @('ConT', 'tag.cont'), @('Cont', 'tag.cont'),
        @('NVRM', 'tag.nvrm'), @('smNp', 'tag.store'), @('smCB', 'tag.store'), @('smBt', 'tag.store'))) { $KnownTagKeys[$pair[0]] = $pair[1] }
$KnownTags = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
foreach ($tagName in $KnownTagKeys.Keys) { $KnownTags[$tagName] = Get-Text $KnownTagKeys[$tagName] }
# Contiguous physical memory of drivers (MmAllocateContiguousMemory*): Windows takes these pages straight from the physical
# page lists, NOT from the non-paged pool, and only RECORDS them in the pool tag table (ExInsertPoolTag) under 'ConT'
# (Windows 10/11; 'Cont' in older kernels, and Windows 11 still shows a few MB of multi-page blocks under 'Cont'). They are
# therefore missing from Pool Nonpaged Bytes and from Task Manager. Get-DriverReservedBytes checks this against the counter,
# so a tag that does sit inside the pool on some build is not counted twice. See docs\how-detection-works.md. (The in-pool
# path of the same API is tagged 'MmCm' and IS counted in the pool, so it is not listed here.)
$ContigTags = @('ConT', 'Cont')

# ---------------------------------------------------------------- memory breakdown (pure functions: tests\Heuristics.Tests.ps1)
# Driver-reserved memory = the contiguous allocations of $ContigTags that are NOT inside the Pool Nonpaged Bytes counter.
# The documented case (Windows Research Kernel: MiAllocateContiguousMemory takes the pages from the physical page lists and
# then calls ExInsertPoolTag) is that none of them is inside. Check on this PC: when the OTHER non-paged tags already explain
# at least half of the counter, at most (counter - others) of the contiguous bytes could hide in it, so they count in full.
# Otherwise only the part the counter provably cannot hold (others + contiguous - counter) counts, so a Windows build that
# did put them inside the pool is never counted twice by much.
function Get-DriverReservedBytes {
    param([double]$ContigBytes, [double]$OtherNonPagedTagBytes, [double]$NonPagedCounter)
    if ($ContigBytes -le 0) { return 0.0 }
    if ($OtherNonPagedTagBytes -ge 0.5 * $NonPagedCounter) { return [double]$ContigBytes }
    return [math]::Max(0.0, [math]::Min([double]$ContigBytes, $OtherNonPagedTagBytes + $ContigBytes - $NonPagedCounter))
}

# Where the memory in use is, in parts that add up to Used. Task Manager's Memory column shows the private working sets
# only; everything else is "hidden" from it. Each part takes at most what is left (in this order), so sampling noise never
# makes the parts add up to more than the memory in use:
#   Kernel       non-paged pool + paged pool in RAM
#   System       system file cache in RAM + pageable driver code in RAM + modified page list
#   Drivers      driver-reserved contiguous memory (Get-DriverReservedBytes)
#   Shared       what is left, at most SharedSum = sum over processes of (Working Set - Private Working Set). That sum
#                counts a page once for EVERY process that maps it, so it is only an upper bound: Shared is an ESTIMATE
#                (it also holds small kernel structures that have no counter, such as page tables and kernel stacks)
#   Unexplained  what is left even beyond that upper bound: driver-locked pages the tag table does not record, AWE, a RAM
#                disk, a hidden process ...
# Unattributed (the corrected "not attributed to any process") = Drivers + Unexplained: outside every working set and
# outside the kernel pool and cache counters. The old formula (Used - sum of working sets - non-paged - modified) let the
# double-counted shared working sets cancel the driver reservations out; here they are measured on their own.
function Get-MemoryBreakdown {
    param([double]$Used, [double]$Private, [double]$SharedSum, [double]$NonPaged, [double]$PagedResident, [double]$CacheResident,
        [double]$DriverResident, [double]$Modified, [double]$DriverReserved)
    $left = [math]::Max(0.0, $Used - [math]::Max(0.0, $Private))
    $hidden = $left
    $kernel = [math]::Min($left, [math]::Max(0.0, $NonPaged + $PagedResident)); $left -= $kernel
    $system = [math]::Min($left, [math]::Max(0.0, $CacheResident + $DriverResident + $Modified)); $left -= $system
    $drivers = [math]::Min($left, [math]::Max(0.0, $DriverReserved)); $left -= $drivers
    $sharedPart = [math]::Min($left, [math]::Max(0.0, $SharedSum)); $left -= $sharedPart
    return [pscustomobject]@{ Hidden = $hidden; Kernel = $kernel; System = $system; Drivers = $drivers; Shared = $sharedPart; Unexplained = $left; Unattributed = $drivers + $left }
}

# Memory reserved by drivers: medium from 512 MB (it stays well below that on ordinary PCs: a few contiguous DMA buffers),
# high from 2 GB only when it also grew by 30 MB or more during the window (a stable reservation is a driver setting or a
# second graphics adapter, not a leak; the 30 MB matches the kernel-pool leak rule). Byte thresholds follow -ThresholdScale.
function Get-DriverReservedLevel {
    param([double]$Bytes, [double]$GrowthBytes = 0, [double]$Scale = 1.0)
    if ($Bytes -ge $Scale * 2GB -and $GrowthBytes -ge 30MB) { return 'high' }
    if ($Bytes -ge $Scale * 512MB) { return 'med' }
    return ''
}

# Candidates for driver-reserved memory. The tag is written by the Windows memory manager on behalf of the driver, so it can
# never name the driver: these are only the usual suspects - the display adapters (their drivers reserve DMA / frame
# memory) and running graphics, capture, virtual-display or virtual-machine drivers that are not Microsoft's own.
# $Drivers: Name, Display, Path, Company (file version info) and Trust. Graphics drivers are WHQL-signed by Microsoft, so
# the signature cannot tell them apart from Windows' inbox drivers; the company in the file can (when it was readable).
$DisplayDriverRx = '(?i)amdkmd|atikm|nvlddmkm|igdkmd|igfx|iigd|graphic|display|video|\bgpu|capture|parsec|virtual|vdd|spacedesk|displaylink|elgato|avermedia|magewell|vbox|vmx86'
function Get-DriverReservedCandidates {
    param([object[]]$Drivers = @(), [string[]]$Adapters = @(), [int]$Max = 6)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Adapters) {
        # "(TM)" / "(R)" inside a name only scrambles the text in a right-to-left report
        $nm = ((([string]$a) -replace '\((TM|R|C)\)|[\u00AE\u2122]', '') -replace '\s{2,}', ' ').Trim()
        if ($nm -and $nm -notmatch '^(?i)microsoft\b' -and -not $out.Contains($nm)) { $out.Add($nm) }
    }
    foreach ($d in $Drivers) {
        if (-not $d) { continue }
        if ($d.Company) { if ([string]$d.Company -match '^(?i)microsoft\b') { continue } }
        elseif ($d.Trust -in 'OS', 'MS') { continue }
        $file = if ($d.Path) { [IO.Path]::GetFileName([string]$d.Path) } else { '' }
        if (("{0} {1} {2}" -f $d.Name, $d.Display, $file) -notmatch $DisplayDriverRx) { continue }
        $label = if ($file) { $file } else { [string]$d.Name }
        if ($d.Display -and [string]$d.Display -ne [string]$d.Name) { $label += ' (' + [string]$d.Display + ')' }
        if (-not $out.Contains($label)) { $out.Add($label) }
    }
    return @($out | Select-Object -First $Max)
}

# "Where is my memory?" as a headline: the two biggest parts of what Task Manager does not show ($Breakdown = the GB fields
# of the plan's memory object). Empty when less than 1 GB is hidden (then the classic headlines are clearer). -NoLeak:$false
# leaves out "No leak found" (a program is growing right now, so that cannot be claimed).
function Get-WhereHeadline {
    param($Breakdown, [bool]$NoLeak = $true)
    if (-not $Breakdown -or [double]$Breakdown.HiddenGB -lt 1) { return '' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $parts = @(
        @{ Key = 'verdict.part.shared'; GB = [double]$Breakdown.SharedUniqueGB; Order = 0 },
        @{ Key = 'verdict.part.drivers'; GB = [double]$Breakdown.DriverReservedGB; Order = 1 },
        @{ Key = 'verdict.part.kernel'; GB = [double]$Breakdown.KernelPoolsGB; Order = 2 },
        @{ Key = 'verdict.part.system'; GB = [double]$Breakdown.SystemOtherGB; Order = 3 },
        @{ Key = 'verdict.part.unexpl'; GB = [double]$Breakdown.UnexplainedGB; Order = 4 }
    ) | Sort-Object @{ Expression = { $_.GB }; Descending = $true }, @{ Expression = { $_.Order }; Descending = $false }
    $one = $parts[0]; $two = $parts[1]
    $hid = ([double]$Breakdown.HiddenGB).ToString('0.#', $inv)
    $keys = $(if ($NoLeak) { @('verdict.where', 'verdict.where.one') } else { @('verdict.where.part', 'verdict.where.part.one') })
    if ($two.GB -lt 0.1) { return (Get-Text $keys[1] $hid (Get-Text $one.Key) ($one.GB.ToString('0.#', $inv))) }
    return (Get-Text $keys[0] $hid (Get-Text $one.Key) ($one.GB.ToString('0.#', $inv)) (Get-Text $two.Key) ($two.GB.ToString('0.#', $inv)))
}

# The verdict headline, most urgent first. The breakdown headline answers the user's real question ("where is my memory?")
# whenever nothing worse is going on: no urgent or kernel finding, no growing driver reservation or unexplained memory and
# no high observation (an active pool leak is one). It says "No leak found" only when no program is growing right now.
function Get-VerdictHeadline {
    param([bool]$Urgent, [bool]$KernelPool, [bool]$DriverReservedLeak, [double]$DriverReservedGB = 0, [bool]$Unexplained,
        [bool]$Growing, $Breakdown, [int]$MaxLevel = 0)
    if ($Urgent) { return (Get-Text 'verdict.urgent') }
    if ($KernelPool) { return (Get-Text 'verdict.driver') }
    if ($DriverReservedLeak) { return (Get-Text 'verdict.drvres' (([double]$DriverReservedGB).ToString('0.#', [Globalization.CultureInfo]::InvariantCulture))) }
    if ($Unexplained) { return (Get-Text 'verdict.unacc') }
    if ($MaxLevel -lt 3) {
        $where = Get-WhereHeadline $Breakdown -NoLeak (-not $Growing)
        if ($where) {
            if ($MaxLevel -ge 2) { $where += Get-Text 'verdict.where.more' }
            return $where
        }
    }
    if ($MaxLevel -ge 2) { return (Get-Text 'verdict.medium') }
    return (Get-Text 'verdict.ok')
}

# ---------------------------------------------------------------- snapshot #1
Phase 'start'
Say 'Snapshot #1: memory counters, per-process memory, kernel pool tags ...'
$t0 = Get-Date
$mem1 = Get-MemCounters
$perf1 = Get-ProcPerf
$pool1 = Get-PoolSnapshot
if (-not $pool1) { Warn 'Kernel pool-tag table unavailable (needs admin / native helper).' }

# ---------------------------------------------------------------- system facts
Phase 'after snapshot1'
Say 'Collecting system facts ...'
$osInfo = Get-CimInstance Win32_OperatingSystem -Property Caption, Version, LastBootUpTime
$csInfo = Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory, HypervisorPresent
$installedBytes = (Get-CimInstance Win32_PhysicalMemory -Property Capacity | Measure-Object Capacity -Sum).Sum
if (-not $installedBytes) { $installedBytes = [int64]$csInfo.TotalPhysicalMemory }
$gpus = @(Get-CimInstance Win32_VideoController -Property Name | ForEach-Object { $_.Name })
$cpuName = (Get-CimInstance Win32_Processor -Property Name | Select-Object -First 1).Name
$uptime = (Get-Date) - $osInfo.LastBootUpTime
$fastStartup = $false
try { $fastStartup = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled -eq 1) } catch { }
$sys = [pscustomobject]@{
    Host = $HostName
    User = $env:USERNAME
    OS = "$($osInfo.Caption) ($($osInfo.Version))"
    Cpu = $cpuName
    Gpus = ($gpus -join ' / ')
    InstalledGB = ToGB $installedBytes
    UsableGB = ToGB $mem1.TotalBytes
    ReservedGB = ToGB ($installedBytes - $mem1.TotalBytes)
    Uptime = ('{0}d {1}h {2}m' -f $uptime.Days, $uptime.Hours, $uptime.Minutes)
    UptimeDays = [math]::Round($uptime.TotalDays, 1)
    FastStartup = $fastStartup
    Hypervisor = [bool]$csInfo.HypervisorPresent
    IsAdmin = $IsAdmin
    Culture = (Get-Culture).Name
}

# ---------------------------------------------------------------- inventory of everything that runs / persists
$Items = New-Object System.Collections.ArrayList
function Add-Item([hashtable]$h) {
    # Signals / Sig are filled in later by plain assignment (Add-Member on ~1000 objects is slow and allocation-heavy)
    if (-not $h.ContainsKey('Signals')) { $h['Signals'] = $null }
    if (-not $h.ContainsKey('Sig')) { $h['Sig'] = $null }
    [void]$Items.Add([pscustomobject]$h)
}

Phase 'after sysfacts'
Say 'Inventory: processes ...'
# keep a small record per process (6 fields) instead of the full CIM objects
$cimProcs = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine, CreationDate | ForEach-Object {
        [pscustomobject]@{ ProcessId = [int]$_.ProcessId; ParentProcessId = [int]$_.ParentProcessId; Name = [string]$_.Name; ExecutablePath = [string]$_.ExecutablePath; CommandLine = [string]$_.CommandLine; CreationDate = $_.CreationDate }
    })
$procById = @{}
foreach ($p in $cimProcs) { $procById[$p.ProcessId] = $p }
$lsassCount = 0; foreach ($p in $cimProcs) { if ($p.Name -ieq 'lsass.exe') { $lsassCount++ } }

# network: who talks to the outside world (native table, no PowerShell module needed)
$netByPid = @{}
try {
    foreach ($row in [RamDoc.Native]::GetEstablishedTcp()) {
        $f = $row.Split('|'); $ra = $f[1]
        if ($ra -match '^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|::1|fe80|f[cd][0-9a-f]{2}:|0\.0\.0\.0|::$)') { continue }
        $k = [int]$f[0]
        if (-not $netByPid.ContainsKey($k)) { $netByPid[$k] = New-Object System.Collections.ArrayList }
        [void]$netByPid[$k].Add([pscustomobject]@{ Remote = $ra; Port = [int]$f[2] })
    }
} catch { Warn "Network table unavailable: $($_.Exception.Message)" }

foreach ($p in $cimProcs) {
    $id = [int]$p.ProcessId
    if ($id -eq 0) { continue }
    $pf = $perf1[$id]
    $parent = $procById[[int]$p.ParentProcessId]
    $exePath = [string]$p.ExecutablePath
    if (-not $exePath -and $NativeOk) {   # protected / other-user processes: ask the kernel for the image name instead
        try { $img = [RamDoc.Native]::GetImageName([uint32]$id); if ($img -match '^\\Device\\') { $exePath = [RamDoc.Native]::NtToDosPath($img) } } catch { }
    }
    Add-Item @{
        Kind = 'Process'; Name = $p.Name; Path = $exePath; Cmd = [string]$p.CommandLine
        Pid = $id; ParentName = $(if ($parent) { [string]$parent.Name } else { '' }); Start = $p.CreationDate
        PrivWS = $(if ($pf) { [int64]$pf.WorkingSetPrivate } else { 0 }); WS = $(if ($pf) { [int64]$pf.WorkingSet } else { 0 })
        PrivBytes = $(if ($pf) { [int64]$pf.PrivateBytes } else { 0 }); Handles = $(if ($pf) { [int]$pf.HandleCount } else { 0 })
        Net = $netByPid[$id]; Growth = 0
    }
}

Phase 'after proc inventory'
Say 'Inventory: services ...'
foreach ($s in (Get-CimInstance Win32_Service -Property Name, DisplayName, PathName, StartMode, State)) {
    if (-not $s.PathName -or $s.StartMode -eq 'Disabled') { continue }
    $exe = Get-ExePathFromCommand $s.PathName
    $path = $exe
    if ($exe -match 'svchost\.exe$') {
        $pk = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)\Parameters"
        if (Test-Path -LiteralPath $pk) {
            $dll = (Get-ItemProperty -LiteralPath $pk -Name ServiceDll -ErrorAction SilentlyContinue).ServiceDll
            if ($dll) { $path = Resolve-ExePath $dll }
        }
    }
    Add-Item @{ Kind = 'Service'; Name = $s.Name; Display = $s.DisplayName; Path = $path; Cmd = [string]$s.PathName; StartMode = $s.StartMode; State = $s.State }
}

Phase 'after services'
Say 'Inventory: scheduled tasks ...'
try {
    Import-Module -Name (Join-Path $PSHOME 'Modules\ScheduledTasks\ScheduledTasks.psd1') -ErrorAction Stop -Verbose:$false
    foreach ($t in (Get-ScheduledTask -ErrorAction Stop)) {
        if ($t.State -eq 'Disabled') { continue }
        foreach ($a in $t.Actions) {
            if (-not $a.PSObject.Properties['Execute'] -or -not $a.Execute) { continue }
            $path = Resolve-ExePath $a.Execute
            $cmd = ($a.Execute + ' ' + $a.Arguments).Trim()
            if ($t.TaskPath -like '\Microsoft\Windows\*' -and $path.ToLowerInvariant().StartsWith($WinDirL + '\') -and $cmd -notmatch 'https?://|-enc') { continue }
            Add-Item @{ Kind = 'Task'; Name = $t.TaskName; TaskPath = $t.TaskPath; Path = $path; Cmd = $cmd; State = [string]$t.State }
        }
    }
} catch { Warn "Scheduled tasks unavailable: $($_.Exception.Message)" }

Phase 'after tasks'
Say 'Inventory: startup entries ...'
$runKeys = New-Object System.Collections.ArrayList
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') { [void]$runKeys.Add($k) }
foreach ($u in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-' -and $_.PSChildName -notmatch '_Classes$' })) {
    foreach ($sub in 'Run', 'RunOnce') { [void]$runKeys.Add("Registry::HKEY_USERS\$($u.PSChildName)\SOFTWARE\Microsoft\Windows\CurrentVersion\$sub") }
}
foreach ($k in $runKeys) {
    $props = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    foreach ($v in $props.PSObject.Properties) {
        if ($v.Name -match '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { continue }
        $cmd = [string]$v.Value
        Add-Item @{ Kind = 'Autorun'; Name = $v.Name; Location = $k; Path = (Get-ExePathFromCommand $cmd); Cmd = $cmd; Via = 'Registry'; File = '' }
    }
}
$startupDirs = New-Object System.Collections.ArrayList
[void]$startupDirs.Add((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'))
$usersRoot = Split-Path -Parent $env:USERPROFILE; if (-not $usersRoot) { $usersRoot = "$env:SystemDrive\Users" }
foreach ($d in (Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue)) {
    [void]$startupDirs.Add((Join-Path $d.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'))
}
$wsh = $null
foreach ($d in $startupDirs) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $d -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -ieq 'desktop.ini') { continue }
        $target = $f.FullName; $cmd = $f.FullName
        if ($f.Extension -ieq '.lnk') {
            try {
                if (-not $wsh) { $wsh = New-Object -ComObject WScript.Shell }
                $lnk = $wsh.CreateShortcut($f.FullName)
                $target = Resolve-ExePath $lnk.TargetPath
                $cmd = ($lnk.TargetPath + ' ' + $lnk.Arguments).Trim()
            } catch { }
        }
        Add-Item @{ Kind = 'Autorun'; Name = $f.Name; Location = $d; Path = $target; Cmd = $cmd; Via = 'StartupFolder'; File = $f.FullName }
    }
}

Phase 'after startup'
Say 'Inventory: WMI permanent event subscriptions (fileless persistence) ...'
try {
    foreach ($c in (Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer -ErrorAction Stop)) {
        $cls = $c.CimClass.CimClassName
        if ($cls -eq 'NTEventLogEventConsumer' -and $c.Name -eq 'SCM Event Log Consumer') { continue }
        $cmd = ''
        if ($cls -eq 'CommandLineEventConsumer') { $cmd = ($c.ExecutablePath + ' ' + $c.CommandLineTemplate).Trim() }
        elseif ($cls -eq 'ActiveScriptEventConsumer') { $cmd = ($c.ScriptFileName + ' ' + $c.ScriptText).Trim() }
        Add-Item @{ Kind = 'Wmi'; Name = $c.Name; WmiClass = $cls; Path = ''; Cmd = $cmd }
    }
} catch { Warn "WMI subscriptions unavailable: $($_.Exception.Message)" }

Phase 'after wmi'
Say 'Inventory: running kernel drivers ...'
foreach ($d in (Get-CimInstance Win32_SystemDriver -Property Name, DisplayName, PathName, StartMode, State -Filter "State='Running'")) {
    if (-not $d.PathName) { continue }
    $path = Resolve-ExePath $d.PathName
    Add-Item @{ Kind = 'Driver'; Name = $d.Name; Display = $d.DisplayName; Path = $path; Cmd = ''; StartMode = $d.StartMode; State = $d.State }
}

# ---------------------------------------------------------------- hidden process check
Phase 'after drivers inv'
Say 'Hidden-process check (direct kernel PID probe vs. process lists) ...'
$hidden = New-Object System.Collections.ArrayList
if ($NativeOk) {
    try {
        $known = @{}
        $refresh = {   # two independent sources (kernel process list + WMI), IDs only, nothing retained
            foreach ($pr in [Diagnostics.Process]::GetProcesses()) { $known[[uint32]$pr.Id] = $true; $pr.Dispose() }
            foreach ($r in (Get-CimInstance Win32_Process -Property ProcessId)) { $known[[uint32]$r.ProcessId] = $true }
        }
        & $refresh
        $probe = [RamDoc.Native]::ProbePids(400000)
        & $refresh
        $cand = New-Object System.Collections.ArrayList
        foreach ($e in $probe) {
            $parts = $e.Split(':'); $pid1 = [uint32]$parts[0]
            if (-not $known.ContainsKey($pid1)) { [void]$cand.Add([pscustomobject]@{ Pid = $pid1; Kind = $parts[1]; Tag = $e }) }
        }
        if ($cand.Count -gt 0) {
            Start-Sleep -Seconds 2
            $probe2 = @{}
            foreach ($e in [RamDoc.Native]::ProbePids(400000)) { $probe2[$e] = $true }
            & $refresh
            foreach ($c in $cand) {
                if ($probe2.ContainsKey($c.Tag) -and -not $known.ContainsKey($c.Pid)) {
                    $img = [RamDoc.Native]::GetImageName($c.Pid)
                    $isWin = ($img -match '^\\Device\\HarddiskVolume\d+\\Windows\\')
                    [void]$hidden.Add([pscustomobject]@{ Pid = $c.Pid; Live = ($c.Kind -eq 'A'); Image = $img; IsWindowsImage = $isWin })
                }
            }
        }
    } catch { Warn "Hidden-process check failed: $($_.Exception.Message)" }
}
$hiddenLive = @($hidden | Where-Object { $_.Live })
$zombies = @($hidden | Where-Object { -not $_.Live })

# ---------------------------------------------------------------- rate every item
Phase 'after hidden'
Say 'Rating signatures / locations / command lines (this is the slow part) ...'
# never rate this tool's own process chain (powershell / cmd / the app that launched us)
$selfChain = @{}
$walk = [int]$PID
for ($depth = 0; $depth -lt 12 -and $walk -gt 0; $depth++) {
    $selfChain[$walk] = $true
    $pp = $procById[$walk]
    if (-not $pp) { break }
    $walk = [int]$pp.ParentProcessId
}
$rated = 0
foreach ($it in $Items) {
    $r = Get-Signals -Path $it.Path -Cmd $it.Cmd -Name $it.Name -Kind $it.Kind
    $extra = New-Object System.Collections.ArrayList
    foreach ($s in $r.Signals) { [void]$extra.Add($s) }
    if ($it.Kind -eq 'Process') {
        $ln = $it.Name.ToLowerInvariant(); $pn = $it.ParentName.ToLowerInvariant()
        if ($ln -eq 'svchost.exe' -and $pn -and $pn -ne 'services.exe') {
            [void]$extra.Add([pscustomobject]@{ Key = 'parent'; Points = 6; Text = (Get-Text 'sig.parent.svchost' $it.ParentName) })
        }
        if (($ln -eq 'lsass.exe' -or $ln -eq 'services.exe') -and $pn -and $pn -ne 'wininit.exe') {
            [void]$extra.Add([pscustomobject]@{ Key = 'parent'; Points = 6; Text = (Get-Text 'sig.parent.wininit' $it.Name $it.ParentName) })
        }
        if ($ln -eq 'lsass.exe' -and $lsassCount -gt 1) {
            [void]$extra.Add([pscustomobject]@{ Key = 'dup'; Points = 8; Text = (Get-Text 'sig.dup' $lsassCount) })
        }
        if ($it.Net) {
            foreach ($n in $it.Net) {
                if ($MiningPorts -contains $n.Port) {
                    [void]$extra.Add([pscustomobject]@{ Key = 'netmine'; Points = 6; Text = (Get-Text 'sig.netmine' "$($n.Remote):$($n.Port)") }); break
                }
            }
            if ($r.Sig.Trust -in 'Unsigned', 'Untrusted', 'Tampered') {
                [void]$extra.Add([pscustomobject]@{ Key = 'netunsigned'; Points = 1; Text = (Get-Text 'sig.netunsigned') })
            }
        }
    }
    if ($it.Kind -eq 'Wmi') {
        [void]$extra.Add([pscustomobject]@{ Key = 'wmi'; Points = 6; Text = (Get-Text 'sig.wmi' $it.WmiClass) })
    }
    if ($it.Kind -eq 'Process' -and -not $it.Path -and $PseudoProcs -contains $it.Name) {
        $r.Sig = [pscustomobject]@{ Status = 'Internal'; Publisher = 'Windows kernel'; Trust = 'OS' }   # kernel-internal pseudo processes have no file
    }
    if ($it.Kind -eq 'Process' -and $selfChain.ContainsKey($it.Pid)) { $extra.Clear() }
    $it.Signals = $extra
    $it.Sig = $r.Sig
    $rated++
    if ($rated % 50 -eq 0) { [GC]::Collect(); [GC]::WaitForPendingFinalizers(); if ($NativeOk) { [RamDoc.Native]::TrimWorkingSet() } }   # signature checks create many short-lived certificate objects: keep the heap flat
}

# ---------------------------------------------------------------- wait out the sampling window, snapshot #2
$elapsed = ((Get-Date) - $t0).TotalSeconds
if ($elapsed -lt $SampleSeconds) {
    $wait = [int][math]::Ceiling($SampleSeconds - $elapsed)
    Say "Waiting $wait s to complete the growth-observation window ..."
    Start-Sleep -Seconds $wait
}
Phase 'after rating'
Say 'Snapshot #2: measuring growth ...'
$mem2 = Get-MemCounters
$perf2 = Get-ProcPerf
$pool2 = Get-PoolSnapshot
$windowSec = [math]::Max(1, ($mem2.Time - $mem1.Time).TotalSeconds)

foreach ($it in $Items) {
    if ($it.Kind -ne 'Process') { continue }
    $a = $perf1[$it.Pid]; $b = $perf2[$it.Pid]
    if ($a -and $b) {
        $it.Growth = [int64]$b.PrivateBytes - [int64]$a.PrivateBytes
        $it.PrivWS = [int64]$b.WorkingSetPrivate; $it.WS = [int64]$b.WorkingSet
        $it.PrivBytes = [int64]$b.PrivateBytes; $it.Handles = [int]$b.HandleCount
        if ($it.Growth -ge 200MB -and $it.Sig.Trust -notin 'OS', 'MS' -and -not $selfChain.ContainsKey($it.Pid)) {
            [void]$it.Signals.Add([pscustomobject]@{ Key = 'growth'; Points = 2; Text = (Get-Text 'sig.growth' (ToMB $it.Growth)) })
        }
    }
}

# ---------------------------------------------------------------- group items into suspects (by file)
Phase 'after snapshot2'
Say 'Correlating findings ...'
$groups = @{}
foreach ($it in $Items) {
    if ($it.Signals.Count -eq 0) { continue }
    $key = if ($it.Path) { $it.Path.ToLowerInvariant() } else { "nopath:$($it.Kind):$($it.Name)".ToLowerInvariant() }
    # Windows/Microsoft binaries (powershell.exe, cmd.exe...) are shared by countless innocent commands:
    # judge each command separately instead of lumping them into one "file".
    if ($it.Path -and $it.Sig.Trust -in 'OS', 'MS') { $key = "$key|$($it.Kind)|$($it.Name)|$($it.Pid)" }
    if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.ArrayList }
    [void]$groups[$key].Add($it)
}
$persistKinds = 'Service', 'Task', 'Autorun', 'Driver', 'Wmi'
$suspectList = New-Object System.Collections.ArrayList
foreach ($key in $groups.Keys) {
    $members = $groups[$key]
    $merged = @{}
    foreach ($m in $members) { foreach ($s in $m.Signals) { if (-not $merged.ContainsKey($s.Key) -or $merged[$s.Key].Points -lt $s.Points) { $merged[$s.Key] = $s } } }
    $score = ($merged.Values | Measure-Object Points -Sum).Sum
    $hasPersist = @($members | Where-Object { $persistKinds -contains $_.Kind }).Count -gt 0
    if ($hasPersist -and $score -ge 4) { $score += 1; $merged['persist'] = [pscustomobject]@{ Key = 'persist'; Points = 1; Text = (Get-Text 'sig.persist') } }
    if ($score -lt 3) { continue }
    $risk = if ($score -ge 8) { 'High' } elseif ($score -ge 5) { 'Medium' } else { 'Low' }
    $first = $members[0]
    [void]$suspectList.Add([pscustomobject]@{
            Key = $key; Path = $first.Path; Name = $(if ($first.Path) { [IO.Path]::GetFileName($first.Path) } else { $first.Name })
            Score = [int]$score; Risk = $risk; Reasons = @($merged.Values | Sort-Object Points -Descending | ForEach-Object { $_.Text })
            Members = $members; Trust = $first.Sig.Trust; SigStatus = $first.Sig.Status; Publisher = $first.Sig.Publisher
        })
}
$suspects = @($suspectList | Sort-Object Score -Descending)

# enrich suspects with hash / size / version info, and attach every context that uses the same file
$allByPath = @{}
foreach ($it in $Items) { if ($it.Path) { $k = $it.Path.ToLowerInvariant(); if (-not $allByPath.ContainsKey($k)) { $allByPath[$k] = New-Object System.Collections.ArrayList }; [void]$allByPath[$k].Add($it) } }
$suspectOut = New-Object System.Collections.ArrayList
$n = 0
foreach ($s in $suspects) {
    $n++
    $sha = ''; $size = 0; $created = ''; $company = ''; $desc = ''; $exists = $false
    if ($s.Path -and (Test-Path -LiteralPath $s.Path -PathType Leaf)) {
        $exists = $true
        try { $sha = (Get-FileHash -LiteralPath $s.Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
        try { $fi = Get-Item -LiteralPath $s.Path -Force; $size = $fi.Length; $created = IsoDate $fi.CreationTime; $company = [string]$fi.VersionInfo.CompanyName; $desc = [string]$fi.VersionInfo.FileDescription } catch { }
    }
    $ctx = if ($s.Path -and $s.Trust -notin 'OS', 'MS') { @($allByPath[$s.Path.ToLowerInvariant()]) } else { @($s.Members) }
    $procs = @($ctx | Where-Object Kind -eq 'Process' | ForEach-Object { [pscustomobject]@{ pid = $_.Pid; start = (IsoDate $_.Start); cmd = $_.Cmd; privMB = (ToMB $_.PrivWS); growthMB = (ToMB $_.Growth); remote = @(if ($_.Net) { $_.Net | ForEach-Object { "$($_.Remote):$($_.Port)" } | Select-Object -First 5 }) } })
    $svcs = @($ctx | Where-Object Kind -eq 'Service' | ForEach-Object { [pscustomobject]@{ name = $_.Name; display = $_.Display; startMode = $_.StartMode; state = $_.State } })
    $tasks = @($ctx | Where-Object Kind -eq 'Task' | ForEach-Object { [pscustomobject]@{ taskPath = $_.TaskPath; taskName = $_.Name; state = $_.State; cmd = $_.Cmd } })
    $runs = @($ctx | Where-Object Kind -eq 'Autorun' | ForEach-Object { [pscustomobject]@{ via = $_.Via; location = $_.Location; name = $_.Name; value = $_.Cmd; file = $_.File } })
    $drvs = @($ctx | Where-Object Kind -eq 'Driver' | ForEach-Object { [pscustomobject]@{ name = $_.Name; display = $_.Display; startMode = $_.StartMode } })
    $wmis = @($ctx | Where-Object Kind -eq 'Wmi' | ForEach-Object { [pscustomobject]@{ class = $_.WmiClass; name = $_.Name; cmd = $_.Cmd } })
    [void]$suspectOut.Add([pscustomobject]@{
            id = $n; risk = $s.Risk; score = $s.Score; name = $s.Name; path = $s.Path; fileExists = $exists
            protectedFile = ($s.Trust -in 'OS', 'MS')
            sha256 = $sha; sizeBytes = $size; created = $created; trust = $s.Trust; sigStatus = $s.SigStatus; publisher = $s.Publisher
            company = $company; description = $desc; reasons = $s.Reasons
            procs = $procs; services = $svcs; tasks = $tasks; autoruns = $runs; drivers = $drvs; wmi = $wmis
        })
}

# ---------------------------------------------------------------- memory accounting
$used = $mem2.TotalBytes - $mem2.AvailBytes
$allProc = @($Items | Where-Object Kind -eq 'Process')
$sumPriv = ($allProc | Measure-Object PrivWS -Sum).Sum
$sumWS = ($allProc | Measure-Object WS -Sum).Sum
$unaccounted = [math]::Max(0.0, [double]($used - $sumWS - $mem2.NonPaged - $mem2.ModifiedBytes))   # 1.0-1.1 formula, kept for older readers
$shared = [math]::Max(0.0, [double]($sumWS - $sumPriv))   # summed over processes: a page mapped by 10 processes counts 10 times

# top consumers (per process and per program); "shared" per program = its working sets minus their private part
$topProcs = @($allProc | Sort-Object PrivWS -Descending | Select-Object -First 15 | ForEach-Object {
        [pscustomobject]@{ pid = $_.Pid; name = $_.Name; privMB = (ToMB $_.PrivWS); wsMB = (ToMB $_.WS); commitMB = (ToMB $_.PrivBytes); handles = $_.Handles; growthMB = (ToMB $_.Growth); trust = $_.Sig.Trust; publisher = $_.Sig.Publisher; path = $_.Path }
    })
$programs = @($allProc | Group-Object { $_.Name.ToLowerInvariant() } | ForEach-Object {
        $pw = [double]($_.Group | Measure-Object PrivWS -Sum).Sum
        $pws = [double]($_.Group | Measure-Object WS -Sum).Sum
        $pb = ($_.Group | Measure-Object PrivBytes -Sum).Sum
        $f = $_.Group | Where-Object { $_.Sig.Trust -ne 'Unknown' } | Select-Object -First 1   # prefer an instance whose path we could read
        if (-not $f) { $f = $_.Group | Select-Object -First 1 }
        [pscustomobject]@{ name = $f.Name; count = $_.Count; privMB = (ToMB $pw); sharedMB = (ToMB ([math]::Max(0.0, $pws - $pw))); commitMB = (ToMB $pb); trust = $f.Sig.Trust; publisher = $f.Sig.Publisher }
    })
$byProgram = @($programs | Sort-Object privMB -Descending | Select-Object -First 12)
$topShared = @($programs | Where-Object { $_.sharedMB -gt 0 } | Sort-Object sharedMB -Descending | Select-Object -First 3 | ForEach-Object { [pscustomobject]@{ name = $_.name; count = $_.count; sharedMB = $_.sharedMB } })

# memory reserved by drivers (contiguous allocations recorded in the pool tag table, see Get-DriverReservedBytes)
$drvResBytes = 0.0; $drvResGrowth = 0.0
if ($pool2) {
    $contig2 = 0.0; $otherNon2 = 0.0
    foreach ($r in $pool2.Values) { if ($ContigTags -ccontains [string]$r.Tag) { $contig2 += [double]$r.NonPagedUsed } else { $otherNon2 += [double]$r.NonPagedUsed } }
    $drvResBytes = Get-DriverReservedBytes -ContigBytes $contig2 -OtherNonPagedTagBytes $otherNon2 -NonPagedCounter ([double]$mem2.NonPaged)
    if ($pool1) {
        $contig1 = 0.0
        foreach ($r in $pool1.Values) { if ($ContigTags -ccontains [string]$r.Tag) { $contig1 += [double]$r.NonPagedUsed } }
        $drvResGrowth = $contig2 - $contig1
    }
}
# the company is read only for the few drivers whose name looks like graphics / capture / virtual display
$drvForCands = @($Items | Where-Object { $_.Kind -eq 'Driver' } | ForEach-Object {
        $file = if ($_.Path) { [IO.Path]::GetFileName($_.Path) } else { '' }
        if (("{0} {1} {2}" -f $_.Name, $_.Display, $file) -match $DisplayDriverRx) {
            $co = ''; try { $co = [string](Get-Item -LiteralPath $_.Path -Force -ErrorAction Stop).VersionInfo.CompanyName } catch { }
            [pscustomobject]@{ Name = $_.Name; Display = $_.Display; Path = $_.Path; Company = $co; Trust = $_.Sig.Trust }
        }
    })
$drvResCands = @(Get-DriverReservedCandidates -Drivers $drvForCands -Adapters $gpus)
$bd = Get-MemoryBreakdown -Used ([double]$used) -Private ([double]$sumPriv) -SharedSum $shared -NonPaged ([double]$mem2.NonPaged) -PagedResident ([double]$mem2.PagedResident) `
    -CacheResident ([double]$mem2.CacheResident) -DriverResident ([double]$mem2.DriverResident) -Modified ([double]$mem2.ModifiedBytes) -DriverReserved $drvResBytes
$memory = [pscustomobject]@{
    TotalGB = ToGB $mem2.TotalBytes; UsedGB = ToGB $used; AvailGB = ToGB $mem2.AvailBytes
    FreeGB = ToGB $mem2.FreeBytes; StandbyGB = ToGB $mem2.StandbyBytes; ModifiedGB = ToGB $mem2.ModifiedBytes
    ProcPrivateGB = ToGB $sumPriv; ProcSharedGB = ToGB $shared; NonPagedGB = ToGB $mem2.NonPaged
    PagedGB = ToGB $mem2.Paged; PagedResidentGB = ToGB $mem2.PagedResident; UnaccountedGB = ToGB $unaccounted
    CommittedGB = ToGB $mem2.Committed; CommitLimitGB = ToGB $mem2.CommitLimit
    CacheResidentGB = ToGB $mem2.CacheResident; DriverResidentGB = ToGB $mem2.DriverResident
    WindowSec = [math]::Round($windowSec, 0)
    NonPagedGrowthMB = ToMB ($mem2.NonPaged - $mem1.NonPaged); PagedGrowthMB = ToMB ($mem2.Paged - $mem1.Paged)
    CommitGrowthMB = ToMB ($mem2.Committed - $mem1.Committed); UsedGrowthMB = ToMB (($mem2.TotalBytes - $mem2.AvailBytes) - ($mem1.TotalBytes - $mem1.AvailBytes))
    # additive fields (added after 1.1.2): where the memory that Task Manager does not show is (Get-MemoryBreakdown)
    HiddenGB = ToGB $bd.Hidden; SharedUniqueGB = ToGB $bd.Shared; DriverReservedGB = ToGB $bd.Drivers; DriverReservedKnown = [bool]$pool2
    DriverReservedGrowthMB = ToMB $drvResGrowth; KernelPoolsGB = ToGB $bd.Kernel; SystemOtherGB = ToGB $bd.System
    UnexplainedGB = ToGB $bd.Unexplained; UnattributedGB = ToGB $bd.Unattributed
    TopShared = @($topShared); DriverReservedCandidates = @($drvResCands)
}
$topGrowers = @($allProc | Where-Object { $_.Growth -ge 20MB } | Sort-Object Growth -Descending | Select-Object -First 8 | ForEach-Object {
        [pscustomobject]@{ pid = $_.Pid; name = $_.Name; growthMB = (ToMB $_.Growth); commitMB = (ToMB $_.PrivBytes); trust = $_.Sig.Trust }
    })

# ---------------------------------------------------------------- kernel pool tags -> owning drivers
$poolNon = @(); $poolPaged = @(); $poolGrow = @()
if ($pool2) {
Phase 'after correlation'
    Say 'Mapping top pool tags to driver files ...'
    $rows2 = $pool2.Values
    $topNon = @($rows2 | Sort-Object NonPagedUsed -Descending | Select-Object -First 12)
    $topPg = @($rows2 | Sort-Object PagedUsed -Descending | Select-Object -First 6)
    $growNon = @()
    if ($pool1) {
        $growNon = @($rows2 | ForEach-Object {
                $o = $pool1[$_.Tag]; $before = if ($o) { [int64]$o.NonPagedUsed + [int64]$o.PagedUsed } else { 0 }
                [pscustomobject]@{ Row = $_; Delta = ([int64]$_.NonPagedUsed + [int64]$_.PagedUsed) - $before }
            } | Where-Object { $_.Delta -ge 1MB } | Sort-Object Delta -Descending | Select-Object -First 6)
    }
    $wanted = New-Object System.Collections.Generic.HashSet[string]
    # the contiguous tags are written by the memory manager for whichever driver asked, so a byte search would only find chance matches
    foreach ($r in ($topNon + $topPg + ($growNon | ForEach-Object { $_.Row }))) { if ($r.Printable -and $ContigTags -cnotcontains [string]$r.Tag) { [void]$wanted.Add($r.Tag) } }
    $driverFiles = @($Items | Where-Object { $_.Kind -eq 'Driver' -and $_.Path -and (Test-Path -LiteralPath $_.Path) } | ForEach-Object { $_.Path } | Select-Object -Unique)
    $tagMap = @{}
    if ($NativeOk -and $driverFiles.Count -gt 0) {
        try { $tagMap = [RamDoc.Native]::FindTagsInFiles([string[]]$driverFiles, [string[]]@($wanted)) } catch { Warn "Tag->driver search failed: $($_.Exception.Message)" }
    }
    $mkRow = {
        param($r, $bytes, $delta)
        $files = @(); if ($tagMap -and $tagMap.ContainsKey($r.Tag)) { $files = @($tagMap[$r.Tag]) }
        $cands = @($files | ForEach-Object {
                $sg = Get-SigInfo $_
                [pscustomobject]@{ file = [IO.Path]::GetFileName($_); path = $_; trust = $sg.Trust; publisher = $sg.Publisher }
            })
        [pscustomobject]@{
            tag = $r.Tag; mb = (ToMB $bytes); deltaMB = $(if ($null -ne $delta) { [math]::Round($delta / 1MB, 1) } else { 0 })
            allocs = $(if ($bytes -eq $r.NonPagedUsed) { $r.NonPagedAllocs } else { $r.PagedAllocs })
            known = $(if ($KnownTags.ContainsKey($r.Tag)) { $KnownTags[$r.Tag] } else { '' })
            candidates = @(if ($cands.Count -le 8) { $cands }); tooGeneric = ($cands.Count -gt 8)
        }
    }
    $poolNon = @($topNon | ForEach-Object { & $mkRow $_ $_.NonPagedUsed $null })
    $poolPaged = @($topPg | ForEach-Object { & $mkRow $_ $_.PagedUsed $null })
    $poolGrow = @($growNon | ForEach-Object { & $mkRow $_.Row ([int64]$_.Row.NonPagedUsed + [int64]$_.Row.PagedUsed) $_.Delta })
}

# third-party running drivers (the usual suspects for a pool leak)
$drivers3p = @($Items | Where-Object { $_.Kind -eq 'Driver' -and $_.Sig.Trust -notin 'OS', 'MS' } | ForEach-Object {
        $fi = $null; try { $fi = Get-Item -LiteralPath $_.Path -Force -ErrorAction Stop } catch { }
        [pscustomobject]@{
            name = $_.Name; display = $_.Display; file = [IO.Path]::GetFileName($_.Path); path = $_.Path; trust = $_.Sig.Trust; publisher = $_.Sig.Publisher
            company = $(if ($fi) { [string]$fi.VersionInfo.CompanyName } else { '' }); version = $(if ($fi) { [string]$fi.VersionInfo.FileVersion } else { '' })
            installed = $(if ($fi) { IsoDate $fi.CreationTime } else { '' }); startMode = $_.StartMode
        }
    } | Sort-Object installed -Descending)

# ---------------------------------------------------------------- misc evidence
Phase 'after pool map'
Say 'Collecting Defender status and event-log evidence ...'
$defender = $null
try {
    # the same WMI classes the Defender cmdlets read, without loading the (large) Defender PowerShell module
    $dns = 'root/Microsoft/Windows/Defender'
    $mp = Get-CimInstance -Namespace $dns -ClassName MSFT_MpComputerStatus -Property AMServiceEnabled, RealTimeProtectionEnabled, AntivirusSignatureAge, QuickScanAge -ErrorAction Stop | Select-Object -First 1
    if (-not $mp) { throw 'no Defender status' }
    $threats = @()
    try { $threats = @(Get-CimInstance -Namespace $dns -ClassName MSFT_MpThreatDetection -Property InitialDetectionTime, ProcessName, Resources -ErrorAction Stop | Sort-Object InitialDetectionTime -Descending | Select-Object -First 5 | ForEach-Object { [pscustomobject]@{ time = (IsoDate $_.InitialDetectionTime); process = [string]$_.ProcessName; resources = (@($_.Resources) -join '; ') } }) } catch { }
    $defender = [pscustomobject]@{
        Enabled = [bool]$mp.AMServiceEnabled; RealTime = [bool]$mp.RealTimeProtectionEnabled
        SignatureAgeDays = [int]$mp.AntivirusSignatureAge; QuickScanAgeDays = [int]$mp.QuickScanAge; RecentThreats = $threats
    }
} catch { Warn 'Windows Defender status unavailable (a third-party antivirus may be in charge).' }

$exhaustion = @()
try {
    # .NET event-log reader instead of Get-WinEvent (no extra PowerShell module); newest first, at most 3 events
    $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('System', [System.Diagnostics.Eventing.Reader.PathType]::LogName, "*[System[Provider[@Name='Microsoft-Windows-Resource-Exhaustion-Detector'] and (EventID=2004)]]")
    $q.ReverseDirection = $true
    $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
    try {
        $list = New-Object System.Collections.ArrayList
        while ($list.Count -lt 3 -and ($ev = $reader.ReadEvent())) {
            $msg = ''; try { $msg = [string]$ev.FormatDescription() } catch { }
            if ($msg.Length -gt 700) { $msg = $msg.Substring(0, 700) + ' ...' }
            [void]$list.Add([pscustomobject]@{ time = (IsoDate $ev.TimeCreated); message = $msg })
            $ev.Dispose()
        }
        $exhaustion = @($list)
    } finally { $reader.Dispose() }
} catch { }

Phase 'after evidence'
$anomalies = New-Object System.Collections.ArrayList
try {
    $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
    if ($wl.Shell -and $wl.Shell -ne 'explorer.exe') { [void]$anomalies.Add([pscustomobject]@{ Level = 'high'; Title = (Get-Text 'anom.shell.t'); Detail = (Get-Text 'anom.shell.d' $wl.Shell) }) }
    if ($wl.Userinit -and $wl.Userinit.TrimEnd(',') -ine "$WinDir\system32\userinit.exe") { [void]$anomalies.Add([pscustomobject]@{ Level = 'high'; Title = (Get-Text 'anom.userinit.t'); Detail = (Get-Text 'anom.userinit.d' $wl.Userinit) }) }
} catch { }
try {
    $ifeo = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' -ErrorAction Stop
    foreach ($k in $ifeo) {
        $dbg = (Get-ItemProperty -LiteralPath $k.PSPath -Name Debugger -ErrorAction SilentlyContinue).Debugger
        if ($dbg) { [void]$anomalies.Add([pscustomobject]@{ Level = 'med'; Title = (Get-Text 'anom.ifeo.t' $k.PSChildName); Detail = (Get-Text 'anom.ifeo.d' $dbg) }) }
    }
} catch { }
try {
    $aw = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows' -ErrorAction Stop
    if ($aw.LoadAppInit_DLLs -eq 1 -and $aw.AppInit_DLLs) { [void]$anomalies.Add([pscustomobject]@{ Level = 'high'; Title = (Get-Text 'anom.appinit.t'); Detail = (Get-Text 'anom.appinit.d' $aw.AppInit_DLLs) }) }
} catch { }

# ---------------------------------------------------------------- observations + verdict (in the scan language, see lib\Strings.ps1)
$obs = New-Object System.Collections.ArrayList
function Add-Obs([string]$Level, [string]$Title, [string]$Body) { [void]$obs.Add([pscustomobject]@{ Level = $Level; Title = $Title; Body = $Body }) }
$totalB = $mem2.TotalBytes
# thresholds (bytes); -ThresholdScale lets you make the tool more / less sensitive
$Th = [pscustomobject]@{
    NppHigh = $ThresholdScale * [math]::Max(3GB, 0.12 * $totalB); NppMed = $ThresholdScale * [math]::Max(1.5GB, 0.06 * $totalB)
    PagedHigh = $ThresholdScale * [math]::Max(3GB, 0.12 * $totalB)
    UnaccHigh = $ThresholdScale * [math]::Max(4GB, 0.2 * $totalB); UnaccMed = $ThresholdScale * [math]::Max(2GB, 0.1 * $totalB)
}
$topTag = if ($poolNon.Count -gt 0) { $poolNon[0] } else { $null }
$topTagText = ''
if ($topTag) {
    $who = if ($topTag.known) { $topTag.known } elseif (@($topTag.candidates).Count -gt 0) { Get-Text 'obs.toptag.maybe' ((@($topTag.candidates) | ForEach-Object { $_.file }) -join (Get-Text 'sep.list')) } else { Get-Text 'obs.toptag.unknown' }
    $topTagText = Get-Text 'obs.toptag' $topTag.tag $topTag.mb $who
}
if ($mem2.NonPaged -ge $Th.NppHigh) {
    Add-Obs 'high' (Get-Text 'obs.npp.high.t') ((Get-Text 'obs.npp.high.b' (Num (ToGB $mem2.NonPaged))) + $topTagText)
} elseif ($mem2.NonPaged -ge $Th.NppMed) {
    Add-Obs 'med' (Get-Text 'obs.npp.med.t') ((Get-Text 'obs.npp.med.b' (Num (ToGB $mem2.NonPaged))) + $topTagText)
}
if ($mem2.Paged -ge $Th.PagedHigh) {
    Add-Obs 'high' (Get-Text 'obs.paged.t') (Get-Text 'obs.paged.b' (Num (ToGB $mem2.Paged)))
}
# memory reserved by a hardware driver (invisible in Task Manager and in the pool counters), before the security findings
$drvResLevel = Get-DriverReservedLevel -Bytes $drvResBytes -GrowthBytes $drvResGrowth -Scale $ThresholdScale
if ($drvResLevel) {
    $candText = if ($drvResCands.Count -gt 0) { $drvResCands -join (Get-Text 'sep.list') } else { Get-Text 'obs.drvres.nocand' }
    $drvBody = Get-Text 'obs.drvres.b' (Num (ToGB $drvResBytes)) $candText
    if ($drvResGrowth -ge 30MB) { $drvBody += ' ' + (Get-Text 'obs.drvres.grow' (ToMB $drvResGrowth) $memory.WindowSec) }
    $drvTitle = if ($drvResLevel -eq 'high') { Get-Text 'obs.drvres.high.t' } else { Get-Text 'obs.drvres.t' (Num (ToGB $drvResBytes)) }
    Add-Obs $drvResLevel $drvTitle $drvBody
}
# memory that nothing explains: the corrected remainder (Get-MemoryBreakdown), which no longer counts the kernel pools, the
# cache or the driver reservations (they have counters / observations of their own) and no longer hides behind shared pages
$unexplained = [double]$bd.Unexplained
if ($unexplained -ge $Th.UnaccHigh) {
    Add-Obs 'high' (Get-Text 'obs.unacc.high.t') (Get-Text 'obs.unacc.high.b' (Num (ToGB $unexplained)))
} elseif ($unexplained -ge $Th.UnaccMed) {
    Add-Obs 'med' (Get-Text 'obs.unacc.med.t') (Get-Text 'obs.unacc.med.b' (Num (ToGB $unexplained)))
}
if ($allProc.Count -gt 0 -and $byProgram.Count -gt 0) {
    $topP = $byProgram[0]
    if (($topP.privMB * 1MB) -ge 0.30 * $used) {
        $lvl = if ($topP.trust -in 'OS', 'MS', 'Signed') { 'info' } else { 'med' }
        $sigText = [string]$topP.trust + $(if ($topP.publisher) { ' - ' + $topP.publisher })
        Add-Obs $lvl (Get-Text 'obs.top.t' $topP.name) (Get-Text 'obs.top.b' $topP.name $topP.count (Num ($topP.privMB / 1024)) $sigText)
    }
}
if ($hiddenLive.Count -gt 0) {
    Add-Obs 'high' (Get-Text 'obs.hidden.t') (Get-Text 'obs.hidden.b' $hiddenLive.Count (($hiddenLive | ForEach-Object { $_.Pid }) -join ', '))
}
$zombieOdd = @($zombies | Where-Object { -not $_.IsWindowsImage })
if ($zombieOdd.Count -gt 0) {
    Add-Obs 'med' (Get-Text 'obs.zombie.t') (Get-Text 'obs.zombie.b' (($zombieOdd | ForEach-Object { "$($_.Pid) [$($_.Image)]" }) -join (Get-Text 'sep.semi')))
}
$highS = @($suspectOut | Where-Object { $_.risk -eq 'High' })
$medS = @($suspectOut | Where-Object { $_.risk -eq 'Medium' })
if ($highS.Count -gt 0) {
    Add-Obs 'high' (Get-Text 'obs.high.t' $highS.Count) (Get-Text 'obs.high.b' (($highS | ForEach-Object { $_.name }) -join (Get-Text 'sep.list')))
}
if ($medS.Count -gt 0) {
    Add-Obs 'med' (Get-Text 'obs.med.t' $medS.Count) (Get-Text 'obs.med.b' (($medS | Select-Object -First 8 | ForEach-Object { $_.name }) -join (Get-Text 'sep.list')))
}
foreach ($a in $anomalies) { Add-Obs $a.Level $a.Title $a.Detail }
if ($mem2.NonPaged - $mem1.NonPaged -ge 30MB -or $mem2.Paged - $mem1.Paged -ge 30MB) {
    Add-Obs 'high' (Get-Text 'obs.leak.t') (Get-Text 'obs.leak.b' $memory.WindowSec $memory.NonPagedGrowthMB $memory.PagedGrowthMB)
} elseif ($topGrowers.Count -gt 0 -and $topGrowers[0].growthMB -ge 100) {
    Add-Obs 'med' (Get-Text 'obs.grower.t') (Get-Text 'obs.grower.b' $topGrowers[0].name $topGrowers[0].pid $topGrowers[0].growthMB $memory.WindowSec)
}
if ($mem2.Committed -ge 0.9 * $mem2.CommitLimit) {
    Add-Obs 'med' (Get-Text 'obs.commit.t') (Get-Text 'obs.commit.b' (Num (ToGB $mem2.Committed)) (Num (ToGB $mem2.CommitLimit)))
}
if ($sys.ReservedGB -ge 1) {
    Add-Obs 'info' (Get-Text 'obs.reserved.t') (Get-Text 'obs.reserved.b' $sys.InstalledGB $sys.UsableGB $sys.ReservedGB)
}
if ($sys.UptimeDays -ge 7 -and $sys.FastStartup) {
    Add-Obs 'med' (Get-Text 'obs.fast.t') (Get-Text 'obs.fast.b' $sys.Uptime)
}
if ($defender -and (-not $defender.RealTime)) { Add-Obs 'med' (Get-Text 'obs.defrt.t') (Get-Text 'obs.defrt.b') }
if ($defender -and $defender.RecentThreats.Count -gt 0) { Add-Obs 'med' (Get-Text 'obs.defthreat.t') (Get-Text 'obs.defthreat.b' $defender.RecentThreats[0].resources) }
if ($mem2.StandbyBytes -ge 0.25 * $totalB) {
    Add-Obs 'info' (Get-Text 'obs.standby.t') (Get-Text 'obs.standby.b' (Num (ToGB $mem2.StandbyBytes)))
}

$levels = @{ high = 3; med = 2; low = 1; info = 0 }
$maxLevel = 0; foreach ($o in $obs) { if ($levels[$o.Level] -gt $maxLevel) { $maxLevel = $levels[$o.Level] } }
$headline = Get-VerdictHeadline -Urgent ($hiddenLive.Count -gt 0 -or $highS.Count -gt 0) -KernelPool ($mem2.NonPaged -ge $Th.NppMed -or $mem2.Paged -ge $Th.PagedHigh) `
    -DriverReservedLeak ($drvResLevel -eq 'high') -DriverReservedGB (ToGB $drvResBytes) -Unexplained ($unexplained -ge $Th.UnaccMed) `
    -Growing ($topGrowers.Count -gt 0 -and $topGrowers[0].growthMB -ge 100) -Breakdown $memory -MaxLevel $maxLevel
$verdict = [pscustomobject]@{ Level = $(@('ok', 'low', 'med', 'high')[$maxLevel]); Headline = $headline }
# most severe first; findings of the same level keep the order they were added in (memory explanations before security ones)
$obsSorted = @(for ($i = 0; $i -lt $obs.Count; $i++) { [pscustomobject]@{ O = $obs[$i]; I = $i } }) |
    Sort-Object @{ Expression = { -$levels[$_.O.Level] } }, @{ Expression = { $_.I } } | ForEach-Object { $_.O }

# ---------------------------------------------------------------- write outputs
$data = [pscustomobject]@{
    Tool = 'RAM-Doctor'; Version = $ToolVersion; Lang = (Get-UiLang); Created = IsoDate (Get-Date); Sys = $sys; Memory = $memory; Verdict = $verdict
    Observations = @($obsSorted); TopProcesses = $topProcs; ByProgram = $byProgram; TopGrowers = $topGrowers
    PoolNonPaged = $poolNon; PoolPaged = $poolPaged; PoolGrowing = $poolGrow; PoolAvailable = [bool]$pool2
    Suspects = @($suspectOut); Drivers3p = $drivers3p; Hidden = @($hidden); Defender = $defender; Exhaustion = $exhaustion
    Warnings = @($Warnings); ItemCounts = [pscustomobject]@{
        Processes = @($Items | Where-Object Kind -eq 'Process').Count; Services = @($Items | Where-Object Kind -eq 'Service').Count
        Tasks = @($Items | Where-Object Kind -eq 'Task').Count; Autoruns = @($Items | Where-Object Kind -eq 'Autorun').Count
        Drivers = @($Items | Where-Object Kind -eq 'Driver').Count; Wmi = @($Items | Where-Object Kind -eq 'Wmi').Count
    }
}
# Keeps the reports folder small: the newest $Keep scans of THIS PC, and the scan just written always counts as one of
# them (a clock that runs behind must not make it look old). Scans of other PC names (copied here, or from before the PC
# was renamed) are never touched, as in 1.0.x. Only files that follow the exact naming scheme are ever removed.
function Remove-OldScans([string]$Dir, [string]$HostName, [string]$CurrentStamp, [int]$Keep = 3) {
    $mine = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter 'Plan-*.json' -File -Force -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($f.Name, '^Plan-(.+)-(\d{8}-\d{6})\.json$')
        if (-not $m.Success -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        if ($m.Groups[1].Value -ine $HostName) { continue }      # exact host match: host "PC" never eats files of host "PC-2"
        [void]$mine.Add([pscustomobject]@{ Host = $m.Groups[1].Value; Stamp = $m.Groups[2].Value })
    }
    $old = @($mine | Where-Object { $_.Stamp -ne $CurrentStamp } | Sort-Object Stamp -Descending | Select-Object -Skip ([Math]::Max(0, $Keep - 1)))
    foreach ($o in $old) {
        foreach ($n in "Plan-$($o.Host)-$($o.Stamp).json", "RAMDoctor-$($o.Host)-$($o.Stamp).html", "RAMDoctor-$($o.Host)-$($o.Stamp).json") {
            foreach ($x in $n, "$n.bak") {
                $fp = Join-Path $Dir $x
                $fi = New-Object IO.FileInfo($fp)
                if ($fi.Exists -and -not ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

# Two scans finishing at the same moment (two windows) must not prune each other's files or share a name.
$outLock = Enter-StoreLock -Name (Get-StoreLockName -Prefix 'reports' -Path $OutDir) -TimeoutMs 20000
if ($outLock.Status -eq 'Busy') { Warn 'Another scan is writing its results into the same folder; continuing without the folder lock.' }
while ((Test-Path -LiteralPath (Join-Path $OutDir "Plan-$HostName-$Stamp.json")) -or (Test-Path -LiteralPath (Join-Path $OutDir "RAMDoctor-$HostName-$Stamp.html"))) {
    $Stamp = ([datetime]::ParseExact($Stamp, 'yyyyMMdd-HHmmss', $Inv)).AddSeconds(1).ToString('yyyyMMdd-HHmmss', $Inv)   # never replace another scan's files
}
$base = "RAMDoctor-$HostName-$Stamp"
$htmlPath = Join-Path $OutDir "$base.html"
$jsonPath = Join-Path $OutDir "$base.json"
$planPath = Join-Path $OutDir "Plan-$HostName-$Stamp.json"
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
# Light footprint: only two small files per scan (report ~30 KB + plan ~15 KB). The big raw JSON is optional.
# Every file is written crash-safe (<file>.tmp, flushed, then renamed): a power cut never leaves a half-written plan behind.
if ($KeepRawJson) { try { Write-TextAtomic -Path $jsonPath -Text ($data | ConvertTo-Json -Depth 8) } catch { Warn "Raw data could not be written: $($_.Exception.Message)" } }
Phase 'before report write'
try { Write-TextAtomic -Path $htmlPath -Text (New-RamReportHtml $data) } catch { Warn "Report generation failed: $($_.Exception.Message)" }
Phase 'after html'
$peakMB = 0; $peakCommitMB = 0   # measured AFTER the heaviest step
try { $me = [Diagnostics.Process]::GetCurrentProcess(); $peakMB = [int][math]::Round($me.PeakWorkingSet64 / 1MB); $peakCommitMB = [int][math]::Round($me.PeakPagedMemorySize64 / 1MB) } catch { }
$plan = [pscustomobject]@{
    tool = 'RAM-Doctor'; version = $ToolVersion; lang = (Get-UiLang); host = $HostName; created = IsoDate (Get-Date); isAdmin = $IsAdmin; report = $htmlPath
    verdict = $verdict; observations = @($data.Observations); memory = $memory; suspects = @($suspectOut)
    scan = [pscustomobject]@{ durationSec = [int][math]::Round(((Get-Date) - $t0).TotalSeconds); peakWorkingSetMB = $peakMB; peakCommitMB = $peakCommitMB; sampleSeconds = [int]$windowSec }   # additive, informational
}
$planOk = $true
try { Write-JsonAtomic -Path $planPath -Object $plan -Schema 1 -Depth 12 }   # schema 1 = the plan format since 1.0.0 (plus additive fields)
catch { $planOk = $false; Warn "The plan could not be written: $($_.Exception.Message)" }
Phase 'after plan'
# keep only the 3 newest scans of this PC, so reports never pile up (exact host match: host "PC" must not eat files of host "PC-2")
if ($planOk) { try { Remove-OldScans -Dir $OutDir -HostName $HostName -CurrentStamp $Stamp } catch { } }
Exit-StoreLock $outLock
Write-Host ''
Write-Host '================ RESULT ================' -ForegroundColor Cyan
Write-Host ("Memory: used {0} GB of {1} GB | NonPaged {2} GB | Paged {3} GB | not attributed {4} GB (old formula {5} GB)" -f $memory.UsedGB, $memory.TotalGB, $memory.NonPagedGB, $memory.PagedGB, $memory.UnattributedGB, $memory.UnaccountedGB)
Write-Host ("Not shown by Task Manager: {0} GB = shared (estimate) {1} + driver-reserved {2}{3} + kernel pools {4} + cache/other {5} + unexplained {6} GB" -f $memory.HiddenGB, $memory.SharedUniqueGB, $memory.DriverReservedGB, $(if ($memory.DriverReservedKnown) { '' } else { ' (not measured)' }), $memory.KernelPoolsGB, $memory.SystemOtherGB, $memory.UnexplainedGB)
Write-Host ("Suspects: {0} high, {1} medium, {2} low | hidden live processes: {3}" -f $highS.Count, $medS.Count, @($suspectOut | Where-Object { $_.risk -eq 'Low' }).Count, $hiddenLive.Count)
Write-Host "Report : $htmlPath"
Write-Host "Plan   : $planPath   (read by the Quarantine step; nothing has been changed)"
Write-Host ("Tool footprint: peak working set {0} MB, peak commit {1} MB, scan took {2} s" -f $peakMB, $peakCommitMB, [int][math]::Round(((Get-Date) - $t0).TotalSeconds))
Write-Host '========================================' -ForegroundColor Cyan
# machine-readable for the window (ASCII only): it builds the file names from its own PC name and this stamp
if ($planOk) { Write-Host "SCAN_STAMP: $Stamp" } else { Write-Host 'SCAN_STAMP: none' }
if (-not $NoOpen) { try { Start-Process -FilePath $htmlPath } catch { } }
if (-not $planOk) { exit 1 }
