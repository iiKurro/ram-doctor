#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Tests for the code that only does its real work when the process is ELEVATED (administrator): the locked-down
# quarantine store, the hardened restore / purge, service start-type changes, and the native-helper loader.
#
# On a normal (non-admin) session every test is SKIPPED, cleanly. They run on GitHub's windows-latest runners (which are
# administrators) and in an elevated console:
#       powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-ElevatedTests.ps1
#
# SAFETY RULES for this file (it changes system state, so it is deliberately boring):
#   * every object it creates is named RamDoctorCiTest-<8 hex>... and recorded for AfterAll to remove
#   * it never touches a real service, driver, task, Run value or file; test services point at a plain-text file and are never started
#   * the real quarantine store (C:\ProgramData\RAM-Doctor) is used for the default-location tests; if it already exists
#     it is never modified beyond what a normal run does, only the batch folders created here are removed, and it is
#     removed as a whole only if it did not exist before
#   * throw-away store roots for the hardening tests live next to it as C:\ProgramData\RamDoctorCiTest-...

BeforeDiscovery {
    $script:Elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $script:IsElevated = Test-IsElevated
    if (-not $script:IsElevated) { return }     # nothing below may run on a normal session

    $script:Root = Get-RepoRoot
    $script:Actions = Join-Path $script:Root 'src\RAM-Doctor-Actions.ps1'
    $script:Engine = Join-Path $script:Root 'src\RAM-Doctor.ps1'
    $script:Tag = 'RamDoctorCiTest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $script:Started = Get-Date
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) $script:Tag
    New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
    $script:ProgramData = [Environment]::GetFolderPath('CommonApplicationData')
    $script:DefaultStore = Join-Path $script:ProgramData 'RAM-Doctor'
    $script:StoreExisted = Test-Path -LiteralPath $script:DefaultStore
    $script:RunKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $script:Trusted = @('S-1-5-18', 'S-1-5-32-544')
    $script:Me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    # everything created is recorded here and removed in AfterAll
    $script:CleanServices = New-Object System.Collections.Generic.List[string]
    $script:CleanDirs = New-Object System.Collections.Generic.List[string]
    $script:CleanRunValues = New-Object System.Collections.Generic.List[string]
    $script:CleanFiles = New-Object System.Collections.Generic.List[string]
    $script:CleanRegKeys = New-Object System.Collections.Generic.List[string]

    # ---------------------------------------------------------------------------------------------------- helpers
    function New-Hog([string]$Label) {
        # a harmless plain-text "suspect" file
        $p = Join-Path $script:Work ('{0}-{1}.exe' -f $script:Tag, $Label)
        [IO.File]::WriteAllText($p, "RAM Doctor CI fixture $Label - plain text, not an executable.", [Text.Encoding]::ASCII)
        return [pscustomobject]@{ Path = $p; Name = [IO.Path]::GetFileName($p); Sha = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
    }

    function Add-RunValue([string]$Name, [string]$Path) {
        # a freshly created profile (e.g. a CI runner) may not have the Run key yet
        if (-not (Test-Path -LiteralPath $script:RunKey)) { New-Item -Path $script:RunKey -Force | Out-Null }
        New-ItemProperty -LiteralPath $script:RunKey -Name $Name -Value ('"{0}"' -f $Path) -PropertyType String -Force | Out-Null
        $script:CleanRunValues.Add($Name)
    }
    function Get-RunValue([string]$Name) { return (Get-ItemProperty -LiteralPath $script:RunKey -Name $Name -ErrorAction SilentlyContinue).$Name }

    function Add-TestService([string]$Name, [string]$Binary, [string]$StartupType) {
        New-Service -Name $Name -BinaryPathName ('"{0}"' -f $Binary) -DisplayName $Name -StartupType $StartupType | Out-Null
        $script:CleanServices.Add($Name)
    }
    function Get-ServiceStart([string]$Name) { return (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -ErrorAction SilentlyContinue).Start }

    function New-CasePlan {
        param($Hog, [string]$RunName = '', [string]$ServiceName = '', [string]$DriverName = '')
        $plan = New-SyntheticPlan -HostName $env:COMPUTERNAME -SuspectPath $Hog.Path -Sha256 $Hog.Sha
        $s = $plan.suspects[0]
        $s.name = $Hog.Name
        if ($RunName) { $s.autoruns = @([pscustomobject]@{ via = 'Registry'; location = $script:RunKey; name = $RunName; value = ('"{0}"' -f $Hog.Path); file = '' }) }
        if ($ServiceName) { $s.services = @([pscustomobject]@{ name = $ServiceName; display = $ServiceName; startMode = 'Auto'; state = 'Stopped' }) }
        if ($DriverName) { $s.drivers = @([pscustomobject]@{ name = $DriverName; display = $DriverName; startMode = 'Manual' }) }
        $file = Join-Path $script:Work ('plan-{0}.json' -f [guid]::NewGuid().ToString('N').Substring(0, 6))
        Write-PlanFile -Plan $plan -Path $file
        return $file
    }

    function Invoke-Act([string]$Mode, [string[]]$More = @()) {
        # the REAL default store, running elevated: no -StoreDir, no -AllowNonAdmin
        $a = @('-Mode', $Mode, '-Yes') + $More
        if ($Mode -eq 'Quarantine') { $a += '-NoRestorePoint' }
        return (Invoke-ChildPowerShell -File $script:Actions -ArgumentList $a -TimeoutSec 240)
    }

    function New-QuarantinedCase {
        param([string]$Label, [switch]$WithRun, [string]$ServiceName = '', [string]$DriverName = '')
        $hog = New-Hog $Label
        $run = ''
        if ($WithRun) { $run = '{0}-run-{1}' -f $script:Tag, $Label; Add-RunValue $run $hog.Path }
        $plan = New-CasePlan -Hog $hog -RunName $run -ServiceName $ServiceName -DriverName $DriverName
        $q = Invoke-Act 'Quarantine' @('-Plan', $plan, '-Select', '1')
        $batch = $null
        if ($q.StdOut -match '(?m)Quarantine batch: (.+?)\s*$') { $batch = $Matches[1].Trim(); $script:CleanDirs.Add($batch) }
        $name = $null; if ($batch) { $name = Split-Path $batch -Leaf }
        return [pscustomobject]@{ Hog = $hog; Run = $run; Plan = $plan; Q = $q; Batch = $batch; BatchName = $name }
    }

    function Edit-Manifest([string]$BatchDir, [scriptblock]$Mutate) {
        $mf = Join-Path $BatchDir 'manifest.json'
        $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
        & $Mutate $m
        [IO.File]::WriteAllText($mf, ($m | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($true)))
    }

    function Set-DirOwner([string]$Path, [string]$Sid) {
        $di = New-Object IO.DirectoryInfo($Path)
        $a = $di.GetAccessControl()
        $a.SetOwner((New-Object Security.Principal.SecurityIdentifier($Sid)))
        $di.SetAccessControl($a)
    }

    function New-ThrowawayRoot([string]$Case) {
        $p = Join-Path $script:ProgramData ('{0}-{1}' -f $script:Tag, $Case)
        $script:CleanDirs.Add($p)
        return $p
    }

    # code run inside a fresh powershell.exe after dot-sourcing the Actions functions (see Invoke-ActionsSnippet)
    $script:InitProbe = @'
$ok = Initialize-StoreRoot
$di = New-Object IO.DirectoryInfo($DataRoot)
$acl = $di.GetAccessControl()
$allow = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' } | ForEach-Object { @{ sid = $_.IdentityReference.Value; rights = [string]$_.FileSystemRights } })
$chk = Test-StoreRootSecure $DataRoot
'RESULT:' + (@{ initialized = [bool]$ok; dataRoot = [string]$DataRoot; secure = [bool]$chk.Secure; reason = [string]$chk.Reason; owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value; protected = [bool]$acl.AreAccessRulesProtected; reparse = [bool]($di.Attributes -band [IO.FileAttributes]::ReparsePoint); quarantineExists = (Test-Path -LiteralPath $QRoot); allow = $allow } | ConvertTo-Json -Depth 5 -Compress)
'@
    $script:CheckProbe = @'
$chk = Test-StoreRootSecure $DataRoot
'RESULT:' + (@{ secure = [bool]$chk.Secure; reason = [string]$chk.Reason } | ConvertTo-Json -Compress)
'@

    function Start-ImportNativeProbe {
        # starts a child that runs the engine's Import-Native (extracted from src\RAM-Doctor.ps1 with the parser) with a private TEMP
        param([string]$PrivateTemp, [switch]$HideCsc)
        $fn = (Get-FunctionSource -Path $script:Engine -Name 'Import-Native')['Import-Native']
        if (-not $fn) { return $null }
        if ($HideCsc) {
            if (-not $fn.Contains("'csc.exe'")) { return $null }
            $fn = $fn.Replace("'csc.exe'", "'csc-missing-ramdoctor-ci.exe'")      # the function now cannot find the compiler
        }
        $lines = @(
            "`$ErrorActionPreference = 'Stop'",
            ("`$Root = '{0}'" -f (Join-Path $script:Root 'src')),
            '$IsAdmin = $true',
            $fn,
            '$ok = Import-Native',
            "'RESULT:' + (@{ ok = [bool]`$ok; typeLoaded = [bool]('RamDoc.Native' -as [type]) } | ConvertTo-Json -Compress)"
        )
        $file = Join-Path $script:Work ('probe-{0}.ps1' -f [guid]::NewGuid().ToString('N').Substring(0, 6))
        [IO.File]::WriteAllText($file, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Get-WindowsPowerShellPath
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $file
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['TEMP'] = $PrivateTemp; $psi.EnvironmentVariables['TMP'] = $PrivateTemp
        $p = [System.Diagnostics.Process]::Start($psi)
        return [pscustomobject]@{ Process = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
    }

    function Watch-WorkFolder($Probe, [string]$PrivateTemp) {
        # polls the private TEMP while the child runs and records the ACL of the compiler work folder the moment it exists
        $seen = $null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $Probe.Process.HasExited -and $sw.Elapsed.TotalSeconds -lt 180) {
            if (-not $seen) {
                foreach ($d in @(Get-ChildItem -LiteralPath $PrivateTemp -Directory -Filter 'RamDoctor-*' -Force -ErrorAction SilentlyContinue)) {
                    try {
                        $acl = $d.GetAccessControl()
                        $seen = [pscustomobject]@{
                            Name = $d.Name; Owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value; Protected = [bool]$acl.AreAccessRulesProtected
                            Allow = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' } | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
                            Reparse = [bool]($d.Attributes -band [IO.FileAttributes]::ReparsePoint)
                        }
                    }
                    catch { }
                }
            }
            Start-Sleep -Milliseconds 4
        }
        if (-not $Probe.Process.HasExited) { try { $Probe.Process.Kill() } catch { } }
        $Probe.Process.WaitForExit()
        return $seen
    }
}

AfterAll {
    if (-not $script:IsElevated) { return }
    foreach ($n in $script:CleanServices) {
        & sc.exe stop $n 2>&1 | Out-Null
        & sc.exe delete $n 2>&1 | Out-Null
    }
    foreach ($n in $script:CleanRunValues) { Remove-ItemProperty -LiteralPath $script:RunKey -Name $n -ErrorAction SilentlyContinue }
    foreach ($k in $script:CleanRegKeys) { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($d in $script:CleanDirs) { Remove-TreeForce -Path $d }
    # throw-away store roots and whatever was moved aside from them
    foreach ($d in @(Get-ChildItem -LiteralPath $script:ProgramData -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($script:Tag + '*') })) { Remove-TreeForce -Path $d.FullName }
    # the default store: remove it only if the tests created it; otherwise only the logs written during the run
    if ($script:DefaultStore) {
        if (-not $script:StoreExisted) { Remove-TreeForce -Path $script:DefaultStore }
        elseif (Test-Path -LiteralPath $script:DefaultStore) {
            foreach ($f in @(Get-ChildItem -LiteralPath $script:DefaultStore -File -Filter 'actions-*.log' -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $script:Started.AddSeconds(-2) })) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($f in $script:CleanFiles) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    Remove-TreeForce -Path (Join-Path $env:SystemRoot ('Temp\{0}-forged.exe' -f $script:Tag))
    Remove-TreeForce -Path $script:Work
}

# ====================================================================================================================
Describe 'Quarantine store root: default location (C:\ProgramData\RAM-Doctor)' -Tag 'Elevated' -Skip:(-not $script:Elevated) {

    It 'Initialize-StoreRoot leaves it with ACL = SYSTEM + Administrators only, trusted owner, no inheritance, not a junction' {
        if ($script:StoreExisted) {
            $pre = Get-SnippetResult -Run (Invoke-ActionsSnippet -Code $script:CheckProbe)
            if (-not $pre.secure) { Set-ItResult -Skipped -Because "the store that already exists on this machine is not locked down ($($pre.reason)); this test will not alter someone's real data"; return }
        }
        $r = Invoke-ActionsSnippet -Code $script:InitProbe
        $r.ExitCode | Should -Be 0 -Because ($r.StdErr + $r.StdOut)
        $res = Get-SnippetResult -Run $r
        $res.initialized | Should -BeTrue
        $res.dataRoot | Should -Be $script:DefaultStore
        $res.secure | Should -BeTrue -Because $res.reason
        $res.protected | Should -BeTrue
        $res.reparse | Should -BeFalse
        $script:Trusted | Should -Contain $res.owner
        $res.quarantineExists | Should -BeTrue
        $sids = @($res.allow | ForEach-Object { $_.sid } | Sort-Object -Unique)
        $sids | Should -Be @('S-1-5-18', 'S-1-5-32-544')
        foreach ($a in $res.allow) { $a.rights | Should -Be 'FullControl' }
    }

    It 'is re-verified on every run: a second Initialize-StoreRoot gives the same, still-secure result' {
        $pre = Get-SnippetResult -Run (Invoke-ActionsSnippet -Code $script:CheckProbe)
        if (-not $pre.secure) { Set-ItResult -Skipped -Because 'the default store is not secure on this machine (see the previous test)'; return }
        $res = Get-SnippetResult -Run (Invoke-ActionsSnippet -Code $script:InitProbe)
        $res.initialized | Should -BeTrue
        $res.secure | Should -BeTrue
    }
}

# ====================================================================================================================
Describe 'Quarantine store root: hardening on throw-away roots' -Tag 'Elevated' -Skip:(-not $script:Elevated) {

    It 'creates a missing root already locked down, owned by SYSTEM/Administrators' {
        $root = New-ThrowawayRoot 'fresh'
        $r = Invoke-ActionsSnippet -StoreDir $root -Code $script:InitProbe
        $r.ExitCode | Should -Be 0 -Because ($r.StdErr + $r.StdOut)
        $res = Get-SnippetResult -Run $r
        $res.initialized | Should -BeTrue
        $res.secure | Should -BeTrue -Because $res.reason
        $res.protected | Should -BeTrue
        $script:Trusted | Should -Contain $res.owner
        @($res.allow | ForEach-Object { $_.sid } | Sort-Object -Unique) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
    }

    It 'repairs an existing root whose permissions are too open (inherited ACL) and keeps its content' {
        $root = New-ThrowawayRoot 'open'
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-DirOwner $root 'S-1-5-32-544'                 # trusted owner, so only the open permissions are wrong
        [IO.File]::WriteAllText((Join-Path $root 'keep.txt'), 'content that must survive', [Text.Encoding]::ASCII)
        $pre = Get-SnippetResult -Run (Invoke-ActionsSnippet -StoreDir $root -Code $script:CheckProbe)
        $pre.secure | Should -BeFalse
        $res = Get-SnippetResult -Run (Invoke-ActionsSnippet -StoreDir $root -Code $script:InitProbe)
        $res.initialized | Should -BeTrue
        $res.secure | Should -BeTrue -Because $res.reason
        $res.protected | Should -BeTrue
        @($res.allow | ForEach-Object { $_.sid } | Sort-Object -Unique) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:ProgramData -Directory -Force | Where-Object { $_.Name -like ($script:Tag + '-open.untrusted-*') }).Count | Should -Be 0 -Because 'a root with trusted owner is repaired in place, not moved'
    }

    It 'moves a root owned by somebody else aside and starts a clean one (never reuses its content)' {
        $root = New-ThrowawayRoot 'owner'
        New-Item -ItemType Directory -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'planted-manifest.txt'), 'planted by another user', [Text.Encoding]::ASCII)
        Set-DirOwner $root $script:Me
        $pre = Get-SnippetResult -Run (Invoke-ActionsSnippet -StoreDir $root -Code $script:CheckProbe)
        $pre.secure | Should -BeFalse
        $pre.reason | Should -Match 'owner'
        $res = Get-SnippetResult -Run (Invoke-ActionsSnippet -StoreDir $root -Code $script:InitProbe)
        $res.initialized | Should -BeTrue
        $res.secure | Should -BeTrue -Because $res.reason
        Test-Path -LiteralPath (Join-Path $root 'planted-manifest.txt') | Should -BeFalse -Because 'the new root must not contain what the old owner left'
        $aside = @(Get-ChildItem -LiteralPath $script:ProgramData -Directory -Force | Where-Object { $_.Name -like ($script:Tag + '-owner.untrusted-*') })
        $aside.Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $aside[0].FullName 'planted-manifest.txt') | Should -BeTrue -Because 'the old folder is kept (moved aside), not deleted'
    }

    It 'moves a junction aside without following it, and leaves the junction target untouched' {
        $root = New-ThrowawayRoot 'junction'
        $target = Join-Path $script:Work 'junction-target'
        New-Item -ItemType Directory -Path $target | Out-Null
        [IO.File]::WriteAllText((Join-Path $target 'sentinel.txt'), 'target content', [Text.Encoding]::ASCII)
        $sddlBefore = (New-Object IO.DirectoryInfo($target)).GetAccessControl().GetSecurityDescriptorSddlForm('All')
        & cmd.exe /c mklink /J "$root" "$target" | Out-Null
        Test-Path -LiteralPath $root | Should -BeTrue
        $pre = Get-SnippetResult -Run (Invoke-ActionsSnippet -StoreDir $root -Code $script:CheckProbe)
        $pre.secure | Should -BeFalse
        $pre.reason | Should -Match 'reparse|junction'
        $res = Get-SnippetResult -Run (Invoke-ActionsSnippet -StoreDir $root -Code $script:InitProbe)
        $res.initialized | Should -BeTrue
        $res.secure | Should -BeTrue -Because $res.reason
        $res.reparse | Should -BeFalse -Because 'the store root must now be a real folder, not a junction'
        Test-Path -LiteralPath (Join-Path $target 'sentinel.txt') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $target -Force).Count | Should -Be 1 -Because 'nothing may be created through the junction'
        (New-Object IO.DirectoryInfo($target)).GetAccessControl().GetSecurityDescriptorSddlForm('All') | Should -Be $sddlBefore -Because "the target's permissions must not be changed"
        $aside = @(Get-ChildItem -LiteralPath $script:ProgramData -Directory -Force | Where-Object { $_.Name -like ($script:Tag + '-junction.untrusted-*') })
        $aside.Count | Should -Be 1
        ($aside[0].Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0 -Because 'the junction itself was renamed, not entered'
    }
}

