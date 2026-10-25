#  RAM Doctor - crash-safe JSON files and an inter-process lock (src/lib/Store.ps1)
#
#  Dot-source this file. It defines functions only and changes nothing by itself.
#
#    Write-JsonAtomic -Path <file> -Object <obj> -Schema <n>
#        Writes <file> so that a crash, a power cut or a full disk can never leave a half-written file behind:
#        the JSON goes to <file>.tmp (created new, UTF-8 with BOM, flushed to the disk), then one rename installs it
#        and keeps the previous version as <file>.bak. Adds a "schema" field. Throws a clear error on failure; the
#        original file is then unchanged and no .tmp is left behind.
#
#    Read-JsonSafe -Path <file> -MaxSchema <n> [-Validate { param($data) ... $true }]
#        Never throws. Returns  Status = Ok | Missing | Recovered | Damaged | TooNew,  Data, Message
#        (plus Schema, Source = main|bak, DamagedFiles). A file that cannot be parsed is renamed to
#        <file>.damaged-<stamp> (never deleted) and the .bak copy is used instead (Status Recovered). Missing means that
#        no copy exists at all: while only damaged copies are left the status stays Damaged until the file is written
#        again. TooNew (a newer version wrote it) never falls back to the older .bak and never renames anything.
#        Files written by 1.0.x have no "schema" field: they are read as schema 1.
#
#    Write-TextAtomic -Path <file> -Text <text>
#        The same crash-safe write for a text file (no schema), e.g. the HTML report.
#
#    Use-StoreLock -Name <name> -Script { ... } [-TimeoutMs <ms>]
#        Runs the script block while holding a named mutex (Global\ namespace, Local\ when that is not possible).
#        Returns  Status = Ok (Value = the script's output) | Busy (the script did not run).
#        Enter-StoreLock / Exit-StoreLock are the same lock for scripts that hold it until they exit;
#        Get-StoreLockName -Prefix <p> -Path <folder> gives one lock name per folder.
#
#    New-StorePrivateDir -Parent <dir> -Prefix <p>   /   Remove-StorePrivateDir -Path <dir>
#        A fresh, randomly named folder that an elevated process can write in %TEMP% without a junction trap, and a
#        delete that never follows a link.
#
#  Files on disk (formats unchanged since 1.0.0 apart from the extra "schema" field):
#      <name>.json                   current version: UTF-8 with BOM, a JSON object with "schema": <n>
#      <name>.json.bak               the previous version
#      <name>.json.tmp               only while a write is in progress; readers ignore it, the next write replaces it
#      <name>.json.damaged-<stamp>   a file that could not be read, kept for inspection
#
#  Trust: these functions do not decide whether a FOLDER can be trusted. Code that runs elevated over a folder another
#  account can write keeps its own checks (store ACL, owner, junctions). At the file level the final step is always a
#  rename, so a link planted at the destination name is replaced, never written through, and the .tmp file is opened
#  with CreateNew, so it never follows a planted link either.

$script:StoreUtf8Bom = New-Object System.Text.UTF8Encoding($true)
$script:StoreUtf8Strict = New-Object System.Text.UTF8Encoding($false, $true)   # invalid bytes = damaged, never "repaired" silently
$script:StoreMaxBytes = 64MB
$script:StoreInv = [Globalization.CultureInfo]::InvariantCulture

function Get-StoreErrorText {
    # The innermost exception message of an error record or exception (.NET calls are wrapped by PowerShell).
    param($ErrorObject)
    $e = $ErrorObject
    if ($e -is [System.Management.Automation.ErrorRecord]) { $e = $e.Exception }
    while ($e -and $e.InnerException -and ($e -is [System.Management.Automation.MethodInvocationException] -or $e -is [System.Management.Automation.RuntimeException])) { $e = $e.InnerException }
    if (-not $e) { return 'unknown error' }
    return ($e.Message -replace '\s+', ' ').Trim()
}

