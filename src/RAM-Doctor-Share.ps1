#requires -Version 5.1
<#
.SYNOPSIS
  RAM Doctor - sharing helper (command line used by the GUI). Opt-in: nothing here runs unless it is called.

.DESCRIPTION
  Actions
    Summary        offline: short redacted plain-text summary for a chat app  -> "SUMMARY: <path>"
    ShowProfile    "PROFILE: configured=<bool> name=<n> userId=<id> helper=<h> endpointConfigured=<bool>"
    SaveProfile    -Username [-Code]   the profile is just a chosen name + a random fixed userId. The invite code is
                   OPTIONAL (only needed if the helper's relay enforces one); it may also come from
                   $env:RAMDOC_SHARE_CODE (the name from $env:RAMDOC_SHARE_NAME) so it never sits on a command line.
    DeleteProfile
    Preview        writes the redacted bundle to %TEMP%\RAM-Doctor-share-preview\ -> "PREVIEW: <dir>" + "FILES: ..."
    Share          uploads the bundle (protocol v1) -> "RESULT: OK <url>" | "RESULT: ERROR <code> <message>"
    Health         GET /v1/health of the configured relay
  Progress lines look like "[hh:mm:ss] message"; results are the machine-readable lines above.
  -Lang ar|en  language of the messages shown to the user (RESULT: ERROR ... text) and of the chat summary labels;
               default: the Windows UI language (Arabic -> ar, otherwise en). The strings live in lib\Strings.ps1.
  Exit code: 0 = OK, 1 = error. Output is UTF-8. The invite code is never printed.
  The upload is DORMANT unless src\share.config.json (or -Endpoint) names a relay.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Summary', 'ShowProfile', 'SaveProfile', 'DeleteProfile', 'Preview', 'Share', 'Health')][string]$Action,
    [string]$Username,
    [string]$Code,
    [string]$PlanPath,
    [switch]$IncludeHostName,
    [string]$Endpoint,
    [string]$ProfileDir,
    [string]$ConfigPath,
    [string]$PreviewDir,
    [switch]$DryRun,
    [double]$BackoffSeconds = 2,
    [ValidateSet('ar', 'en')][string]$Lang
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }
. (Join-Path $Root 'lib\Strings.ps1')
. (Join-Path $Root 'lib\Share.ps1')
Set-UiLang $Lang
if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'share.config.json' }
if (-not $PreviewDir) { $PreviewDir = Join-Path $env:TEMP 'RAM-Doctor-share-preview' }

function Say([string]$m) { Write-Output ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $m) }
function Fail([string]$code, [string]$message) { Write-Output ("RESULT: ERROR $code $message"); exit 1 }
function Fail-Simple([string]$message) { Write-Output ("RESULT: ERROR $message"); exit 1 }
function Kb([string]$s) { ([Text.Encoding]::UTF8.GetByteCount($s) / 1KB).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) }

$cfg = Get-ShareConfig -Path $ConfigPath
$endpointUsed = if ($Endpoint) { $Endpoint.Trim() } else { $cfg.endpoint }
if (-not $Code -and $env:RAMDOC_SHARE_CODE) { $Code = $env:RAMDOC_SHARE_CODE }
if (-not $Username -and $env:RAMDOC_SHARE_NAME) { $Username = $env:RAMDOC_SHARE_NAME }

function Get-PlanOrFail {
    if (-not $PlanPath -or -not (Test-Path -LiteralPath $PlanPath)) { Fail 'no-plan' (Get-ShareMessage 'no-plan') }
}

