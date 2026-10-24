#requires -Version 5.1
<#
.SYNOPSIS
  RAM Doctor - triage for "RAM is full but Task Manager shows nothing".

.DESCRIPTION
  READ-ONLY. Collects memory / kernel pool / process / startup / driver evidence, writes an HTML
  report (Arabic) + a JSON action plan. It never kills, deletes or changes anything.
  Acting on the findings is a separate, explicit step: RAM-Doctor-Actions.ps1.
  No network access, nothing is uploaded.
#>
[CmdletBinding()]
param(
    [int]$SampleSeconds = 30,   # minimum observation window for "what is growing right now"
    [string]$OutDir = '',
    [switch]$NoOpen,
    [switch]$KeepRawJson,           # also save the full raw data as .json (for technicians; off by default to stay light)
    [double]$ThresholdScale = 1.0   # <1 = more sensitive (kernel-pool / unaccounted-memory alarms trigger earlier)
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$ToolVersion = '1.0'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$WinDir = $env:SystemRoot.TrimEnd('\')
$WinDirL = $WinDir.ToLowerInvariant()
$Warnings = New-Object System.Collections.Generic.List[string]

function Say([string]$m) { Write-Host ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $m) }
function Warn([string]$m) { $Warnings.Add($m); Write-Host ('   ! ' + $m) -ForegroundColor Yellow }
function ToGB([double]$b) { [math]::Round($b / 1GB, 2) }
function ToMB([double]$b) { [math]::Round($b / 1MB, 0) }
function Num($x) { ([double]$x).ToString('0.##', $Inv) }
function IsoDate($d) { if ($d) { ([datetime]$d).ToString('yyyy-MM-dd HH:mm:ss', $Inv) } else { '' } }

. (Join-Path $Root 'lib\Report.ps1')

# ---------------------------------------------------------------- output folder
if (-not $OutDir) { $OutDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'RAM-Doctor-Reports' }   # one small, easy-to-find folder
try {
    New-Item -ItemType Directory -Force -Path $OutDir -ErrorAction Stop | Out-Null
    $probe = Join-Path $OutDir '.write-test'
    Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force
} catch {
    $OutDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'RAM-Doctor-Reports'
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$HostName = $env:COMPUTERNAME

Say "RAM Doctor $ToolVersion  (admin: $IsAdmin)  - read-only scan, nothing will be changed"
if (-not $IsAdmin) { Warn 'Not running as administrator: results for protected processes / other users may be incomplete. Use 1-Scan.bat.' }

# ---------------------------------------------------------------- native helper
$NativeOk = $false
try {
    if (-not ('RamDoc.Native' -as [type])) {
        Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $Root 'lib\Native.cs') -Raw) -Language CSharp -ErrorAction Stop
    }
    $NativeOk = $true
} catch { Warn "Native helper failed to load (pool tags / hidden-process check disabled): $($_.Exception.Message)" }

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
        & $add 'missing' 5 'عملية شغّالة وملفها غير موجود على القرص (حُذف بعد التشغيل أو يعمل من الذاكرة فقط)'
    }
    if ($sig.Trust -eq 'Unsigned') { & $add 'unsigned' 2 'الملف غير موقّع رقميًا' }
    if ($sig.Trust -eq 'Untrusted') { & $add 'untrusted' 3 "توقيع الملف غير موثوق ($($sig.Status))" }
    if ($sig.Trust -eq 'Tampered') { & $add 'tampered' 8 'توقيع الملف لا يطابق محتواه (الملف عُدّل بعد توقيعه)' }
    if ($weak -and $sig.Trust -ne 'Missing' -and $zone -in 'Temp', 'Public', 'Downloads') {
        & $add 'zone' 3 "يعمل من مجلد مؤقت/عام ($zone) وليس من مجلد تثبيت"
    } elseif ($weak -and $sig.Trust -ne 'Missing' -and $zone -in 'AppData', 'ProgramData') {
        & $add 'zone' 2 "يعمل من مجلد بيانات المستخدم ($zone) وليس من Program Files"
    } elseif ($weak -and $sig.Trust -ne 'Missing' -and $zone -eq 'UserPrograms') {
        & $add 'zone' 1 'يعمل من مجلد برامج المستخدم (AppData\Local\Programs)'
    } elseif ($sig.Trust -eq 'Signed' -and $zone -in 'Temp', 'Public') {
        & $add 'zone' 2 "ملف موقّع لكنه يعمل من مجلد مؤقت ($zone)"
    }
    if ($weak -and $leaf -and (Test-RandomName $leaf)) { & $add 'random' 2 'اسم الملف يبدو عشوائيًا' }
    if ($weak -and $sig.Trust -ne 'Missing' -and (Get-HasVersionInfo $Path)) { & $add 'verinfo' -1 'يحمل معلومات إصدار كاملة (شركة/منتج/وصف) - يخفف الشبهة قليلًا' }

    if (-not $trusted -and $base -in $CriticalNames -and $Path -and -not $Path.StartsWith($WinDir, [StringComparison]::OrdinalIgnoreCase)) {
        & $add 'masq' 8 "اسمه ($leaf) يطابق عملية نظام لكنه خارج مجلد ويندوز - انتحال شائع للبرمجيات الخبيثة"
    } elseif (-not $trusted -and $base.Length -ge 5) {
        foreach ($c in $CriticalNames) {
            if ($c.Length -ge 5 -and (Test-OneEdit $base $c)) { & $add 'lookalike' 7 "اسمه ($leaf) يشبه عملية النظام $c بفارق حرف واحد"; break }
        }
    }

    if ($Cmd) {
        # Many legitimate apps launch PowerShell/cmd with odd arguments, so a one-off running process
        # weighs less than the same command wired into startup (task / autorun / service / WMI).
        $running = ($Kind -eq 'Process')
        $hostIsScripter = ($base -in $Scripters)
        if ($Cmd -match $MinerRegex) { & $add 'miner' 8 'سطر الأوامر يحتوي مؤشرات تعدين عملات رقمية (Miner)' }
        if ($Cmd -match $EncodedRegex) { & $add 'encoded' $(if ($running) { 3 } else { 6 }) 'سطر الأوامر مشفّر أو يحمّل ويشغّل كودًا (PowerShell مشفّر / Download cradle)' }
        if ($Cmd -match $LolbinRegex) { & $add 'lolbin' $(if ($running) { 6 } else { 7 }) 'استخدام أداة نظام لتحميل/تشغيل كود من الإنترنت' }
        if ($hostIsScripter -and $Cmd -match 'https?://') { & $add 'urlcmd' $(if ($running) { 1 } else { 3 }) 'أداة سكربت تتصل برابط إنترنت في سطر أوامرها' }
        if ($hostIsScripter -and $Cmd -match '(?i)\\(temp|appdata|programdata|users\\public)\\') { & $add 'argpath' $(if ($running) { 1 } else { 3 }) 'أداة سكربت تشغّل ملفًا من مجلد مؤقت/AppData' }
    }
    return [pscustomobject]@{ Signals = $sigs; Sig = $sig; Zone = $zone }
}