function Get-StoreInnerException {
    param($ErrorObject)
    $e = $ErrorObject
    if ($e -is [System.Management.Automation.ErrorRecord]) { $e = $e.Exception }
    while ($e -and $e.InnerException -and ($e -is [System.Management.Automation.MethodInvocationException] -or $e -is [System.Management.Automation.RuntimeException])) { $e = $e.InnerException }
    return $e
}

function Remove-StoreTemp([string]$Path) {
    try { if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) } } catch { }
}

# Renames a damaged file to <Path>.damaged-<stamp>[-n]. Returns the new path, or '' (and the reason in $script:StoreLastError).
function Move-StoreDamaged([string]$Path) {
    $script:StoreLastError = ''
    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss', $script:StoreInv)
    for ($i = 0; $i -lt 50; $i++) {
        $dst = if ($i -eq 0) { "$Path.damaged-$stamp" } else { "$Path.damaged-$stamp-$i" }
        if ([IO.File]::Exists($dst) -or [IO.Directory]::Exists($dst)) { continue }
        try { [IO.File]::Move($Path, $dst); return $dst } catch { $script:StoreLastError = Get-StoreErrorText $_; return '' }
    }
    $script:StoreLastError = 'no free name for the damaged copy'
    return ''
}

# Copies set aside earlier by Move-StoreDamaged (main and .bak).
function Get-StoreDamagedCopies([string]$Path) {
    try {
        $dir = [IO.Path]::GetDirectoryName($Path); $leaf = [IO.Path]::GetFileName($Path)
        return @(@([IO.Directory]::GetFiles($dir, "$leaf.damaged-*")) + @([IO.Directory]::GetFiles($dir, "$leaf.bak.damaged-*")))
    }
    catch { return @() }
}

# Reads and checks ONE file. State = Ok | Missing | Damaged | TooNew. ContentBad = the bytes themselves are bad (as opposed
# to a file that is locked or not readable right now): only such a file is renamed aside.
function Read-StoreCandidate {
    param([string]$Path, [long]$MaxSchema, [scriptblock]$Validate)
    $c = [pscustomobject]@{ State = 'Missing'; Data = $null; Schema = 0; Reason = ''; ContentBad = $false }
    if ([IO.Directory]::Exists($Path)) { $c.State = 'Damaged'; $c.Reason = 'is a folder, not a file'; return $c }
    if (-not [IO.File]::Exists($Path)) { return $c }

    $bytes = $null; $err = ''
    for ($i = 0; $i -lt 3 -and $null -eq $bytes; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds (100 * $i) }     # an antivirus scan or a writer may hold it for a moment
        $fs = $null
        try {
            $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            if ($fs.Length -gt $script:StoreMaxBytes) { $err = "is larger than $($script:StoreMaxBytes / 1MB) MB"; break }
            $buf = New-Object byte[] ([int]$fs.Length)
            $off = 0
            while ($off -lt $buf.Length) { $n = $fs.Read($buf, $off, $buf.Length - $off); if ($n -le 0) { break }; $off += $n }
            if ($off -ne $buf.Length) { throw 'the file changed while it was being read' }
            $bytes = $buf
        }
        catch {
            $inner = Get-StoreInnerException $_
            if ($inner -is [IO.FileNotFoundException] -or $inner -is [IO.DirectoryNotFoundException]) { return $c }   # renamed away meanwhile
            $err = Get-StoreErrorText $_
        }
        finally { if ($fs) { $fs.Dispose() } }
    }
    if ($null -eq $bytes) { $c.State = 'Damaged'; $c.Reason = "could not be read ($err)"; return $c }

    $c.State = 'Damaged'; $c.ContentBad = $true
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
    $text = $null
    try { $text = $script:StoreUtf8Strict.GetString($bytes, $start, $bytes.Length - $start) } catch { $c.Reason = 'is not valid UTF-8'; return $c }
    if ($text.IndexOf([char]0) -ge 0) { $c.Reason = 'contains NUL bytes (typical after a crash or power loss)'; return $c }
    if ([string]::IsNullOrWhiteSpace($text)) { $c.Reason = 'is empty'; return $c }
    $obj = $null
    try { $obj = ConvertFrom-Json -InputObject $text -ErrorAction Stop } catch { $c.Reason = 'is not valid JSON (truncated?)'; return $c }
    if ($obj -isnot [System.Management.Automation.PSCustomObject]) { $c.Reason = 'does not contain a JSON object'; return $c }

    $schema = [long]1                                            # 1.0.x wrote no schema field
    $sp = $obj.PSObject.Properties['schema']
    if ($sp) {
        $v = $sp.Value
        if (($v -is [int] -or $v -is [long]) -and $v -ge 1) { $schema = [long]$v }
        else { $c.Reason = 'has a schema field that is not a positive whole number'; return $c }
    }
    $c.Schema = $schema
    if ($schema -gt $MaxSchema) {
        $c.State = 'TooNew'; $c.ContentBad = $false
        $c.Reason = "was written by a newer version of RAM Doctor (schema $schema; this version reads up to $MaxSchema)"
        return $c
    }
    if ($Validate) {
        $ok = $false; $why = ''
        try { $ok = [bool](@(& $Validate $obj) | Select-Object -Last 1) } catch { $why = Get-StoreErrorText $_ }
        if (-not $ok) { $c.Reason = 'failed the content check' + $(if ($why) { ": $why" } else { '' }); return $c }
    }
    $c.State = 'Ok'; $c.ContentBad = $false; $c.Data = $obj
    return $c
}