try {
    switch ($Action) {

        'Summary' {
            if (-not $PlanPath -or -not (Test-Path -LiteralPath $PlanPath)) { Fail-Simple (Get-ShareMessage 'no-plan') }
            Say 'Building short summary ...'
            $text = New-ShareShortSummary -PlanPath $PlanPath -IncludeHostName:$IncludeHostName -Lang $Lang
            New-Item -ItemType Directory -Force -Path $PreviewDir | Out-Null
            $out = Join-Path $PreviewDir 'summary.txt'
            [IO.File]::WriteAllText($out, $text, (New-Object System.Text.UTF8Encoding($true)))
            Write-Output "SUMMARY: $out"
            exit 0
        }

        'ShowProfile' {
            $p = Get-ShareProfile -ProfileDir $ProfileDir
            $epOk = [bool]($endpointUsed -and ($null -eq (Test-ShareEndpoint $endpointUsed)))
            if ($p) {
                Write-Output ('PROFILE: configured=true name={0} userId={1} helper={2} endpointConfigured={3}' -f $p.displayName, $p.userId, $cfg.helperName, $epOk.ToString().ToLower())
                Write-Output ('PROFILE_JSON: ' + ([ordered]@{ configured = $true; name = $p.displayName; userId = $p.userId; helper = $cfg.helperName; endpointConfigured = $epOk; hasCode = [bool]$p.codeProtected } | ConvertTo-Json -Compress))
            } else {
                Write-Output ('PROFILE: configured=false name= userId= helper={0} endpointConfigured={1}' -f $cfg.helperName, $epOk.ToString().ToLower())
                Write-Output ('PROFILE_JSON: ' + ([ordered]@{ configured = $false; name = ''; userId = ''; helper = $cfg.helperName; endpointConfigured = $epOk; hasCode = $false } | ConvertTo-Json -Compress))
            }
            exit 0
        }

        'SaveProfile' {
            $r = Save-ShareProfile -Username $Username -Code $Code -ProfileDir $ProfileDir
            if ($r.Ok) { Write-Output 'RESULT: OK'; exit 0 }
            Fail-Simple $r.Error
        }

        'DeleteProfile' {
            Remove-ShareProfile -ProfileDir $ProfileDir
            Write-Output 'RESULT: OK'
            exit 0
        }

        { $_ -in 'Preview', 'Share' } {
            Get-PlanOrFail
            $shareProfile = Get-ShareProfile -ProfileDir $ProfileDir
            if ($Action -eq 'Share') {
                if (-not $shareProfile) { Fail 'no-profile' (Get-ShareMessage 'no-profile') }
                if (-not $DryRun) {
                    $epErr = Test-ShareEndpoint $endpointUsed
                    if ($epErr) { Fail $epErr (Get-ShareMessage $epErr) }
                }
            }
            Say 'Redacting names, e-mails and secrets ...'
            try { $bundle = New-ShareBundle -PlanPath $PlanPath -Profile $shareProfile -IncludeHostName:$IncludeHostName }
            catch { $k = [string]$_.Exception.Message; if ($k -ne 'no-plan') { $k = 'bad-plan' }; Fail $k (Get-ShareMessage $k) }
            $sizes = ($bundle.Files | ForEach-Object { '{0}={1}' -f $_.name, (Kb $_.content) }) -join ' '

            if ($Action -eq 'Preview') {
                if (Test-Path -LiteralPath $PreviewDir) { Remove-Item -LiteralPath $PreviewDir -Recurse -Force -ErrorAction SilentlyContinue }
                New-Item -ItemType Directory -Force -Path $PreviewDir | Out-Null
                foreach ($f in $bundle.Files) { [IO.File]::WriteAllText((Join-Path $PreviewDir $f.name), $f.content, (New-Object System.Text.UTF8Encoding($true))) }
                Write-Output "PREVIEW: $PreviewDir"
                Write-Output "FILES: $sizes"
                exit 0
            }

            # Share: the invite code is optional - it is sent only when one is stored (and readable).
            # Keep the body under the limit (drop the big html first).
            $codePlain = [string](Get-ShareInviteCode -Profile $shareProfile)
            $json = New-ShareRequestJson -Profile $shareProfile -Code $codePlain -Bundle $bundle
            if ((Get-ShareBodyBytes $json) -gt $cfg.maxBytes) {
                Say 'Report is large: leaving out report.html'
                $bundle.Files = @($bundle.Files | Where-Object { $_.name -ne 'report.html' })
                $json = New-ShareRequestJson -Profile $shareProfile -Code $codePlain -Bundle $bundle
            }
            if ((Get-ShareBodyBytes $json) -gt $cfg.maxBytes) { $codePlain = $null; Fail '413' (Get-ShareMessage '413') }
            Say ('Upload size: {0} KB' -f ((Get-ShareBodyBytes $json) / 1KB).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))
            if ($DryRun) { $codePlain = $null; Write-Output 'RESULT: OK dryrun'; exit 0 }
            Say 'Uploading ...'
            $res = Send-ShareReport -Endpoint $endpointUsed -Json $json -CodeSent:([bool]$codePlain) -BackoffSeconds $BackoffSeconds
            $json = $null; $codePlain = $null
            if ($res.Ok) { Say 'Uploaded.'; Write-Output "RESULT: OK $($res.Url)"; exit 0 }
            Fail $res.Code $res.Message
        }

        'Health' {
            $epErr = Test-ShareEndpoint $endpointUsed
            if ($epErr) { Fail $epErr (Get-ShareMessage $epErr) }
            $h = Test-ShareHealth -Endpoint $endpointUsed
            if ($h.Ok) { Write-Output 'HEALTH: ok=true'; Write-Output 'RESULT: OK'; exit 0 }
            Write-Output 'HEALTH: ok=false'
            Fail $h.Code $h.Message
        }
    }
}
catch {
    # last resort: never leak details such as the request body
    Write-Output ('RESULT: ERROR internal ' + $_.Exception.GetType().Name)
    exit 1
}
