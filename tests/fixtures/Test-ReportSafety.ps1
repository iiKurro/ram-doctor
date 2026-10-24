# ------------------------------------------------------------------------------------------
#  Unit-level check of the "inert report" contract for src/lib/Report.ps1.
#
#  Renders the synthetic scenarios (leak / miner / clean) plus a HOSTILE variant (every free-text
#  field stuffed with <script>, onerror=, javascript:, data:, external URLs) and asserts:
#    (a) marker comment right after the doctype            <!-- ram-doctor-report vX.Y.Z -->
#    (b) at most ONE inline <script>, <= 3 KB, no <script src>, no inline on*= handlers,
#        none of: fetch XMLHttpRequest WebSocket sendBeacon eval Function( import document.write
#        location window.open innerHTML .src=
#    (c) no iframe/object/embed/form/base/link/frame/applet/meta http-equiv, no src= attributes,
#        no javascript:/vbscript:/data: URLs, the ONLY external URLs are
#        https://www.virustotal.com/gui/file/<64-hex> and https://github.com/...
#    plus: PC name only once (header chip), no e-mail addresses, balanced tags, size sanity.
#
#  Usage:  powershell -File tests\fixtures\Test-ReportSafety.ps1 [-OutDir <folder>]
#          -OutDir also writes the rendered HTML (light + dark) for screenshots.
#  Exit code: 0 = all good, 1 = at least one assertion failed.   Windows PowerShell 5.1 compatible.
# ------------------------------------------------------------------------------------------
[CmdletBinding()]
param([string]$OutDir = '')

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'src\lib\Report.ps1')
. (Join-Path $PSScriptRoot 'Demo-ReportData.ps1')

$script:fails = New-Object System.Collections.Generic.List[string]
$script:checks = 0
function Check([bool]$ok, [string]$what, [string]$scenario) {
    $script:checks++
    if (-not $ok) { $script:fails.Add("[$scenario] $what"); Write-Host "  FAIL  [$scenario] $what" -ForegroundColor Red }
}

# --- hostile variant: every attacker-controlled string carries a payload
function Get-HostileData {
    $d = Get-DemoReportData -Scenario miner
    $evil = '"><script>alert(1)</script><img src=x onerror=alert(2)> javascript:alert(3) data:text/html,<b>x</b> https://evil.example/payload.exe vbscript:x'
    $d.Observations[0].Title = $evil; $d.Observations[0].Body = $evil
    $d.Verdict.Headline = $evil
    $s = $d.Suspects[0]
    $s.name = $evil; $s.path = "C:\Users\Friend\$evil.exe"; $s.company = $evil; $s.description = $evil; $s.publisher = $evil
    $s.sha256 = 'javascript:alert(4)'                        # not a valid hash -> must not become a link
    $s.reasons = @($evil); $s.procs[0].remote = @($evil); $s.autoruns[0].name = $evil; $s.autoruns[0].location = $evil
    $d.TopProcesses[0].name = $evil; $d.TopProcesses[0].path = $evil; $d.ByProgram[0].name = $evil
    $d.Sys.Host = 'DESKTOP-DEMO'; $d.Sys.Cpu = $evil
    $d.Warnings = @($evil)
    $d.Defender.RecentThreats = @([pscustomobject]@{ time = $evil; process = $evil; resources = $evil })
    $d.Exhaustion = @([pscustomobject]@{ time = $evil; message = $evil })
    $d.Hidden = @([pscustomobject]@{ Pid = 1; Live = $true; Image = $evil; IsWindowsImage = $false })
    return $d
}

$scenarios = [ordered]@{
    leak = (Get-DemoReportData -Scenario leak); miner = (Get-DemoReportData -Scenario miner)
    clean = (Get-DemoReportData -Scenario clean); hostile = (Get-HostileData)
}