function ConvertTo-StoreDocument {
    param($Object, [int]$Schema)
    $doc = [ordered]@{ schema = $Schema }
    if ($Object -is [Collections.IDictionary]) {
        foreach ($k in @($Object.Keys)) { if ([string]$k -ne 'schema') { $doc[[string]$k] = $Object[$k] } }
    }
    elseif ($Object -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Object.PSObject.Properties) { if ($p.Name -ne 'schema') { $doc[$p.Name] = $p.Value } }
    }
    else { throw 'Write-JsonAtomic: -Object must be a hashtable, an ordered dictionary or a PSCustomObject.' }
    return $doc
}

function Write-JsonAtomic {
    <# Writes -Object as JSON to -Path atomically (see the top of this file). Throws on failure; the old file stays intact. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][ValidateRange(1, 1000000)][int]$Schema,
        [ValidateRange(2, 99)][int]$Depth = 12
    )
    try { $full = [IO.Path]::GetFullPath($Path) } catch { throw "Write-JsonAtomic: invalid path '$Path': $(Get-StoreErrorText $_)" }
    $dir = [IO.Path]::GetDirectoryName($full)
    if (-not $dir -or -not [IO.Directory]::Exists($dir)) { throw "Write-JsonAtomic: the folder of '$full' does not exist." }
    if ([IO.Directory]::Exists($full)) { throw "Write-JsonAtomic: '$full' is a folder." }

    $doc = ConvertTo-StoreDocument -Object $Object -Schema $Schema
    $json = ConvertTo-Json -InputObject $doc -Depth $Depth
    # Windows PowerShell 5.1 silently turns anything nested deeper than -Depth into a type name. One level more must not
    # change the text, otherwise data would be lost.
    if ((ConvertTo-Json -InputObject $doc -Depth ($Depth + 1)) -cne $json) { throw "Write-JsonAtomic: the data for '$full' is nested deeper than -Depth $Depth; nothing was written." }

    # The current file decides how it may be replaced: never over a newer version, never push a damaged file onto the
    # good backup copy.
    $current = Read-StoreCandidate -Path $full -MaxSchema ([long]::MaxValue) -Validate $null
    if ($current.State -eq 'Ok' -and $current.Schema -gt $Schema) { throw "Write-JsonAtomic: '$full' was written by a newer version (schema $($current.Schema) > $Schema); it was not overwritten." }
    if ($current.State -eq 'Damaged' -and $current.ContentBad) {
        if (-not (Move-StoreDamaged $full)) { throw "Write-JsonAtomic: '$full' is damaged and could not be set aside ($script:StoreLastError); nothing was written." }
    }

    Install-StoreText -Path $full -Text $json -Who 'Write-JsonAtomic'
}

