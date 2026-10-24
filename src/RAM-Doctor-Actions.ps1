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
    [switch]$AllowNonAdmin         # testing only: lets the user-level parts run without elevation
)

$ErrorActionPreference = 'Continue'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }
$WinDir = $env:SystemRoot.TrimEnd('\')
$WinDirL = $WinDir.ToLowerInvariant()
$DataRoot = if ($StoreDir) { $StoreDir } else { Join-Path $env:ProgramData 'RAM-Doctor' }
$QRoot = Join-Path $DataRoot 'Quarantine'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $DataRoot "actions-$Stamp.log"
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$SelectIds = @($Select -split '[,;\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin -and -not $AllowNonAdmin) { Write-Host 'This needs administrator rights. Run 2-Quarantine.bat (it elevates automatically).' -ForegroundColor Red; exit 1 }
if (-not $IsAdmin) { Write-Host 'WARNING: not elevated - service/driver/system-wide changes will fail (testing mode).' -ForegroundColor Yellow }
New-Item -ItemType Directory -Force -Path $QRoot | Out-Null

$script:RedCount = 0   # number of error-coloured log lines (used to decide whether a restore fully succeeded)
function Log([string]$m, [string]$color = '') {
    if ($color -eq 'Red') { $script:RedCount++ }
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $m
    if ($color) { Write-Host $line -ForegroundColor $color } else { Write-Host $line }
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}
function Ask([string]$q) { if ($Yes) { return '' } return (Read-Host $q) }
function IsoDate($d) { if ($d) { ([datetime]$d).ToString('yyyy-MM-dd HH:mm:ss', $Inv) } else { '' } }

function Test-ProtectedPath([string]$p) {
    if (-not $p) { return $false }
    $l = $p.ToLowerInvariant()
    if ($l.StartsWith($WinDirL + '\')) { return $true }
    $guard = @("$env:ProgramFiles\Windows Defender", "${env:ProgramFiles(x86)}\Windows Defender", "$env:ProgramData\Microsoft\Windows Defender",
        "$env:ProgramFiles\WindowsApps\Microsoft.", $Root, $DataRoot)
    foreach ($g in $guard) { if ($g -and $l.StartsWith($g.ToLowerInvariant())) { return $true } }
    return $false
}

function Test-MicrosoftSigned([string]$p) {
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $p -ErrorAction Stop
        return ($s.Status -eq 'Valid' -and $s.SignerCertificate -and $s.SignerCertificate.Subject -match 'O=Microsoft (Corporation|Windows)')
    } catch { return $false }
}

function Move-Safe([string]$src, [string]$dst) {
    for ($i = 0; $i -lt 4; $i++) {
        try { Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop; return $true } catch { Start-Sleep -Milliseconds 700 }
    }
    return $false
}

function Get-StartCode([string]$name) {
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
    try {
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
        return [pscustomobject]@{ Start = [int]$p.Start; Delayed = [int]$p.DelayedAutostart }
    } catch { return $null }
}
function Set-StartCode([string]$name, [int]$start, [int]$delayed) {
    $arg = switch ($start) { 0 { 'boot' } 1 { 'system' } 2 { if ($delayed -eq 1) { 'delayed-auto' } else { 'auto' } } 3 { 'demand' } default { 'disabled' } }
    $out = & sc.exe config $name start= $arg 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Save-Manifest($manifest, [string]$dir) {
    [IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 10), $Utf8Bom)
}

function Get-Batches {
    @(Get-ChildItem -LiteralPath $QRoot -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') } | Sort-Object Name -Descending)
}
function Read-Manifest([string]$dir) { Get-Content -LiteralPath (Join-Path $dir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json }

function Select-Batch {
    $all = Get-Batches
    if ($all.Count -eq 0) { Log 'No quarantine batches found.' 'Yellow'; return $null }
    if ($Batch) { $m = $all | Where-Object Name -eq $Batch | Select-Object -First 1; if (-not $m) { Log "Batch '$Batch' not found." 'Red' }; return $m }
    if ($all.Count -eq 1 -or $Yes) { return $all[0] }
    for ($i = 0; $i -lt $all.Count; $i++) { $mm = Read-Manifest $all[$i].FullName; Write-Host ("  [{0}] {1}  ({2} item(s){3})" -f ($i + 1), $all[$i].Name, @($mm.entries).Count, $(if ($mm.purgedAt) { ', purged' } else { '' })) }
    $a = Read-Host 'Choose batch number (Enter = latest)'
    if (-not $a) { return $all[0] }
    $idx = 0; if ([int]::TryParse($a, [ref]$idx) -and $idx -ge 1 -and $idx -le $all.Count) { return $all[$idx - 1] }
    return $null
}

# ================================================================ LIST
if ($Mode -eq 'List') {
    $all = Get-Batches
    if ($all.Count -eq 0) { Write-Host 'No quarantine batches.'; exit 0 }
    foreach ($b in $all) {
        $mm = Read-Manifest $b.FullName
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
    if ($mm.purgedAt) { Log 'This batch was purged; nothing left to restore.' 'Yellow'; exit 1 }
    if ($mm.restoredAt) { Log "This batch was already restored on $($mm.restoredAt)." 'Yellow'; exit 0 }
    Log "Restoring batch $($b.Name) ..." 'Cyan'
    foreach ($e in @($mm.entries)) {
        Log "-- #$($e.id) $($e.name)"
        $rev = @($e.ops); [array]::Reverse($rev)   # undo in the opposite order of how it was done
        foreach ($op in $rev) {
            if ($op.status -ne 'done') { continue }
            switch ($op.type) {
                { $_ -in 'QuarantineFile', 'MoveStartupFile' } {
                    if (-not (Test-Path -LiteralPath $op.stored)) { Log "   stored file missing: $($op.stored)" 'Yellow'; break }
                    $dst = $op.original
                    if (Test-Path -LiteralPath $dst) { $dst = $dst + '.restored'; Log "   original path is occupied, restoring as $dst" 'Yellow' }
                    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
                    if (Move-Safe $op.stored $dst) { Log "   file restored: $dst" 'Green' } else { Log "   could not restore $dst" 'Red' }
                }
                { $_ -in 'DisableService', 'DisableDriver' } {
                    if (Set-StartCode $op.name ([int]$op.prevStart) ([int]$op.prevDelayed)) { Log "   $($op.type) undone: $($op.name) start=$($op.prevStart)" 'Green' } else { Log "   failed to restore start type of $($op.name)" 'Red' }
                }
                'DisableTask' { try { Enable-ScheduledTask -TaskPath $op.taskPath -TaskName $op.taskName -ErrorAction Stop | Out-Null; Log "   task re-enabled: $($op.taskName)" 'Green' } catch { Log "   task restore failed: $($_.Exception.Message)" 'Red' } }
                'RemoveRunValue' {
                    try { New-ItemProperty -LiteralPath $op.location -Name $op.name -Value $op.value -PropertyType $op.kind -Force -ErrorAction Stop | Out-Null; Log "   Run value restored: $($op.name)" 'Green' } catch { Log "   Run value restore failed: $($_.Exception.Message)" 'Red' }
                }
                'RemoveWmi' { Log "   WMI subscription '$($op.name)' cannot be auto-restored; its original definition is saved in manifest.json" 'Yellow' }
                default { }
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
        if (Test-Path $fd) { $fs = @(Get-ChildItem -LiteralPath $fd -File -Force); $count += $fs.Count; $totalBytes += ($fs | Measure-Object Length -Sum).Sum }
    }
    Write-Host ("About to PERMANENTLY delete {0} quarantined file(s), {1} MB, from {2} batch(es). This cannot be undone." -f $count, [math]::Round($totalBytes / 1MB, 1), $targets.Count) -ForegroundColor Red
    if (-not $Yes) { if ((Read-Host "Type DELETE to confirm") -cne 'DELETE') { Log 'Cancelled.'; exit 0 } }
    foreach ($t in $targets) {
        $fd = Join-Path $t.FullName 'files'
        if (Test-Path $fd) { Remove-Item -LiteralPath $fd -Recurse -Force -ErrorAction SilentlyContinue }
        $mm = Read-Manifest $t.FullName
        $mm | Add-Member -NotePropertyName purgedAt -NotePropertyValue (IsoDate (Get-Date)) -Force
        Save-Manifest $mm $t.FullName
        Log "Purged batch $($t.Name)" 'Green'
    }
    exit 0
}

# ================================================================ QUARANTINE
# ---- locate and validate the plan
if (-not $Plan) {
    $dirs = @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'RAM-Doctor-Reports'))
    $cand = foreach ($d in $dirs) { if (Test-Path $d) { Get-ChildItem -LiteralPath $d -Filter 'Plan-*.json' -File } }
    $latest = $cand | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { Log 'No plan found. Run 1-Scan.bat first.' 'Red'; exit 1 }
    $Plan = $latest.FullName
}
Log "Using plan: $Plan"
$planData = Get-Content -LiteralPath $Plan -Raw -Encoding UTF8 | ConvertFrom-Json   # (not $plan: PowerShell variables are case-insensitive and $Plan is the typed [string] parameter)
if ($planData.host -ne $env:COMPUTERNAME) { Log "Plan belongs to '$($planData.host)', this PC is '$($env:COMPUTERNAME)'. Refusing." 'Red'; exit 1 }
$ageH = ((Get-Date) - [datetime]$planData.created).TotalHours
if ($ageH -gt 24) { Log ("Plan is {0:N0} h old; every item is re-verified live before anything is touched." -f $ageH) 'Yellow' }

$cands = @($planData.suspects | Where-Object { $_.risk -in 'High', 'Medium' -or ($IncludeLow -and $_.risk -eq 'Low') } | Sort-Object id)
if ($cands.Count -eq 0) { Log 'The scan found nothing at High/Medium risk. Nothing to do.' 'Green'; exit 0 }

Write-Host ''
Write-Host '================ Candidates ================' -ForegroundColor Cyan
foreach ($c in $cands) {
    $col = switch ($c.risk) { 'High' { 'Red' } 'Medium' { 'Yellow' } default { 'Gray' } }
    Write-Host ("[#{0}] {1,-6} score {2,-3} {3}" -f $c.id, $c.risk.ToUpper(), $c.score, $c.name) -ForegroundColor $col
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
Write-Host 'Nothing is deleted. Files are moved to quarantine and can be restored with 3-Restore.bat.' -ForegroundColor Cyan
if (-not $Yes) { if ((Read-Host 'Type YES to proceed') -cne 'YES') { Log 'Cancelled - nothing changed.'; exit 0 } }

# ---- safety net
if (-not $NoRestorePoint) {
    try { Checkpoint-Computer -Description 'RAM-Doctor before quarantine' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; Log 'System restore point created.' 'Green' }
    catch { Log "No restore point created (System Protection off, or one was made in the last 24h): $($_.Exception.Message)" 'Yellow' }
}

$batchName = $Stamp
$batchDir = Join-Path $QRoot $batchName
$filesDir = Join-Path $batchDir 'files'
New-Item -ItemType Directory -Force -Path $filesDir | Out-Null
$manifest = [pscustomobject]@{ batch = $batchName; created = (IsoDate (Get-Date)); host = $env:COMPUTERNAME; plan = $Plan; entries = @() }
$entries = New-Object System.Collections.ArrayList

foreach ($s in $chosen) {
    Log "=== #$($s.id) $($s.name) [$($s.risk)] ===" 'Cyan'
    $ops = New-Object System.Collections.ArrayList
    function AddOp([hashtable]$h) { [void]$ops.Add([pscustomobject]$h) }

    $path = [string]$s.path
    $exists = [bool]$path -and (Test-Path -LiteralPath $path -PathType Leaf)
    $moveFile = $exists -and -not $s.protectedFile
    $skipAll = $false

    if ($exists) {
        $curHash = ''
        try { $curHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
        if ($s.sha256 -and $curHash -and $curHash -ne $s.sha256) {
            Log "   file changed since the scan (hash mismatch) - skipping this item for safety. Re-run the scan." 'Red'; $skipAll = $true
        }
        if ($moveFile -and (Test-ProtectedPath $path)) { Log '   path is in a protected location - file will NOT be moved.' 'Yellow'; $moveFile = $false }
        if ($moveFile -and (Test-MicrosoftSigned $path)) { Log '   file is Microsoft-signed - file will NOT be moved.' 'Yellow'; $moveFile = $false }
    }
    if ($skipAll) { continue }

    # 1) stop processes (PID + start-time guard against PID reuse)
    $toKill = New-Object System.Collections.Generic.List[int]
    foreach ($p in @($s.procs)) {
        $proc = Get-Process -Id ([int]$p.pid) -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        $okStart = $true
        if ($p.start) { try { $okStart = [math]::Abs(($proc.StartTime - [datetime]$p.start).TotalSeconds) -le 3 } catch { } }
        if ($okStart) { $toKill.Add([int]$p.pid) }
    }
    if ($moveFile) {   # also catch copies respawned after the scan
        foreach ($proc in (Get-Process -ErrorAction SilentlyContinue)) {
            try { if ($proc.Path -and $proc.Path -ieq $path -and -not $toKill.Contains($proc.Id)) { $toKill.Add($proc.Id) } } catch { }
        }
    }
    foreach ($procId in $toKill) {
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
            Wait-Process -Id $procId -Timeout 5 -ErrorAction SilentlyContinue   # let the kernel finish tearing it down before we touch its file
            Log "   stopped process $procId" 'Green'; AddOp @{ type = 'StopProcess'; pid = $procId; status = 'done' }
        }
        catch { Log "   could not stop process ${procId}: $($_.Exception.Message)" 'Red'; AddOp @{ type = 'StopProcess'; pid = $procId; status = 'failed'; note = $_.Exception.Message } }
    }

    # 2) services
    foreach ($sv in @($s.services)) {
        $code = Get-StartCode $sv.name
        if (-not $code) { Log "   service $($sv.name) not found" 'Yellow'; continue }
        try { Stop-Service -Name $sv.name -Force -ErrorAction SilentlyContinue } catch { }
        if (Set-StartCode $sv.name 4 0) { Log "   service disabled: $($sv.name)" 'Green'; AddOp @{ type = 'DisableService'; name = $sv.name; prevStart = $code.Start; prevDelayed = $code.Delayed; status = 'done' } }
        else { Log "   failed to disable service $($sv.name)" 'Red'; AddOp @{ type = 'DisableService'; name = $sv.name; status = 'failed' } }
    }

    # 3) drivers: only 3rd-party, non-boot, non-Microsoft
    foreach ($dv in @($s.drivers)) {
        $code = Get-StartCode $dv.name
        if (-not $code) { continue }
        if ($code.Start -le 1) { Log "   driver $($dv.name) is boot/system-start: refusing to disable (could stop Windows booting)" 'Yellow'; continue }
        if ($path -and ((Test-ProtectedPath $path) -or (Test-MicrosoftSigned $path))) { Log "   driver $($dv.name) is a Windows/Microsoft driver: refusing" 'Yellow'; continue }
        if (Set-StartCode $dv.name 4 0) { Log "   driver disabled (takes effect at next boot): $($dv.name)" 'Green'; AddOp @{ type = 'DisableDriver'; name = $dv.name; prevStart = $code.Start; prevDelayed = $code.Delayed; status = 'done' } }
        else { Log "   failed to disable driver $($dv.name)" 'Red' }
    }

    # 4) scheduled tasks
    foreach ($t in @($s.tasks)) {
        try { Disable-ScheduledTask -TaskPath $t.taskPath -TaskName $t.taskName -ErrorAction Stop | Out-Null; Log "   task disabled: $($t.taskPath)$($t.taskName)" 'Green'; AddOp @{ type = 'DisableTask'; taskPath = $t.taskPath; taskName = $t.taskName; status = 'done' } }
        catch { Log "   could not disable task $($t.taskName): $($_.Exception.Message)" 'Red' }
    }

    # 5) startup entries
    foreach ($r in @($s.autoruns)) {
        if ($r.via -eq 'Registry') {
            try {
                $cur = (Get-ItemProperty -LiteralPath $r.location -Name $r.name -ErrorAction Stop).($r.name)
                if ([string]$cur -ne [string]$r.value) { Log "   Run value '$($r.name)' changed since the scan - left alone" 'Yellow'; continue }
                $kind = (Get-Item -LiteralPath $r.location).GetValueKind($r.name).ToString()
                Remove-ItemProperty -LiteralPath $r.location -Name $r.name -ErrorAction Stop
                Log "   startup value removed: $($r.name)" 'Green'
                AddOp @{ type = 'RemoveRunValue'; location = $r.location; name = $r.name; value = [string]$cur; kind = $kind; status = 'done' }
            } catch { Log "   could not remove Run value '$($r.name)': $($_.Exception.Message)" 'Red' }
        } elseif ($r.via -eq 'StartupFolder' -and $r.file -and (Test-Path -LiteralPath $r.file)) {
            $stored = Join-Path $filesDir ('{0:D3}_startup_{1}.quar' -f [int]$s.id, (Split-Path $r.file -Leaf))
            if (Move-Safe $r.file $stored) { Log "   startup shortcut moved: $($r.file)" 'Green'; AddOp @{ type = 'MoveStartupFile'; original = $r.file; stored = $stored; status = 'done' } }
            else { Log "   could not move startup file $($r.file)" 'Red' }
        }
    }

    # 6) WMI subscriptions (definition saved so a human can recreate it)
    foreach ($w in @($s.wmi)) {
        try {
            $ns = 'root\subscription'
            $cons = @(Get-CimInstance -Namespace $ns -ClassName $w.class -ErrorAction Stop | Where-Object Name -eq $w.name)
            $saved = $cons | ForEach-Object { $h = @{}; foreach ($p in $_.CimInstanceProperties) { $h[$p.Name] = [string]$p.Value }; $h }
            foreach ($bnd in @(Get-CimInstance -Namespace $ns -ClassName __FilterToConsumerBinding -ErrorAction SilentlyContinue | Where-Object { $_.Consumer.Name -eq $w.name })) { Remove-CimInstance -InputObject $bnd -ErrorAction SilentlyContinue }
            foreach ($c in $cons) { Remove-CimInstance -InputObject $c -ErrorAction Stop }
            Log "   WMI consumer removed: $($w.name)" 'Green'
            AddOp @{ type = 'RemoveWmi'; class = $w.class; name = $w.name; definition = $saved; status = 'done' }
        } catch { Log "   could not remove WMI consumer $($w.name): $($_.Exception.Message)" 'Red' }
    }

    # 7) finally the file itself
    if ($moveFile) {
        $stored = Join-Path $filesDir ('{0:D3}_{1}.quar' -f [int]$s.id, (Split-Path $path -Leaf))
        if (Move-Safe $path $stored) {
            Log "   file quarantined -> $stored" 'Green'
            AddOp @{ type = 'QuarantineFile'; original = $path; stored = $stored; sha256 = $s.sha256; status = 'done' }
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
Save-Manifest $manifest $batchDir
Write-Host ''
Log "Done. Quarantine batch: $batchDir" 'Cyan'
Log 'Restart the PC, then re-run 1-Scan.bat to confirm the memory problem is gone.' 'Cyan'
Log 'Undo: 3-Restore.bat      Delete for good: 4-Purge.bat' 'Cyan'