# ---------------------------------------------------------------- memory counters (locale independent: WMI)
function Get-MemCounters {
    $os = Get-CimInstance Win32_OperatingSystem
    $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
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
    foreach ($r in (Get-CimInstance Win32_PerfFormattedData_PerfProc_Process)) {
        if ($r.Name -ne '_Total' -and $r.Name -ne 'Idle' -and [int]$r.IDProcess -gt 0) { $h[[int]$r.IDProcess] = $r }
    }
    return $h
}

function Get-PoolSnapshot {
    if (-not $NativeOk) { return $null }
    try {
        $rows = [RamDoc.Native]::GetPoolTags()
        if ($rows.Count -eq 0) { return $null }
        $h = @{}
        foreach ($r in $rows) {
            if ($h.ContainsKey($r.Tag)) { $h[$r.Tag].NonPagedUsed += $r.NonPagedUsed; $h[$r.Tag].PagedUsed += $r.PagedUsed }
            else { $h[$r.Tag] = $r }
        }
        return $h
    } catch { return $null }
}

$KnownTags = @{
    'File' = 'كائنات الملفات (File objects) - نواة ويندوز'
    'MmCa' = 'ملفات معيّنة في الذاكرة (Mapped files / control areas) - نواة ويندوز'
    'Thre' = 'كائنات الخيوط (Threads) - نواة ويندوز'
    'Proc' = 'كائنات العمليات (Processes) - نواة ويندوز'
    'Toke' = 'رموز الأمان (Tokens) - نواة ويندوز'
    'ALPC' = 'منافذ ALPC للتواصل بين العمليات - نواة ويندوز'
    'Even' = 'كائنات الأحداث (Events) - نواة ويندوز'
    'EtwB' = 'مخازن ETW لتتبّع الأحداث - نواة ويندوز'
    'Irp ' = 'حزم طلبات الإدخال/الإخراج (IRP) - نواة ويندوز'
    'Mdl ' = 'واصفات الذاكرة (MDL) - نواة ويندوز'
    'Cont' = 'ذاكرة فيزيائية متجاورة محجوزة (غالبًا تعريف أجهزة)'
    'NVRM' = 'تعريف NVIDIA للشاشة (nvlddmkm.sys)'
    'smNp' = 'مدير المخزن / ضغط الذاكرة (Store Manager) - نواة ويندوز'
    'smCB' = 'مدير المخزن / ضغط الذاكرة (Store Manager) - نواة ويندوز'
    'smBt' = 'مدير المخزن / ضغط الذاكرة (Store Manager) - نواة ويندوز'
}