function Write-TextAtomic {
    <# Writes -Text (UTF-8 with BOM) to -Path the same crash-safe way as Write-JsonAtomic (.tmp, flush, one rename,
       previous version kept as .bak). No schema, no parsing: for reports and other text files. Throws on failure. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    try { $full = [IO.Path]::GetFullPath($Path) } catch { throw "Write-TextAtomic: invalid path '$Path': $(Get-StoreErrorText $_)" }
    $dir = [IO.Path]::GetDirectoryName($full)
    if (-not $dir -or -not [IO.Directory]::Exists($dir)) { throw "Write-TextAtomic: the folder of '$full' does not exist." }
    if ([IO.Directory]::Exists($full)) { throw "Write-TextAtomic: '$full' is a folder." }
    Install-StoreText -Path $full -Text $Text -Who 'Write-TextAtomic'
}

# Writes <Path>.tmp (CreateNew, UTF-8 with BOM, flushed) and installs it with one rename. Throws "<Who>: ..." on failure,
# after removing the .tmp; the previous version is then unchanged.
function Install-StoreText {
    param([string]$Path, [string]$Text, [string]$Who)
    $full = $Path
    $tmp = $full + '.tmp'
    $bak = $full + '.bak'
    # 1. the new content goes to <file>.tmp, created new (a leftover of a crashed write is removed first) and flushed
    if ([IO.File]::Exists($tmp)) {
        try { [IO.File]::Delete($tmp) } catch { throw "${Who}: a leftover '$tmp' could not be removed: $(Get-StoreErrorText $_)" }
    }
    $fs = $null
    try {
        $fs = [IO.FileStream]::new($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $pre = $script:StoreUtf8Bom.GetPreamble()
        $body = $script:StoreUtf8Bom.GetBytes($Text)
        $fs.Write($pre, 0, $pre.Length)
        $fs.Write($body, 0, $body.Length)
        $fs.Flush($true)                                         # through the OS cache onto the disk
        $fs.Dispose(); $fs = $null
    }
    catch {
        $why = Get-StoreErrorText $_
        if ($fs) { try { $fs.Dispose() } catch { } }
        Remove-StoreTemp $tmp
        throw "${Who}: could not write '$full' ($why); the previous version is unchanged."
    }

    # 2. one rename installs it: Replace keeps the previous version as .bak; a new file is simply moved into place
    $installed = $false; $why = ''
    for ($i = 0; $i -lt 4 -and -not $installed; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds (150 * $i) }   # a reader or an antivirus scan may hold the file briefly
        try {
            if ([IO.File]::Exists($full)) { [IO.File]::Replace($tmp, $full, $bak, $true) } else { [IO.File]::Move($tmp, $full) }
            $installed = $true
        }
        catch { $why = Get-StoreErrorText $_ }
    }
    if (-not $installed) {
        # Fallback for file systems without ReplaceFile: renames only (never a copy that could write through a planted link).
        $movedAside = $false
        try {
            if ([IO.File]::Exists($full)) {
                if ([IO.File]::Exists($bak)) { [IO.File]::Delete($bak) }
                [IO.File]::Move($full, $bak); $movedAside = $true
            }
            [IO.File]::Move($tmp, $full)
            $installed = $true
        }
        catch {
            $why = $why + ' / ' + (Get-StoreErrorText $_)
            if ($movedAside -and -not [IO.File]::Exists($full)) { try { [IO.File]::Move($bak, $full) } catch { } }
        }
    }
    if (-not $installed) {
        Remove-StoreTemp $tmp
        throw "${Who}: could not replace '$full' ($why); the previous version is unchanged."
    }
}

