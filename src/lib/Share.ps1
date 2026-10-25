# RAM Doctor - "share my report with my helper" client library.
#
# Opt-in only: nothing in this file runs unless the user presses the share button. The scan itself never
# touches the network. This file only defines functions (no side effects when dot-sourced).
#
# Flow:  profile (chosen name, fixed userId, DPAPI-protected invite code)
#        -> bundle (summary.md + report.html + plan.json, all redacted)
#        -> POST {endpoint}/v1/reports   (protocol v1, answered by the relay; the GitHub token lives ONLY in the relay)
#   The profile is just a chosen name + a random fixed userId; the invite code is OPTIONAL (sent only if stored).
#   share.config.json ships with an empty endpoint, so uploading stays dormant until the helper configures a relay.
#   Also offline: New-ShareShortSummary (short redacted text for pasting into a chat app, no profile, no network).
#
# Windows PowerShell 5.1. Keep this file UTF-8 with BOM (the user-facing texts, Arabic and English, live in lib\Strings.ps1).

if (-not (Get-Command Get-Text -CommandType Function -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'Strings.ps1') }
if (-not (Get-Command Read-JsonSafe -CommandType Function -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'Store.ps1') }   # crash-safe profile file

$script:ShareToolVersion = '1.1.1'
$script:ShareReservedUserNames = @('public', 'default', 'default user', 'all users', 'defaultuser0', 'desktop.ini')
# account names that are ordinary words: a whole-word search for them would damage the prose, so only the
# C:\Users\<name> form is masked for these.
$script:ShareGenericNames = @('user', 'users', 'admin', 'administrator', 'public', 'default', 'guest', 'system', 'test', 'owner', 'root', 'windows', 'home', 'local')

# ---------------------------------------------------------------- messages (shown to the user; the texts are in lib\Strings.ps1)
# The language is the current UI language (Set-UiLang), or -Lang for one lookup. An unknown key comes back unchanged.
function Get-ShareMessage {
    param([Parameter(Mandatory)][string]$Key, [string]$Lang = '')
    $k = 'share.msg.' + $Key
    if (Test-TextKey $k -Lang $Lang) { return (Get-Text $k -Lang $Lang) }
    return $Key
}

# Language of the texts written FOR a plan: -Lang when given, else the language the scan wrote the plan in,
# else Arabic (a plan without "lang" comes from the Arabic-only releases).
function Resolve-ShareLang {
    param($Plan, [string]$Lang = '')
    if ($Lang) { return (Resolve-UiLang $Lang) }
    if ($Plan -and $Plan.PSObject.Properties['lang'] -and $Plan.lang) { return (Resolve-UiLang ([string]$Plan.lang)) }
    return 'ar'
}

# ---------------------------------------------------------------- config
function Get-ShareConfig {
    [CmdletBinding()]
    param([string]$Path)
    $cfg = [pscustomobject]@{ endpoint = ''; helperName = '7san'; maxBytes = 2000000 }
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.endpoint) { $cfg.endpoint = ([string]$j.endpoint).Trim() }
            if ($j.helperName) { $cfg.helperName = [string]$j.helperName }
            if ($j.maxBytes -and ([int64]$j.maxBytes) -gt 0) { $cfg.maxBytes = [int64]$j.maxBytes }
        } catch { }
    }
    return $cfg
}

# Returns $null when the endpoint is acceptable, otherwise the message key. https only - plain http is allowed
# for loopback addresses so the local test relay works.
function Test-ShareEndpoint {
    [CmdletBinding()]
    param([string]$Endpoint)
    if ([string]::IsNullOrWhiteSpace($Endpoint)) { return 'not-configured' }
    $uri = $null
    if (-not [Uri]::TryCreate($Endpoint.Trim(), [UriKind]::Absolute, [ref]$uri)) { return 'insecure-endpoint' }
    if ($uri.Scheme -eq 'https') { return $null }
    if ($uri.Scheme -eq 'http' -and ($uri.IsLoopback)) { return $null }
    return 'insecure-endpoint'
}

# ---------------------------------------------------------------- user name rules
# 2-24 chars: Arabic or Latin letters, digits, space, '_' or '-'.  The relay applies the same rule.
function Test-ShareUsername {
    [CmdletBinding()]
    param([string]$Name)
    $n = if ($null -eq $Name) { '' } else { ($Name -replace '\s+', ' ').Trim() }
    if ($n.Length -lt 2 -or $n.Length -gt 24) { return [pscustomobject]@{ Ok = $false; Name = $n; Error = (Get-ShareMessage 'name-length') } }
    if ($n -notmatch '^[A-Za-z0-9\u0600-\u06FF _-]+$' -or $n -notmatch '[A-Za-z0-9\u0600-\u06FF]') {
        return [pscustomobject]@{ Ok = $false; Name = $n; Error = (Get-ShareMessage 'name-chars') }
    }
    return [pscustomobject]@{ Ok = $true; Name = $n; Error = '' }
}

# Folder slug used by the relay: lower-case, every run of characters outside [a-z0-9 Arabic] becomes one '-'.
function ConvertTo-ShareSlug {
    [CmdletBinding()]
    param([string]$Name)
    $s = ([string]$Name).ToLowerInvariant() -replace '[^a-z0-9\u0600-\u06ff]+', '-'
    $s = $s.Trim('-')
    if (-not $s) { $s = 'user' }
    return $s
}

function Test-ShareInviteCode {
    [CmdletBinding()]
    param([string]$Code)
    return ($Code -match '^\S{4,128}$')
}

# ---------------------------------------------------------------- profile (%APPDATA%\RAM-Doctor\profile.json)
function Get-ShareDefaultProfileDir { Join-Path $env:APPDATA 'RAM-Doctor' }

