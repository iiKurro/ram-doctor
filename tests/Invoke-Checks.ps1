#requires -Version 5.1
<#
.SYNOPSIS
  One command that proves the repository is healthy: static gate + analyzer + Pester. Used by CI and by contributors.

.DESCRIPTION
  Static gate (fast, no admin, no side effects):
    1  every PowerShell file parses                         5  no unfinished-work or merge-conflict markers left behind
    2  encodings: Arabic-capable sources have a UTF-8 BOM,   6  src\share.config.json parses and has its keys
       .bat files are ASCII + CRLF + no BOM, YAML/MD/JSON    7  build\VERSION is valid (and matches the CHANGELOG)
       files have no BOM                                     8  PSScriptAnalyzer (tests\PSScriptAnalyzerSettings.psd1)
    3  C# sources compile in Windows PowerShell 5.1 (C# 5)   9  Pester: every tests\**\*.Tests.ps1 except tests\gui
    4  no personal data and no secrets anywhere in the repo
    7b the release RAM-Doctor.bat has no environment hooks (builds it into a temp folder and inspects it: no RAMDOC_ text,
       no -TestScript pass-through, only $env:SELF read by PowerShell, only allowed %variables% in cmd.exe)
    7c release.yml builds without -DevHooks and publishes only dist/RAM-Doctor.bat + dist/SHA256SUMS.txt; no workflow
       uploads the test build (RAM-Doctor.devhooks.bat)

  Windows PowerShell 5.1 is the product's only supported host, so run this with powershell.exe:
      powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-Checks.ps1

  Exit code 0 = all green (warnings allowed), 1 = at least one failure.
  A line can opt out of the secret scan by containing the text  allow-secret-scan  (for deliberately fake fixtures).
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [switch]$SkipPester,
    [switch]$SkipAnalyzer,
    [switch]$SkipCompile,
    [switch]$InstallMissing,    # install Pester 5 / PSScriptAnalyzer from the PowerShell Gallery when absent (used in CI)
    [switch]$FailOnWarning,     # analyzer warnings fail the run too
    [string[]]$ExcludeTag = @(),   # Pester tags to leave out, e.g. Elevated (CI runs those in their own job)
    [string]$ResultsDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
if (-not $ResultsDir) { $ResultsDir = Join-Path ([IO.Path]::GetTempPath()) 'ramdoctor-checks' }
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
. (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')

$script:Results = New-Object System.Collections.Generic.List[object]
$onGitHub = [bool]$env:GITHUB_ACTIONS

# ---- Pester comes first -----------------------------------------------------------------------------------------------
# Resolve and import the pinned Pester BEFORE anything else runs. PSScriptAnalyzer resolves commands inside the test files
# and would otherwise auto-load the highest Pester it finds, which then collides with the pinned version that is imported
# later ("[Pester.Factory] does not contain a method ...").
$script:PesterVersion = $null
$script:PesterProblem = $null
if (-not $SkipPester) {
    $wanted = $env:RAMDOC_PESTER_VERSION     # CI pins an exact version; locally any Pester >= 5.5 will do
    $min = [version]'5.5.0'
    $pick = { @(Get-Module -ListAvailable -Name Pester | Where-Object { if ($wanted) { $_.Version -eq [version]$wanted } else { $_.Version -ge $min } } | Sort-Object Version -Descending) }
    $have = & $pick
    if (-not $have -and $InstallMissing) {
        try {
            if ($wanted) { Install-Module Pester -RequiredVersion $wanted -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber -ErrorAction Stop }
            else { Install-Module Pester -MinimumVersion $min -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber -ErrorAction Stop }
        }
        catch { Write-Host ('could not install Pester: ' + $_.Exception.Message) }
        $have = & $pick
    }
    if (-not $have) { $script:PesterProblem = 'Pester 5 is required (the Windows built-in 3.4 is too old). Install: Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck   (or pass -InstallMissing)' }
    else {
        Get-Module Pester | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module Pester -RequiredVersion $have[0].Version -Force
        $script:PesterVersion = $have[0].Version
    }
}
function Add-Result {
    param([string]$Name, [ValidateSet('PASS', 'FAIL', 'WARN', 'SKIP')][string]$Status, [string[]]$Details = @())
    $script:Results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Details = $Details })
    $color = @{ PASS = 'Green'; FAIL = 'Red'; WARN = 'Yellow'; SKIP = 'DarkGray' }[$Status]
    Write-Host ('[{0}] {1}' -f $Status, $Name) -ForegroundColor $color
    foreach ($d in ($Details | Select-Object -First 25)) { Write-Host ('       ' + $d) }
    if ($Details.Count -gt 25) { Write-Host ('       ... and {0} more' -f ($Details.Count - 25)) }
}