# ====================================================================================================================
Describe 'Actions lifecycle on the REAL default store (quarantine -> restore -> purge)' -Tag 'Elevated' -Skip:(-not $script:Elevated) {
    BeforeAll {
        $script:Case = New-QuarantinedCase -Label 'life' -WithRun
    }

    It 'quarantine succeeds elevated: file moved into the store, Run value removed, nothing else touched' {
        $script:Case.Q.TimedOut | Should -BeFalse
        $script:Case.Q.ExitCode | Should -Be 0 -Because ($script:Case.Q.StdOut + $script:Case.Q.StdErr)
        $script:Case.Batch | Should -Not -BeNullOrEmpty
        $script:Case.Batch.StartsWith((Join-Path $script:DefaultStore 'Quarantine') + '\', [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        Test-Path -LiteralPath $script:Case.Hog.Path | Should -BeFalse
        $stored = @(Get-ChildItem -LiteralPath (Join-Path $script:Case.Batch 'files') -File -Force)
        $stored.Count | Should -Be 1
        $stored[0].Name | Should -Match '^001_.+\.quar$'
        (Get-FileHash -LiteralPath $stored[0].FullName -Algorithm SHA256).Hash | Should -Be $script:Case.Hog.Sha
        Get-RunValue $script:Case.Run | Should -BeNullOrEmpty
    }

    It 'the store root and the new batch are locked down (owner SYSTEM/Administrators, no allow-rule for anybody else)' {
        $chk = Get-SnippetResult -Run (Invoke-ActionsSnippet -Code $script:CheckProbe)
        $chk.secure | Should -BeTrue -Because $chk.reason
        foreach ($p in @($script:Case.Batch, (Join-Path $script:Case.Batch 'manifest.json'), (Join-Path $script:Case.Batch 'files'))) {
            $acl = (Get-Item -LiteralPath $p -Force).GetAccessControl()
            $script:Trusted | Should -Contain $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -Because $p
            $allow = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' } | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
            $allow | Should -Be @('S-1-5-18', 'S-1-5-32-544') -Because $p
        }
    }

    It 'List shows the batch' {
        $r = Invoke-Act 'List'
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Match ([regex]::Escape($script:Case.BatchName))
    }

    It 'restore puts the file back byte-identical, re-creates the Run value exactly, and marks the batch restored' {
        $r = Invoke-Act 'Restore' @('-Batch', $script:Case.BatchName)
        $r.ExitCode | Should -Be 0 -Because ($r.StdOut + $r.StdErr)
        Test-Path -LiteralPath $script:Case.Hog.Path | Should -BeTrue
        (Get-FileHash -LiteralPath $script:Case.Hog.Path -Algorithm SHA256).Hash | Should -Be $script:Case.Hog.Sha
        Get-RunValue $script:Case.Run | Should -Be ('"{0}"' -f $script:Case.Hog.Path)
        (Get-Content -LiteralPath (Join-Path $script:Case.Batch 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties['restoredAt'] | Should -Not -BeNullOrEmpty
    }

    It 'restoring the same batch again is a harmless no-op' {
        $r = Invoke-Act 'Restore' @('-Batch', $script:Case.BatchName)
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Match 'already restored'
        Test-Path -LiteralPath $script:Case.Hog.Path | Should -BeTrue
    }

    It 'purge deletes the quarantined file for good and marks the batch purged (only the named batch)' {
        $again = New-QuarantinedCase -Label 'purge' -WithRun
        $again.Q.ExitCode | Should -Be 0 -Because ($again.Q.StdOut + $again.Q.StdErr)
        $otherManifest = Join-Path $script:Case.Batch 'manifest.json'
        $otherBefore = (Get-FileHash -LiteralPath $otherManifest -Algorithm SHA256).Hash
        $r = Invoke-Act 'Purge' @('-Batch', $again.BatchName)
        $r.ExitCode | Should -Be 0 -Because ($r.StdOut + $r.StdErr)
        @(Get-ChildItem -LiteralPath (Join-Path $again.Batch 'files') -File -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
        Test-Path -LiteralPath $again.Hog.Path | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $again.Batch 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties['purgedAt'] | Should -Not -BeNullOrEmpty
        (Get-FileHash -LiteralPath $otherManifest -Algorithm SHA256).Hash | Should -Be $otherBefore -Because 'other batches must not be touched'
    }
}

# ====================================================================================================================
Describe 'Actions: forged manifests are refused in the real store' -Tag 'Elevated' -Skip:(-not $script:Elevated) {

    It 'refuses a stored file that is not directly inside the batch files\ folder, and does not move it' {
        $c = New-QuarantinedCase -Label 'outside' -WithRun
        $c.Q.ExitCode | Should -Be 0 -Because ($c.Q.StdOut + $c.Q.StdErr)
        $outside = Join-Path $script:Work ('{0}-outside.quar' -f $script:Tag)
        [IO.File]::WriteAllText($outside, 'outside the batch', [Text.Encoding]::ASCII)
        $h = (Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash
        Edit-Manifest $c.Batch { param($m) foreach ($op in $m.entries[0].ops) { if ($op.type -eq 'QuarantineFile') { $op.stored = $outside; $op.storedSha256 = $h } } }
        $r = Invoke-Act 'Restore' @('-Batch', $c.BatchName)
        $r.StdOut | Should -Match 'not directly inside'
        Test-Path -LiteralPath $c.Hog.Path | Should -BeFalse -Because 'nothing may be restored from outside the batch'
        Test-Path -LiteralPath $outside | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $c.Batch 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties['restoredAt'] | Should -BeNullOrEmpty -Because 'a failed restore must not be recorded as done'
    }

    It 'refuses a quarantined file whose content no longer matches the recorded SHA-256' {
        $c = New-QuarantinedCase -Label 'tampered'
        $c.Q.ExitCode | Should -Be 0 -Because ($c.Q.StdOut + $c.Q.StdErr)
        $stored = @(Get-ChildItem -LiteralPath (Join-Path $c.Batch 'files') -File -Force)[0].FullName
        Add-Content -LiteralPath $stored -Value 'tampered' -Encoding ASCII
        $r = Invoke-Act 'Restore' @('-Batch', $c.BatchName)
        $r.StdOut | Should -Match 'does not match the SHA-256'
        Test-Path -LiteralPath $c.Hog.Path | Should -BeFalse
    }

    It 'refuses a restore destination inside a protected location (Windows folder)' {
        $c = New-QuarantinedCase -Label 'protected'
        $c.Q.ExitCode | Should -Be 0 -Because ($c.Q.StdOut + $c.Q.StdErr)
        $forged = Join-Path $env:SystemRoot ('Temp\{0}-forged.exe' -f $script:Tag)
        Edit-Manifest $c.Batch { param($m) foreach ($op in $m.entries[0].ops) { if ($op.type -eq 'QuarantineFile') { $op.original = $forged } } }
        $r = Invoke-Act 'Restore' @('-Batch', $c.BatchName)
        $r.StdOut | Should -Match 'protected location'
        Test-Path -LiteralPath $forged | Should -BeFalse -Because 'nothing may be written into the Windows folder'
        Test-Path -LiteralPath $c.Hog.Path | Should -BeFalse
    }

    It 'refuses a restore destination that is a UNC / network path' {
        $c = New-QuarantinedCase -Label 'unc'
        $c.Q.ExitCode | Should -Be 0 -Because ($c.Q.StdOut + $c.Q.StdErr)
        Edit-Manifest $c.Batch { param($m) foreach ($op in $m.entries[0].ops) { if ($op.type -eq 'QuarantineFile') { $op.original = '\\localhost\C$\ramdoctor-ci-forged.exe' } } }
        $r = Invoke-Act 'Restore' @('-Batch', $c.BatchName)
        $r.StdOut | Should -Match 'plain local drive path'
        Test-Path -LiteralPath '\\localhost\C$\ramdoctor-ci-forged.exe' | Should -BeFalse
    }

    It 'refuses to re-create a Run value outside the known Run keys' {
        $c = New-QuarantinedCase -Label 'runkey' -WithRun
        $c.Q.ExitCode | Should -Be 0 -Because ($c.Q.StdOut + $c.Q.StdErr)
        $forgedKey = 'HKCU:\SOFTWARE\{0}-forged' -f $script:Tag
        $script:CleanRegKeys.Add($forgedKey)
        Edit-Manifest $c.Batch { param($m) foreach ($op in $m.entries[0].ops) { if ($op.type -eq 'RemoveRunValue') { $op.location = $forgedKey } } }
        $r = Invoke-Act 'Restore' @('-Batch', $c.BatchName)
        $r.StdOut | Should -Match 'not a known Run key'
        Test-Path -LiteralPath $forgedKey | Should -BeFalse -Because 'no registry key may be created from a forged location'
    }

    It 'refuses an unsafe service name (wildcard) and a boot-start type for a real test service' {
        $svc = '{0}-svcforge' -f $script:Tag
        $hog = New-Hog 'svcforge'
        Add-TestService -Name $svc -Binary $hog.Path -StartupType 'Manual'
        (Get-ServiceStart $svc) | Should -Be 3
        $c = New-QuarantinedCase -Label 'forgedsvc'
        $c.Q.ExitCode | Should -Be 0 -Because ($c.Q.StdOut + $c.Q.StdErr)
        Edit-Manifest $c.Batch {
            param($m)
            $m.entries[0].ops = @($m.entries[0].ops) + @(
                [pscustomobject]@{ type = 'DisableService'; name = '*'; prevStart = 2; prevDelayed = 0; status = 'done' },
                [pscustomobject]@{ type = 'DisableService'; name = $svc; prevStart = 0; prevDelayed = 0; status = 'done' })
        }
        $r = Invoke-Act 'Restore' @('-Batch', $c.BatchName)
        $r.StdOut | Should -Match 'unsafe service/driver name'
        $r.StdOut | Should -Match "value '0' is not allowed"
        (Get-ServiceStart $svc) | Should -Be 3 -Because 'a forged manifest must not be able to change a start type to boot'
    }

    It 'ignores a batch folder that is a junction, and refuses to restore from it' {
        $target = Join-Path $script:Work 'evil-target'
        New-Item -ItemType Directory -Path (Join-Path $target 'files') -Force | Out-Null
        $planted = Join-Path $script:Work ('{0}-planted.exe' -f $script:Tag)
        [IO.File]::WriteAllText((Join-Path $target 'files\001_x.quar'), 'evil', [Text.Encoding]::ASCII)
        $h = (Get-FileHash -LiteralPath (Join-Path $target 'files\001_x.quar') -Algorithm SHA256).Hash
        $forged = @{ batch = 'evil'; version = '1.0.0'; entries = @(@{ id = 1; name = 'x'; risk = 'High'; path = $planted; ops = @(@{ type = 'QuarantineFile'; original = $planted; stored = (Join-Path $target 'files\001_x.quar'); sha256 = $h; storedSha256 = $h; status = 'done' }) }) }
        [IO.File]::WriteAllText((Join-Path $target 'manifest.json'), ($forged | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
        $null = Invoke-ActionsSnippet -Code 'Initialize-StoreRoot | Out-Null'      # make sure the store and its Quarantine folder exist
        $evil = Join-Path $script:DefaultStore ('Quarantine\{0}-evil' -f $script:Tag)
        $script:CleanDirs.Add($evil)
        & cmd.exe /c mklink /J "$evil" "$target" | Out-Null
        $r = Invoke-Act 'Restore' @('-Batch', ('{0}-evil' -f $script:Tag))
        ($r.StdOut + $r.StdErr) | Should -Match 'not found \(or not trusted\)|ignoring untrusted batch'
        Test-Path -LiteralPath $planted | Should -BeFalse -Because 'nothing may be restored from a junction-backed batch'
        $l = Invoke-Act 'List'
        $l.StdOut | Should -Match 'ignoring untrusted batch folder'
    }

    It 'ignores a batch folder owned by a normal user, and refuses to restore from it' {
        $dir = Join-Path $script:DefaultStore ('Quarantine\{0}-foreign' -f $script:Tag)
        $script:CleanDirs.Add($dir)
        $null = Invoke-ActionsSnippet -Code 'Initialize-StoreRoot | Out-Null'
        New-Item -ItemType Directory -Path (Join-Path $dir 'files') -Force | Out-Null
        $planted = Join-Path $script:Work ('{0}-planted2.exe' -f $script:Tag)
        [IO.File]::WriteAllText((Join-Path $dir 'files\001_x.quar'), 'evil', [Text.Encoding]::ASCII)
        $h = (Get-FileHash -LiteralPath (Join-Path $dir 'files\001_x.quar') -Algorithm SHA256).Hash
        $forged = @{ batch = 'foreign'; version = '1.0.0'; entries = @(@{ id = 1; name = 'x'; risk = 'High'; path = $planted; ops = @(@{ type = 'QuarantineFile'; original = $planted; stored = (Join-Path $dir 'files\001_x.quar'); sha256 = $h; storedSha256 = $h; status = 'done' }) }) }
        [IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), ($forged | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
        Set-DirOwner $dir $script:Me
        $r = Invoke-Act 'Restore' @('-Batch', ('{0}-foreign' -f $script:Tag))
        ($r.StdOut + $r.StdErr) | Should -Match 'not found \(or not trusted\)|ignoring untrusted batch'
        Test-Path -LiteralPath $planted | Should -BeFalse
        $l = Invoke-Act 'List'
        $l.StdOut | Should -Match 'ignoring untrusted batch folder'
    }
}

# ====================================================================================================================
Describe 'Actions: services and drivers (start type changed through sc.exe, then restored)' -Tag 'Elevated' -Skip:(-not $script:Elevated) {

    It 'disables a test service through the Actions code path (Start=4) and restores its original start type (Start=2)' {
        $svc = '{0}-svc' -f $script:Tag
        $hog = New-Hog 'svc'
        Add-TestService -Name $svc -Binary $hog.Path -StartupType 'Automatic'
        (Get-ServiceStart $svc) | Should -Be 2
        $plan = New-CasePlan -Hog $hog -ServiceName $svc
        $q = Invoke-Act 'Quarantine' @('-Plan', $plan, '-Select', '1')
        $q.ExitCode | Should -Be 0 -Because ($q.StdOut + $q.StdErr)
        $q.StdOut | Should -Match ('service disabled: ' + [regex]::Escape($svc))
        (Get-ServiceStart $svc) | Should -Be 4
        Test-Path -LiteralPath $hog.Path | Should -BeFalse
        $batch = $null; if ($q.StdOut -match '(?m)Quarantine batch: (.+?)\s*$') { $batch = $Matches[1].Trim(); $script:CleanDirs.Add($batch) }
        $batch | Should -Not -BeNullOrEmpty
        $r = Invoke-Act 'Restore' @('-Batch', (Split-Path $batch -Leaf))
        $r.ExitCode | Should -Be 0 -Because ($r.StdOut + $r.StdErr)
        (Get-ServiceStart $svc) | Should -Be 2
        Test-Path -LiteralPath $hog.Path | Should -BeTrue
    }

    It 'driver branch (a plain service entry): demand-start (3) -> disabled (4) -> restored (3)' {
        $drv = '{0}-drv' -f $script:Tag
        $hog = New-Hog 'drv'
        Add-TestService -Name $drv -Binary $hog.Path -StartupType 'Manual'
        (Get-ServiceStart $drv) | Should -Be 3
        $plan = New-CasePlan -Hog $hog -DriverName $drv
        $q = Invoke-Act 'Quarantine' @('-Plan', $plan, '-Select', '1')
        $q.ExitCode | Should -Be 0 -Because ($q.StdOut + $q.StdErr)
        $q.StdOut | Should -Match ('driver disabled \(takes effect at next boot\): ' + [regex]::Escape($drv))
        (Get-ServiceStart $drv) | Should -Be 4
        $batch = $null; if ($q.StdOut -match '(?m)Quarantine batch: (.+?)\s*$') { $batch = $Matches[1].Trim(); $script:CleanDirs.Add($batch) }
        $r = Invoke-Act 'Restore' @('-Batch', (Split-Path $batch -Leaf))
        $r.ExitCode | Should -Be 0 -Because ($r.StdOut + $r.StdErr)
        (Get-ServiceStart $drv) | Should -Be 3
    }

    It 'Test-SafeServiceName rejects wildcards and path-like names but accepts ordinary service names (function level, nothing is changed)' {
        $code = @'
$names = '*', '?', 'a*b', '..\evil', 'x/y', 'a;b', '', 'RamDoctorCiTest-ok_1.2', 'Spooler'
'RESULT:' + (@{ results = @($names | ForEach-Object { @{ name = $_; safe = [bool](Test-SafeServiceName $_) } }) } | ConvertTo-Json -Depth 4 -Compress)
'@
        $res = Get-SnippetResult -Run (Invoke-ActionsSnippet -Code $code)
        $map = @{}; foreach ($x in @($res.results)) { $map[[string]$x.name] = [bool]$x.safe }
        foreach ($bad in '*', '?', 'a*b', '..\evil', 'x/y', 'a;b', '') { $map[$bad] | Should -BeFalse -Because "'$bad' must be rejected" }
        $map['RamDoctorCiTest-ok_1.2'] | Should -BeTrue
        $map['Spooler'] | Should -BeTrue
    }
}

# ====================================================================================================================
Describe 'Engine native-helper loader (Import-Native in src\RAM-Doctor.ps1)' -Tag 'Elevated' -Skip:(-not $script:Elevated) {

    It 'compiles with csc.exe inside a work folder that only SYSTEM and Administrators can access, loads the type, and removes the folder' {
        $priv = Join-Path $script:Work 'native-temp'
        New-Item -ItemType Directory -Path $priv -Force | Out-Null
        $probe = Start-ImportNativeProbe -PrivateTemp $priv
        if (-not $probe) { Set-ItResult -Skipped -Because 'Import-Native was not found in src\RAM-Doctor.ps1 (the loader changed; update this test)'; return }
        $seen = Watch-WorkFolder -Probe $probe -PrivateTemp $priv
        $probe.Process.ExitCode | Should -Be 0 -Because ($probe.Err.Result + $probe.Out.Result)
        $res = ($probe.Out.Result -split "`r?`n" | Where-Object { $_ -like 'RESULT:*' } | Select-Object -Last 1).Substring(7) | ConvertFrom-Json
        $res.ok | Should -BeTrue
        $res.typeLoaded | Should -BeTrue
        @(Get-ChildItem -LiteralPath $priv -Directory -Filter 'RamDoctor-*' -Force).Count | Should -Be 0 -Because 'the compiler work folder is deleted when the helper is loaded'
        if (-not $seen) { Set-ItResult -Skipped -Because 'the compile finished before the work folder could be observed (the ACL assertion needs a snapshot of it)'; return }
        $seen.Reparse | Should -BeFalse
        $seen.Protected | Should -BeTrue -Because 'inheritance must be off, or a normal user could write the DLL before it is loaded'
        $seen.Allow | Should -Be @('S-1-5-18', 'S-1-5-32-544')
        $script:Trusted | Should -Contain $seen.Owner
    }

    It 'falls back to Add-Type when csc.exe cannot be found: no compiler work folder is ever created, the type still loads' {
        $priv = Join-Path $script:Work 'native-temp-fallback'
        New-Item -ItemType Directory -Path $priv -Force | Out-Null
        $probe = Start-ImportNativeProbe -PrivateTemp $priv -HideCsc
        if (-not $probe) { Set-ItResult -Skipped -Because "Import-Native or its 'csc.exe' lookup was not found in src\RAM-Doctor.ps1 (the loader changed; update this test)"; return }
        $seen = Watch-WorkFolder -Probe $probe -PrivateTemp $priv
        $probe.Process.ExitCode | Should -Be 0 -Because ($probe.Err.Result + $probe.Out.Result)
        $res = ($probe.Out.Result -split "`r?`n" | Where-Object { $_ -like 'RESULT:*' } | Select-Object -Last 1).Substring(7) | ConvertFrom-Json
        $res.ok | Should -BeTrue
        $res.typeLoaded | Should -BeTrue
        $seen | Should -BeNullOrEmpty -Because 'without csc.exe the loader must not create the DLL work folder at all'
    }
}
