# Shared helpers for the Pester tests and the CI smoke script. Dot-source it:  . "$PSScriptRoot\helpers\TestHelpers.ps1"
# ASCII only (read by Windows PowerShell 5.1 without a BOM).

function Get-RepoRoot {
    # this file lives in <repo>\tests\helpers
    return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
}

function Get-WindowsPowerShellPath {
    # Always the inbox Windows PowerShell 5.1 (the product's only supported host), even when the tests run under pwsh.
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Test-IsElevated {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-TreeForce {
    <# Deletes a folder tree that may be locked down (ACL) or be / contain a junction. A junction is removed as a link and
       its target is never entered. Best effort, never throws. #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($Path); return }
        foreach ($c in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
            if ($c.PSIsContainer) { Remove-TreeForce -Path $c.FullName } else { Remove-Item -LiteralPath $c.FullName -Force -ErrorAction SilentlyContinue }
        }
        [IO.Directory]::Delete($Path)
    }
    catch {
        # a folder whose ACL does not include us: take it back (we are its owner or an administrator) and try once more
        try { & icacls.exe $Path /grant ("{0}:(OI)(CI)F" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name) /T /C /Q 2>&1 | Out-Null; Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Get-HeaderPieces {
    <# The P1..P6 pieces of the PowerShell command in the header of a built RAM-Doctor.bat, plus the final command line. #>
    param([Parameter(Mandatory)][string]$Bat)
    $pieces = @{}
    $final = $null
    foreach ($l in @(Get-Content -LiteralPath $Bat -Encoding UTF8 -TotalCount 80)) {
        if ($l -match '^set "(P\d+)=(.*)"\s*$') { $pieces[$Matches[1]] = $Matches[2] }
        elseif ($l -match '-Command "(%P1%.*)"\s*$') { $final = $Matches[1] }
    }
    return [pscustomobject]@{ Pieces = $pieces; Final = $final }
}

function Invoke-HeaderSnippet {
    <# Runs P1+P2+P3 of the header (the ACL helpers: New-LockedAcl, New-LockedDir, Test-LockedDir) followed by your code,
       in a fresh Windows PowerShell. Returns the Invoke-ChildPowerShell result. #>
    param([Parameter(Mandatory)][string]$Bat, [Parameter(Mandatory)][string]$Code, [int]$TimeoutSec = 60)
    $h = Get-HeaderPieces -Bat $Bat
    $file = Join-Path ([IO.Path]::GetTempPath()) ('ramdoc-header-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
    [IO.File]::WriteAllText($file, ($h.Pieces['P1'] + "`r`n" + $h.Pieces['P2'] + "`r`n" + $h.Pieces['P3'] + "`r`n" + $Code + "`r`n"), [Text.Encoding]::ASCII)
    try { return (Invoke-ChildPowerShell -File $file -TimeoutSec $TimeoutSec) } finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

function Invoke-ActionsSnippet {
    <# Runs PowerShell code in a fresh powershell.exe after dot-sourcing src\RAM-Doctor-Actions.ps1 with -LoadFunctionsOnly
       (only its functions and variables are defined, nothing is executed). -StoreDir picks the store root the functions
       use; leave it out to work on the real default (C:\ProgramData\RAM-Doctor). #>
    param([Parameter(Mandatory)][string]$Code, [string]$StoreDir = '', [int]$TimeoutSec = 120)
    $actions = Join-Path (Get-RepoRoot) 'src\RAM-Doctor-Actions.ps1'
    $dot = ". '$actions' -LoadFunctionsOnly"
    if ($StoreDir) { $dot += " -StoreDir '$StoreDir'" }
    $file = Join-Path ([IO.Path]::GetTempPath()) ('ramdoc-snippet-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
    [IO.File]::WriteAllText($file, ("`$ErrorActionPreference = 'Stop'`r`n" + $dot + "`r`n" + $Code + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    try { return (Invoke-ChildPowerShell -File $file -TimeoutSec $TimeoutSec) } finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

function Get-SnippetResult {
    <# The JSON object a snippet printed on a line starting with RESULT: (see the tests), or $null. #>
    param([Parameter(Mandatory)]$Run)
    $line = @(($Run.StdOut -split "`r?`n") | Where-Object { $_ -like 'RESULT:*' } | Select-Object -Last 1)
    if (-not $line) { return $null }
    return ($line[0].Substring(7) | ConvertFrom-Json)
}

function Get-FunctionSource {
    <# Source text of the named top-level functions of a script, extracted with the PowerShell parser (the script is NOT executed). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Name)
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)   # ParseFile resolves relative paths against the process folder, not the PowerShell location
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $found = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $map = @{}
    foreach ($f in $found) { if ($Name -contains $f.Name) { $map[$f.Name] = $f.Extent.Text } }
    return $map
}

function Invoke-ChildPowerShell {
    <# Runs powershell.exe -File with a timeout; returns ExitCode / StdOut / StdErr / TimedOut. Optional environment overrides. #>
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [int]$TimeoutSec = 120
    )
    $quote = { param($a) if ($a -match '[\s"]' -or $a -eq '') { '"' + ($a -replace '"', '\"') + '"' } else { $a } }
    $parts = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (& $quote $File)) + @($ArgumentList | ForEach-Object { & $quote ([string]$_) })
    return (Invoke-ChildProcess -FilePath (Get-WindowsPowerShellPath) -Arguments ($parts -join ' ') -Environment $Environment -TimeoutSec $TimeoutSec)
}

function Invoke-ChildProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [hashtable]$Environment = @{},
        [int]$TimeoutSec = 120,
        [string]$StdIn = ''
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$Environment[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($StdIn); $p.StandardInput.Close()      # EOF on stdin so a 'pause' never blocks
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { $timedOut = $true; try { $p.Kill() } catch { } }
    $p.WaitForExit()
    return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $so.Result; StdErr = $se.Result; TimedOut = $timedOut }
}

function New-TempDirectory {
    param([string]$Prefix = 'ramdoc-test')
    $d = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# ---------------------------------------------------------------------------------------------------------------------
# Plan JSON contract.  The scan (src\RAM-Doctor.ps1) writes Plan-<host>-<stamp>.json; the actions script and the window
# read it.  Test-RamPlan returns a list of human-readable violations (empty list = valid).
# ---------------------------------------------------------------------------------------------------------------------
function Test-RamPlan {
    param([Parameter(Mandatory)]$Plan)
    $err = New-Object System.Collections.Generic.List[string]
    $has = { param($o, $n) ($null -ne $o) -and ($null -ne $o.PSObject.Properties[$n]) }
    $isInt = { param($v) ($v -is [int]) -or ($v -is [long]) }
    $isStr = { param($v) $v -is [string] }
    $isArr = { param($v) $v -is [System.Array] }

    foreach ($n in 'tool', 'version', 'host', 'created', 'isAdmin', 'report', 'verdict', 'observations', 'suspects') {
        if (-not (& $has $Plan $n)) { $err.Add("plan: missing '$n'") }
    }
    if ($err.Count -gt 0) { return $err.ToArray() }

    if ($Plan.tool -ne 'RAM-Doctor') { $err.Add("plan.tool must be 'RAM-Doctor'") }
    if (-not (& $isStr $Plan.version) -or [string]::IsNullOrWhiteSpace($Plan.version)) { $err.Add('plan.version must be a non-empty string') }
    if (-not (& $isStr $Plan.host) -or [string]::IsNullOrWhiteSpace($Plan.host)) { $err.Add('plan.host must be a non-empty string') }
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$Plan.created, [ref]$dt)) { $err.Add("plan.created is not a date: '$($Plan.created)'") }
    if ($Plan.isAdmin -isnot [bool]) { $err.Add('plan.isAdmin must be a boolean') }
    # optional: the language the scan wrote its texts in (added with the English UI; plans of older releases have none = Arabic)
    if ((& $has $Plan 'lang') -and (@('ar', 'en') -notcontains [string]$Plan.lang)) { $err.Add("plan.lang invalid: '$($Plan.lang)'") }

    # optional (scans after 1.1.2): the breakdown of the memory Task Manager does not show. Additive: older plans have none,
    # but when a field is there it must have the right type, because the window and the share summaries read it.
    if ((& $has $Plan 'memory') -and $null -ne $Plan.memory) {
        $mem = $Plan.memory
        foreach ($n in 'HiddenGB', 'SharedUniqueGB', 'DriverReservedGB', 'KernelPoolsGB', 'SystemOtherGB', 'UnexplainedGB', 'UnattributedGB') {
            if (& $has $mem $n) {
                $v = $mem.$n
                if (-not ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal])) { $err.Add("plan.memory.$n must be a number") }
                elseif ([double]$v -lt 0) { $err.Add("plan.memory.$n must not be negative") }
            }
        }
        if ((& $has $mem 'DriverReservedKnown') -and $mem.DriverReservedKnown -isnot [bool]) { $err.Add('plan.memory.DriverReservedKnown must be a boolean') }
        if (& $has $mem 'TopShared') {
            if (-not (& $isArr $mem.TopShared)) { $err.Add('plan.memory.TopShared must be an array') }
            else {
                $t = 0
                foreach ($x in $mem.TopShared) {
                    foreach ($f in 'name', 'count', 'sharedMB') { if (-not (& $has $x $f)) { $err.Add("plan.memory.TopShared[$t]: missing '$f'") } }
                    $t++
                }
            }
        }
        if (& $has $mem 'DriverReservedCandidates') {
            if (-not (& $isArr $mem.DriverReservedCandidates)) { $err.Add('plan.memory.DriverReservedCandidates must be an array') }
            elseif (@($mem.DriverReservedCandidates | Where-Object { -not (& $isStr $_) }).Count -gt 0) { $err.Add('plan.memory.DriverReservedCandidates must contain strings only') }
        }
    }

    # verdict + observations are what the window shows
    foreach ($n in 'Level', 'Headline') { if (-not (& $has $Plan.verdict $n)) { $err.Add("plan.verdict: missing '$n'") } }
    if ((& $has $Plan.verdict 'Level') -and (@('ok', 'low', 'med', 'high') -notcontains [string]$Plan.verdict.Level)) { $err.Add("plan.verdict.Level invalid: '$($Plan.verdict.Level)'") }
    if ((& $has $Plan.verdict 'Headline') -and [string]::IsNullOrWhiteSpace([string]$Plan.verdict.Headline)) { $err.Add('plan.verdict.Headline is empty') }
    if (-not (& $isArr $Plan.observations)) { $err.Add('plan.observations must be an array') }
    else {
        $i = 0
        foreach ($o in $Plan.observations) {
            foreach ($n in 'Level', 'Title', 'Body') { if (-not (& $has $o $n)) { $err.Add("observations[$i]: missing '$n'") } }
            if ((& $has $o 'Level') -and (@('high', 'med', 'low', 'info') -notcontains [string]$o.Level)) { $err.Add("observations[$i].Level invalid: '$($o.Level)'") }
            $i++
        }
    }

    # suspects: what the actions script acts on
    if (-not (& $isArr $Plan.suspects)) { $err.Add('plan.suspects must be an array'); return $err.ToArray() }
    $seen = @{}
    $arrayProps = @{
        procs    = @('pid', 'start')
        services = @('name')
        tasks    = @('taskPath', 'taskName')
        autoruns = @('via', 'location', 'name', 'value', 'file')
        drivers  = @('name')
        wmi      = @('class', 'name')
    }
    $k = 0
    foreach ($s in $Plan.suspects) {
        $w = "suspects[$k]"
        foreach ($n in 'id', 'risk', 'score', 'name', 'path', 'fileExists', 'protectedFile', 'sha256', 'trust', 'reasons') {
            if (-not (& $has $s $n)) { $err.Add("${w}: missing '$n'") }
        }
        if ((& $has $s 'id')) {
            if (-not (& $isInt $s.id) -or $s.id -lt 1) { $err.Add("${w}.id must be an integer >= 1") }
            elseif ($seen.ContainsKey([int]$s.id)) { $err.Add("${w}.id $($s.id) is duplicated") } else { $seen[[int]$s.id] = $true }
        }
        if ((& $has $s 'risk') -and (@('High', 'Medium', 'Low') -notcontains [string]$s.risk)) { $err.Add("${w}.risk invalid: '$($s.risk)'") }
        if ((& $has $s 'score') -and -not (& $isInt $s.score)) { $err.Add("${w}.score must be an integer") }
        if ((& $has $s 'name') -and [string]::IsNullOrWhiteSpace([string]$s.name)) { $err.Add("${w}.name is empty") }
        if ((& $has $s 'path') -and -not (& $isStr $s.path)) { $err.Add("${w}.path must be a string") }
        if ((& $has $s 'fileExists') -and $s.fileExists -isnot [bool]) { $err.Add("${w}.fileExists must be a boolean") }
        if ((& $has $s 'protectedFile') -and $s.protectedFile -isnot [bool]) { $err.Add("${w}.protectedFile must be a boolean") }
        if ((& $has $s 'sha256') -and ([string]$s.sha256 -notmatch '^([0-9A-Fa-f]{64})?$')) { $err.Add("${w}.sha256 must be empty or 64 hex characters") }
        if ((& $has $s 'reasons')) {
            if (-not (& $isArr $s.reasons) -or $s.reasons.Count -lt 1) { $err.Add("${w}.reasons must be a non-empty array") }
            else { foreach ($r in $s.reasons) { if (-not (& $isStr $r)) { $err.Add("${w}.reasons must contain strings only") ; break } } }
        }
        foreach ($ap in $arrayProps.Keys) {
            if (-not (& $has $s $ap)) { $err.Add("${w}: missing '$ap'"); continue }
            if (-not (& $isArr $s.$ap)) { $err.Add("${w}.$ap must be an array"); continue }
            $j = 0
            foreach ($item in $s.$ap) {
                foreach ($f in $arrayProps[$ap]) { if (-not (& $has $item $f)) { $err.Add("${w}.$ap[$j]: missing '$f'") } }
                if ($ap -eq 'procs' -and (& $has $item 'pid') -and -not (& $isInt $item.pid)) { $err.Add("${w}.procs[$j].pid must be an integer") }
                if ($ap -eq 'autoruns' -and (& $has $item 'via') -and (@('Registry', 'StartupFolder') -notcontains [string]$item.via)) { $err.Add("${w}.autoruns[$j].via invalid: '$($item.via)'") }
                $j++
            }
        }
        $k++
    }
    return $err.ToArray()
}

function New-SyntheticPlan {
    <# A valid plan built from synthetic data only. The suspect points at a real file you pass in (a harmless fixture). #>
    param(
        [string]$HostName = $env:COMPUTERNAME,
        [string]$SuspectPath = 'C:\Users\Example\AppData\Local\Temp\qz8wm1rt.exe',
        [string]$Sha256 = ('A' * 64),
        [string]$Risk = 'High',
        [bool]$Protected = $false,
        [bool]$FileExists = $true
    )
    $suspect = [pscustomobject]@{
        id = 1; risk = $Risk; score = 10; name = [IO.Path]::GetFileName($SuspectPath); path = $SuspectPath
        fileExists = $FileExists; protectedFile = $Protected; sha256 = $Sha256; sizeBytes = 4096; created = '2026-01-01 10:00:00'
        trust = 'Unsigned'; sigStatus = 'NotSigned'; publisher = ''; company = ''; description = ''
        reasons = @('synthetic reason: unsigned file in a temporary folder')
        procs = @(); services = @(); tasks = @(); autoruns = @(); drivers = @(); wmi = @()
    }
    return [pscustomobject]@{
        tool = 'RAM-Doctor'; version = '1.0'; host = $HostName; created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        isAdmin = $false; report = 'C:\Example\RAMDoctor-EXAMPLE-20260101-100000.html'
        verdict = [pscustomobject]@{ Level = 'high'; Headline = 'synthetic headline' }
        observations = @([pscustomobject]@{ Level = 'high'; Title = 'synthetic observation'; Body = 'synthetic body' })
        memory = [pscustomobject]@{ TotalGB = 16; UsedGB = 12 }
        suspects = @($suspect)
    }
}

function Write-PlanFile {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$Path)
    [IO.File]::WriteAllText($Path, ($Plan | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
}