function Write-Annotation {
    # shows up inline on the pull request / run summary when running in GitHub Actions
    param([ValidateSet('error', 'warning')][string]$Level, [string]$File, [int]$Line, [string]$Message)
    if (-not $onGitHub) { return }
    $rel = if ($File -and $File.StartsWith($Root)) { $File.Substring($Root.Length + 1).Replace('\', '/') } else { $File }
    $msg = ($Message -replace '%', '%25' -replace "`r", '' -replace "`n", '%0A')
    if ($rel) { Write-Host ("::{0} file={1},line={2}::{3}" -f $Level, $rel, [math]::Max(1, $Line), $msg) } else { Write-Host ("::{0}::{1}" -f $Level, $msg) }
}

# ---- repository file enumeration (generated / vendored folders are never inspected) ----------------------------------
$skipDirs = '\.git', 'dist', 'node_modules', '\.wrangler', 'results'
$allFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
        $rel = $_.FullName.Substring($Root.Length)
        $ok = $true
        foreach ($d in $skipDirs) { if ($rel -match ('^\\' + $d + '\\')) { $ok = $false; break } }
        if ($rel -match '\\node_modules\\') { $ok = $false }
        $ok
    })
function Select-Files([string[]]$Extensions) { @($allFiles | Where-Object { $Extensions -contains $_.Extension.ToLowerInvariant() }) }
function Get-Rel([string]$full) { if ($full -and $full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { $full.Substring($Root.Length + 1) } else { $full } }

# ---- 1. parse ---------------------------------------------------------------------------------------------------------
$bad = New-Object System.Collections.Generic.List[string]
$psFiles = Select-Files @('.ps1', '.psm1', '.psd1')
foreach ($f in $psFiles) {
    $t = $null; $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
    foreach ($x in $e) { $bad.Add(('{0}:{1}  {2}' -f (Get-Rel $f.FullName), $x.Extent.StartLineNumber, $x.Message)); Write-Annotation error $f.FullName $x.Extent.StartLineNumber $x.Message }
}
if ($bad.Count) { Add-Result 'PowerShell files parse' 'FAIL' $bad.ToArray() } else { Add-Result ("PowerShell files parse ({0} files)" -f $psFiles.Count) 'PASS' }

# ---- 2. encodings -----------------------------------------------------------------------------------------------------
$bad = New-Object System.Collections.Generic.List[string]
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
function Test-HasBom([byte[]]$b) { return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) }
function Test-NonAscii([byte[]]$b) { foreach ($x in $b) { if ($x -gt 127) { return $true } } return $false }
foreach ($f in (Select-Files @('.ps1', '.psm1', '.psd1', '.cs'))) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    if ((Test-NonAscii $b) -and -not (Test-HasBom $b)) { $bad.Add((Get-Rel $f.FullName) + ': contains non-ASCII text but has no UTF-8 BOM (Windows PowerShell 5.1 would misread it)') }
    try { [void]$utf8Strict.GetString($b) } catch { $bad.Add((Get-Rel $f.FullName) + ': is not valid UTF-8') }
}
foreach ($f in (Select-Files @('.bat', '.cmd'))) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $name = Get-Rel $f.FullName
    if (Test-HasBom $b) { $bad.Add("${name}: batch files must not have a BOM (cmd would choke on the first line)") }
    if (Test-NonAscii $b) { $bad.Add("${name}: batch files must be pure ASCII") }
    $s = [Text.Encoding]::ASCII.GetString($b)
    if ([regex]::IsMatch($s, "(?<!`r)`n")) { $bad.Add("${name}: batch files must use CRLF line endings") }
}
foreach ($f in (Select-Files @('.yml', '.yaml', '.md', '.html', '.css', '.js', '.mjs', '.cjs', '.json', '.jsonc', '.toml', '.txt', '.svg'))) {
    $rel = Get-Rel $f.FullName
    if ($rel -like 'src\*') { continue }       # src\*.json is unpacked with a BOM anyway and read with Get-Content
    $b = [IO.File]::ReadAllBytes($f.FullName)
    if (Test-HasBom $b) { $bad.Add("${rel}: must not have a UTF-8 BOM") }
    try { [void]$utf8Strict.GetString($b) } catch { $bad.Add("${rel}: is not valid UTF-8") }
    # YAML forbids tab characters for indentation; catching it here saves a red workflow run on GitHub
    if (@('.yml', '.yaml') -contains $f.Extension.ToLowerInvariant() -and ($b -contains 9)) { $bad.Add("${rel}: contains a TAB character (YAML must be indented with spaces)") }
}
if ($bad.Count) { $bad | ForEach-Object { Write-Annotation error '' 1 $_ }; Add-Result 'File encodings' 'FAIL' $bad.ToArray() } else { Add-Result 'File encodings (BOM / ASCII / CRLF rules)' 'PASS' }