foreach ($name in $scenarios.Keys) {
    $html = New-RamReportHtml $scenarios[$name]
    $bytes = [Text.Encoding]::UTF8.GetByteCount($html)
    Write-Host ("{0,-8} {1,7:N1} KB" -f $name, ($bytes / 1KB))

    # (a) marker right after the doctype
    Check ($html -match '^(?i)<!doctype html>\r?\n<!-- ram-doctor-report v\d+\.\d+\.\d+ -->') 'marker comment must follow the doctype' $name

    # (b) scripts
    $scripts = [regex]::Matches($html, '(?is)<script\b([^>]*)>(.*?)</script>')
    Check ($scripts.Count -le 1) "at most one <script> block (found $($scripts.Count))" $name
    Check (([regex]::Matches($html, '(?i)<script\b')).Count -eq $scripts.Count) 'every <script> is a closed inline block' $name
    foreach ($sc in $scripts) {
        $attrs = $sc.Groups[1].Value; $body = $sc.Groups[2].Value
        Check ($attrs -notmatch '(?i)\bsrc\s*=') '<script src> is forbidden' $name
        Check ([Text.Encoding]::UTF8.GetByteCount($body) -le 3072) "script must be <= 3 KB (is $([Text.Encoding]::UTF8.GetByteCount($body)) B)" $name
        Check ($body -match 'addEventListener') 'script must register handlers with addEventListener' $name
        foreach ($bad in 'fetch', 'XMLHttpRequest', 'WebSocket', 'sendBeacon', 'eval', 'import', 'location', 'innerHTML', 'outerHTML', 'insertAdjacentHTML', 'postMessage', 'importScripts') {
            Check ($body -notmatch "(?i)\b$bad\b") "script must not use '$bad'" $name
        }
        Check ($body -notmatch '(?i)\bnew\s+Function\b|\bFunction\s*\(') 'script must not use Function(' $name
        Check ($body -notmatch '(?i)document\s*\.\s*write') 'script must not use document.write' $name
        Check ($body -notmatch '(?i)window\s*\.\s*open|\bopen\s*\(') 'script must not open windows' $name
        Check ($body -notmatch '(?i)\.\s*src\s*=|\.\s*href\s*=|\.\s*action\s*=') 'script must not assign src/href/action' $name
        Check ($body -notmatch '(?i)https?:|//') 'script must not contain URLs' $name
    }
    $tags = [regex]::Matches($html, '(?is)<[a-z][^<>]*>')
    $inline = @($tags | Where-Object { $_.Value -match '(?i)\son[a-z]+\s*=' })
    Check ($inline.Count -eq 0) "no inline on*= handlers (found $($inline.Count))" $name

    # (c) forbidden tags / attributes / schemes / URLs
    foreach ($t in 'iframe', 'object', 'embed', 'form', 'base', 'link', 'frame', 'frameset', 'applet', 'portal') {
        Check (([regex]::Matches($html, "(?i)<$t\b")).Count -eq 0) "no <$t> element" $name
    }
    Check ($html -notmatch '(?i)<meta[^>]+http-equiv') 'no <meta http-equiv>' $name
    Check ($html -notmatch '(?i)\ssrc\s*=') 'no src= attributes (no external/embedded resources)' $name
    Check ($html -notmatch '(?i)[\s"''<>]on[a-z]{3,}\s*=') 'no on*= pattern anywhere (not even inside visible text)' $name
    Check ($html -notmatch '(?i)\b(javascript|vbscript|data):') 'no javascript:/vbscript:/data: anywhere' $name
    Check ($html -notmatch '(?i)url\s*\(') 'no CSS url() references' $name
    Check ($html -notmatch '(?i)@import') 'no CSS @import' $name
    $urls = [regex]::Matches($html, '(?i)\b[a-z][a-z0-9+.\-]*://[^\s"''<>)]*')
    foreach ($u in $urls) {
        $ok = ($u.Value -match '^(?i)https://www\.virustotal\.com/gui/file/[0-9a-f]{64}$') -or ($u.Value -match '^(?i)https://github\.com/')
        Check $ok "external URL not allowed: $($u.Value)" $name
    }
    foreach ($h in [regex]::Matches($html, '(?i)\shref\s*=\s*["'']([^"'']*)["'']')) {
        $v = $h.Groups[1].Value
        $ok = $v.StartsWith('#') -or ($v -match '^https://www\.virustotal\.com/gui/file/[0-9a-f]{64}$') -or ($v -match '^https://github\.com/')
        Check $ok "href not allowed: $v" $name
    }
    Check ($html -notmatch '(?i)\s(href|action)\s*=\s*["'']?//') 'no protocol-relative URLs' $name

    # privacy shape: no e-mail addresses / tokens; PC name only in the header chip
    if ($name -ne 'hostile') {
        Check ($html -notmatch '[\w.+\-]+@[\w\-]+\.[\w.\-]+') 'no e-mail addresses' $name
        Check ($html -notmatch '(?i)\b(gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_\-]{20,}\.)') 'no token-like strings' $name
        Check (([regex]::Matches($html, 'DESKTOP-DEMO')).Count -eq 1) 'PC name appears exactly once (header chip)' $name
        Check ($html -notmatch '(?is)<title>[^<]*DESKTOP-DEMO') 'PC name is not in <title>' $name
    }

    # hostile payloads must be inert text
    if ($name -eq 'hostile') {
        Check ($html -notmatch '<script>alert') 'raw <script>alert must not survive' $name
        Check ($html -notmatch '(?i)<img\b') 'no <img> element may be injected' $name
        Check ($html -match '&lt;script&gt;alert\(1\)') 'payload is present only as escaped text' $name
        Check ($html -notmatch 'virustotal\.com/gui/file/javascript') 'invalid hash must not create a VirusTotal link' $name
    }

    # structure: balanced containers
    foreach ($t in 'div', 'details', 'section', 'table', 'ul', 'ol', 'li', 'tr', 'span') {
        $o = ([regex]::Matches($html, "(?i)<$t(\s|>)")).Count; $c = ([regex]::Matches($html, "(?i)</$t>")).Count
        Check ($o -eq $c) "balanced <$t> ($o open / $c close)" $name
    }
    Check ($bytes -lt 400KB) 'report stays under 400 KB' $name

    if ($OutDir) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        $bom = New-Object System.Text.UTF8Encoding($true)
        [IO.File]::WriteAllText((Join-Path $OutDir "report-$name.html"), $html.Replace('<html lang="ar" dir="rtl">', '<html lang="ar" dir="rtl" data-theme="light">'), $bom)
        [IO.File]::WriteAllText((Join-Path $OutDir "report-$name-dark.html"), $html.Replace('<html lang="ar" dir="rtl">', '<html lang="ar" dir="rtl" data-theme="dark">'), $bom)
    }
}

Write-Host ''
if ($script:fails.Count -eq 0) { Write-Host "OK - $($script:checks) assertions passed across $($scenarios.Count) scenarios." -ForegroundColor Green; exit 0 }
Write-Host "$($script:fails.Count) of $($script:checks) assertions FAILED." -ForegroundColor Red
exit 1