# The profile file is written crash-safe (profile.json.tmp + rename, previous version profile.json.bak) and read with
# Read-JsonSafe: Status Ok | Recovered (the .bak was used) | Missing | Damaged (set aside as profile.json.damaged-<stamp>,
# never deleted) | TooNew. A damaged profile is NOT the same as no profile: the window says so, and a new profile keeps
# the old userId when it can be read from the damaged copy, so the helper still sees one person.
function Get-ShareProfileState {
    [CmdletBinding()]
    param([string]$ProfileDir)
    if (-not $ProfileDir) { $ProfileDir = Get-ShareDefaultProfileDir }
    $r = Read-JsonSafe -Path (Join-Path $ProfileDir 'profile.json') -MaxSchema 1 -Validate {
        param($j) ([string]$j.displayName).Trim().Length -ge 1 -and ([string]$j.userId) -match '^[0-9a-f]{8}$'
    }
    $prof = $null
    if ($r.Status -eq 'Ok' -or $r.Status -eq 'Recovered') {
        $j = $r.Data
        $prof = [pscustomobject]@{ displayName = [string]$j.displayName; userId = [string]$j.userId; createdAt = [string]$j.createdAt; codeProtected = [string]$j.code }
    }
    return [pscustomobject]@{ Status = $r.Status; Profile = $prof; Message = $r.Message; DamagedFiles = @($r.DamagedFiles) }
}

function Get-ShareProfile {
    [CmdletBinding()]
    param([string]$ProfileDir)
    return (Get-ShareProfileState -ProfileDir $ProfileDir).Profile
}

# Decrypts the invite code (DPAPI, current Windows user only). Returns $null if it cannot be read.
function Get-ShareInviteCode {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'A parameter named Profile only shadows the profile-path variable inside this function.')]
    [CmdletBinding()]
    param($Profile)
    if (-not $Profile -or -not $Profile.codeProtected) { return $null }
    try {
        $sec = ConvertTo-SecureString -String $Profile.codeProtected -ErrorAction Stop
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { return $null }
}

function New-ShareUserId {
    $b = New-Object byte[] 4
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Creates the profile, or (same name) refreshes the invite code. The name and userId never change afterwards.
function Save-ShareProfile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The optional invite code arrives as text from the user and is immediately encrypted with DPAPI (current user); it is never stored in clear.')]
    [CmdletBinding()]
    param([string]$Username, [string]$Code, [string]$ProfileDir)
    if (-not $ProfileDir) { $ProfileDir = Get-ShareDefaultProfileDir }
    $v = Test-ShareUsername $Username
    if (-not $v.Ok) { return [pscustomobject]@{ Ok = $false; Error = $v.Error; Profile = $null } }
    # the invite code is OPTIONAL (only needed if the helper's relay enforces one)
    if ($Code -and -not (Test-ShareInviteCode $Code)) { return [pscustomobject]@{ Ok = $false; Error = (Get-ShareMessage 'code-invalid'); Profile = $null } }
    $state = Get-ShareProfileState -ProfileDir $ProfileDir
    # written by a newer version, or held by another program right now (its content is unknown): never overwritten
    if ($state.Status -eq 'TooNew' -or $state.Status -eq 'Unreadable') { return [pscustomobject]@{ Ok = $false; Error = (Get-ShareMessage 'profile-write'); Profile = $null } }
    $existing = $state.Profile
    $userId = $null; $created = $null; $prot = ''
    if ($existing) {
        if ($existing.displayName -ne $v.Name) { return [pscustomobject]@{ Ok = $false; Error = (Get-ShareMessage 'name-fixed'); Profile = $existing } }
        $userId = $existing.userId; $created = $existing.createdAt; $prot = $existing.codeProtected   # saving again without a code keeps the stored one
    } else {
        # a damaged profile that was set aside still carries the userId most of the time: keep it
        foreach ($f in @($state.DamagedFiles)) {
            try { $m = [regex]::Match([IO.File]::ReadAllText($f), '"userId"\s*:\s*"([0-9a-f]{8})"'); if ($m.Success) { $userId = $m.Groups[1].Value; break } } catch { }
        }
        if (-not $userId) { $userId = New-ShareUserId }
        $created = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    }
    try {
        if ($Code) {
            $sec = ConvertTo-SecureString -String $Code -AsPlainText -Force
            $prot = ConvertFrom-SecureString -SecureString $sec
        }
        New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null
        $obj = [ordered]@{ v = 1; displayName = $v.Name; userId = $userId; createdAt = $created; code = $prot }
        Write-JsonAtomic -Path (Join-Path $ProfileDir 'profile.json') -Object $obj -Schema 1
    } catch { return [pscustomobject]@{ Ok = $false; Error = (Get-ShareMessage 'profile-write'); Profile = $null } }
    return [pscustomobject]@{ Ok = $true; Error = ''; Profile = (Get-ShareProfile -ProfileDir $ProfileDir) }
}