function Read-JsonSafe {
    <# Reads a file written by Write-JsonAtomic (or by RAM Doctor 1.0.x). Never throws; see the top of this file. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateRange(1, 1000000)][int]$MaxSchema,
        [scriptblock]$Validate = $null
    )
    $res = [pscustomobject]@{ Status = 'Missing'; Data = $null; Message = ''; Schema = 0; Source = ''; DamagedFiles = @() }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $name = [IO.Path]::GetFileName($full)
        $notes = New-Object System.Collections.Generic.List[string]
        $damaged = New-Object System.Collections.Generic.List[string]
        $setAside = {
            param($file, $label)
            $moved = Move-StoreDamaged $file
            if ($moved) { $damaged.Add($moved); $notes.Add("$label was kept as $([IO.Path]::GetFileName($moved))") }
            else { $notes.Add("$label could not be renamed aside ($script:StoreLastError)") }
        }

        $main = Read-StoreCandidate -Path $full -MaxSchema $MaxSchema -Validate $Validate
        if ($main.State -eq 'Ok') { $res.Status = 'Ok'; $res.Data = $main.Data; $res.Schema = $main.Schema; $res.Source = 'main'; return $res }
        if ($main.State -eq 'TooNew') { $res.Status = 'TooNew'; $res.Schema = $main.Schema; $res.Message = "$name $($main.Reason)."; return $res }
        if ($main.State -eq 'Damaged') {
            $notes.Add("$name $($main.Reason)")
            if ($main.ContentBad) { & $setAside $full $name }
        }

        $bakPath = $full + '.bak'
        $bak = Read-StoreCandidate -Path $bakPath -MaxSchema $MaxSchema -Validate $Validate
        if ($bak.State -eq 'Ok') {
            $res.Status = 'Recovered'; $res.Data = $bak.Data; $res.Schema = $bak.Schema; $res.Source = 'bak'
            if ($main.State -eq 'Missing') { $notes.Add("$name is missing") }
            $notes.Add('the backup copy (.bak) was used; the most recent change may be missing')
        }
        elseif ($bak.State -eq 'TooNew') {
            $res.Status = 'TooNew'; $res.Schema = $bak.Schema
            $notes.Add("the backup copy $($bak.Reason)")
        }
        elseif ($bak.State -eq 'Damaged') {
            $res.Status = 'Damaged'
            $notes.Add("the backup copy $($bak.Reason)")
            if ($bak.ContentBad) { & $setAside $bakPath "$name.bak" }
        }
        elseif ($main.State -eq 'Missing') {
            # Damage stays visible: once both copies were set aside the file is "Damaged", not "Missing", until it is
            # written again (otherwise a damaged profile would silently turn into a brand-new one on the next start).
            $left = @(Get-StoreDamagedCopies $full)
            if ($left.Count -eq 0) { $res.Status = 'Missing'; $res.Message = "$name does not exist."; return $res }
            $res.Status = 'Damaged'
            foreach ($f in $left) { $damaged.Add($f) }
            $notes.Add("$name is missing and only damaged copies are left (" + (($left | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ', ') + ')')
        }
        else {
            $res.Status = 'Damaged'
            $notes.Add('there is no backup copy')
        }
        $res.DamagedFiles = $damaged.ToArray()
        $res.Message = ($notes -join '; ') + '.'
        return $res
    }
    catch {
        $res.Status = 'Damaged'; $res.Data = $null
        $res.Message = "could not read '$Path': $(Get-StoreErrorText $_)"
        return $res
    }
}

function Test-StoreElevated {
    try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}