# ---- 3. C# compiles on Windows PowerShell 5.1 -------------------------------------------------------------------------
if ($SkipCompile) { Add-Result 'C# sources compile' 'SKIP' @('-SkipCompile') }
else {
    $cs = Select-Files @('.cs')
    $bad = New-Object System.Collections.Generic.List[string]
    $helper = Join-Path ([IO.Path]::GetTempPath()) ('ramdoc-compile-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
    [IO.File]::WriteAllText($helper, @'
param([string]$Path)
$ErrorActionPreference = 'Stop'
try {
    Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition ([IO.File]::ReadAllText($Path)) -Language CSharp
    'compiled'
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
'@)
    try {
        foreach ($f in $cs) {
            $r = Invoke-ChildPowerShell -File $helper -ArgumentList @('-Path', $f.FullName) -TimeoutSec 180
            if ($r.TimedOut -or $r.ExitCode -ne 0) {
                $why = (($r.StdErr + $r.StdOut) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 6) -join ' / '
                $bad.Add((Get-Rel $f.FullName) + ': does not compile - ' + $why)
                Write-Annotation error $f.FullName 1 ('does not compile: ' + $why)
            }
        }
    }
    finally { Remove-Item -LiteralPath $helper -Force -ErrorAction SilentlyContinue }
    if ($bad.Count) { Add-Result 'C# sources compile (C# 5, fresh powershell.exe each)' 'FAIL' $bad.ToArray() } else { Add-Result ("C# sources compile ({0} files, C# 5, fresh powershell.exe each)" -f $cs.Count) 'PASS' }
}

# ---- 4. personal data and secrets -------------------------------------------------------------------------------------
# The patterns are assembled from pieces so that this very file never matches itself.
$personal = New-Object System.Collections.Generic.List[object]
$personal.Add(@{ Name = 'a local user name'; Rx = [regex]::new(('hssh' + '1'), 'IgnoreCase') })
$personal.Add(@{ Name = 'a workstation name'; Rx = [regex]::new(('7' + 'SAN'), 'None') })
$personal.Add(@{ Name = 'a Google Drive path'; Rx = [regex]::new('G:[\\/]+My Drive', 'IgnoreCase') })
$personal.Add(@{ Name = 'a personal e-mail address'; Rx = [regex]::new('@gmail\.com', 'IgnoreCase') })
if ($env:USERPROFILE -and $env:USERPROFILE.Length -gt 12) { $personal.Add(@{ Name = 'the local profile path'; Rx = [regex]::new([regex]::Escape($env:USERPROFILE), 'IgnoreCase') }) }
$generic = 'administrator', 'admin', 'user', 'runner', 'runneradmin', 'public', 'default', 'system', 'owner', 'test'
if ($env:USERNAME -and $env:USERNAME.Length -ge 5 -and ($generic -notcontains $env:USERNAME.ToLowerInvariant())) {
    $personal.Add(@{ Name = 'the local account name'; Rx = [regex]::new('\b' + [regex]::Escape($env:USERNAME) + '\b', 'IgnoreCase') })
}
$secrets = @(
    @{ Name = 'GitHub token'; Rx = [regex]::new('\bgh[pousr]_[A-Za-z0-9]{20,}') }
    @{ Name = 'GitHub fine-grained token'; Rx = [regex]::new('\bgithub_pat_[A-Za-z0-9_]{20,}') }
    @{ Name = 'private key block'; Rx = [regex]::new('-----BEGIN (RSA |OPENSSH |EC |DSA |ENCRYPTED |PGP )?PRIVATE KEY') }
    @{ Name = 'Cloudflare token assignment'; Rx = [regex]::new('(?i)\b(cloudflare|cf)[_-]?(api)?[_-]?(token|key|secret)\w*\s*[:=]\s*["'']?[A-Za-z0-9_-]{37,}') }
    @{ Name = 'bearer token'; Rx = [regex]::new('(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{30,}') }
    @{ Name = 'AWS access key'; Rx = [regex]::new('\bAKIA[0-9A-Z]{16}\b') }
    @{ Name = 'Slack token'; Rx = [regex]::new('\bxox[abprs]-[A-Za-z0-9-]{10,}') }
    @{ Name = 'Google API key'; Rx = [regex]::new('\bAIza[0-9A-Za-z_-]{35}\b') }
    @{ Name = 'API secret key'; Rx = [regex]::new('\bsk-[A-Za-z0-9]{32,}\b') }
)
$binary = '.png', '.jpg', '.jpeg', '.gif', '.ico', '.webp', '.zip', '.pdf', '.woff', '.woff2', '.ttf', '.eot', '.mp4', '.webm', '.exe', '.dll', '.bin'
$bad = New-Object System.Collections.Generic.List[string]
foreach ($f in $allFiles) {
    if ($binary -contains $f.Extension.ToLowerInvariant()) { continue }
    if ($f.Length -gt 5MB) { continue }
    $rel = Get-Rel $f.FullName
    $lines = $null
    try { $lines = [IO.File]::ReadAllLines($f.FullName) } catch { continue }
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line.Length -lt 4) { continue }
        foreach ($p in $personal) { if ($p.Rx.IsMatch($line)) { $bad.Add(("{0}:{1}  contains {2}" -f $rel, ($i + 1), $p.Name)); Write-Annotation error $f.FullName ($i + 1) ("personal data: " + $p.Name) } }
        if ($line.Contains('allow-secret-scan')) { continue }
        foreach ($s in $secrets) { if ($s.Rx.IsMatch($line)) { $bad.Add(("{0}:{1}  looks like a secret ({2})" -f $rel, ($i + 1), $s.Name)); Write-Annotation error $f.FullName ($i + 1) ("possible secret: " + $s.Name) } }
    }
}
if ($bad.Count) { Add-Result 'No personal data / secrets in the repository' 'FAIL' $bad.ToArray() } else { Add-Result ("No personal data / secrets ({0} text files scanned)" -f @($allFiles | Where-Object { $binary -notcontains $_.Extension.ToLowerInvariant() }).Count) 'PASS' }

# ---- 5. leftovers -----------------------------------------------------------------------------------------------------
$marker = [regex]::new('\b(' + 'TO' + 'DO|FIX' + 'ME)\b')
$conflict = [regex]::new('^(<{7}|>{7})( |$)')
$bad = New-Object System.Collections.Generic.List[string]
foreach ($f in (Select-Files @('.ps1', '.psm1', '.psd1', '.cs', '.md', '.html', '.css', '.js', '.mjs', '.cjs', '.json', '.yml', '.yaml', '.bat', '.cmd', '.toml'))) {
    $rel = Get-Rel $f.FullName
    if ($rel -like 'CHANGELOG.md') { continue }
    $lines = [IO.File]::ReadAllLines($f.FullName)
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($marker.IsMatch($lines[$i])) { $bad.Add(("{0}:{1}  unfinished-work marker" -f $rel, ($i + 1))); Write-Annotation error $f.FullName ($i + 1) 'unfinished-work marker left in the code' }
        if ($conflict.IsMatch($lines[$i])) { $bad.Add(("{0}:{1}  merge-conflict marker" -f $rel, ($i + 1))); Write-Annotation error $f.FullName ($i + 1) 'merge-conflict marker' }
    }
}
if ($bad.Count) { Add-Result 'No unfinished-work or merge-conflict markers' 'FAIL' $bad.ToArray() } else { Add-Result 'No unfinished-work or merge-conflict markers' 'PASS' }

