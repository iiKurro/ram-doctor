# Shared helpers for build\Build-SingleFile.ps1 and build\Expand-SingleFile.ps1 (dot-source this file).
# ASCII only on purpose: it is read by Windows PowerShell 5.1 without a BOM.

# File types that are packed into the single-file edition. Anything else under src\ is ignored.
$script:PackExtensions = @('.ps1', '.cs', '.psd1', '.json')
# The window that is launched after unpacking; it is always packed first.
$script:PackEntry = 'src\RAM-Doctor-GUI.ps1'

# What the RELEASE file may read from the environment (see Get-ReleaseHygieneProblems).
# cmd.exe lines:   %SELF% (set by the file itself from %~f0), %SystemRoot% (to call tools by full path), %P1%..%P6%, %errorlevel%, %~f0, %~1
# PowerShell:      $env:SELF only
$script:AllowedCmdVariables = @('SELF', 'SystemRoot', 'P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'errorlevel')
$script:AllowedCmdModifiers = @('%~f0', '%~1')
$script:AllowedPsEnvironment = @('SELF')
# RAMDOC_* names that the PAYLOAD (the scripts under src\) legitimately uses: the window hands the sharing secrets to its own
# child process through the environment so they never sit on a command line. Anything else is a hook and fails the check.
$script:AllowedPayloadEnvNames = @('RAMDOC_SHARE_NAME', 'RAMDOC_SHARE_CODE')

function Get-PackFiles {
    <# Relative paths (backslash style, as written in the '#@@FILE' markers), entry first, rest in ordinal order. #>
    param([Parameter(Mandatory)][string]$Root)
    $srcDir = Join-Path $Root 'src'
    $rel = New-Object System.Collections.Generic.List[string]
    foreach ($f in (Get-ChildItem -LiteralPath $srcDir -Recurse -File)) {
        if ($script:PackExtensions -contains $f.Extension.ToLowerInvariant()) {
            $rel.Add($f.FullName.Substring($Root.TrimEnd('\').Length + 1))
        }
    }
    $rest = New-Object 'System.Collections.Generic.List[string]'
    foreach ($r in $rel) { if ($r -ne $script:PackEntry) { $rest.Add($r) } }
    $arr = $rest.ToArray()
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    if ($rel -notcontains $script:PackEntry) { throw "Entry script not found: $script:PackEntry" }
    return @($script:PackEntry) + $arr
}

function Get-PackText {
    <# Source text exactly as embedded: BOM stripped, CRLF line endings, always ends with CRLF. #>
    param([Parameter(Mandatory)][string]$Path)
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $text = $text -replace "`r?`n", "`r`n"
    if (-not $text.EndsWith("`r`n")) { $text += "`r`n" }
    return $text
}

function Get-ExpectedUnpackedBytes {
    <# What the unpacker must produce for a source file: UTF-8 BOM + normalized text. #>
    param([Parameter(Mandatory)][string]$Path)
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    return ($utf8.GetPreamble() + $utf8.GetBytes((Get-PackText -Path $Path)))
}

function Split-SingleFile {
    <# Header (what cmd.exe executes) and payload (the '#@@FILE' sections) of a built RAM-Doctor.bat.
       The first marker is searched at the START of a line: the unpacker's own regex contains the text "#@@FILE " too. #>
    param([Parameter(Mandatory)][string]$Path)
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $m = [regex]::Match($text, '(?m)^#@@FILE ')
    if (-not $m.Success) { throw "No payload found in $Path" }
    return [pscustomobject]@{ Header = $text.Substring(0, $m.Index); Payload = $text.Substring($m.Index) }
}

function Get-ReleaseHygieneProblems {
    <# The RELEASE build must contain no behaviour that an environment variable can steer.
       Returns a list of problems (empty = clean):
         * header: no RAMDOC_ text at all, no test banner, no -TestScript / GUI_ARGS / UNPACK_ONLY / NOELEVATE, no 'if defined',
                   PowerShell reads only $env:SELF, cmd.exe expands only the variables in $script:AllowedCmdVariables
         * payload: RAMDOC_* names only from $script:AllowedPayloadEnvNames (a new hook in src\ would be caught here) #>
    param([Parameter(Mandatory)][string]$Path)
    $parts = Split-SingleFile -Path $Path
    $h = $parts.Header
    $problems = New-Object System.Collections.Generic.List[string]
    if ($h -match '(?i)RAMDOC_') { $problems.Add('the header mentions RAMDOC_ (an environment hook)') }
    foreach ($word in 'TestScript', 'GUI_ARGS', 'UNPACK_ONLY', 'NOELEVATE', 'DevHooks', 'TEST BUILD') {
        if ($h -match ('(?i)' + [regex]::Escape($word))) { $problems.Add("the header contains '$word' (test-only build material)") }
    }
    if ($h -match '(?im)^\s*if\s+(not\s+)?defined\b') { $problems.Add("the header branches on 'if defined' (an environment check)") }
    if ($h -match '(?i)GetEnvironmentVariable|ExpandEnvironmentVariables|Get-(Item|ChildItem)\s+env:|\bgci\s+env:|\[Environment\]::GetEnvironmentVariables') {
        $problems.Add('the header reads the environment through an API')
    }
    foreach ($m in [regex]::Matches($h, '\$env:([A-Za-z_][A-Za-z0-9_]*)')) {
        if ($script:AllowedPsEnvironment -notcontains $m.Groups[1].Value) { $problems.Add("PowerShell reads `$env:$($m.Groups[1].Value) (only `$env:SELF is allowed)") }
    }
    # cmd.exe expansion: ignore 'rem' comment lines, look at the executed lines only
    $executed = (($h -split "`r?`n") | Where-Object { $_ -notmatch '^\s*rem(\s|$)' }) -join "`n"
    foreach ($m in [regex]::Matches($executed, '%([A-Za-z0-9_]+)%')) {
        if ($script:AllowedCmdVariables -notcontains $m.Groups[1].Value) { $problems.Add("cmd.exe expands %$($m.Groups[1].Value)% (allowed: $($script:AllowedCmdVariables -join ', '))") }
    }
    foreach ($m in [regex]::Matches($executed, '%~[A-Za-z0-9]+')) {
        if ($script:AllowedCmdModifiers -notcontains $m.Value) { $problems.Add("cmd.exe uses $($m.Value) (allowed: $($script:AllowedCmdModifiers -join ', '))") }
    }
    foreach ($m in [regex]::Matches($parts.Payload, 'RAMDOC_[A-Za-z0-9_]+')) {
        if ($script:AllowedPayloadEnvNames -notcontains $m.Value) { $problems.Add("the packed scripts use $($m.Value), which is not on the list of allowed names") }
    }
    return @($problems | Select-Object -Unique)
}
