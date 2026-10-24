# ------------------------------------------------------------------------------------------
#  Hardening tests for src/RAM-Doctor-Actions.ps1 (the part that runs ELEVATED in real life).
#
#  Runs the real Quarantine -> Restore cycle against a harmless victim file + a Run-key value in a
#  TEMP store (-AllowNonAdmin -StoreDir <tmp>, never elevated, nothing under C:\ProgramData), then
#  FORGES manifests and plans and asserts that every hostile case is REFUSED and has no side effect:
#     stored path outside the batch's files\ folder      hash mismatch of the stored file
#     UNC / device destination                            destination under %WINDIR%
#     existing destination (must never be overwritten)    wildcard / UNC service names, wildcard task names
#     Run value restored into a non-Run key               files\ replaced by a junction (purge must not follow it)
#     plan: unsafe names, protected path, missing SHA-256, UNC path
#  plus the store-ACL helpers (Protect-StoreRoot / Test-StoreRootSecure) on a temp folder.
#
#  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\fixtures\Test-ActionsHardening.ps1
#  Exit code 0 = all assertions passed.  Windows PowerShell 5.1.  Cleans up everything it creates.
#  Note: the elevated-only branch (Initialize-StoreRoot on C:\ProgramData with admin rights) cannot run here.
# ------------------------------------------------------------------------------------------
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$actions = Join-Path $repo 'src\RAM-Doctor-Actions.ps1'
$tmp = Join-Path $env:TEMP ('ramdoc-hardening-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$store = Join-Path $tmp 'store'
$victimDir = Join-Path $tmp 'victim'
$decoyDir = Join-Path $tmp 'decoy'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$runKey = "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$runName = 'RamDoctorHardeningTest'
$forgedKey = "Registry::HKEY_USERS\$sid\SOFTWARE\RamDoctorForgedKey"
$inv = [Globalization.CultureInfo]::InvariantCulture
$script:fails = New-Object System.Collections.Generic.List[string]
$script:checks = 0
function Check([bool]$ok, [string]$what) {
    $script:checks++
    if ($ok) { Write-Host "  ok    $what" -ForegroundColor DarkGreen } else { $script:fails.Add($what); Write-Host "  FAIL  $what" -ForegroundColor Red }
}
function Section([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }

function Run-Actions([string[]]$argv) {
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $actions) + $argv + @('-Yes', '-AllowNonAdmin', '-StoreDir', $store)
    $o = & powershell.exe @all 2>&1 | Out-String
    return $o
}
function Latest-Batch { Get-ChildItem -LiteralPath (Join-Path $store 'Quarantine') -Directory | Sort-Object Name -Descending | Select-Object -First 1 }
function Read-Man($b) { Get-Content -LiteralPath (Join-Path $b.FullName 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Write-Man($b, $m) { [IO.File]::WriteAllText((Join-Path $b.FullName 'manifest.json'), ($m | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($true))) }
function New-Victim {
    New-Item -ItemType Directory -Force -Path $victimDir | Out-Null
    $f = Join-Path $victimDir 'zq8wm1rt.exe'
    [IO.File]::WriteAllBytes($f, [Text.Encoding]::ASCII.GetBytes('RAM Doctor hardening test file ' + [guid]::NewGuid()))
    New-ItemProperty -LiteralPath $runKey -Name $runName -Value ('"' + $f + '"') -PropertyType String -Force | Out-Null
    return $f
}
function New-Suspect([int]$id, [string]$path, [string]$sha, [hashtable]$over) {
    $h = @{
        id = $id; risk = 'High'; score = 9; name = [IO.Path]::GetFileName($path); path = $path; fileExists = $true; protectedFile = $false; sha256 = $sha
        sizeBytes = 10; created = ''; trust = 'Unsigned'; sigStatus = 'NotSigned'; publisher = ''; company = ''; description = ''; reasons = @('test')
        procs = @(); services = @(); tasks = @(); autoruns = @(); drivers = @(); wmi = @()
    }
    if ($over) { foreach ($k in $over.Keys) { $h[$k] = $over[$k] } }
    return [pscustomobject]$h
}
function New-PlanFile($suspects) {
    $plan = [pscustomobject]@{ tool = 'RAM-Doctor'; version = '1.0.0'; host = $env:COMPUTERNAME; created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $inv); suspects = @($suspects) }
    $f = Join-Path $tmp 'plan.json'
    [IO.File]::WriteAllText($f, ($plan | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($true)))
    return $f
}
function Quarantine-Victim {
    $f = New-Victim
    $sha = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
    $run = [pscustomobject]@{ via = 'Registry'; location = $runKey; name = $runName; value = ('"' + $f + '"'); file = '' }
    $plan = New-PlanFile @((New-Suspect 1 $f $sha @{ autoruns = @($run) }))
    $o = Run-Actions @('-Mode', 'Quarantine', '-Plan', $plan, '-Select', '1', '-NoRestorePoint')
    Start-Sleep -Milliseconds 1100
    return [pscustomobject]@{ File = $f; Sha = $sha; Out = $o; Batch = (Latest-Batch) }
}
function Cleanup {
    foreach ($j in "$store\Quarantine\20990101-000001\files") { if (Test-Path -LiteralPath $j) { cmd.exe /c rmdir "$j" 2>$null | Out-Null } }
    Remove-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $forgedKey -Recurse -ErrorAction SilentlyContinue
    foreach ($l in "$tmp\acl-junction") { if (Test-Path -LiteralPath $l) { cmd.exe /c rmdir "$l" 2>$null | Out-Null } }
    if (Test-Path -LiteralPath "$tmp\acl-dir") {   # give ourselves access back before deleting the locked-down folder
        try {
            $me = New-Object Security.Principal.SecurityIdentifier($sid)
            $di = New-Object IO.DirectoryInfo("$tmp\acl-dir"); $a = $di.GetAccessControl(); $a.SetAccessRuleProtection($false, $false)
            $a.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($me, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
            $di.SetAccessControl($a)
        } catch { Write-Host "  (cleanup: could not restore ACL: $($_.Exception.Message))" -ForegroundColor Yellow }
    }
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

try {
    New-Item -ItemType Directory -Force -Path $tmp, $store, $decoyDir | Out-Null

    # ------------------------------------------------------------------ baseline cycle
    Section 'baseline: quarantine -> restore works exactly as before'
    $q = Quarantine-Victim
    Check ($q.Out -match 'Done\. Quarantine batch') 'quarantine reports success'
    Check (-not (Test-Path -LiteralPath $q.File)) 'victim file was moved away'
    Check ($null -eq (Get-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue)) 'Run value was removed'
    $m = Read-Man $q.Batch
    $op = @($m.entries[0].ops | Where-Object { $_.type -eq 'QuarantineFile' })[0]
    Check ($op.storedSha256 -ieq $q.Sha) 'manifest records the stored file SHA-256'
    Check (Test-Path -LiteralPath $op.stored) 'stored file exists inside the batch'
    $o = Run-Actions @('-Mode', 'Restore', '-Batch', $q.Batch.Name)
    Check ($o -match 'Restore finished') 'restore finishes'
    Check (Test-Path -LiteralPath $q.File) 'victim file is back'
    Check ((Get-FileHash -LiteralPath $q.File -Algorithm SHA256).Hash -ieq $q.Sha) 'restored file is byte-identical'
    Check ($null -ne (Get-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue)) 'Run value is back'
    Check ([bool](Read-Man $q.Batch).restoredAt) 'batch is marked restored'

    # ------------------------------------------------------------------ 8.3 short names (very common in %TEMP%)
    Section 'short (8.3) paths such as C:\Users\NAME~1\...\Temp are accepted (regression: they were refused as "not a plain local drive path")'
    $longDir = Join-Path $tmp 'a-folder-with-a-long-name'
    New-Item -ItemType Directory -Force -Path $longDir | Out-Null
    $longFile = Join-Path $longDir 'zq8wm1rt-short.exe'
    [IO.File]::WriteAllBytes($longFile, [Text.Encoding]::ASCII.GetBytes('RAM Doctor short path test ' + [guid]::NewGuid()))
    $shortFile = ''
    try { $shortFile = (New-Object -ComObject Scripting.FileSystemObject).GetFile($longFile).ShortPath } catch { }
    if (-not $shortFile -or $shortFile -ieq $longFile -or $shortFile -notmatch '~') {
        Write-Host '  SKIP  8.3 short names are not generated on this volume' -ForegroundColor Yellow
    } else {
        $sha83 = (Get-FileHash -LiteralPath $longFile -Algorithm SHA256).Hash
        $plan83 = New-PlanFile @((New-Suspect 1 $shortFile $sha83 @{}))
        $o = Run-Actions @('-Mode', 'Quarantine', '-Plan', $plan83, '-Select', '1', '-NoRestorePoint')
        Start-Sleep -Milliseconds 1100
        Check ($o -match 'Done\. Quarantine batch') 'quarantine of a file given by its 8.3 name reports success'
        Check (-not (Test-Path -LiteralPath $longFile)) 'the file was moved away'
        $o = Run-Actions @('-Mode', 'Restore', '-Batch', (Latest-Batch).Name)
        Check ($o -match 'Restore finished') 'restore works when the recorded original path is a short name'
        Check (Test-Path -LiteralPath $longFile) 'the file is back'
        Start-Sleep -Milliseconds 1100
    }
    Remove-Item -LiteralPath $q.File -Force; Remove-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue

    # ------------------------------------------------------------------ forged manifests
    Section 'A) stored path outside the batch files\ folder'
    $q = Quarantine-Victim
    $decoy = Join-Path $decoyDir 'decoy-A.txt'; Set-Content -LiteralPath $decoy -Value 'must stay put'
    $m = Read-Man $q.Batch; ($m.entries[0].ops | Where-Object { $_.type -eq 'QuarantineFile' }).stored = $decoy; Write-Man $q.Batch $m
    $o = Run-Actions @('-Mode', 'Restore', '-Batch', $q.Batch.Name)
    Check ($o -match 'refusing to restore: stored file is not directly inside') 'refused'
    Check ((Test-Path -LiteralPath $decoy) -and -not (Test-Path -LiteralPath $q.File)) 'decoy untouched and nothing restored'
    Remove-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue

    Section 'B) stored file tampered (SHA-256 mismatch)'
    $q = Quarantine-Victim
    $m = Read-Man $q.Batch; $stored = ($m.entries[0].ops | Where-Object { $_.type -eq 'QuarantineFile' }).stored
    [IO.File]::AppendAllText($stored, 'TAMPERED')
    $o = Run-Actions @('-Mode', 'Restore', '-Batch', $q.Batch.Name)
    Check ($o -match 'does not match the SHA-256 recorded') 'refused'
    Check (-not (Test-Path -LiteralPath $q.File)) 'nothing restored to the original path'
    Remove-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue

    Section 'C) UNC destination'
    $q = Quarantine-Victim
    $m = Read-Man $q.Batch; ($m.entries[0].ops | Where-Object { $_.type -eq 'QuarantineFile' }).original = '\\localhost\c$\Users\Public\zq8wm1rt.exe'; Write-Man $q.Batch $m
    $o = Run-Actions @('-Mode', 'Restore', '-Batch', $q.Batch.Name)
    Check ($o -match 'not a plain local drive path') 'refused'
    Check (-not (Test-Path -LiteralPath 'C:\Users\Public\zq8wm1rt.exe')) 'nothing written to the UNC target'
    Remove-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue

    Section 'D) destination under %WINDIR% (protected)'
    $q = Quarantine-Victim
    $m = Read-Man $q.Batch; ($m.entries[0].ops | Where-Object { $_.type -eq 'QuarantineFile' }).original = "$env:SystemRoot\zq8wm1rt.exe"; Write-Man $q.Batch $m
    $o = Run-Actions @('-Mode', 'Restore', '-Batch', $q.Batch.Name)
    Check ($o -match 'protected location') 'refused'
    Check (-not (Test-Path -LiteralPath "$env:SystemRoot\zq8wm1rt.exe")) 'nothing written under %WINDIR%'
    Remove-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue

    Section 'E) destination already exists: never overwritten'
    $q = Quarantine-Victim
    New-Item -ItemType Directory -Force -Path $victimDir | Out-Null
    Set-Content -LiteralPath $q.File -Value 'someone else created this file meanwhile'
    $o = Run-Actions @('-Mode', 'Restore', '-Batch', $q.Batch.Name)
    Check ((Get-Content -LiteralPath $q.File -Raw) -match 'someone else') 'existing file is untouched'
    Check ((Test-Path -LiteralPath ($q.File + '.restored')) -and ((Get-FileHash -LiteralPath ($q.File + '.restored') -Algorithm SHA256).Hash -ieq $q.Sha)) 'original content restored next to it as .restored'
    Remove-Item -LiteralPath $q.File, ($q.File + '.restored') -Force -ErrorAction SilentlyContinue; Remove-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue

    Section 'F) forged service / driver / task entries'
    $fb = Join-Path $store 'Quarantine\20990101-000001'
    New-Item -ItemType Directory -Force -Path (Join-Path $fb 'files') | Out-Null
    $forged = [pscustomobject]@{ batch = '20990101-000001'; entries = @([pscustomobject]@{ id = 1; name = 'forged'; risk = 'High'; path = ''; ops = @(
                [pscustomobject]@{ type = 'DisableService'; name = '*'; prevStart = 2; prevDelayed = 0; status = 'done' },
                [pscustomobject]@{ type = 'DisableService'; name = '\\evil-host'; prevStart = 2; prevDelayed = 0; status = 'done' },
                [pscustomobject]@{ type = 'DisableDriver'; name = 'Spooler'; prevStart = 0; prevDelayed = 0; status = 'done' },
                [pscustomobject]@{ type = 'DisableTask'; taskPath = '\'; taskName = '*'; status = 'done' },
                [pscustomobject]@{ type = 'RemoveRunValue'; location = $forgedKey; name = 'x'; value = 'calc.exe'; kind = 'String'; status = 'done' },
                [pscustomobject]@{ type = 'RemoveRunValue'; location = $runKey; name = 'y'; value = 'calc.exe'; kind = 'Binary'; status = 'done' }) }) }
    [IO.File]::WriteAllText((Join-Path $fb 'manifest.json'), ($forged | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($true)))
    $spoolerBefore = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Spooler').Start
    $o = Run-Actions @('-Mode', 'Restore', '-Batch', '20990101-000001')
    Check (([regex]::Matches($o, "refusing to restore start type: unsafe service/driver name")).Count -eq 2) "wildcard '*' and '\\evil-host' service names refused"
    Check ($o -match "refusing to restore start type of Spooler: value '0'") 'boot-start value (0) refused for a driver/service restore'
    Check ($o -match "refusing to re-enable task: unsafe name") "task name '*' refused"
    Check ($o -match "refusing to restore Run value: '.*RamDoctorForgedKey' is not a known Run key") 'Run value into a non-Run key refused'
    Check ($o -match "refusing to restore Run value 'y': kind 'Binary' is not allowed") 'non-string Run value kind refused'
    Check (-not (Test-Path -LiteralPath $forgedKey)) 'forged registry key was not created'
    Check ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Spooler').Start -eq $spoolerBefore) 'no real service was modified'

    Section 'G) purge must not follow a junction'
    $decoyFile = Join-Path $decoyDir 'must-survive.quar'; Set-Content -LiteralPath $decoyFile -Value 'precious'
    Remove-Item -LiteralPath (Join-Path $fb 'files') -Recurse -Force
    cmd.exe /c mklink /J "$fb\files" "$decoyDir" | Out-Null
    $o = Run-Actions @('-Mode', 'Purge', '-Batch', '20990101-000001')
    Check ($o -match 'not found \(or not trusted\)|ignoring untrusted|refusing') 'batch with a junctioned files\ folder is refused'
    Check (Test-Path -LiteralPath $decoyFile) 'file behind the junction survived'
    cmd.exe /c rmdir "$fb\files" | Out-Null
    $o = Run-Actions @('-Mode', 'Purge', '-OlderThanDays', '0')
    Check (Test-Path -LiteralPath $decoyFile) 'purge --all also left the decoy alone'

    # ------------------------------------------------------------------ hostile plans
    Section 'H) hostile plan: unsafe names / UNC path / protected path / no hash'
    $f = New-Victim; $sha = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
    $f2 = Join-Path $victimDir 'zq8wm1rt-b.exe'; Set-Content -LiteralPath $f2 -Value 'second harmless victim, no hash in the plan'
    $np = "$env:SystemRoot\System32\notepad.exe"; $npSha = (Get-FileHash -LiteralPath $np -Algorithm SHA256).Hash
    $plan = New-PlanFile @(
        (New-Suspect 1 $f $sha @{ services = @([pscustomobject]@{ name = '*'; display = ''; startMode = 'Auto'; state = 'Running' }, [pscustomobject]@{ name = 'RpcSs'; display = ''; startMode = 'Auto'; state = 'Running' })
                tasks = @([pscustomobject]@{ taskPath = '\'; taskName = '*'; state = 'Ready'; cmd = '' })
                autoruns = @([pscustomobject]@{ via = 'Registry'; location = $forgedKey; name = 'x'; value = 'calc'; file = '' })
                wmi = @([pscustomobject]@{ class = 'Win32_Process'; name = 'x'; cmd = '' }) }),
        (New-Suspect 2 '\\localhost\c$\Users\Public\evil.exe' ('A' * 64) @{}),
        (New-Suspect 3 $np $npSha @{}),
        (New-Suspect 4 $f2 '' @{}))
    $o = Run-Actions @('-Mode', 'Quarantine', '-Plan', $plan, '-Select', '1,2,3,4', '-NoRestorePoint')
    Check ($o -match "refusing: unsafe service name '\*'") "service name '*' refused"
    Check ($o -match 'refusing to disable essential Windows service RpcSs') 'essential service RpcSs refused'
    Check ($o -match 'refusing: unsafe task name') "task name '*' refused"
    Check ($o -match "refusing: '.*RamDoctorForgedKey' is not a known Run key") 'Run value outside the Run keys refused'
    Check ($o -match "refusing: 'Win32_Process' is not a WMI event-consumer class") 'non-consumer WMI class refused'
    Check ($o -match 'refusing: ''\\\\localhost\\c\$\\Users\\Public\\evil\.exe'' is not a plain local drive path') 'UNC target path refused'
    Check ($o -match 'protected location' -and (Test-Path -LiteralPath $np)) 'notepad.exe (protected) not moved'
    Check (($o -match 'plan has no SHA-256') -and (Test-Path -LiteralPath $f2)) 'file without a plan hash refused and left in place'
    Check (-not (Test-Path -LiteralPath $forgedKey)) 'no registry key was created or touched'
    Remove-Item -LiteralPath $f, $f2 -Force -ErrorAction SilentlyContinue; Remove-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue

    # ------------------------------------------------------------------ store ACL helpers
    Section 'I) store ACL helpers (Protect-StoreRoot / Test-StoreRootSecure)'
    $aclTest = Join-Path $tmp 'acl-test.ps1'
    @"
. '$actions' -LoadFunctionsOnly -StoreDir '$tmp\acl-root'
`$d = '$tmp\acl-dir'; [void][IO.Directory]::CreateDirectory(`$d)
`$weak = Test-StoreRootSecure `$d
'weak.Secure=' + `$weak.Secure
Protect-StoreRoot `$d
`$acl = (New-Object IO.DirectoryInfo `$d).GetAccessControl()
'protected=' + `$acl.AreAccessRulesProtected
'sids=' + ((@(`$acl.GetAccessRules(`$true,`$true,[Security.Principal.SecurityIdentifier]) | ForEach-Object { `$_.IdentityReference.Value }) | Sort-Object) -join ',')
`$after = Test-StoreRootSecure `$d
'after.Secure=' + `$after.Secure + ' reason=' + `$after.Reason
cmd.exe /c mklink /J '$tmp\acl-junction' '$tmp\acl-dir' | Out-Null
`$j = Test-StoreRootSecure '$tmp\acl-junction'
'junction.Secure=' + `$j.Secure + ' reason=' + `$j.Reason
"@ | Set-Content -LiteralPath $aclTest -Encoding UTF8
    $r = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $aclTest 2>&1 | Out-String)
    Check ($r -match 'weak\.Secure=False') 'a default (inherited) folder ACL is reported as NOT secure'
    Check ($r -match 'protected=True') 'inheritance is disabled after Protect-StoreRoot'
    Check ($r -match 'sids=S-1-5-18,S-1-5-32-544') 'only SYSTEM (S-1-5-18) and Administrators (S-1-5-32-544) keep access'
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($elevated) { Check ($r -match 'after\.Secure=True') 'folder verifies as secure (elevated run)' }
    else { Check ($r -match 'after\.Secure=(True|False) reason=(|.*owner is .*)') 'non-elevated: ACL part is right; only the owner check can still object' }
    Check ($r -match 'junction\.Secure=False reason=folder is a reparse point') 'a junction is never accepted as the store root'
}
finally { Cleanup }

Write-Host ''
if ($script:fails.Count -eq 0) { Write-Host "OK - $($script:checks) assertions passed." -ForegroundColor Green; exit 0 }
Write-Host "$($script:fails.Count) of $($script:checks) assertions FAILED:" -ForegroundColor Red
$script:fails | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