# ---- 6. share.config.json ---------------------------------------------------------------------------------------------
$cfgPath = Join-Path $Root 'src\share.config.json'
if (-not (Test-Path -LiteralPath $cfgPath)) { Add-Result 'src\share.config.json' 'WARN' @('file not present (the opt-in report-sharing feature has not been added yet)') }
else {
    $problems = New-Object System.Collections.Generic.List[string]
    try {
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in 'endpoint', 'helperName', 'maxBytes') { if ($null -eq $cfg.PSObject.Properties[$k]) { $problems.Add("missing key '$k'") } }
        if ($null -ne $cfg.PSObject.Properties['maxBytes']) {
            $mb = $cfg.maxBytes
            if (-not (($mb -is [int] -or $mb -is [long]) -and $mb -gt 0)) { $problems.Add('maxBytes must be a positive integer') }
        }
        # an empty endpoint is allowed: the helper fills it in later
    }
    catch { $problems.Add('does not parse as JSON: ' + $_.Exception.Message) }
    if ($problems.Count) { Add-Result 'src\share.config.json' 'FAIL' $problems.ToArray() } else { Add-Result 'src\share.config.json parses and has endpoint / helperName / maxBytes' 'PASS' }
}

# ---- 7. version -------------------------------------------------------------------------------------------------------
$verFile = Join-Path $Root 'build\VERSION'
if (-not (Test-Path -LiteralPath $verFile)) { Add-Result 'build\VERSION' 'FAIL' @('missing') }
else {
    $v = ([IO.File]::ReadAllText($verFile)).Trim()
    if ($v -notmatch '^\d+\.\d+\.\d+$') { Add-Result 'build\VERSION' 'FAIL' @("not x.y.z: '$v'") }
    else {
        $cl = Join-Path $Root 'CHANGELOG.md'
        if ((Test-Path -LiteralPath $cl) -and -not ([IO.File]::ReadAllText($cl) -match ('(?m)^##\s*\[?v?' + [regex]::Escape($v) + '\b'))) { Add-Result "build\VERSION = $v" 'WARN' @("CHANGELOG.md has no '## [$v]' heading yet") }
        else { Add-Result "build\VERSION = $v is valid" 'PASS' }
    }
}