# A lock name for a folder: <prefix>-<16 hex of the SHA-256 of its full, lower-case path> (mutex names allow no "\").
function Get-StoreLockName {
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$Path)
    $full = $Path
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full.ToLowerInvariant())) } finally { $sha.Dispose() }
    return $Prefix + '-' + ((@($h[0..7]) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Enter-StoreLock {
    <# Takes the machine-wide mutex RAM-Doctor-<Name> and returns a handle for Exit-StoreLock:
         Status = 'Ok'   held (or Guarded = $false: no trustworthy lock could be had at all, see below); Scope = Global | Local
         Status = 'Busy' another process holds it (waited -TimeoutMs); nothing is held
       Any program can create a mutex name. When elevated, a lock whose owner is not SYSTEM / Administrators was made by a
       non-elevated program (for example malware squatting the name to block quarantine): it is ignored (Global, then
       Local) and at worst the caller runs without a lock (Guarded = $false) instead of waiting forever.
       -TrustedOwners replaces that owner list (an empty list = accept any owner, the default when not elevated).
       The lock belongs to the thread: the same thread can take it again, so a WinForms DoEvents loop still needs its
       own busy flag. A process that ends without Exit-StoreLock releases it implicitly (the next holder sees Abandoned). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateRange(0, 600000)][int]$TimeoutMs = 3000,
        [string[]]$TrustedOwners = @()
    )
    $trusted = @($TrustedOwners)
    if (-not $PSBoundParameters.ContainsKey('TrustedOwners')) { $trusted = if (Test-StoreElevated) { @('S-1-5-18', 'S-1-5-32-544') } else { @() } }
    $leaf = 'RAM-Doctor-' + ($Name -replace '[^A-Za-z0-9._-]', '_')
    if ($leaf.Length -gt 200) { $leaf = $leaf.Substring(0, 200) }
    $h = [pscustomobject]@{ Status = 'Ok'; Name = $Name; Mutex = $null; Scope = ''; Guarded = $true; Abandoned = $false; Message = '' }
    $notes = New-Object System.Collections.Generic.List[string]

    foreach ($ns in @('Global', 'Local')) {
        $m = $null; $created = $false
        try { $m = [Threading.Mutex]::new($false, "$ns\$leaf", [ref]$created) }
        catch {
            if ((Get-StoreInnerException $_) -is [UnauthorizedAccessException] -and $trusted.Count -eq 0) {
                # it exists and this process may not open it: held by a RAM Doctor process that runs with other rights
                $h.Status = 'Busy'; $h.Scope = $ns; $h.Message = "lock '$Name' is held by another process (access denied)"
                return $h
            }
            $notes.Add("$ns lock unavailable: $(Get-StoreErrorText $_)"); continue
        }
        if ($trusted.Count -gt 0 -and -not $created) {
            $owner = ''
            try { $owner = $m.GetAccessControl().GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { }
            if ($trusted -notcontains $owner) { $notes.Add("$ns lock ignored: it was created by an untrusted owner ($owner)"); $m.Dispose(); continue }
        }
        $h.Mutex = $m; $h.Scope = $ns; break
    }
    if (-not $h.Mutex) { $h.Guarded = $false; $h.Message = ($notes -join '; '); return $h }

    $acquired = $false
    try { $acquired = $h.Mutex.WaitOne($TimeoutMs) }
    catch {
        if ((Get-StoreInnerException $_) -is [Threading.AbandonedMutexException]) { $acquired = $true; $h.Abandoned = $true; $notes.Add('the previous holder ended without releasing the lock') }
        else { $h.Mutex.Dispose(); throw }
    }
    if (-not $acquired) {
        $h.Mutex.Dispose(); $h.Mutex = $null
        $h.Status = 'Busy'; $h.Message = "lock '$Name' is held by another process (waited $TimeoutMs ms)"
        return $h
    }
    $h.Message = ($notes -join '; ')
    return $h
}

function Exit-StoreLock {
    <# Releases a handle from Enter-StoreLock (safe to call twice, or with a Busy / unguarded handle). #>
    param($Handle)
    if (-not $Handle -or -not $Handle.Mutex) { return }
    try { $Handle.Mutex.ReleaseMutex() } catch { }
    try { $Handle.Mutex.Dispose() } catch { }
    $Handle.Mutex = $null
}

function Use-StoreLock {
    <# Runs -Script while holding the lock RAM-Doctor-<Name> (Enter-StoreLock / Exit-StoreLock). Returns a result object:
         Status = 'Ok'   the script ran; Value = its output; Scope, Guarded, Abandoned as from Enter-StoreLock
         Status = 'Busy' another process holds the lock (waited -TimeoutMs); the script did NOT run
       Exceptions thrown by the script propagate after the lock is released.
       The script block sees the caller's variables (this function only uses lk* names). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script,
        [ValidateRange(0, 600000)][int]$TimeoutMs = 3000,
        [string[]]$TrustedOwners = @()
    )
    # The script block runs in this function's dynamic scope and would see its variables in place of the caller's ones
    # with the same name: keep the parameters under lk* names and drop the originals before it runs.
    $lkScript = $Script
    $lkArgs = @{ Name = $Name; TimeoutMs = $TimeoutMs }
    if ($PSBoundParameters.ContainsKey('TrustedOwners')) { $lkArgs['TrustedOwners'] = @($TrustedOwners) }
    Remove-Variable -Name Name, Script, TimeoutMs, TrustedOwners -Scope Local -Force -ErrorAction SilentlyContinue

    $lkHandle = Enter-StoreLock @lkArgs
    $lkRes = [pscustomobject]@{ Status = $lkHandle.Status; Value = $null; Message = $lkHandle.Message; Scope = $lkHandle.Scope; Guarded = $lkHandle.Guarded; Abandoned = $lkHandle.Abandoned }
    if ($lkHandle.Status -eq 'Busy') { return $lkRes }
    try { $lkRes.Value = & $lkScript }
    finally { Exit-StoreLock $lkHandle }
    return $lkRes
}

