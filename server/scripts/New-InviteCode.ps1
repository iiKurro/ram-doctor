<#
.SYNOPSIS
  OPTIONAL helper for the relay's "code mode". Not needed in the default open mode.

.DESCRIPTION
  Generates a strong, readable invite code (80 bits, e.g. RD-7K3M-QX9P-2WTA-H4NE) and prints the JSON for the
  INVITE_CODES secret. Use -ExistingJson to add to the codes you already have, -Revoke to remove one.
  Nothing is sent anywhere; paste the printed JSON into:  npx wrangler secret put INVITE_CODES

.EXAMPLE
  powershell -File server\scripts\New-InviteCode.ps1 -Label ali
.EXAMPLE
  powershell -File server\scripts\New-InviteCode.ps1 -Label sara -ExistingJson '{"RD-AAAA-BBBB-CCCC-DDDD":"ali"}'
.EXAMPLE
  powershell -File server\scripts\New-InviteCode.ps1 -Revoke RD-AAAA-BBBB-CCCC-DDDD -ExistingJson '{"RD-AAAA-BBBB-CCCC-DDDD":"ali"}'
#>
[CmdletBinding()]
param(
    [string]$Label = 'friend',
    [string]$ExistingJson = '',
    [string]$Revoke = ''
)

$ErrorActionPreference = 'Stop'

function ConvertTo-OrderedMap([string]$json) {
    $map = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($json)) { return $map }
    $obj = $json | ConvertFrom-Json
    foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
    return $map
}

function New-Code {
    # Crockford-style alphabet without look-alikes (no 0/O, 1/I/L, U): 16 symbols x 5 bits = 80 bits of randomness
    $alphabet = 'ABCDEFGHJKMNPQRSTVWXYZ23456789'.ToCharArray()   # 30 symbols -> rejection-sample to stay unbiased
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $buf = New-Object byte[] 1
    $chars = New-Object System.Collections.Generic.List[char]
    while ($chars.Count -lt 16) {
        $rng.GetBytes($buf)
        if ($buf[0] -lt (256 - (256 % $alphabet.Length))) { $chars.Add($alphabet[$buf[0] % $alphabet.Length]) }
    }
    $rng.Dispose()
    $s = -join $chars
    return 'RD-{0}-{1}-{2}-{3}' -f $s.Substring(0, 4), $s.Substring(4, 4), $s.Substring(8, 4), $s.Substring(12, 4)
}

$map = ConvertTo-OrderedMap $ExistingJson

if ($Revoke) {
    if ($map.Contains($Revoke)) { $map.Remove($Revoke) | Out-Null; Write-Host "Revoked: $Revoke" -ForegroundColor Yellow }
    else { Write-Host "That code is not in the existing JSON - nothing removed." -ForegroundColor Yellow }
} else {
    if ($Label -notmatch '^[\p{L}\p{Nd} _.-]{1,40}$') { throw 'Label: 1-40 letters, digits, space, _ . or - only.' }
    $code = New-Code
    $map[$code] = $Label
    Write-Host ''
    Write-Host "New invite code for '$Label':" -ForegroundColor Cyan
    Write-Host "    $code" -ForegroundColor Green
    Write-Host '    (give it to that person; it goes into src/share.config.json "code" or is typed in the app)'
}

$compact = ($map | ConvertTo-Json -Compress)
if ($map.Count -eq 0) { $compact = '{}' }
Write-Host ''
Write-Host 'Value for the INVITE_CODES secret (all codes, one line):' -ForegroundColor Cyan
Write-Host "    $compact"
Write-Host ''
Write-Host 'Apply it:' -ForegroundColor Cyan
Write-Host '    cd server\worker'
Write-Host '    npx wrangler secret put INVITE_CODES     # paste the line above, press Enter'
Write-Host ''
if ($map.Count -eq 0) { Write-Host 'No codes left: uploads are open again unless REQUIRE_CODE=true (then the relay refuses to run).' -ForegroundColor Yellow }