# ---- 7b. the RELEASE file has no environment-controlled behaviour -----------------------------------------------------
# It runs elevated, so no variable a normal program can set may steer it. The check builds the release variant and inspects it:
# no RAMDOC_ text, no -TestScript pass-through, only $env:SELF read by PowerShell, only the allowed %variables% in cmd.exe,
# and no RAMDOC_ name in the packed scripts other than the sharing secrets the window hands to its own child process.
$buildScript = Join-Path $Root 'build\Build-SingleFile.ps1'
$buildCommon = Join-Path $Root 'build\BuildCommon.ps1'
if (-not (Test-Path -LiteralPath $buildScript) -or -not (Test-Path -LiteralPath $buildCommon)) {
    Add-Result 'Release file has no environment hooks' 'SKIP' @('build\Build-SingleFile.ps1 is not part of this tree')
}
else {
    $tmpRel = Join-Path ([IO.Path]::GetTempPath()) ('ramdoc-gate-rel-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        . $buildCommon
        $relFile = Join-Path $tmpRel 'RAM-Doctor.bat'
        $null = & $buildScript -OutFile $relFile -NoChecksum 6>$null
        $bad = @(Get-ReleaseHygieneProblems -Path $relFile)
        foreach ($b in $bad) { Write-Annotation error $buildScript 1 ('release file: ' + $b) }
        if ($bad.Count) { Add-Result 'Release file has no environment hooks' 'FAIL' $bad } else { Add-Result 'Release file has no environment hooks (no RAMDOC_ / -TestScript pass-through, PowerShell reads only $env:SELF)' 'PASS' }
    }
    catch { Add-Result 'Release file has no environment hooks' 'FAIL' @('could not build / inspect the release file: ' + $_.Exception.Message) }
    finally { Remove-Item -LiteralPath $tmpRel -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- 7c. the release workflow builds the RELEASE variant and publishes only the two release files ----------------------
$wfDir = Join-Path $Root '.github\workflows'
$relYml = Join-Path $wfDir 'release.yml'
if (-not (Test-Path -LiteralPath $relYml)) { Add-Result 'Workflows keep the test build out of releases' 'SKIP' @('.github\workflows\release.yml is not part of this tree') }
else {
    $bad = New-Object System.Collections.Generic.List[string]
    $rt = [IO.File]::ReadAllText($relYml)
    if ($rt -match '(?i)dev-?hooks') { $bad.Add('release.yml mentions the test build (-DevHooks / devhooks): the release must be built without it') }
    if ($rt -notmatch 'Build-SingleFile\.ps1') { $bad.Add('release.yml does not build with build\Build-SingleFile.ps1') }
    foreach ($m in [regex]::Matches($rt, 'dist/[\w.\-/]+')) {
        if (@('dist/RAM-Doctor.bat', 'dist/SHA256SUMS.txt') -notcontains $m.Value) { $bad.Add("release.yml references $($m.Value): only dist/RAM-Doctor.bat and dist/SHA256SUMS.txt may be published") }
    }
    foreach ($wf in @(Get-ChildItem -LiteralPath $wfDir -File -Filter '*.yml')) {
        $w = [IO.File]::ReadAllText($wf.FullName)
        foreach ($blk in [regex]::Matches($w, '(?s)uses:\s*actions/upload-artifact@\S+(.*?)(?=\r?\n\s*-\s+(?:name|uses|run)\s*:|\z)')) {
            if ($blk.Groups[1].Value -match '(?i)dev-?hooks') { $bad.Add("$($wf.Name) uploads the test build as an artifact") }
        }
    }
    @($bad | Select-Object -Unique) | ForEach-Object { Write-Annotation error $relYml 1 $_ }
    if ($bad.Count) { Add-Result 'Workflows keep the test build out of releases' 'FAIL' @($bad | Select-Object -Unique) } else { Add-Result 'Workflows keep the test build out of releases (release.yml builds without -DevHooks and publishes only RAM-Doctor.bat + SHA256SUMS.txt)' 'PASS' }
}

# ---- 8. PSScriptAnalyzer ----------------------------------------------------------------------------------------------
if ($SkipAnalyzer) { Add-Result 'PSScriptAnalyzer' 'SKIP' @('-SkipAnalyzer') }
else {
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        if ($InstallMissing) {
            try { Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber -ErrorAction Stop } catch { Write-Host ('       could not install PSScriptAnalyzer: ' + $_.Exception.Message) }
        }
    }
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) { Add-Result 'PSScriptAnalyzer' 'SKIP' @('module not installed (use -InstallMissing, or: Install-Module PSScriptAnalyzer -Scope CurrentUser)') }
    else {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
        $found = New-Object System.Collections.Generic.List[object]
        foreach ($dir in 'src', 'build', 'tests') {
            $p = Join-Path $Root $dir
            if (Test-Path -LiteralPath $p) { foreach ($x in @(Invoke-ScriptAnalyzer -Path $p -Recurse -Settings $settings)) { $found.Add($x) } }
        }
        $errs = @($found | Where-Object { $_.Severity -eq 'Error' })
        $warns = @($found | Where-Object { $_.Severity -ne 'Error' })
        $fmt = { param($x) '{0}:{1}  {2}  {3}' -f (Get-Rel $x.ScriptName), $x.Line, $x.RuleName, ($x.Message -replace '\s+', ' ') }
        foreach ($x in $errs) { Write-Annotation error $x.ScriptName $x.Line ("$($x.RuleName): $($x.Message)") }
        foreach ($x in $warns) { Write-Annotation warning $x.ScriptName $x.Line ("$($x.RuleName): $($x.Message)") }
        if ($errs.Count -or ($FailOnWarning -and $warns.Count)) { Add-Result 'PSScriptAnalyzer' 'FAIL' @($errs + $warns | ForEach-Object { & $fmt $_ }) }
        elseif ($warns.Count) { Add-Result ("PSScriptAnalyzer: no errors, {0} warning(s)" -f $warns.Count) 'WARN' @($warns | ForEach-Object { & $fmt $_ }) }
        else { Add-Result 'PSScriptAnalyzer: clean' 'PASS' }
    }
}