# ------------------------------------------------------------------------------------------ private temp folders
# A folder for files that an ELEVATED process writes into a place the user can write to (%TEMP%): a fresh random name
# (nothing can be planted there in advance), created with its final permissions in one step when elevated (owner
# Administrators, inheritance off: SYSTEM and Administrators full control, the user read-only, so a program running
# without elevation can read the files - Explorer - but neither change them nor turn the folder into a link), and checked
# afterwards (a real folder, not a junction, trusted owner). Returns the path; throws when the folder cannot be trusted.
function New-StorePrivateDir {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Prefix)
    if (-not [IO.Directory]::Exists($Parent)) { [void][IO.Directory]::CreateDirectory($Parent) }
    $dir = Join-Path $Parent ($Prefix + [guid]::NewGuid().ToString('N'))
    if ([IO.Directory]::Exists($dir) -or [IO.File]::Exists($dir)) { throw "New-StorePrivateDir: '$dir' already exists." }
    if (Test-StoreElevated) {
        $sec = New-Object Security.AccessControl.DirectorySecurity
        $sec.SetAccessRuleProtection($true, $false)
        $inh = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
            $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), [Security.AccessControl.FileSystemRights]::FullControl, $inh, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
        }
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($me, [Security.AccessControl.FileSystemRights]::ReadAndExecute, $inh, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
        try { $sec.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544'))) } catch { }
        [void][IO.Directory]::CreateDirectory($dir, $sec)
        $di = New-Object IO.DirectoryInfo($dir)
        $owner = ''
        try { $owner = $di.GetAccessControl().GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { }
        if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -or @('S-1-5-18', 'S-1-5-32-544') -notcontains $owner) {
            throw "New-StorePrivateDir: '$dir' is not a private folder (owner $owner)."
        }
    }
    else {
        [void][IO.Directory]::CreateDirectory($dir)
        if ((New-Object IO.DirectoryInfo($dir)).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "New-StorePrivateDir: '$dir' is a link." }
    }
    return $dir
}

# Deletes a folder made by New-StorePrivateDir (or any flat folder of files) without ever following a link: only the
# files directly inside are removed, a junction is removed as a link and never entered. Returns $true when it is gone.
function Remove-StorePrivateDir {
    param([string]$Path)
    if (-not $Path) { return $true }
    try {
        if (-not [IO.Directory]::Exists($Path)) { return $true }
        $di = New-Object IO.DirectoryInfo($Path)
        if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($Path); return $true }
        foreach ($f in $di.GetFileSystemInfos()) {
            if ($f -is [IO.DirectoryInfo]) {
                if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($f.FullName) }
                continue                                         # an unexpected sub-folder is left alone (never recursed into)
            }
            try { $f.Attributes = [IO.FileAttributes]::Normal; $f.Delete() } catch { }
        }
        [IO.Directory]::Delete($Path)
        return $true
    }
    catch { return $false }
}