function Remove-ShareProfile {
    [CmdletBinding()]
    param([string]$ProfileDir)
    if (-not $ProfileDir) { $ProfileDir = Get-ShareDefaultProfileDir }
    # the user asked for their profile to go: the current file, its backup and any damaged copies set aside earlier
    foreach ($f in @(Get-ChildItem -LiteralPath $ProfileDir -Filter 'profile.json*' -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -match '^profile\.json(\.bak|\.tmp|(\.bak)?\.damaged-[\d-]+)?$') { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------- redaction
# Every account name that appears as ...\Users\<name>\... in the given texts (reserved folders excluded).
function Find-ShareUserNames {
    [CmdletBinding()]
    param([string[]]$Texts)
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($t in $Texts) {
        if ([string]::IsNullOrEmpty($t)) { continue }
        foreach ($m in [regex]::Matches($t, '(?i)(?<=[\\/])Users(?:\\\\|\\|/)+([^\\/\r\n"''<>|:*?&]+)')) {
            $n = $m.Groups[1].Value.Trim()
            if ($n -and -not $n.StartsWith('<') -and ($script:ShareReservedUserNames -notcontains $n.ToLowerInvariant())) { $found.Add($n) }
        }
    }
    return @($found | Select-Object -Unique)
}

# Builds the rule list once (compiled regexes) so large reports are redacted quickly.
# -UserNames / -ComputerName / -ExtraComputerNames inject names; -DiscoverFrom adds every name found under
# \Users\ in those texts; -NoAutoDetect skips reading this PC's real names (tests).
function New-ShareRedactor {
    [CmdletBinding()]
    param([string[]]$UserNames = @(), [string]$ComputerName = '', [string[]]$ExtraComputerNames = @(), [string[]]$DiscoverFrom = @(), [switch]$IncludeHostName, [switch]$NoAutoDetect)

    $ro = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Compiled
    $rules = New-Object System.Collections.ArrayList
    $add = { param($pattern, $replacement) [void]$rules.Add([pscustomobject]@{ Regex = (New-Object System.Text.RegularExpressions.Regex($pattern, $ro)); Replacement = $replacement; Evaluator = $null }) }
    $addEval = { param($pattern, [scriptblock]$eval) [void]$rules.Add([pscustomobject]@{ Regex = (New-Object System.Text.RegularExpressions.Regex($pattern, $ro)); Replacement = $null; Evaluator = [System.Text.RegularExpressions.MatchEvaluator]$eval }) }

    # names to hide: injected + (auto) this PC's account / profile folders / domain
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($n in $UserNames) { if ($n) { $names.Add($n.Trim()) } }
    foreach ($n in (Find-ShareUserNames -Texts $DiscoverFrom)) { $names.Add($n) }
    $compNames = New-Object System.Collections.Generic.List[string]
    if ($ComputerName) { $compNames.Add($ComputerName.Trim()) }
    foreach ($c in $ExtraComputerNames) { if ($c) { $compNames.Add($c.Trim()) } }
    $domain = ''
    if (-not $NoAutoDetect) {
        if ($env:USERNAME) { $names.Add($env:USERNAME) }
        try { if ([Environment]::UserName) { $names.Add([Environment]::UserName) } } catch { }
        try {
            $usersDir = Join-Path $env:SystemDrive 'Users'
            if (Test-Path -LiteralPath $usersDir) { foreach ($d in (Get-ChildItem -LiteralPath $usersDir -Directory -ErrorAction SilentlyContinue)) { $names.Add($d.Name) } }
        } catch { }
        if ($env:COMPUTERNAME) { $compNames.Add($env:COMPUTERNAME) }
        if ($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME -and @('WORKGROUP', 'AzureAD', 'NT AUTHORITY') -notcontains $env:USERDOMAIN) { $domain = $env:USERDOMAIN }
    }
    $names = @($names | Where-Object { $_ -and $_.Length -ge 3 -and ($script:ShareReservedUserNames -notcontains $_.ToLowerInvariant()) -and ($_ -notmatch '^[<$]') } | Select-Object -Unique)

    $valueAlt = '(?:&quot;.*?&quot;|&#39;.*?&#39;|"[^"\r\n]*"|''[^''\r\n]*''|[^\s"''<>&,;]+)'
    $secretWord = '(?:token|api[_-]?key|apikey|password|passwd|pwd|secret|credential|private[_-]?key|access[_-]?key)'

    # 1. Windows SIDs identify the account
    & $add 'S-1-5-21-\d+-\d+-\d+(?:-\d+)?' '<SID>'
    # 2. credentials inside URLs  scheme://user:pass@host
    & $add '\b([a-z][a-z0-9+.\-]*://)[^/\s:@"''<>]+:[^/\s@"''<>]+@' '${1}<USER>:<REDACTED>@'
    # 2b. e-mail addresses - BEFORE the name rules, otherwise "friend@example.com" would become "<USER>@example.com"
    & $add '\b[A-Z0-9._%+\-]+@[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)*\.[A-Z]{2,}\b' '<EMAIL>'
    # 3. profile folders: ...\Users\<name>\..., also JSON-escaped (\\) and forward slashes; Public/Default untouched
    & $addEval '(?<=[\\/])(Users(?:\\\\|\\|/)+)([^\\/\r\n"''<>|:*?&]+)' {
        param($m)
        $nm = $m.Groups[2].Value.Trim()
        if ($nm.StartsWith('<') -or ($script:ShareReservedUserNames -contains $nm.ToLowerInvariant())) { return $m.Value }
        return $m.Groups[1].Value + '<USER>'
    }
    # OneDrive for work/school folder names carry the organisation name
    & $add '\bOneDrive - [^\\/\r\n"<>|]+' 'OneDrive - <ORG>'
    # 4. account names as whole words (not alphanumerics around them)
    foreach ($n in $names) {
        if ($script:ShareGenericNames -contains $n.ToLowerInvariant()) { continue }
        & $add ('(?<![A-Za-z0-9_])' + [regex]::Escape($n) + '(?![A-Za-z0-9_])') '<USER>'
    }
    if ($domain -and $domain.Length -ge 3) { & $add ('(?<![A-Za-z0-9_])' + [regex]::Escape($domain) + '(?![A-Za-z0-9_])') '<DOMAIN>' }
    # 5. computer name (kept only on request)
    if (-not $IncludeHostName) {
        foreach ($c in ($compNames | Where-Object { $_ -and $_.Length -ge 3 -and $_ -notmatch '^[<$]' } | Select-Object -Unique)) {
            & $add ('(?<![A-Za-z0-9_])' + [regex]::Escape($c) + '(?![A-Za-z0-9_])') '<PC>'
        }
    }
    # 6. authorization headers / long bearer tokens
    & $add '(authorization\s*[:=]\s*)(?:(?:bearer|basic|token)\s+)?[^\s"''<>&,;]+' '${1}<REDACTED>'
    & $add '\bbearer\s+[A-Za-z0-9._~+/=\-]{16,}' 'Bearer <REDACTED>'
    # 7. key=value / key: value  (token, api-key, password, secret, ... also inside names like API_KEY_21ST)
    & $add ('(?<![A-Za-z0-9])([\w.\-]*' + $secretWord + '[\w.\-]*)(\s*[=:]\s*)' + $valueAlt) '${1}${2}<REDACTED>'
    # 8. command-line flags with a separate value:  --token VALUE
    & $add ('(\s--?[\w\-]*' + $secretWord + '[\w\-]*\s+)(?!-)' + $valueAlt) '${1}<REDACTED>'
    # 9. PowerShell encoded commands
    & $add '(\s-(?:enc|ec|encodedcommand)\s+)[A-Za-z0-9+/=]{24,}' '${1}<REDACTED-BASE64>'
    & $add '(\s-e\s+)[A-Za-z0-9+/=]{60,}' '${1}<REDACTED-BASE64>'
    # 10. tokens in query strings (also after &amp;)
    & $add '([?&;](?:access_token|refresh_token|id_token|token|auth|authorization|key|api_key|apikey|sig|signature|password|pwd|secret|code|session|sid)=)[^&\s"''<>#]+' '${1}<REDACTED>'
    # 12. any very long base64-looking blob (SHA-256 is 64 hex chars and is never touched)
    & $add '(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{120,}={0,2}(?![A-Za-z0-9+/=])' '<BASE64-BLOB>'

    return [pscustomobject]@{ Rules = @($rules); IncludeHostName = [bool]$IncludeHostName; ComputerNames = @($compNames | Select-Object -Unique); UserNames = $names }
}

function Protect-Text {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text, $Redactor)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if (-not $Redactor) { $Redactor = New-ShareRedactor -DiscoverFrom @($Text) }
    $t = $Text
    foreach ($r in $Redactor.Rules) {
        if ($r.Evaluator) { $t = $r.Regex.Replace($t, $r.Evaluator) } else { $t = $r.Regex.Replace($t, $r.Replacement) }
    }
    return $t
}

# HTML: <script>, <style> and the report marker comment (<!-- ram-doctor-report ... -->) are passed through
# byte-for-byte (the relay accepts report.html only if it is inert and carries the marker); only the visible
# text/attributes are redacted.
function Protect-Html {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Html, $Redactor)
    if ([string]::IsNullOrEmpty($Html)) { return $Html }
    if (-not $Redactor) { $Redactor = New-ShareRedactor -DiscoverFrom @($Html) }
    # protected: whole script/style blocks and the literal marker prefix "<!-- ram-doctor-report" (the rest of that
    # comment is ordinary text and IS redacted)
    $parts = [regex]::Split($Html, '(?is)(<script\b[^>]*>.*?</script\s*>|<style\b[^>]*>.*?</style\s*>|<!--\s*ram-doctor-report)')
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i % 2 -eq 1) { [void]$sb.Append($parts[$i]) }   # captured protected segment
        else { [void]$sb.Append((Protect-Text -Text $parts[$i] -Redactor $Redactor)) }
    }
    return $sb.ToString()
}