# ---- 9. Pester --------------------------------------------------------------------------------------------------------
if ($SkipPester) { Add-Result 'Pester' 'SKIP' @('-SkipPester') }
elseif ($script:PesterProblem) { Add-Result 'Pester' 'FAIL' @($script:PesterProblem) }
else {
    $files = @(Get-ChildItem -LiteralPath (Join-Path $Root 'tests') -Recurse -Filter '*.Tests.ps1' -File | Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]gui[\\/]' } | Sort-Object FullName)
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = [string[]]($files | ForEach-Object { $_.FullName })
    $cfg.Run.PassThru = $true
    $cfg.Run.Exit = $false
    if ($ExcludeTag.Count -gt 0) { $cfg.Filter.ExcludeTag = [string[]]$ExcludeTag }
    $cfg.Output.Verbosity = 'Normal'
    $cfg.TestResult.Enabled = $true
    $cfg.TestResult.OutputFormat = 'NUnitXml'
    $cfg.TestResult.OutputPath = (Join-Path $ResultsDir 'pester.xml')
    Write-Host ("Pester {0}: {1} test file(s)" -f $script:PesterVersion, $files.Count)
    $res = Invoke-Pester -Configuration $cfg
    $det = @($res.Failed | ForEach-Object { $_.ExpandedPath + '  ->  ' + (($_.ErrorRecord | Select-Object -First 1).Exception.Message -replace '\s+', ' ') })
    foreach ($t in $res.Failed) { Write-Annotation error $t.ScriptBlock.File 1 ($t.ExpandedPath + ': ' + (($t.ErrorRecord | Select-Object -First 1).Exception.Message)) }
    if ($res.FailedCount -gt 0 -or $res.FailedContainersCount -gt 0) { Add-Result ("Pester: {0} passed, {1} failed" -f $res.PassedCount, $res.FailedCount) 'FAIL' $det }
    else { Add-Result ("Pester: {0} passed, {1} skipped" -f $res.PassedCount, $res.SkippedCount) 'PASS' }
}
# ---- summary ----------------------------------------------------------------------------------------------------------
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
$warned = @($script:Results | Where-Object { $_.Status -eq 'WARN' })
Write-Host ''
Write-Host ('{0} check(s): {1} failed, {2} with warnings' -f $script:Results.Count, $failed.Count, $warned.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })

if ($env:GITHUB_STEP_SUMMARY) {
    $md = New-Object System.Collections.Generic.List[string]
    $md.Add('### Repository checks'); $md.Add(''); $md.Add('| | Check |'); $md.Add('|---|---|')
    foreach ($r in $script:Results) { $icon = @{ PASS = ':white_check_mark:'; FAIL = ':x:'; WARN = ':warning:'; SKIP = ':fast_forward:' }[$r.Status]; $md.Add(("| {0} | {1} |" -f $icon, ($r.Name -replace '\|', '/'))) }
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n") -Encoding UTF8
}

if ($failed.Count) { exit 1 } else { exit 0 }