# ---------------------------------------------------------------- snapshot #1
Say 'Snapshot #1: memory counters, per-process memory, kernel pool tags ...'
$t0 = Get-Date
$mem1 = Get-MemCounters
$perf1 = Get-ProcPerf
$pool1 = Get-PoolSnapshot
if (-not $pool1) { Warn 'Kernel pool-tag table unavailable (needs admin / native helper).' }

# ---------------------------------------------------------------- system facts
Say 'Collecting system facts ...'
$osInfo = Get-CimInstance Win32_OperatingSystem
$csInfo = Get-CimInstance Win32_ComputerSystem
$installedBytes = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum
if (-not $installedBytes) { $installedBytes = [int64]$csInfo.TotalPhysicalMemory }
$gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name })
$cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
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
function Add-Item([hashtable]$h) { [void]$Items.Add([pscustomobject]$h) }

Say 'Inventory: processes ...'
$cimProcs = @(Get-CimInstance Win32_Process)
$procById = @{}
foreach ($p in $cimProcs) { $procById[[int]$p.ProcessId] = $p }
$lsassCount = @($cimProcs | Where-Object { $_.Name -ieq 'lsass.exe' }).Count

# network: who talks to the outside world
$netByPid = @{}
try {
    foreach ($c in (Get-NetTCPConnection -State Established -ErrorAction Stop)) {
        $ra = [string]$c.RemoteAddress
        if ($ra -match '^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|::1|fe80|f[cd][0-9a-f]{2}:|0\.0\.0\.0)') { continue }
        $k = [int]$c.OwningProcess
        if (-not $netByPid.ContainsKey($k)) { $netByPid[$k] = New-Object System.Collections.ArrayList }
        [void]$netByPid[$k].Add([pscustomobject]@{ Remote = $ra; Port = [int]$c.RemotePort })
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

Say 'Inventory: services ...'
foreach ($s in (Get-CimInstance Win32_Service)) {
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

Say 'Inventory: scheduled tasks ...'
try {
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
foreach ($d in (Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
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

Say 'Inventory: running kernel drivers ...'
$driverRows = New-Object System.Collections.ArrayList
foreach ($d in (Get-CimInstance Win32_SystemDriver | Where-Object { $_.State -eq 'Running' })) {
    if (-not $d.PathName) { continue }
    $path = Resolve-ExePath $d.PathName
    Add-Item @{ Kind = 'Driver'; Name = $d.Name; Display = $d.DisplayName; Path = $path; Cmd = ''; StartMode = $d.StartMode; State = $d.State }
}

# ---------------------------------------------------------------- hidden process check
Say 'Hidden-process check (direct kernel PID probe vs. process lists) ...'
$hidden = New-Object System.Collections.ArrayList
if ($NativeOk) {
    try {
        $known = @{}
        $refresh = {
            foreach ($i in (Get-Process).Id) { $known[[uint32]$i] = $true }
            foreach ($i in (Get-CimInstance Win32_Process).ProcessId) { $known[[uint32]$i] = $true }
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
foreach ($it in $Items) {
    $r = Get-Signals -Path $it.Path -Cmd $it.Cmd -Name $it.Name -Kind $it.Kind
    $extra = New-Object System.Collections.ArrayList
    foreach ($s in $r.Signals) { [void]$extra.Add($s) }
    if ($it.Kind -eq 'Process') {
        $ln = $it.Name.ToLowerInvariant(); $pn = $it.ParentName.ToLowerInvariant()
        if ($ln -eq 'svchost.exe' -and $pn -and $pn -ne 'services.exe') {
            [void]$extra.Add([pscustomobject]@{ Key = 'parent'; Points = 6; Text = "svchost.exe أبوه $($it.ParentName) وليس services.exe (غير طبيعي)" })
        }
        if (($ln -eq 'lsass.exe' -or $ln -eq 'services.exe') -and $pn -and $pn -ne 'wininit.exe') {
            [void]$extra.Add([pscustomobject]@{ Key = 'parent'; Points = 6; Text = "$($it.Name) أبوه $($it.ParentName) وليس wininit.exe (غير طبيعي)" })
        }
        if ($ln -eq 'lsass.exe' -and $lsassCount -gt 1) {
            [void]$extra.Add([pscustomobject]@{ Key = 'dup'; Points = 8; Text = "يوجد $lsassCount نسخ من lsass.exe (يجب أن تكون نسخة واحدة)" })
        }
        if ($it.Net) {
            foreach ($n in $it.Net) {
                if ($MiningPorts -contains $n.Port) {
                    [void]$extra.Add([pscustomobject]@{ Key = 'netmine'; Points = 6; Text = "اتصال بمنفذ شائع لمجمّعات التعدين ($($n.Remote):$($n.Port))" }); break
                }
            }
            if ($r.Sig.Trust -in 'Unsigned', 'Untrusted', 'Tampered') {
                [void]$extra.Add([pscustomobject]@{ Key = 'netunsigned'; Points = 1; Text = 'برنامج غير موثوق التوقيع لديه اتصال نشط بالإنترنت' })
            }
        }
    }
    if ($it.Kind -eq 'Wmi') {
        [void]$extra.Add([pscustomobject]@{ Key = 'wmi'; Points = 6; Text = "اشتراك WMI دائم ($($it.WmiClass)) ينفّذ أوامر - أسلوب إخفاء معروف لا يظهر في قوائم التشغيل" })
    }
    if ($it.Kind -eq 'Process' -and -not $it.Path -and $PseudoProcs -contains $it.Name) {
        $r.Sig = [pscustomobject]@{ Status = 'Internal'; Publisher = 'Windows kernel'; Trust = 'OS' }   # kernel-internal pseudo processes have no file
    }
    if ($it.Kind -eq 'Process' -and $selfChain.ContainsKey($it.Pid)) { $extra.Clear() }
    $it | Add-Member -NotePropertyName Signals -NotePropertyValue $extra -Force
    $it | Add-Member -NotePropertyName Sig -NotePropertyValue $r.Sig -Force
}

# ---------------------------------------------------------------- wait out the sampling window, snapshot #2
$elapsed = ((Get-Date) - $t0).TotalSeconds
if ($elapsed -lt $SampleSeconds) {
    $wait = [int][math]::Ceiling($SampleSeconds - $elapsed)
    Say "Waiting $wait s to complete the growth-observation window ..."
    Start-Sleep -Seconds $wait
}
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
            [void]$it.Signals.Add([pscustomobject]@{ Key = 'growth'; Points = 2; Text = "حجم ذاكرته الخاصة زاد $(ToMB $it.Growth) MB خلال فترة الفحص" })
        }
    }
}

# ---------------------------------------------------------------- group items into suspects (by file)
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
    if ($hasPersist -and $score -ge 4) { $score += 1; $merged['persist'] = [pscustomobject]@{ Key = 'persist'; Points = 1; Text = 'مضبوط على التشغيل التلقائي (خدمة / مهمة مجدولة / تشغيل عند الإقلاع) فيعود بعد إعادة التشغيل' } }
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
$unaccounted = [math]::Max(0.0, [double]($used - $sumWS - $mem2.NonPaged - $mem2.ModifiedBytes))
$shared = [math]::Max(0.0, [double]($sumWS - $sumPriv))
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
}

# top consumers (per process and per program)
$topProcs = @($allProc | Sort-Object PrivWS -Descending | Select-Object -First 15 | ForEach-Object {
        [pscustomobject]@{ pid = $_.Pid; name = $_.Name; privMB = (ToMB $_.PrivWS); wsMB = (ToMB $_.WS); commitMB = (ToMB $_.PrivBytes); handles = $_.Handles; growthMB = (ToMB $_.Growth); trust = $_.Sig.Trust; publisher = $_.Sig.Publisher; path = $_.Path }
    })
$byProgram = @($allProc | Group-Object { $_.Name.ToLowerInvariant() } | ForEach-Object {
        $pw = ($_.Group | Measure-Object PrivWS -Sum).Sum
        $pb = ($_.Group | Measure-Object PrivBytes -Sum).Sum
        $f = $_.Group | Where-Object { $_.Sig.Trust -ne 'Unknown' } | Select-Object -First 1   # prefer an instance whose path we could read
        if (-not $f) { $f = $_.Group | Select-Object -First 1 }
        [pscustomobject]@{ name = $f.Name; count = $_.Count; privMB = (ToMB $pw); commitMB = (ToMB $pb); trust = $f.Sig.Trust; publisher = $f.Sig.Publisher }
    } | Sort-Object privMB -Descending | Select-Object -First 12)
$topGrowers = @($allProc | Where-Object { $_.Growth -ge 20MB } | Sort-Object Growth -Descending | Select-Object -First 8 | ForEach-Object {
        [pscustomobject]@{ pid = $_.Pid; name = $_.Name; growthMB = (ToMB $_.Growth); commitMB = (ToMB $_.PrivBytes); trust = $_.Sig.Trust }
    })

# ---------------------------------------------------------------- kernel pool tags -> owning drivers
$poolNon = @(); $poolPaged = @(); $poolGrow = @()
if ($pool2) {
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
    foreach ($r in ($topNon + $topPg + ($growNon | ForEach-Object { $_.Row }))) { if ($r.Printable) { [void]$wanted.Add($r.Tag) } }
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
Say 'Collecting Defender status and event-log evidence ...'
$defender = $null
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $threats = @()
    try { $threats = @(Get-MpThreatDetection -ErrorAction Stop | Sort-Object InitialDetectionTime -Descending | Select-Object -First 5 | ForEach-Object { [pscustomobject]@{ time = (IsoDate $_.InitialDetectionTime); process = [string]$_.ProcessName; resources = (@($_.Resources) -join '; ') } }) } catch { }
    $defender = [pscustomobject]@{
        Enabled = [bool]$mp.AMServiceEnabled; RealTime = [bool]$mp.RealTimeProtectionEnabled
        SignatureAgeDays = [int]$mp.AntivirusSignatureAge; QuickScanAgeDays = [int]$mp.QuickScanAge; RecentThreats = $threats
    }
} catch { Warn 'Windows Defender status unavailable (a third-party antivirus may be in charge).' }

$exhaustion = @()
try {
    $exhaustion = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'; Id = 2004 } -MaxEvents 3 -ErrorAction Stop | ForEach-Object {
            $msg = [string]$_.Message; if ($msg.Length -gt 700) { $msg = $msg.Substring(0, 700) + ' ...' }
            [pscustomobject]@{ time = (IsoDate $_.TimeCreated); message = $msg }
        })
} catch { }

$anomalies = New-Object System.Collections.ArrayList
try {
    $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
    if ($wl.Shell -and $wl.Shell -ne 'explorer.exe') { [void]$anomalies.Add([pscustomobject]@{ Level = 'high'; Title = 'قيمة Winlogon\Shell معدّلة'; Detail = "القيمة الحالية: $($wl.Shell) (الطبيعي: explorer.exe)" }) }
    if ($wl.Userinit -and $wl.Userinit.TrimEnd(',') -notmatch '(?i)^c:\\windows\\system32\\userinit\.exe$') { [void]$anomalies.Add([pscustomobject]@{ Level = 'high'; Title = 'قيمة Winlogon\Userinit معدّلة'; Detail = "القيمة الحالية: $($wl.Userinit)" }) }
} catch { }
try {
    $ifeo = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' -ErrorAction Stop
    foreach ($k in $ifeo) {
        $dbg = (Get-ItemProperty -LiteralPath $k.PSPath -Name Debugger -ErrorAction SilentlyContinue).Debugger
        if ($dbg) { [void]$anomalies.Add([pscustomobject]@{ Level = 'med'; Title = "IFEO Debugger مضبوط على $($k.PSChildName)"; Detail = "يُشغَّل بدلًا منه: $dbg (تستخدمه بعض أدوات المطوّرين لكنه أسلوب شائع لتعطيل برامج الحماية)" }) }
    }
} catch { }
try {
    $aw = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows' -ErrorAction Stop
    if ($aw.LoadAppInit_DLLs -eq 1 -and $aw.AppInit_DLLs) { [void]$anomalies.Add([pscustomobject]@{ Level = 'high'; Title = 'AppInit_DLLs مفعّل'; Detail = "يُحقن في كل برنامج: $($aw.AppInit_DLLs)" }) }
} catch { }

# ---------------------------------------------------------------- observations + verdict (Arabic)
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
    $who = if ($topTag.known) { $topTag.known } elseif (@($topTag.candidates).Count -gt 0) { 'قد يتبع: ' + ((@($topTag.candidates) | ForEach-Object { $_.file }) -join '، ') } else { 'غير معروف' }
    $topTagText = " أكبر مستهلك داخل المجمّع هو الوسم [$($topTag.tag)] بحجم $($topTag.mb) MB ($who)."
}
if ($mem2.NonPaged -ge $Th.NppHigh) {
    Add-Obs 'high' 'تسرّب محتمل في ذاكرة النواة (Non-paged pool)' ("مجمّع الذاكرة غير المتصفّح = $(Num (ToGB $mem2.NonPaged)) GB (الطبيعي أقل من نحو 1 GB). هذا أقوى مؤشر على تسرّب ذاكرة من تعريف/درايفر، ولا يُنسب في مدير المهام لأي برنامج." + $topTagText)
} elseif ($mem2.NonPaged -ge $Th.NppMed) {
    Add-Obs 'med' 'ذاكرة النواة (Non-paged pool) أعلى من المعتاد' ("القيمة $(Num (ToGB $mem2.NonPaged)) GB. ليست حرجة لكنها أعلى من الطبيعي؛ راقب إن كانت تكبر مع الوقت." + $topTagText)
}
if ($mem2.Paged -ge $Th.PagedHigh) {
    Add-Obs 'high' 'تضخّم في Paged pool' "حجم Paged pool = $(Num (ToGB $mem2.Paged)) GB (الطبيعي أقل من نحو 1.5 GB). يشير غالبًا لتسرّب في تعريف أو برنامج حماية/VPN."
}
if ($unaccounted -ge $Th.UnaccHigh) {
    Add-Obs 'high' 'ذاكرة كبيرة خارج أي عملية' "حوالي $(Num (ToGB $unaccounted)) GB من الاستخدام لا تقع ضمن أي Working Set ولا ضمن مجمّع النواة. من أسبابها: ذاكرة محجوزة من تعريف (Driver Locked)، أو AWE، أو RAM Disk، أو عملية مخفية. افتح أداة RAMMap من Sysinternals وراجع تبويب Use Counts."
} elseif ($unaccounted -ge $Th.UnaccMed) {
    Add-Obs 'med' 'جزء من الذاكرة غير منسوب لعمليات' "حوالي $(Num (ToGB $unaccounted)) GB خارج الـ Working Sets. قد يكون طبيعيًا (ذاكرة تعريفات/ألعاب) لكنه يستحق المتابعة عبر RAMMap."
}
if ($allProc.Count -gt 0 -and $byProgram.Count -gt 0) {
    $topP = $byProgram[0]
    if (($topP.privMB * 1MB) -ge 0.30 * $used) {
        $lvl = if ($topP.trust -in 'OS', 'MS', 'Signed') { 'info' } else { 'med' }
        Add-Obs $lvl "أكبر مستهلك: $($topP.name)" "البرنامج $($topP.name) ($($topP.count) عملية) يستهلك نحو $(Num ($topP.privMB / 1024)) GB من الذاكرة الخاصة، وتوقيعه: $($topP.trust)$(if ($topP.publisher) { ' - ' + $topP.publisher })."
    }
}
if ($hiddenLive.Count -gt 0) {
    Add-Obs 'high' 'عملية حيّة مخفية عن قوائم النظام' ("وُجدت $($hiddenLive.Count) عملية تستجيب مباشرة للنواة لكنها غير ظاهرة في Get-Process ولا WMI (PID: " + (($hiddenLive | ForEach-Object { $_.Pid }) -join ', ') + '). هذا سلوك Rootkit؛ يُنصح بفحص بقرص إنقاذ (Offline) بدل الاعتماد على ويندوز نفسه.')
}
$zombieOdd = @($zombies | Where-Object { -not $_.IsWindowsImage })
if ($zombieOdd.Count -gt 0) {
    Add-Obs 'med' 'عمليات منتهية لكن النواة ما زالت تحتفظ بها' ("PIDs: " + (($zombieOdd | ForEach-Object { "$($_.Pid) [$($_.Image)]" }) -join '؛ ') + '. غالبًا برنامج يحتفظ بمقبض (Handle) لعملية انتهت، وقد يكون سبب تسرّب ذاكرة صغير.')
}
$highS = @($suspectOut | Where-Object { $_.risk -eq 'High' })
$medS = @($suspectOut | Where-Object { $_.risk -eq 'Medium' })
if ($highS.Count -gt 0) {
    Add-Obs 'high' "ملفات عالية الخطورة ($($highS.Count))" ('مؤشرات متعددة اجتمعت على: ' + (($highS | ForEach-Object { $_.name }) -join '، ') + '. هذه مؤشرات وليست حكمًا نهائيًا؛ راجع التفاصيل قبل أي إجراء.')
}
if ($medS.Count -gt 0) {
    Add-Obs 'med' "ملفات متوسطة الخطورة ($($medS.Count))" ('تستحق المراجعة: ' + (($medS | Select-Object -First 8 | ForEach-Object { $_.name }) -join '، '))
}
foreach ($a in $anomalies) { Add-Obs $a.Level $a.Title $a.Detail }
if ($mem2.NonPaged - $mem1.NonPaged -ge 30MB -or $mem2.Paged - $mem1.Paged -ge 30MB) {
    Add-Obs 'high' 'التسرّب نشط الآن' "خلال $($memory.WindowSec) ثانية فقط زاد Non-paged بمقدار $($memory.NonPagedGrowthMB) MB وPaged بمقدار $($memory.PagedGrowthMB) MB. راجع جدول الوسوم (Pool tags) الأسرع نموًا."
} elseif ($topGrowers.Count -gt 0 -and $topGrowers[0].growthMB -ge 100) {
    Add-Obs 'med' 'برنامج تتضخّم ذاكرته الآن' "$($topGrowers[0].name) (PID $($topGrowers[0].pid)) زادت ذاكرته الخاصة $($topGrowers[0].growthMB) MB خلال $($memory.WindowSec) ثانية."
}
if ($mem2.Committed -ge 0.9 * $mem2.CommitLimit) {
    Add-Obs 'med' 'قريب من حد الذاكرة الافتراضية (Commit limit)' "المحجوز $(Num (ToGB $mem2.Committed)) GB من أصل $(Num (ToGB $mem2.CommitLimit)) GB. قد تظهر رسائل نفاد الذاكرة وتتعطل برامج."
}
if ($sys.ReservedGB -ge 1) {
    Add-Obs 'info' 'ذاكرة محجوزة للعتاد' "المركّب $($sys.InstalledGB) GB والمتاح لويندوز $($sys.UsableGB) GB؛ الفرق ($($sys.ReservedGB) GB) تحجزه الـ BIOS/الشاشة المدمجة وهذا طبيعي."
}
if ($sys.UptimeDays -ge 7 -and $sys.FastStartup) {
    Add-Obs 'med' 'التشغيل السريع (Fast Startup) مفعّل والجهاز شغّال منذ مدة' "مدة التشغيل $($sys.Uptime). مع Fast Startup خيار «إيقاف التشغيل» لا يصفّر النواة، فأي تسرّب يبقى بعد الإطفاء. استخدم «إعادة التشغيل» (Restart) أو عطّل Fast Startup."
}
if ($defender -and (-not $defender.RealTime)) { Add-Obs 'med' 'حماية Defender اللحظية متوقفة' 'إن لم يكن هناك برنامج حماية آخر فالجهاز غير محمي حاليًا.' }
if ($defender -and $defender.RecentThreats.Count -gt 0) { Add-Obs 'med' 'Defender سجّل اكتشافات حديثة' ('آخر اكتشاف: ' + $defender.RecentThreats[0].resources) }
if ($mem2.StandbyBytes -ge 0.25 * $totalB) {
    Add-Obs 'info' 'ذاكرة التخزين المؤقت (Standby/Cached)' "حوالي $(Num (ToGB $mem2.StandbyBytes)) GB. هذي ذاكرة مُخزَّنة للتسريع ويحرّرها ويندوز فورًا عند الحاجة، فهي ليست مشكلة حتى لو ظهرت كاستخدام."
}

$levels = @{ high = 3; med = 2; low = 1; info = 0 }
$maxLevel = 0; foreach ($o in $obs) { if ($levels[$o.Level] -gt $maxLevel) { $maxLevel = $levels[$o.Level] } }
$headline = ''
if ($hiddenLive.Count -gt 0 -or $highS.Count -gt 0) { $headline = 'تم رصد مؤشرات تستحق التدقيق العاجل (قد تكون برمجية خبيثة)' }
elseif ($mem2.NonPaged -ge $Th.NppMed -or $mem2.Paged -ge $Th.PagedHigh) { $headline = 'السبب الأرجح: تسرّب ذاكرة في تعريف (Driver) على مستوى النواة' }
elseif ($unaccounted -ge $Th.UnaccMed) { $headline = 'جزء كبير من الذاكرة غير منسوب لأي عملية (ذاكرة مشتركة/محجوزة)' }
elseif ($maxLevel -ge 2) { $headline = 'توجد ملاحظات متوسطة الخطورة، راجع القائمة' }
else { $headline = 'لا يوجد تسرّب أو مؤشر خبيث واضح في هذه اللحظة' }
$verdict = [pscustomobject]@{ Level = $(@('ok', 'low', 'med', 'high')[$maxLevel]); Headline = $headline }

# ---------------------------------------------------------------- write outputs
$data = [pscustomobject]@{
    Tool = 'RAM-Doctor'; Version = $ToolVersion; Created = IsoDate (Get-Date); Sys = $sys; Memory = $memory; Verdict = $verdict
    Observations = @($obs | Sort-Object { -$levels[$_.Level] }); TopProcesses = $topProcs; ByProgram = $byProgram; TopGrowers = $topGrowers
    PoolNonPaged = $poolNon; PoolPaged = $poolPaged; PoolGrowing = $poolGrow; PoolAvailable = [bool]$pool2
    Suspects = @($suspectOut); Drivers3p = $drivers3p; Hidden = @($hidden); Defender = $defender; Exhaustion = $exhaustion
    Warnings = @($Warnings); ItemCounts = [pscustomobject]@{
        Processes = @($Items | Where-Object Kind -eq 'Process').Count; Services = @($Items | Where-Object Kind -eq 'Service').Count
        Tasks = @($Items | Where-Object Kind -eq 'Task').Count; Autoruns = @($Items | Where-Object Kind -eq 'Autorun').Count
        Drivers = @($Items | Where-Object Kind -eq 'Driver').Count; Wmi = @($Items | Where-Object Kind -eq 'Wmi').Count
    }
}
$base = "RAMDoctor-$HostName-$Stamp"
$htmlPath = Join-Path $OutDir "$base.html"
$jsonPath = Join-Path $OutDir "$base.json"
$planPath = Join-Path $OutDir "Plan-$HostName-$Stamp.json"
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
# Light footprint: only two small files per scan (report ~30 KB + plan ~15 KB). The big raw JSON is optional.
if ($KeepRawJson) { [IO.File]::WriteAllText($jsonPath, ($data | ConvertTo-Json -Depth 8), $utf8Bom) }
$plan = [pscustomobject]@{
    tool = 'RAM-Doctor'; version = $ToolVersion; host = $HostName; created = IsoDate (Get-Date); isAdmin = $IsAdmin; report = $htmlPath
    verdict = $verdict; observations = @($data.Observations); memory = $memory; suspects = @($suspectOut)
}
[IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 8), $utf8Bom)
[IO.File]::WriteAllText($htmlPath, (New-RamReportHtml $data), $utf8Bom)
# keep only the 3 newest scans of this PC, so reports never pile up
try {
    $old = @(Get-ChildItem -LiteralPath $OutDir -Filter "Plan-$HostName-*.json" -File | Sort-Object Name -Descending | Select-Object -Skip 3)
    foreach ($f in $old) {
        $stampOld = $f.BaseName.Substring(("Plan-$HostName-").Length)
        foreach ($n in "$($f.Name)", "RAMDoctor-$HostName-$stampOld.html", "RAMDoctor-$HostName-$stampOld.json") { Remove-Item -LiteralPath (Join-Path $OutDir $n) -Force -ErrorAction SilentlyContinue }
    }
} catch { }

Write-Host ''
Write-Host '================ RESULT ================' -ForegroundColor Cyan
Write-Host ("Memory: used {0} GB of {1} GB | NonPaged {2} GB | Paged {3} GB | unaccounted {4} GB" -f $memory.UsedGB, $memory.TotalGB, $memory.NonPagedGB, $memory.PagedGB, $memory.UnaccountedGB)
Write-Host ("Suspects: {0} high, {1} medium, {2} low | hidden live processes: {3}" -f $highS.Count, $medS.Count, @($suspectOut | Where-Object { $_.risk -eq 'Low' }).Count, $hiddenLive.Count)
Write-Host "Report : $htmlPath"
Write-Host "Plan   : $planPath   (used by 2-Quarantine.bat, nothing has been changed)"
Write-Host '========================================' -ForegroundColor Cyan
if (-not $NoOpen) { try { Start-Process -FilePath $htmlPath } catch { } }