# Walks a parsed JSON value and redacts every string (keeps the structure valid).
function ConvertTo-ShareRedactedObject {
    param($Value, $Redactor)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Protect-Text -Text $Value -Redactor $Redactor) }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = (ConvertTo-ShareRedactedObject -Value $p.Value -Redactor $Redactor) }
        return [pscustomobject]$h
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($i in $Value) { [void]$list.Add((ConvertTo-ShareRedactedObject -Value $i -Redactor $Redactor)) }
        return , $list.ToArray()
    }
    return $Value
}

function Protect-ShareJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json, $Redactor)
    if (-not $Redactor) { $Redactor = New-ShareRedactor -DiscoverFrom @($Json) }
    $obj = $Json | ConvertFrom-Json
    $red = ConvertTo-ShareRedactedObject -Value $obj -Redactor $Redactor
    return ($red | ConvertTo-Json -Depth 20)
}

# ---------------------------------------------------------------- bundle (summary.md + report.html + plan.json)
function ConvertTo-ShareMdCell {
    param([AllowNull()]$Value)
    $s = if ($null -eq $Value) { '' } else { [string]$Value }
    return (($s -replace '\|', '\|') -replace '\s*[\r\n]+\s*', ' ').Trim()
}

function New-ShareSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [string]$DisplayName = '', [string]$UserId = '', [string]$Version = $script:ShareToolVersion, [string]$HostLabel = '<PC>', [string]$Lang = '')
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $sb = New-Object System.Text.StringBuilder
    $nl = "`n"
    # The labels of this summary are English (the helper reads English); the scan's own sentences (verdict, observations, reasons)
    # keep the language of the scan. Arabic ones are wrapped in a right-to-left block; English ones need no wrapper (the relay
    # only keeps <div dir="rtl">, so an LTR wrapper would turn into visible text).
    $rtl = ((Resolve-ShareLang $Plan $Lang) -eq 'ar')
    $divOpen = $(if ($rtl) { "<div dir=`"rtl`">$nl$nl" } else { '' })
    $divCloseText = $(if ($rtl) { "$nl$nl</div>$nl$nl" } else { "$nl$nl" })
    $divCloseList = $(if ($rtl) { "$nl</div>$nl$nl" } else { $nl })
    $verdict = $Plan.verdict
    $level = if ($verdict -and $verdict.Level) { [string]$verdict.Level } else { 'unknown' }
    $headline = if ($verdict -and $verdict.Headline) { [string]$verdict.Headline } else { '' }
    $who = if ($DisplayName) { "$DisplayName ($UserId)" } else { '(profile not set)' }
    $bt = [string][char]96   # markdown code-span backtick

    [void]$sb.Append("# RAM Doctor report - $who$nl$nl")
    [void]$sb.Append("| | |$nl|---|---|$nl")
    [void]$sb.Append("| Scan time | $(ConvertTo-ShareMdCell $Plan.created) |$nl")
    [void]$sb.Append("| Tool | RAM-Doctor $(ConvertTo-ShareMdCell $Version) |$nl")
    [void]$sb.Append("| Computer | $(ConvertTo-ShareMdCell $HostLabel) |$nl")
    [void]$sb.Append("| Administrator scan | $(if ($Plan.isAdmin) { 'yes' } else { 'no (limited)' }) |$nl$nl")

    [void]$sb.Append("## Verdict ($level)$nl$nl")
    [void]$sb.Append("$divOpen**$(ConvertTo-ShareMdCell $headline)**$divCloseText")

    $m = $Plan.memory
    if ($m) {
        [void]$sb.Append("## Memory$nl$nl| Metric | GB |$nl|---|---:|$nl")
        $rows = @(
            @('Total (usable)', 'TotalGB'), @('Used', 'UsedGB'), @('Available', 'AvailGB'), @('Standby (cache)', 'StandbyGB'), @('Modified', 'ModifiedGB'),
            @('Process private', 'ProcPrivateGB'), @('Process shared', 'ProcSharedGB'), @('Kernel non-paged pool', 'NonPagedGB'), @('Kernel paged pool', 'PagedGB'),
            @('Not attributed to any process', 'UnaccountedGB'), @('Committed', 'CommittedGB'), @('Commit limit', 'CommitLimitGB'))
        foreach ($r in $rows) { $v = $m.($r[1]); if ($null -ne $v) { [void]$sb.Append("| $($r[0]) | $(([double]$v).ToString('0.##', $inv)) |$nl") } }
        $g = @()
        if ($null -ne $m.NonPagedGrowthMB) { $g += "non-paged $($m.NonPagedGrowthMB) MB" }
        if ($null -ne $m.PagedGrowthMB) { $g += "paged $($m.PagedGrowthMB) MB" }
        if ($null -ne $m.CommitGrowthMB) { $g += "commit $($m.CommitGrowthMB) MB" }
        if ($null -ne $m.UsedGrowthMB) { $g += "used $($m.UsedGrowthMB) MB" }
        if ($g.Count -gt 0) { [void]$sb.Append("$nl*Growth during the scan window ($($m.WindowSec) s): $($g -join ', ')*$nl") }
        [void]$sb.Append($nl)
    }

    $obs = @($Plan.observations | Where-Object { $_ })
    [void]$sb.Append("## Observations ($($obs.Count))$nl$nl")
    if ($obs.Count -eq 0) { [void]$sb.Append("None.$nl$nl") }
    else {
        [void]$sb.Append($divOpen)
        foreach ($o in $obs) { [void]$sb.Append("- **[$(ConvertTo-ShareMdCell $o.Level)] $(ConvertTo-ShareMdCell $o.Title)** - $(ConvertTo-ShareMdCell $o.Body)$nl") }
        [void]$sb.Append($divCloseList)
    }

    $sus = @($Plan.suspects | Where-Object { $_ })
    [void]$sb.Append("## Suspicious files ($($sus.Count))$nl$nl")
    if ($sus.Count -eq 0) { [void]$sb.Append("None above the reporting threshold.$nl$nl") }
    else {
        [void]$sb.Append("| # | Risk | Score | Name | Trust | SHA-256 | VirusTotal |$nl|---:|---|---:|---|---|---|---|$nl")
        foreach ($s in $sus) {
            $sha = [string]$s.sha256
            $shaCell = if ($sha) { $bt + $sha + $bt } else { '-' }
            $vt = if ($sha) { "[lookup](https://www.virustotal.com/gui/file/$sha)" } else { '-' }
            $trust = (ConvertTo-ShareMdCell $s.trust) + $(if ($s.publisher) { ' / ' + (ConvertTo-ShareMdCell $s.publisher) } else { '' })
            [void]$sb.Append("| $($s.id) | $(ConvertTo-ShareMdCell $s.risk) | $($s.score) | $(ConvertTo-ShareMdCell $s.name) | $trust | $shaCell | $vt |$nl")
        }
        [void]$sb.Append($nl)
        foreach ($s in $sus) {
            [void]$sb.Append("### #$($s.id) $(ConvertTo-ShareMdCell $s.name) ($(ConvertTo-ShareMdCell $s.risk))$nl$nl")
            if ($s.path) { [void]$sb.Append("Path: $bt$(ConvertTo-ShareMdCell $s.path)$bt$nl$nl") }
            $reasons = @($s.reasons | Where-Object { $_ })
            if ($reasons.Count -gt 0) {
                [void]$sb.Append($divOpen)
                foreach ($r in $reasons) { [void]$sb.Append("- $(ConvertTo-ShareMdCell $r)$nl") }
                [void]$sb.Append($divCloseList)
            }
        }
    }
    [void]$sb.Append("---$nl*Generated by RAM Doctor $(ConvertTo-ShareMdCell $Version). Redacted before upload: account/computer names, e-mails and secrets are masked.*$nl")
    return $sb.ToString()
}

# Builds the three upload files from a Plan-<HOST>-<stamp>.json (and its RAMDoctor-<HOST>-<stamp>.html neighbour).
function New-ShareBundle {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'A parameter named Profile only shadows the profile-path variable inside this function.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        $Profile,
        [switch]$IncludeHostName,
        $Redactor,
        [string]$Version = $script:ShareToolVersion
    )
    if (-not (Test-Path -LiteralPath $PlanPath)) { throw 'no-plan' }
    $raw = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8
    try { $planObj = $raw | ConvertFrom-Json } catch { throw 'bad-plan' }
    if (-not $planObj) { throw 'bad-plan' }
    # matching html report: same <HOST>-<stamp> as the plan file
    $dir = Split-Path -Parent (Resolve-Path -LiteralPath $PlanPath).Path
    $base = [IO.Path]::GetFileNameWithoutExtension($PlanPath)
    $html = $null
    if ($base -match '^Plan-(?<hs>.+-\d{8}-\d{6})$') { $html = Join-Path $dir ('RAMDoctor-' + $Matches['hs'] + '.html') }
    if ((-not $html -or -not (Test-Path -LiteralPath $html)) -and $planObj.report) {
        $alt = Join-Path $dir ([IO.Path]::GetFileName([string]$planObj.report))
        if (Test-Path -LiteralPath $alt) { $html = $alt }
    }
    $htmlRaw = $null
    if ($html -and (Test-Path -LiteralPath $html)) { $htmlRaw = Get-Content -LiteralPath $html -Raw -Encoding UTF8 }
    # names found under \Users\ anywhere in the scan data are masked everywhere; the plan's own host is the computer name
    if (-not $Redactor) { $Redactor = New-ShareRedactor -DiscoverFrom @($raw, $htmlRaw) -ExtraComputerNames @([string]$planObj.host) -IncludeHostName:$IncludeHostName }

    $planJson = Protect-ShareJson -Json $raw -Redactor $Redactor
    $redPlan = $planJson | ConvertFrom-Json
    $hostLabel = if ($IncludeHostName) { [string]$planObj.host } else { '<PC>' }
    $name = if ($Profile) { [string]$Profile.displayName } else { '' }
    $uid = if ($Profile) { [string]$Profile.userId } else { '' }
    # The chosen display name is the user's own pseudonym: keep it literal even if it equals their account name
    # (placeholders survive the redaction rules, then are swapped back).
    $summary = New-ShareSummary -Plan $redPlan -DisplayName $(if ($name) { '%%RDNAME%%' } else { '' }) -UserId $uid -Version $Version -HostLabel $hostLabel
    $summary = (Protect-Text -Text $summary -Redactor $Redactor).Replace('%%RDNAME%%', $name)

    $files = New-Object System.Collections.ArrayList
    [void]$files.Add([pscustomobject]@{ name = 'summary.md'; content = $summary })

    if ($null -ne $htmlRaw) {
        [void]$files.Add([pscustomobject]@{ name = 'report.html'; content = (Protect-Html -Html $htmlRaw -Redactor $Redactor) })
    }
    [void]$files.Add([pscustomobject]@{ name = 'plan.json'; content = $planJson })
    return [pscustomobject]@{ Files = @($files); Host = $hostLabel; CreatedPlan = [string]$planObj.created }
}

function Get-ShareBodyBytes {
    param([Parameter(Mandatory)][string]$Json)
    return [Text.Encoding]::UTF8.GetByteCount($Json)
}

# ---------------------------------------------------------------- short text summary (copy & paste into a chat app)
# Plain text, <= ~1500 characters, no profile and no network needed. Redaction is applied twice: on the plan's
# strings first, then on the final text.
function New-ShareShortSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [switch]$IncludeHostName,
        $Redactor,
        [int]$MaxChars = 1500,
        [string]$Version = $script:ShareToolVersion,
        [string]$Lang = ''   # language of the labels: -Lang, else the plan's own language, else Arabic
    )
    if (-not (Test-Path -LiteralPath $PlanPath)) { throw 'no-plan' }
    $raw = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8
    try { $rawObj = $raw | ConvertFrom-Json } catch { throw 'bad-plan' }
    $sl = Resolve-ShareLang $rawObj $Lang
    if (-not $Redactor) { $Redactor = New-ShareRedactor -DiscoverFrom @($raw) -ExtraComputerNames @([string]$rawObj.host) -IncludeHostName:$IncludeHostName }
    $plan = (Protect-ShareJson -Json $raw -Redactor $Redactor) | ConvertFrom-Json
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $nl = "`r`n"

    $cut = {
        param([string]$s, [int]$n)
        $t = (([string]$s) -replace '\s+', ' ').Trim()
        if ($t.Length -gt $n) { $t = $t.Substring(0, [Math]::Max(1, $n - 1)).TrimEnd() + [string][char]0x2026 }
        return $t
    }
    $num = { param($v) if ($null -eq $v -or "$v" -eq '') { '?' } else { ([double]$v).ToString('0.##', $inv) } }
    $riskKey = @{ High = 'level.high'; Medium = 'level.med'; Low = 'level.low' }

    $headline = if ($plan.verdict -and $plan.verdict.Headline) { & $cut $plan.verdict.Headline 160 } else { '-' }
    $m = $plan.memory
    $memLine = $null
    if ($m) {
        $memLine = Get-Text 'sum.mem' (& $num $m.UsedGB) (& $num $m.TotalGB) (& $num $m.NonPagedGB) (& $num $m.PagedGB) (& $num $m.UnaccountedGB) -Lang $sl
    }
    $obsAll = @($plan.observations | Where-Object { $_ -and $_.Level -ne 'info' -and $_.Title } | ForEach-Object { '- ' + (& $cut $_.Title 90) })
    $susAll = @($plan.suspects | Where-Object { $_ -and $_.risk -in 'High', 'Medium' } | ForEach-Object {
            $r = if ($riskKey.ContainsKey([string]$_.risk)) { Get-Text $riskKey[[string]$_.risk] -Lang $sl } else { [string]$_.risk }
            $reason = & $cut (@($_.reasons)[0]) 80
            $sha = if ($_.sha256) { ' | sha256:' + ([string]$_.sha256).Substring(0, [Math]::Min(12, ([string]$_.sha256).Length)) } else { '' }
            '- [{0}] {1} ({2}) - {3}{4}' -f $r, (& $cut $_.name 40), (& $cut $_.trust 24), $reason, $sha
        })
    $susTotal = @($plan.suspects | Where-Object { $_ }).Count
    $hostLine = if ($IncludeHostName -and $plan.host) { (Get-Text 'sum.host' -Lang $sl) + (& $cut $plan.host 40) } else { $null }
    $footer = Get-Text 'sum.footer' $Version (& $cut $plan.created 25) -Lang $sl

    $build = {
        param([int]$nObs, [int]$nSus)
        $l = New-Object System.Collections.Generic.List[string]
        $l.Add((Get-Text 'sum.title' -Lang $sl))
        $l.Add((Get-Text 'sum.verdict' -Lang $sl) + $headline)
        if ($memLine) { $l.Add($memLine) }
        if ($hostLine) { $l.Add($hostLine) }
        if ($nObs -gt 0) { $l.Add((Get-Text 'sum.notes' -Lang $sl)); foreach ($o in ($obsAll | Select-Object -First $nObs)) { $l.Add($o) } }
        if ($nSus -gt 0) {
            $l.Add((Get-Text 'sum.sus' $susTotal -Lang $sl))
            foreach ($s in ($susAll | Select-Object -First $nSus)) { $l.Add($s) }
        } elseif ($susTotal -eq 0) { $l.Add((Get-Text 'sum.sus.none' -Lang $sl)) }
        else { $l.Add((Get-Text 'sum.sus.low' $susTotal -Lang $sl)) }
        $l.Add($footer)
        return ($l -join $nl)
    }
    $nObs = [Math]::Min(5, $obsAll.Count); $nSus = [Math]::Min(5, $susAll.Count)
    $text = & $build $nObs $nSus
    while ($text.Length -gt $MaxChars -and ($nObs -gt 3 -or $nSus -gt 1 -or $nObs -gt 0)) {
        if ($nObs -gt 3) { $nObs-- } elseif ($nSus -gt 1) { $nSus-- } elseif ($nObs -gt 0) { $nObs-- } else { break }
        $text = & $build $nObs $nSus
    }
    $text = Protect-Text -Text $text -Redactor $Redactor
    if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars - 1) + [string][char]0x2026 }
    return $text
}

# ---------------------------------------------------------------- upload (protocol v1)
# A new random id for one upload (relay field "requestId"): it is sent unchanged on every retry of that upload, so the
# relay stores the report once even when an answer is lost and the client asks again.
function New-ShareRequestId { return [guid]::NewGuid().ToString() }

function New-ShareRequestJson {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'A parameter named Profile only shadows the profile-path variable inside this function.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile, [string]$Code = '', [Parameter(Mandatory)]$Bundle, [string]$Version = $script:ShareToolVersion, [string]$RequestId = '')
    if (-not $RequestId) { $RequestId = New-ShareRequestId }
    $files = @()
    foreach ($f in $Bundle.Files) { $files += [ordered]@{ name = $f.name; content = $f.content } }
    $body = [ordered]@{ v = 1; displayName = $Profile.displayName; userId = $Profile.userId }
    if ($Code) { $body['code'] = $Code }   # "code" is only sent when one is stored
    $body['requestId'] = $RequestId
    $body['tool'] = [ordered]@{ name = 'RAM-Doctor'; version = $Version }
    $body['createdAt'] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    $body['host'] = $Bundle.Host
    $body['files'] = $files
    return ($body | ConvertTo-Json -Depth 6 -Compress)
}

# One HTTP exchange. Returns Status (0 = network failure), the response text and Retry-After (seconds, 0 = none).
function Send-ShareRequest {
    param([Parameter(Mandatory)][string]$Uri, [string]$Method = 'POST', [string]$Json, [int]$TimeoutSec = 30)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $res = [pscustomobject]@{ Status = 0; Text = ''; Network = $true; Error = ''; RetryAfter = 0 }
    $readRetryAfter = { param($r) $n = 0; try { if ([int]::TryParse([string]$r.Headers['Retry-After'], [ref]$n) -and $n -gt 0) { $res.RetryAfter = $n } } catch { } }
    try {
        $req = [Net.HttpWebRequest]::Create($Uri)
        $req.Method = $Method
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.UserAgent = 'RAM-Doctor/' + $script:ShareToolVersion
        $req.KeepAlive = $false
        $req.Accept = 'application/json'
        if ($Method -eq 'POST') {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
            $req.ContentType = 'application/json; charset=utf-8'
            $req.ContentLength = $bytes.Length
            $rs = $req.GetRequestStream()
            try { $rs.Write($bytes, 0, $bytes.Length) } finally { $rs.Close() }
        }
        $resp = $req.GetResponse()
        try {
            $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            $res.Text = $sr.ReadToEnd(); $sr.Close()
            $res.Status = [int]$resp.StatusCode; $res.Network = $false
            & $readRetryAfter $resp
        } finally { $resp.Close() }
    } catch [System.Net.WebException] {
        $we = $_.Exception
        if ($we.Response) {
            try {
                $res.Status = [int]([Net.HttpWebResponse]$we.Response).StatusCode; $res.Network = $false
                & $readRetryAfter $we.Response
                $sr = New-Object IO.StreamReader($we.Response.GetResponseStream(), [Text.Encoding]::UTF8)
                $res.Text = $sr.ReadToEnd(); $sr.Close()
            } catch { }
            try { $we.Response.Close() } catch { }
        } else { $res.Error = [string]$we.Status }
    } catch { $res.Error = $_.Exception.GetType().Name }
    return $res
}

# Posts the report. Retries network failures and 5xx (never other 4xx) with the SAME body, so the same requestId: a relay
# that already stored the report answers the retry with the first result ("replayed") instead of storing it twice.
#   409 in_progress   the first attempt is still being stored: wait Retry-After (at most -MaxWaitSeconds) and ask again
#   400 unknown_field a relay older than the requestId field: the same body without requestId is sent once
# Never logs the request body.
function Send-ShareReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$Json,
        [switch]$CodeSent,
        [switch]$CodeUnreadable,      # a stored invite code exists but could not be decrypted (DPAPI) on this account
        [int]$MaxAttempts = 3,
        [double]$BackoffSeconds = 2,
        [int]$TimeoutSec = 30,
        [int]$MaxWaitSeconds = 15,
        [int]$MaxInProgressWaits = 4
    )
    $uri = $Endpoint.TrimEnd('/') + '/v1/reports'
    $last = $null; $a = 0; $waits = 0; $legacyTried = $false
    while ($true) {
        $a++
        $r = Send-ShareRequest -Uri $uri -Method POST -Json $Json -TimeoutSec $TimeoutSec
        $last = $r
        if (-not $r.Network -and $r.Status -ge 200 -and $r.Status -lt 300) {
            $j = $null; try { $j = $r.Text | ConvertFrom-Json } catch { }
            if ($j -and $j.ok) {
                $u = if ($j.url) { [string]$j.url } else { [string]$j.folder }
                return [pscustomobject]@{ Ok = $true; Code = 'ok'; Message = ''; Url = $u; Folder = [string]$j.folder; Attempts = $a; Replayed = [bool]($j.PSObject.Properties['replayed'] -and $j.replayed) }
            }
            return [pscustomobject]@{ Ok = $false; Code = 'bad-response'; Message = (Get-ShareMessage 'bad-response'); Url = ''; Folder = ''; Attempts = $a; Replayed = $false }
        }
        if (-not $r.Network -and $r.Status -eq 409 -and $waits -lt $MaxInProgressWaits) {
            $waits++; $a--
            $sec = [Math]::Min([Math]::Max(1, $r.RetryAfter), $MaxWaitSeconds)
            if ($sec -gt 0) { Start-Sleep -Seconds $sec }
            continue
        }
        if (-not $r.Network -and $r.Status -eq 400 -and -not $legacyTried) {
            $field = ''; try { $field = [string](($r.Text | ConvertFrom-Json).field) } catch { }
            $m = [regex]::Match($Json, ',"requestId":"[A-Za-z0-9-]{16,64}"')
            if ($field -eq 'unknown_field' -and $m.Success) { $legacyTried = $true; $a--; $Json = $Json.Remove($m.Index, $m.Length); continue }
        }
        $retry = ($r.Network -or $r.Status -ge 500)
        if (-not $retry -or $a -ge $MaxAttempts) { break }
        if ($BackoffSeconds -gt 0) { Start-Sleep -Milliseconds ([int](1000 * $BackoffSeconds * $a)) }
    }
    if ($last.Network) { return [pscustomobject]@{ Ok = $false; Code = 'offline'; Message = (Get-ShareMessage 'offline'); Url = ''; Folder = ''; Attempts = $a; Replayed = $false } }
    $code = [string]$last.Status
    if ($last.Status -eq 409) { return [pscustomobject]@{ Ok = $false; Code = '409'; Message = (Get-Text 'store.share.inprogress'); Url = ''; Folder = ''; Attempts = $a; Replayed = $false } }
    $key = if ($last.Status -ge 500) { '5xx' } elseif ($last.Status -eq 401 -and $CodeUnreadable) { 'code-unreadable' } elseif ($last.Status -eq 401 -and -not $CodeSent) { '401-nocode' } else { $code }
    $msg = Get-ShareMessage $key
    if ($msg -eq $key) { $msg = Get-ShareMessage '400' }
    return [pscustomobject]@{ Ok = $false; Code = $code; Message = $msg; Url = ''; Folder = ''; Attempts = $a; Replayed = $false }
}
function Test-ShareHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Endpoint, [int]$TimeoutSec = 10)
    $r = Send-ShareRequest -Uri ($Endpoint.TrimEnd('/') + '/v1/health') -Method GET -TimeoutSec $TimeoutSec
    if ($r.Network) { return [pscustomobject]@{ Ok = $false; Code = 'offline'; Message = (Get-ShareMessage 'offline') } }
    $ok = $false; try { $ok = [bool](($r.Text | ConvertFrom-Json).ok) } catch { }
    if ($r.Status -ge 200 -and $r.Status -lt 300 -and $ok) { return [pscustomobject]@{ Ok = $true; Code = 'ok'; Message = '' } }
    return [pscustomobject]@{ Ok = $false; Code = [string]$r.Status; Message = (Get-ShareMessage '5xx') }
}
