# ==========================================================================================
#  RAM Doctor - HTML report generator (src/lib/Report.ps1)
#
#  New-RamReportHtml $data  ->  one self-contained HTML string (inline CSS + a few lines of JS,
#  no external fonts / scripts / images; the report itself never makes network requests).
#  $data is the object built by RAM-Doctor.ps1 (schema: Sys, Memory, Verdict, Observations,
#  TopProcesses, ByProgram, TopGrowers, PoolNonPaged, PoolPaged, PoolGrowing, PoolAvailable,
#  Suspects, Drivers3p, Hidden, Defender, Exhaustion, Warnings, ItemCounts).
#
#  Design: Windows 11 / Fluent look, Arabic RTL first (English technical terms stay LTR),
#  light + dark (follows the system, plus a toggle), responsive down to a phone, and a clean
#  print stylesheet (A4).
#
#  INERT-REPORT CONTRACT (checked by tests/fixtures/Test-ReportSafety.ps1):
#    - marker comment  <!-- ram-doctor-report vX.Y.Z -->  right after the doctype
#    - at most ONE inline <script> (<= 3 KB, addEventListener only, no inline on*= handlers, no
#      network / eval / navigation APIs), no iframe/object/embed/form/base/link/meta-refresh
#    - no javascript:/data: URLs; the only external URLs are https://www.virustotal.com/gui/file/<sha256>
#      (and github.com links when added deliberately). Every text value goes through E().
#
#  Privacy note: the Windows user name and PC name appear only in the header meta chips (and
#  inside file paths) so that a later redaction step can find them reliably. No e-mail addresses
#  or tokens are ever embedded.
#
#  Keep this file UTF-8 WITH BOM (Arabic text).
# ==========================================================================================

$script:RI = [System.Globalization.CultureInfo]::InvariantCulture

# HTML-encode + defuse anything that could turn into a link/script scheme (the report must stay inert:
# the only real URLs in it are the VirusTotal links built from a validated SHA-256).
function E($s) {
    $t = [System.Net.WebUtility]::HtmlEncode([string]$s)
    $t = [regex]::Replace($t, '(?i)\b(https?|ftp|ftps|wss?|file|javascript|vbscript|data):', '$1&#58;')
    # visible text can never look like an attribute assignment (on*=, src=, href=...) even to a naive scanner
    [regex]::Replace($t, '(?i)\b(on[a-z]{3,}|src|srcdoc|href|action|formaction)\s*=', '$1&#61;')
}
# Escapes prose and isolates every run of Latin letters / numbers / units (file names, "Non-paged pool", "9.6 GB")
# in its own <bdi dir=ltr>, so punctuation and numbers keep the right order inside Arabic sentences.
function Rich($s) {
    $text = [string]$s
    # a Latin run may contain ':' (IP:port, drive letters, URLs) - E() still defuses schemes inside each run
    # words are joined by a space, or by a space + operator ("Working Sets − Non-paged", "A = B", "A / B") so a whole
    # Latin phrase/formula stays ONE left-to-right run
    # a run starts with a letter/digit and ENDS with one too: trailing punctuation (". : , )") stays outside, in the Arabic flow
    $tok = '[A-Za-z0-9\[](?:[A-Za-z0-9._\-+/%\[\]~:]*[A-Za-z0-9\]%~])?'
    $rx = $tok + '(?:(?: [−+=×/·&])? ' + $tok + ')*'
    $o = New-Object System.Text.StringBuilder
    $pos = 0
    foreach ($m in [regex]::Matches($text, $rx)) {
        if ($m.Index -gt $pos) { [void]$o.Append((E $text.Substring($pos, $m.Index - $pos))) }
        [void]$o.Append("<bdi dir='ltr'>").Append((E $m.Value)).Append('</bdi>')
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $text.Length) { [void]$o.Append((E $text.Substring($pos))) }
    $o.ToString()
}
function Fx($v, [string]$f = '0.##') { try { ([double]$v).ToString($f, $script:RI) } catch { '0' } }
function Ic([string]$n) { "<svg class='ic' aria-hidden='true' focusable='false'><use href='#i-$n'/></svg>" }
function Chev { "<svg class='ic chev' aria-hidden='true' focusable='false'><use href='#i-chev'/></svg>" }
function Bidi($s) { "<bdi dir='ltr'>$(E $s)</bdi>" }
function Val($v, [string]$unit) { "<bdi dir='ltr'>$(Fx $v)&nbsp;<small>$unit</small></bdi>" }
function Pill([string]$kind, [string]$text, [string]$icon = '') {
    $i = if ($icon) { (Ic $icon) } else { '' }
    "<span class='pill p-$kind'>$i$(E $text)</span>"
}

function TrustAr([string]$t) {
    switch ($t) {
        'OS' { 'ويندوز (موقّع)' }
        'MS' { 'مايكروسوفت (موقّع)' }
        'Signed' { 'موقّع من جهة أخرى' }
        'Unsigned' { 'غير موقّع' }
        'Tampered' { 'توقيع تالف' }
        'Untrusted' { 'توقيع غير موثوق' }
        'Script' { 'ملف سكربت' }
        'Missing' { 'الملف غير موجود' }
        default { 'غير معروف' }
    }
}
# trust -> pill kind
function TrustClass([string]$t) {
    switch ($t) {
        { $_ -in 'OS', 'MS' } { 'ok' }
        'Signed' { 'info' }
        { $_ -in 'Unsigned', 'Script' } { 'warn' }
        { $_ -in 'Tampered', 'Untrusted', 'Missing' } { 'bad' }
        default { 'mute' }
    }
}
function LevelAr([string]$l) {
    switch ($l) { 'high' { 'عالٍ' } 'med' { 'متوسط' } 'low' { 'منخفض' } 'ok' { 'سليم' } default { 'معلومة' } }
}
# observation level -> pill kind
function LvKind([string]$l) {
    switch ($l) { 'high' { 'bad' } 'med' { 'warn' } 'low' { 'info' } 'ok' { 'ok' } default { 'mute' } }
}
function LvIcon([string]$l) {
    switch ($l) { 'high' { 'error' } 'med' { 'warn' } 'ok' { 'check' } default { 'info' } }
}
function RiskKey([string]$r) { switch ($r) { 'High' { 'high' } 'Medium' { 'med' } default { 'low' } } }

function TrustPill([string]$t, [string]$publisher = '') {
    $p = if ($publisher) { " <span class='muted'><bdi dir='ltr'>$(E $publisher)</bdi></span>" } else { '' }
    "$(Pill (TrustClass $t) (TrustAr $t))$p"
}

# status colour of a KPI tile from a value and (warn, bad) thresholds
function KStatus([double]$v, [double]$warn, [double]$bad) { if ($v -ge $bad) { 'bad' } elseif ($v -ge $warn) { 'warn' } else { 'ok' } }

function Kpi([string]$label, [string]$valueHtml, [string]$sub, [string]$status, [double]$pct) {
    $w = Fx ([math]::Max(0, [math]::Min(100, $pct))) '0.#'
    "<div class='kpi k-$status' role='listitem'><div class='kpi-l'>$(E $label)</div><div class='kpi-v'>$valueHtml</div><div class='meter' aria-hidden='true'><i style='width:$w%'></i></div><div class='kpi-s'>$sub</div></div>"
}

function Signed-Delta($v, [string]$unit = 'MB') {
    $x = [double]$v
    $cls = if ($x -ge 30) { 'neg' } elseif ($x -le -30) { 'pos' } else { 'zero' }
    $sign = if ($x -gt 0) { '+' } else { '' }
    "<span class='delta $cls'><bdi dir='ltr'>$sign$(Fx $x '0.#')&nbsp;<small>$unit</small></bdi></span>"
}

# ------------------------------------------------------------------------------------------
$script:ReportDarkTokens = @'
--bg:#202020;--bar:rgba(32,32,32,.82);--layer:#2b2b2b;--layer2:#323232;--layer3:#383838;--stroke:#3d3d3d;--stroke2:#505050;
--text:#ffffff;--text2:#cdcdcd;--text3:#a6a6a6;--accent:#60cdff;--accent-h:#78d6ff;--on-accent:#00131c;--accent-soft:#16384a;
--ok:#6ccb5f;--ok-bg:#2a3a22;--ok-st:#3f5a33;--warn:#fce100;--warn-bg:#43391a;--warn-st:#6b5b1d;
--bad:#ff99a4;--bad-bg:#442726;--bad-st:#6e3a3b;--info:#60cdff;--info-bg:#16384a;--info-st:#245a78;
--seg1:#4a9be8;--seg2:#2d5f94;--seg3:#9a82e6;--seg4:#f0aa3a;--seg5:#f06a60;--seg6:#7b8794;--seg7:#4a4f55;
--shadow:0 1px 2px rgba(0,0,0,.4),0 4px 14px rgba(0,0,0,.25);color-scheme:dark;
'@

$script:ReportLightTokens = @'
--bg:#f3f3f3;--bar:rgba(243,243,243,.84);--layer:#ffffff;--layer2:#f9f9f9;--layer3:#f0f0f0;--stroke:#e5e5e5;--stroke2:#cfcfcf;
--text:#1a1a1a;--text2:#505050;--text3:#6b6b6b;--accent:#0067c0;--accent-h:#1a77c9;--on-accent:#ffffff;--accent-soft:#e8f1fa;
--ok:#0f6b0f;--ok-bg:#dff6dd;--ok-st:#b6e2b3;--warn:#7a4a00;--warn-bg:#fff4ce;--warn-st:#f0d98a;
--bad:#a8231b;--bad-bg:#fde7e9;--bad-st:#f2b4b9;--info:#005a9e;--info-bg:#e8f1fa;--info-st:#b6d4ee;
--seg1:#2f7fd1;--seg2:#9cc6ee;--seg3:#7a5cd1;--seg4:#e0961a;--seg5:#d9453a;--seg6:#9aa5b1;--seg7:#d4d8dd;
--shadow:0 1px 2px rgba(0,0,0,.06),0 2px 10px rgba(0,0,0,.045);color-scheme:light;
'@

$script:ReportCss = @'
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;scroll-behavior:smooth;scroll-padding-top:120px}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.75 "Segoe UI Variable Text","Segoe UI Variable","Segoe UI",Tahoma,"Noto Sans Arabic","Noto Sans",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
:root{--r:8px;--mono:"Cascadia Mono","Cascadia Code",Consolas,"Liberation Mono",monospace}
a{color:var(--accent);text-underline-offset:3px}a:hover{color:var(--accent-h)}
bdi{unicode-bidi:isolate}small{font-size:.72em;font-weight:500;color:var(--text3)}
.wrap{max-width:1080px;margin:0 auto;padding:0 20px}
.skip{position:absolute;inset-inline-start:12px;top:-60px;background:var(--accent);color:var(--on-accent);padding:8px 14px;border-radius:6px;z-index:50;text-decoration:none}
.skip:focus{top:10px}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:4px}
.ic{width:1.15em;height:1.15em;flex:none;stroke:currentColor;fill:none;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round;vertical-align:-.2em}
.muted{color:var(--text2)}.mono{font-family:var(--mono);font-size:12.5px;direction:ltr;unicode-bidi:isolate;word-break:break-all}

/* app bar */
.appbar{position:sticky;top:0;z-index:20;background:var(--bar);backdrop-filter:saturate(1.6) blur(18px);-webkit-backdrop-filter:saturate(1.6) blur(18px);border-bottom:1px solid var(--stroke)}
.appbar .wrap{display:flex;align-items:center;gap:14px;padding-top:12px;padding-bottom:12px}
.logo{width:40px;height:40px;border-radius:10px;background:linear-gradient(145deg,var(--accent),#3a96dd);color:var(--on-accent);display:grid;place-items:center;flex:none;box-shadow:var(--shadow)}
.logo .ic{width:22px;height:22px;stroke-width:1.9}
.ttl{min-width:0;flex:1}.ttl h1{margin:0;font-size:19px;line-height:1.3;font-weight:650}.ttl p{margin:0;color:var(--text2);font-size:12.5px}
.tools{display:flex;gap:8px}
.btn{display:inline-flex;align-items:center;gap:8px;border:1px solid var(--stroke2);background:var(--layer);color:var(--text);padding:6px 13px;border-radius:6px;font:inherit;font-size:13px;cursor:pointer;text-decoration:none;min-height:34px}
.btn:hover{background:var(--layer2)}.btn:active{background:var(--layer3)}
.btn.sm{padding:2px 9px;min-height:26px;font-size:12px}
.btn-icon{padding:6px 9px}
.toc{border-bottom:1px solid var(--stroke);background:var(--bar);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px)}
.toc .wrap{display:flex;gap:6px;overflow-x:auto;padding-top:8px;padding-bottom:8px;scrollbar-width:thin}
.toc a{white-space:nowrap;text-decoration:none;color:var(--text2);padding:3px 12px;border-radius:99px;font-size:13px;border:1px solid transparent}
.toc a:hover{background:var(--layer);border-color:var(--stroke);color:var(--text)}

/* generic blocks */
main{padding-bottom:34px}
section.blk{margin-top:30px}
h2.sec{display:flex;align-items:center;gap:10px;font-size:18px;line-height:1.4;margin:0 0 12px;font-weight:650}
h2.sec .ic{color:var(--accent);width:1.3em;height:1.3em}
h3{font-size:15px;margin:18px 0 8px;font-weight:650}
.lead{color:var(--text2);margin:0 0 12px;font-size:14px}
.card{background:var(--layer);border:1px solid var(--stroke);border-radius:var(--r);box-shadow:var(--shadow);padding:18px 20px}
.card+.card{margin-top:12px}
.meta{display:flex;flex-wrap:wrap;gap:8px;margin:18px 0 0}
.chip{display:inline-flex;align-items:center;gap:6px;background:var(--layer);border:1px solid var(--stroke);border-radius:99px;padding:2px 12px;font-size:12.5px;color:var(--text2)}
.chip b{color:var(--text);font-weight:600}

/* pills */
.pill{display:inline-flex;align-items:center;gap:5px;padding:1px 10px;border-radius:99px;font-size:12px;font-weight:650;border:1px solid transparent;white-space:nowrap;line-height:1.65}
.p-ok{background:var(--ok-bg);color:var(--ok);border-color:var(--ok-st)}.p-warn{background:var(--warn-bg);color:var(--warn);border-color:var(--warn-st)}
.p-bad{background:var(--bad-bg);color:var(--bad);border-color:var(--bad-st)}.p-info{background:var(--info-bg);color:var(--info);border-color:var(--info-st)}
.p-mute{background:var(--layer3);color:var(--text2);border-color:var(--stroke)}

/* hero (InfoBar) */
.hero{display:flex;gap:16px;align-items:flex-start;margin-top:16px;padding:20px 22px;border-radius:var(--r);border:1px solid var(--stroke);background:var(--layer);box-shadow:var(--shadow);border-inline-start:6px solid var(--accent)}
.hero-ok{background:var(--ok-bg);border-color:var(--ok-st);border-inline-start-color:var(--ok)}
.hero-info{background:var(--info-bg);border-color:var(--info-st);border-inline-start-color:var(--info)}
.hero-warn{background:var(--warn-bg);border-color:var(--warn-st);border-inline-start-color:var(--warn)}
.hero-bad{background:var(--bad-bg);border-color:var(--bad-st);border-inline-start-color:var(--bad)}
.hero-ic{width:46px;height:46px;border-radius:50%;display:grid;place-items:center;flex:none;background:var(--layer);box-shadow:var(--shadow)}
.hero-ic .ic{width:26px;height:26px;stroke-width:2}
.hero-ok .hero-ic{color:var(--ok)}.hero-info .hero-ic{color:var(--info)}.hero-warn .hero-ic{color:var(--warn)}.hero-bad .hero-ic{color:var(--bad)}
.hero-body{min-width:0;flex:1}
.eyebrow{margin:0;font-size:12px;letter-spacing:.02em;color:var(--text2);font-weight:600}
.hero h2{margin:2px 0 8px;font-size:22px;line-height:1.45;font-weight:700}
.obs{list-style:none;margin:10px 0 0;padding:0;display:grid;gap:10px}
.obs li{display:grid;grid-template-columns:auto 1fr;gap:4px 12px;align-items:baseline}
.obs b{font-weight:650}.obs .b{grid-column:2;color:var(--text2);font-size:13.5px;margin-top:-2px}
.hero .fine{margin:14px 0 0;color:var(--text2);font-size:12.5px;display:flex;gap:6px;align-items:center}
.summary{display:flex;flex-wrap:wrap;gap:8px;margin-top:14px}

/* KPI tiles */
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(176px,1fr));gap:12px;margin-top:16px}
.kpi{background:var(--layer);border:1px solid var(--stroke);border-radius:var(--r);padding:14px 16px;box-shadow:var(--shadow);border-top:3px solid var(--stroke2)}
.k-ok{border-top-color:var(--ok)}.k-warn{border-top-color:var(--warn)}.k-bad{border-top-color:var(--bad)}
.kpi-l{font-size:12.5px;color:var(--text2);font-weight:600}
.kpi-v{font-size:28px;line-height:1.25;font-weight:650;font-variant-numeric:tabular-nums;margin:2px 0 8px}
.kpi-s{font-size:12px;color:var(--text3);margin-top:6px;line-height:1.5}
.meter{height:6px;border-radius:99px;background:var(--layer3);overflow:hidden}
.meter>i{display:block;height:100%;border-radius:99px;background:var(--accent)}
.k-ok .meter>i{background:var(--ok)}.k-warn .meter>i{background:var(--warn)}.k-bad .meter>i{background:var(--bad)}

/* memory map */
.stack{display:flex;gap:2px;height:32px;border-radius:8px;overflow:hidden;background:var(--layer3);border:1px solid var(--stroke)}
.stack i{display:block;height:100%;min-width:2px}
.legend{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:8px 18px;margin:14px 0 0;padding:0;list-style:none}
.legend li{display:flex;align-items:center;gap:9px;font-size:13px}
.legend .sw{width:12px;height:12px;border-radius:3px;flex:none}
.legend .n{flex:1;color:var(--text2)}.legend .v{font-weight:650;font-variant-numeric:tabular-nums}.legend .p{color:var(--text3);font-size:12px;min-width:44px;text-align:end}
.s1{background:var(--seg1)}.s2{background:var(--seg2)}.s3{background:var(--seg3)}.s4{background:var(--seg4)}.s5{background:var(--seg5)}.s6{background:var(--seg6)}.s7{background:var(--seg7)}
.note{color:var(--text2);font-size:13px;margin:12px 0 0}
.formula{display:inline-block;direction:ltr;text-align:left;unicode-bidi:isolate;font:12.5px/1.6 var(--mono);background:var(--layer2);border:1px solid var(--stroke);border-radius:6px;padding:6px 12px;max-width:100%;overflow-wrap:anywhere}
.grow{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin-top:6px}
.grow div{background:var(--layer2);border:1px solid var(--stroke);border-radius:6px;padding:8px 12px}
.grow span{display:block;font-size:12px;color:var(--text2)}
.delta{font-weight:650;font-variant-numeric:tabular-nums}.delta.neg{color:var(--bad)}.delta.pos{color:var(--ok)}.delta.zero{color:var(--text)}

/* tables */
.tw{overflow:auto;border:1px solid var(--stroke);border-radius:var(--r);background:var(--layer);max-height:560px}
table{width:100%;border-collapse:separate;border-spacing:0;font-size:13.5px}
th,td{padding:9px 12px;text-align:start;vertical-align:top;border-bottom:1px solid var(--stroke)}
th{background:var(--layer2);font-weight:650;color:var(--text2);font-size:12.5px;white-space:nowrap;position:sticky;top:0;z-index:1}
tbody tr:last-child td{border-bottom:0}tbody tr:hover td{background:var(--layer2)}
td.num,th.num{text-align:end;font-variant-numeric:tabular-nums;white-space:nowrap}
td.mono{word-break:normal;white-space:nowrap}
.bcell{position:relative;min-width:150px}.bcell .bg{position:absolute;inset-block:5px;inset-inline-start:0;border-radius:4px;background:var(--accent-soft);z-index:0}
.bcell span{position:relative;z-index:1;font-variant-numeric:tabular-nums}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chipf{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--stroke);background:var(--layer2);border-radius:6px;padding:1px 8px;font-size:12.5px}

/* findings */
details.sus,details.group{background:var(--layer);border:1px solid var(--stroke);border-radius:var(--r);box-shadow:var(--shadow);border-inline-start:5px solid var(--stroke2)}
details.sus+details.sus,details.sus+details.group,details.group+details.sus{margin-top:10px}
details.sus.r-high{border-inline-start-color:var(--bad)}details.sus.r-med{border-inline-start-color:var(--warn)}details.sus.r-low{border-inline-start-color:var(--info)}
summary{list-style:none;cursor:pointer;display:flex;align-items:center;gap:12px;padding:14px 18px;border-radius:var(--r)}
summary::-webkit-details-marker{display:none}
summary:hover{background:var(--layer2)}
summary .chev{margin-inline-start:auto;transition:transform .15s}details[open]>summary .chev{transform:rotate(180deg)}
.sus-name{font-weight:650;font-size:15px;direction:ltr;unicode-bidi:isolate}
.score{display:inline-flex;align-items:center;gap:8px;font-size:12px;color:var(--text2)}
.score .meter{width:70px}.sus.r-high .meter>i{background:var(--bad)}.sus.r-med .meter>i{background:var(--warn)}.sus.r-low .meter>i{background:var(--info)}
.sus-body{padding:2px 20px 18px}
dl.kv{display:grid;grid-template-columns:minmax(110px,150px) 1fr;gap:8px 16px;margin:6px 0 0}
dl.kv dt{color:var(--text2);font-size:13px}dl.kv dd{margin:0;min-width:0}
.why{list-style:none;margin:6px 0 0;padding:0;display:grid;gap:6px}
.why li{display:flex;gap:9px;align-items:flex-start}.why .ic{color:var(--warn);margin-top:.25em}
.ctx{margin:6px 0 0;padding-inline-start:20px;color:var(--text2)}
.callout{display:flex;gap:10px;align-items:flex-start;background:var(--info-bg);border:1px solid var(--info-st);color:var(--text);border-radius:6px;padding:9px 12px;font-size:13.5px;margin:12px 0 0}
.callout .ic{color:var(--info);margin-top:.2em}
.group>summary{font-weight:650}

/* steps */
ol.steps{list-style:none;counter-reset:s;margin:0;padding:0;display:grid;gap:10px}
ol.steps li{counter-increment:s;display:grid;grid-template-columns:34px 1fr;gap:12px;background:var(--layer);border:1px solid var(--stroke);border-radius:var(--r);padding:12px 16px;box-shadow:var(--shadow)}
ol.steps li::before{content:counter(s);width:34px;height:34px;border-radius:50%;display:grid;place-items:center;background:var(--accent);color:var(--on-accent);font-weight:700}
ol.steps b{display:block;margin-bottom:2px}ol.steps span{color:var(--text2);font-size:13.5px}
pre.ev{margin:8px 0 0;padding:10px 12px;background:var(--layer2);border:1px solid var(--stroke);border-radius:6px;white-space:pre-wrap;font:12.5px/1.6 var(--mono);direction:ltr;text-align:left;unicode-bidi:isolate}
.warns{margin:10px 0 0;padding-inline-start:20px;color:var(--warn)}
footer{border-top:1px solid var(--stroke);margin-top:30px;padding:18px 0 40px;color:var(--text2);font-size:12.5px}
footer .wrap{display:flex;flex-wrap:wrap;gap:6px 18px;justify-content:space-between}
.empty{display:flex;align-items:center;gap:10px;color:var(--text2)}.empty .ic{color:var(--ok);width:1.5em;height:1.5em}

@media (max-width:720px){
 body{font-size:14.5px}.wrap{padding:0 14px}
 .appbar .wrap{flex-wrap:wrap}.tools{width:100%}.tools .btn{flex:1;justify-content:center}
 .hero{flex-direction:column;padding:16px}.hero h2{font-size:19px}
 dl.kv{grid-template-columns:1fr;gap:2px}dl.kv dt{margin-top:8px}
 .kpis{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.kpis .kpi:first-child{grid-column:1/-1}.kpi{padding:12px 14px}
 .kpi-v{font-size:24px}.score .meter{display:none}
 summary{flex-wrap:wrap;padding:12px 14px}.sus-body{padding:2px 14px 14px}
}
@media (prefers-reduced-motion:reduce){*{transition:none!important;scroll-behavior:auto!important}}

@media print{
 :root,:root[data-theme="dark"],:root[data-theme="light"]{PRINTTOKENS}
 @page{size:A4;margin:13mm}
 body{background:#fff;font-size:11.5px;line-height:1.55}
 .appbar{position:static;backdrop-filter:none;background:#fff;border-bottom:2px solid #1a1a1a}.toc,.tools,.skip,.btn{display:none!important}
 .wrap{max-width:none;padding:0}
 .card,.kpi,.hero,details.sus,details.group,ol.steps li,tr,.legend li,.grow div{break-inside:avoid;box-shadow:none}
 section.blk{margin-top:16px}h2.sec{break-after:avoid}.tw{max-height:none;overflow:visible}th{position:static}
 summary .chev{display:none}details.sus,details.group{border-color:#bbb}
 *{-webkit-print-color-adjust:exact;print-color-adjust:exact}
}
'@

$script:ReportSprite = @'
<svg style="position:absolute;width:0;height:0;overflow:hidden" aria-hidden="true" focusable="false"><defs>
<symbol id="i-check" viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></symbol>
<symbol id="i-check-circle" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9.5"/><path d="M7.8 12.4l3 3 5.6-6.2"/></symbol>
<symbol id="i-warn" viewBox="0 0 24 24"><path d="M12 3.8l9.2 16H2.8z"/><path d="M12 10v4.6M12 17.4v.2"/></symbol>
<symbol id="i-error" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9.5"/><path d="M12 7.2v6M12 16.6v.2"/></symbol>
<symbol id="i-info" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9.5"/><path d="M12 11v5.4M12 7.6v.2"/></symbol>
<symbol id="i-shield" viewBox="0 0 24 24"><path d="M12 3l7.5 3v5.6c0 4.4-3.1 8.1-7.5 9.9-4.4-1.8-7.5-5.5-7.5-9.9V6z"/><path d="M8.6 12.2l2.5 2.5 4.4-4.9"/></symbol>
<symbol id="i-chip" viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9.5 9.5h5v5h-5zM9 3v3M15 3v3M9 18v3M15 18v3M3 9h3M3 15h3M18 9h3M18 15h3"/></symbol>
<symbol id="i-layers" viewBox="0 0 24 24"><path d="M12 3l9 5-9 5-9-5z"/><path d="M3 12.5l9 5 9-5M3 16.8l9 5 9-5"/></symbol>
<symbol id="i-list" viewBox="0 0 24 24"><path d="M9 6h11M9 12h11M9 18h11M4.5 6h.1M4.5 12h.1M4.5 18h.1"/></symbol>
<symbol id="i-bug" viewBox="0 0 24 24"><path d="M9 7.5a3 3 0 016 0v1H9zM7 9h10v5a5 5 0 01-10 0zM3 12h4M17 12h4M4.5 6.5L8 9M19.5 6.5L16 9M5 19l3-2M19 19l-3-2"/></symbol>
<symbol id="i-eye" viewBox="0 0 24 24"><path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/></symbol>
<symbol id="i-driver" viewBox="0 0 24 24"><rect x="3" y="7" width="18" height="10" rx="2"/><path d="M7 11v2M11 11v2M15 11v2M3 20h18"/></symbol>
<symbol id="i-doc" viewBox="0 0 24 24"><path d="M7 3h7l4 4v14H7z"/><path d="M14 3v4h4M10 12h5M10 16h5"/></symbol>
<symbol id="i-steps" viewBox="0 0 24 24"><path d="M4 19h5v-5h5V9h6M16 5l4 4-4 4"/></symbol>
<symbol id="i-sun" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.2 5.2l1.4 1.4M17.4 17.4l1.4 1.4M18.8 5.2l-1.4 1.4M6.6 17.4l-1.4 1.4"/></symbol>
<symbol id="i-moon" viewBox="0 0 24 24"><path d="M20 14.5A8.5 8.5 0 019.5 4a8.5 8.5 0 1010.5 10.5z"/></symbol>
<symbol id="i-print" viewBox="0 0 24 24"><path d="M7 8V3h10v5M7 17H4.5v-7h15v7H17M7 14h10v7H7z"/></symbol>
<symbol id="i-ext" viewBox="0 0 24 24"><path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 01-1 1H5a1 1 0 01-1-1V7a1 1 0 011-1h5"/></symbol>
<symbol id="i-chev" viewBox="0 0 24 24"><path d="M6 9.5l6 6 6-6"/></symbol>
</defs></svg>
'@

# The ONLY script in the report: theme toggle, print button, copy buttons, open-all-details on print.
# Arrow functions + addEventListener only. No network / navigation / eval-like APIs (see contract above).
$script:ReportJs = @'
(()=>{
const r=document.documentElement,b=document.getElementById('themeBtn');
const cur=()=>r.getAttribute('data-theme')||(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light');
const paint=()=>{if(!b)return;const d=cur()==='dark';b.querySelector('use').setAttribute('href',d?'#i-sun':'#i-moon');b.setAttribute('aria-label',d?'وضع فاتح':'وضع داكن');b.title=b.getAttribute('aria-label')};
try{const s=localStorage.getItem('rd-theme');if(s)r.setAttribute('data-theme',s)}catch(e){}
if(b){b.addEventListener('click',()=>{const n=cur()==='dark'?'light':'dark';r.setAttribute('data-theme',n);try{localStorage.setItem('rd-theme',n)}catch(e){}paint()});paint()}
const p=document.getElementById('printBtn');if(p)p.addEventListener('click',()=>window.print());
let was=[];
addEventListener('beforeprint',()=>{was=[...document.querySelectorAll('details')].map(d=>[d,d.open]);was.forEach(x=>{x[0].open=true})});
addEventListener('afterprint',()=>{was.forEach(x=>{x[0].open=x[1]})});
document.addEventListener('click',e=>{const t=e.target.closest&&e.target.closest('[data-copy]');if(!t)return;e.preventDefault();e.stopPropagation();
const o=t.textContent;navigator.clipboard.writeText(t.getAttribute('data-copy')).then(()=>{t.textContent='تم النسخ';setTimeout(()=>{t.textContent=o},1400)},()=>{})});
})();
'@

# ------------------------------------------------------------------------------------------
function New-RamReportHtml($d) {
    $sb = New-Object System.Text.StringBuilder(131072)
    $script:rptLines = 0
    $script:rptTrim = [bool]('RamDoc.Native' -as [type])   # the scan loads the native helper; the tests render without it
    # every few hundred lines drop the garbage created by the helper calls (and hand idle pages back to the OS),
    # so building the page never balloons the footprint of a tool that runs on RAM-starved PCs
    function L([string]$t) {
        [void]$sb.AppendLine($t); $script:rptLines++
        if ($script:rptLines % 200 -eq 0) { [GC]::Collect(); if ($script:rptTrim) { [RamDoc.Native]::TrimWorkingSet() } }
    }

    $m = $d.Memory
    $s = $d.Sys
    $total = [double]$m.TotalGB; if ($total -le 0) { $total = 1 }
    $light = $script:ReportLightTokens.Replace("`r", '').Replace("`n", '')
    $dark = $script:ReportDarkTokens.Replace("`r", '').Replace("`n", '')
    $css = $script:ReportCss.Replace('PRINTTOKENS', $light)

    # ---------------------------------------------------------------- head
    L '<!doctype html>'
    L "<!-- ram-doctor-report v$($d.Version) -->"
    L '<html lang="ar" dir="rtl"><head><meta charset="utf-8">'
    L '<meta name="viewport" content="width=device-width, initial-scale=1">'
    L '<meta name="color-scheme" content="light dark">'
    L "<meta name=""generator"" content=""RAM Doctor $(E $d.Version)"">"
    L '<title>تقرير فاحص الذاكرة - RAM Doctor</title>'
    L "<style>:root{$light}@media (prefers-color-scheme:dark){:root:not([data-theme=""light""]){$dark}}:root[data-theme=""dark""]{$dark}"
    L $css
    L '</style></head><body>'
    L $script:ReportSprite
    L '<a class="skip" href="#main">تخطَّ إلى المحتوى</a>'

    # ---------------------------------------------------------------- app bar + toc
    L '<header class="appbar"><div class="wrap">'
    L "<div class='logo'>$(Ic 'shield')</div>"
    L "<div class='ttl'><h1>تقرير فاحص الذاكرة</h1><p>RAM Doctor <bdi dir='ltr'>v$(E $d.Version)</bdi> &middot; <bdi dir='ltr'>$(E $d.Created)</bdi></p></div>"
    L "<div class='tools'><button class='btn btn-icon' id='themeBtn' type='button' aria-label='وضع داكن'>$(Ic 'moon')</button><button class='btn' id='printBtn' type='button'>$(Ic 'print')<span>$(Rich 'طباعة أو حفظ PDF')</span></button></div>"
    L '</div></header>'
    $toc = "<a href='#overview'>نظرة عامة</a><a href='#memory'>الذاكرة</a><a href='#consumers'>المستهلكون</a><a href='#pool'>ذاكرة النواة</a><a href='#suspects'>الملفات المشبوهة</a><a href='#hidden'>العمليات المخفية</a><a href='#drivers'>التعريفات</a><a href='#evidence'>أدلة إضافية</a><a href='#next'>الخطوات</a>"
    L "<nav class='toc' aria-label='أقسام التقرير'><div class='wrap'>$toc</div></nav>"
    L '<main id="main" class="wrap">'

    # ---------------------------------------------------------------- overview: meta + hero
    $adminChip = if ($s.IsAdmin) { "<span class='chip'>$(Ic 'check') صلاحيات المدير: <b>نعم</b></span>" } else { "<span class='chip' style='color:var(--warn)'>$(Ic 'warn') صلاحيات المدير: <b>لا (النتائج ناقصة)</b></span>" }
    L "<div class='meta' aria-label='معلومات الجهاز'>"
    L "<span class='chip'>$(Ic 'chip') الجهاز: <b>$(Bidi $s.Host)</b></span><span class='chip'>المستخدم: <b>$(Bidi $s.User)</b></span>"
    L "<span class='chip'>$(E $s.OS)</span><span class='chip'>مدة التشغيل: <b>$(Bidi $s.Uptime)</b></span>$adminChip"
    L "<span class='chip'>المعالج: $(Bidi $s.Cpu)</span>"
    if ($s.Gpus) { L "<span class='chip'>الشاشة: $(Bidi $s.Gpus)</span>" }
    L '</div>'

    $vk = LvKind $d.Verdict.Level
    $heroIcon = switch ($vk) { 'ok' { 'check-circle' } 'info' { 'info' } 'warn' { 'warn' } default { 'error' } }
    L "<section id='overview' class='hero hero-$vk' aria-labelledby='t-overview'>"
    L "<div class='hero-ic'>$(Ic $heroIcon)</div><div class='hero-body'>"
    L "<p class='eyebrow'>الخلاصة</p><h2 id='t-overview'>$(Rich $d.Verdict.Headline)</h2>"
    $top = @($d.Observations | Where-Object { $_.Level -ne 'info' } | Select-Object -First 5)
    if ($top.Count -eq 0) {
        L "<p class='muted' style='margin:0'>لم يتجاوز أي مقياس الحدود المعتادة. إن كانت المشكلة موجودة فعلًا فأعد الفحص وهي ظاهرة (والذاكرة ممتلئة)، لأن الفحص يلتقط حالة اللحظة فقط.</p>"
    } else {
        L "<ul class='obs'>"
        foreach ($o in $top) { L "<li>$(Pill (LvKind $o.Level) (LevelAr $o.Level) (LvIcon $o.Level))<b>$(Rich $o.Title)</b><span class='b'>$(Rich $o.Body)</span></li>" }
        L '</ul>'
    }
    $sus = @($d.Suspects)
    $nHigh = @($sus | Where-Object { $_.risk -eq 'High' }).Count
    $nMed = @($sus | Where-Object { $_.risk -eq 'Medium' }).Count
    $nLow = @($sus | Where-Object { $_.risk -eq 'Low' }).Count
    $hid = @($d.Hidden)
    $nLive = @($hid | Where-Object { $_.Live }).Count
    $pHigh = Pill $(if ($nHigh) { 'bad' } else { 'mute' }) "عالية الخطورة: $nHigh"
    $pMed = Pill $(if ($nMed) { 'warn' } else { 'mute' }) "متوسطة: $nMed"
    $pLow = Pill 'mute' "منخفضة: $nLow"
    $pLive = Pill $(if ($nLive) { 'bad' } else { 'ok' }) "عمليات مخفية حيّة: $nLive"
    L "<div class='summary'>$pHigh $pMed $pLow $pLive</div>"
    L "<p class='fine'>$(Ic 'info') هذه مؤشرات تقنية وليست حكمًا قطعيًا. لم يُحذف أو يُعدَّل أي شيء على الجهاز أثناء الفحص.</p>"
    L '</div></section>'

    # ---------------------------------------------------------------- KPI tiles
    $used = [double]$m.UsedGB; $usedPct = 100 * $used / $total
    $npp = [double]$m.NonPagedGB; $pgd = [double]$m.PagedGB; $una = [double]$m.UnaccountedGB
    $commitPct = if ([double]$m.CommitLimitGB -gt 0) { 100 * [double]$m.CommittedGB / [double]$m.CommitLimitGB } else { 0 }
    $nppBad = [math]::Max(3.0, 0.12 * $total); $nppWarn = [math]::Max(1.5, 0.06 * $total)
    $unaBad = [math]::Max(4.0, 0.2 * $total); $unaWarn = [math]::Max(2.0, 0.1 * $total)
    $usedSt = if ($usedPct -ge 92) { 'bad' } elseif ($usedPct -ge 80) { 'warn' } else { 'ok' }
    $comSt = if ($commitPct -ge 90) { 'bad' } elseif ($commitPct -ge 75) { 'warn' } else { 'ok' }
    L "<div class='kpis' role='list' aria-label='مؤشرات الذاكرة الرئيسية'>"
    L (Kpi 'المستخدم فعليًا' (Val $used 'GB') "من أصل $(Val $total 'GB') · <bdi dir='ltr'>$(Fx $usedPct '0')%</bdi>" $usedSt $usedPct)
    L (Kpi 'Non-paged pool' (Val $npp 'GB') (Rich 'ذاكرة النواة الثابتة · الطبيعي أقل من 1 GB تقريبًا') (KStatus $npp $nppWarn $nppBad) (100 * $npp / $nppBad))
    L (Kpi 'Paged pool' (Val $pgd 'GB') (Rich 'ذاكرة النواة القابلة للترحيل · الطبيعي أقل من 1.5 GB تقريبًا') (KStatus $pgd $nppWarn $nppBad) (100 * $pgd / $nppBad))
    L (Kpi 'غير منسوبة لعملية' (Val $una 'GB') (Rich 'خارج أي Working Set وخارج مجمّع النواة') (KStatus $una $unaWarn $unaBad) (100 * $una / $unaBad))
    L (Kpi 'Committed' (Val $m.CommittedGB 'GB') "الحد: $(Val $m.CommitLimitGB 'GB') · <bdi dir='ltr'>$(Fx $commitPct '0')%</bdi>" $comSt $commitPct)
    L '</div>'

    # ---------------------------------------------------------------- memory map
    L "<section id='memory' class='blk' aria-labelledby='t-memory'><h2 class='sec' id='t-memory'>$(Ic 'layers')أين تذهب الذاكرة؟</h2><div class='card'>"
    $segs = @(
        @{ n = 'عمليات (ذاكرة خاصة)'; v = [double]$m.ProcPrivateGB; c = 's1' },
        @{ n = 'ذاكرة مشتركة داخل العمليات'; v = [double]$m.ProcSharedGB; c = 's2' },
        @{ n = 'نواة: Non-paged pool'; v = [double]$m.NonPagedGB; c = 's3' },
        @{ n = 'Modified (بانتظار الكتابة للقرص)'; v = [double]$m.ModifiedGB; c = 's4' },
        @{ n = 'غير منسوبة لأي عملية'; v = [double]$m.UnaccountedGB; c = 's5' },
        @{ n = 'Standby (مخزَّنة وقابلة للتحرير)'; v = [double]$m.StandbyGB; c = 's6' },
        @{ n = 'حرة'; v = [double]$m.FreeGB; c = 's7' }
    )
    $sum = ($segs | ForEach-Object { $_.v } | Measure-Object -Sum).Sum
    if (-not $sum -or $sum -le 0) { $sum = 1 }
    L "<div class='stack' role='img' aria-label='توزيع الذاكرة'>"
    foreach ($g in $segs) { $w = Fx (100 * $g.v / $sum) '0.##'; L "<i class='$($g.c)' style='flex:0 0 $w%' title='$(E $g.n): $(Fx $g.v) GB'></i>" }
    L '</div><ul class="legend">'
    foreach ($g in $segs) { L "<li><span class='sw $($g.c)'></span><span class='n'>$(Rich $g.n)</span><span class='v'>$(Val $g.v 'GB')</span><span class='p'><bdi dir='ltr'>$(Fx (100 * $g.v / $sum) '0.#')%</bdi></span></li>" }
    L '</ul>'
    L "<p class='note'>$(Rich 'التقسيم تقريبي: قد تتكرر «الذاكرة المشتركة» بين عدة عمليات. وذاكرة Standby ليست مشكلة لأن ويندوز يحرّرها فورًا عند الحاجة.')</p>"
    L "<p class='note' style='margin-bottom:4px'>$(Rich 'طريقة حساب «غير المنسوبة»:')</p><div class='formula'>Unaccounted = Used − Σ Working Sets − Non-paged − Modified</div>"
    L "<h3>النمو خلال فترة الفحص ($(Bidi ([string]$m.WindowSec + ' s')))</h3>"
    L "<div class='grow'><div><span>Non-paged</span>$(Signed-Delta $m.NonPagedGrowthMB)</div><div><span>Paged</span>$(Signed-Delta $m.PagedGrowthMB)</div><div><span>Committed</span>$(Signed-Delta $m.CommitGrowthMB)</div><div><span>المستخدم</span>$(Signed-Delta $m.UsedGrowthMB)</div></div>"
    L '</div></section>'

    # ---------------------------------------------------------------- all observations
    $obsAll = @($d.Observations | Where-Object { $top -notcontains $_ })   # the hero already lists the main ones
    if ($obsAll.Count -gt 0) {
        L "<section class='blk' aria-labelledby='t-obs'><h2 class='sec' id='t-obs'>$(Ic 'list')ملاحظات إضافية</h2><div class='card'><ul class='obs'>"
        foreach ($o in $obsAll) { L "<li>$(Pill (LvKind $o.Level) (LevelAr $o.Level) (LvIcon $o.Level))<b>$(Rich $o.Title)</b><span class='b'>$(Rich $o.Body)</span></li>" }
        L '</ul></div></section>'
    }

    # ---------------------------------------------------------------- consumers
    L "<section id='consumers' class='blk' aria-labelledby='t-cons'><h2 class='sec' id='t-cons'>$(Ic 'chip')أكبر المستهلكين</h2>"
    L "<p class='lead'>مجمّعة حسب البرنامج (مدير المهام لا يجمع دائمًا عمليات البرنامج الواحد). الذاكرة الخاصة = ما يستهلكه البرنامج فعلًا بدون الاشتراك مع غيره.</p>"
    $byProg = @($d.ByProgram)
    $maxPriv = ($byProg | ForEach-Object { [double]$_.privMB } | Measure-Object -Maximum).Maximum; if (-not $maxPriv -or $maxPriv -le 0) { $maxPriv = 1 }
    L "<div class='tw'><table><thead><tr><th>البرنامج</th><th class='num'>العمليات</th><th>ذاكرة خاصة (MB)</th><th class='num'>Commit (MB)</th><th>التوقيع</th></tr></thead><tbody>"
    foreach ($p in $byProg) {
        $w = Fx (100 * [double]$p.privMB / $maxPriv) '0.#'
        L "<tr><td class='mono'>$(E $p.name)</td><td class='num'>$($p.count)</td><td class='bcell'><span class='bg' style='width:$w%'></span><span>$(Bidi ([string]$p.privMB))</span></td><td class='num'>$($p.commitMB)</td><td>$(TrustPill $p.trust $p.publisher)</td></tr>"
    }
    L '</tbody></table></div>'
    L "<details class='group' style='margin-top:12px'><summary>أكبر 15 عملية بالتفصيل $(Chev)</summary><div class='sus-body'>"
    L "<div class='tw'><table><thead><tr><th class='num'>PID</th><th>العملية</th><th class='num'>خاصة MB</th><th class='num'>Working Set MB</th><th class='num'>Commit MB</th><th class='num'>Handles</th><th class='num'>نمو MB</th><th>التوقيع</th></tr></thead><tbody>"
    foreach ($p in @($d.TopProcesses)) { L "<tr><td class='num'>$($p.pid)</td><td class='mono' title='$(E $p.path)'>$(E $p.name)</td><td class='num'>$($p.privMB)</td><td class='num'>$($p.wsMB)</td><td class='num'>$($p.commitMB)</td><td class='num'>$($p.handles)</td><td class='num'>$($p.growthMB)</td><td>$(TrustPill $p.trust)</td></tr>" }
    L '</tbody></table></div></div></details>'
    $gr = @($d.TopGrowers)
    if ($gr.Count -gt 0) {
        L "<h3>الأسرع نموًا أثناء الفحص</h3><div class='tw'><table><thead><tr><th class='num'>PID</th><th>العملية</th><th class='num'>النمو MB</th><th class='num'>Commit MB</th><th>التوقيع</th></tr></thead><tbody>"
        foreach ($p in $gr) { L "<tr><td class='num'>$($p.pid)</td><td class='mono'>$(E $p.name)</td><td class='num'>$(Signed-Delta $p.growthMB)</td><td class='num'>$($p.commitMB)</td><td>$(TrustPill $p.trust)</td></tr>" }
        L '</tbody></table></div>'
    }
    L '</section>'

    # ---------------------------------------------------------------- pool tags
    L "<section id='pool' class='blk' aria-labelledby='t-pool'><h2 class='sec' id='t-pool'>$(Ic 'driver')ذاكرة النواة: الوسوم (Pool tags)</h2>"
    if (-not $d.PoolAvailable) {
        L "<div class='card'><div class='callout' style='margin:0'>$(Ic 'info')<div>تعذّرت قراءة جدول الوسوم (يحتاج صلاحيات المدير). شغّل الأداة كمدير لتحديد التعريف المسؤول عن ذاكرة النواة.</div></div></div>"
    } else {
        L "<p class='lead'>كل جزء من ذاكرة النواة يحمل وسمًا من 4 أحرف يضعه التعريف الذي حجزه. الربط بالملف يتم بالبحث عن الوسم داخل ملفات التعريفات الشغّالة، لذلك هو <b>ترجيح</b> وليس يقينًا (قد يتطابق الوسم مع أكثر من ملف).</p>"
        $tagTable = {
            param($rows, $title)
            $rows = @($rows)
            if ($rows.Count -eq 0) { L "<h3>$title</h3><p class='muted' style='margin:0'>لا توجد بيانات لهذا الجدول.</p>"; return }
            $mx = ($rows | ForEach-Object { [double]$_.mb } | Measure-Object -Maximum).Maximum; if (-not $mx -or $mx -le 0) { $mx = 1 }
            L "<h3>$title</h3><div class='tw'><table><thead><tr><th>الوسم</th><th>الحجم (MB)</th><th class='num'>النمو MB</th><th>الجهة المحتملة</th></tr></thead><tbody>"
            foreach ($r in $rows) {
                if ($r.known) { $who = "<span class='muted'>$(Rich $r.known)</span>" }
                elseif ($r.tooGeneric) { $who = "<span class='muted'>الوسم عام ويظهر في ملفات كثيرة - لا يمكن الجزم</span>" }
                elseif (@($r.candidates).Count -gt 0) {
                    $who = "<div class='chips'>" + ((@($r.candidates) | ForEach-Object { "<span class='chipf'><bdi dir='ltr'>$(E $_.file)</bdi> $(Pill (TrustClass $_.trust) (TrustAr $_.trust))$(if ($_.publisher) { ' <span class=''muted''>' + (E $_.publisher) + '</span>' })</span>" }) -join '') + '</div>'
                } else { $who = "<span class='muted'>غير معروف</span>" }
                $w = Fx (100 * [double]$r.mb / $mx) '0.#'
                L "<tr><td class='mono'>$(E $r.tag)</td><td class='bcell'><span class='bg' style='width:$w%'></span><span>$(Bidi ([string]$r.mb))</span></td><td class='num'>$(Signed-Delta $r.deltaMB)</td><td>$who</td></tr>"
            }
            L '</tbody></table></div>'
        }
        & $tagTable $d.PoolNonPaged 'أكبر وسوم Non-paged'
        & $tagTable $d.PoolPaged 'أكبر وسوم Paged'
        if (@($d.PoolGrowing).Count -gt 0) { & $tagTable $d.PoolGrowing 'الوسوم الأسرع نموًا أثناء الفحص (التسرّب النشط)' }
    }
    L '</section>'

    # ---------------------------------------------------------------- suspects
    L "<section id='suspects' class='blk' aria-labelledby='t-sus'><h2 class='sec' id='t-sus'>$(Ic 'bug')الملفات المشبوهة</h2>"
    if ($sus.Count -eq 0) {
        $ic = $d.ItemCounts
        L "<div class='card'><div class='empty'>$(Ic 'check-circle')<div>لم يُرصد أي ملف يصل مجموع مؤشراته للحد الأدنى.<br><span class='muted'>فُحص: $($ic.Processes) عملية · $($ic.Services) خدمة · $($ic.Tasks) مهمة مجدولة · $($ic.Autoruns) عنصر تشغيل تلقائي · $($ic.Drivers) تعريف.</span></div></div></div>"
    } else {
        L "<p class='lead'>الرقم # هو رقم العنصر في خطوة العزل. لا يُنفَّذ أي شيء إلا بعد اختيارك وتأكيدك، والعزل لا يحذف (يمكن التراجع عنه).</p>"
        $card = {
            param($x)
            $rk = RiskKey $x.risk
            $kind = LvKind $rk
            $sc = Fx ([math]::Min(100, 100 * [double]$x.score / 12)) '0'
            $openAttr = if ($rk -ne 'low') { ' open' } else { '' }
            L "<details class='sus r-$rk'$openAttr><summary>$(Pill $kind (LevelAr $rk) (LvIcon $rk))<span class='muted'>#$($x.id)</span><span class='sus-name'>$(E $x.name)</span><span class='score' title='نقاط الخطر'><span class='meter'><i style='width:$sc%'></i></span><bdi dir='ltr'>$($x.score)</bdi></span>$(Chev)</summary><div class='sus-body'>"
            L "<dl class='kv'><dt>المسار</dt><dd><span class='mono'>$(E $x.path)</span> <button type='button' class='btn sm' data-copy='$(E $x.path)'>نسخ</button></dd>"
            L "<dt>التوقيع</dt><dd>$(TrustPill $x.trust $x.publisher)</dd>"
            if ($x.company -or $x.description) { L "<dt>الوصف</dt><dd><bdi dir='ltr'>$(E $x.company) $(E $x.description)</bdi></dd>" }
            if ($x.fileExists) { L "<dt>الحجم / التاريخ</dt><dd><bdi dir='ltr'>$(Fx ([double]$x.sizeBytes / 1KB) '0') KB &middot; $(E $x.created)</bdi></dd>" }
            if ($x.sha256 -match '^[0-9A-Fa-f]{64}$') { L "<dt>SHA-256</dt><dd><span class='mono'>$(E $x.sha256)</span> <button type='button' class='btn sm' data-copy='$(E $x.sha256)'>نسخ</button> <a class='btn sm' href='https://www.virustotal.com/gui/file/$($x.sha256.ToLowerInvariant())' target='_blank' rel='noopener noreferrer'>فحص في VirusTotal $(Ic 'ext')</a></dd>" }
            elseif ($x.sha256) { L "<dt>SHA-256</dt><dd><span class='mono'>$(E $x.sha256)</span></dd>" }
            L '</dl>'
            if ($x.protectedFile) { L "<div class='callout'>$(Ic 'shield')<div>الملف نفسه تابع لويندوز/مايكروسوفت: <b>لن يُعزل أبدًا</b>. الإجراء الممكن هو إيقاف هذه العملية أو إلغاء هذا الأمر من التشغيل التلقائي فقط.</div></div>" }
            L '<h3>لماذا هو مشبوه؟</h3><ul class="why">'
            foreach ($r in @($x.reasons)) { L "<li>$(Ic 'warn')<span>$(Rich $r)</span></li>" }
            L '</ul>'
            $ctx = New-Object System.Collections.Generic.List[string]
            foreach ($p in @($x.procs)) { $rem = if (@($p.remote).Count) { ' · اتصال: ' + (@($p.remote) -join ', ') } else { '' }; $ctx.Add("عملية شغّالة PID $($p.pid) - ذاكرة خاصة $($p.privMB) MB، نمو $($p.growthMB) MB$rem") }
            foreach ($p in @($x.services)) { $ctx.Add("خدمة: $($p.name) ($($p.display)) - $($p.startMode)/$($p.state)") }
            foreach ($p in @($x.tasks)) { $ctx.Add("مهمة مجدولة: $($p.taskPath)$($p.taskName) - $($p.state)") }
            foreach ($p in @($x.autoruns)) { $loc = ([string]$p.location) -replace '^Registry::HKEY_USERS\\S-1-5-21-[\d-]+', 'HKEY_USERS\<SID>'; $ctx.Add("تشغيل تلقائي ($($p.via)): $loc → $($p.name)") }
            foreach ($p in @($x.drivers)) { $ctx.Add("تعريف نواة: $($p.name) - $($p.startMode)") }
            foreach ($p in @($x.wmi)) { $ctx.Add("اشتراك WMI: $($p.class) / $($p.name)") }
            if ($ctx.Count -gt 0) { L '<h3>أين يتصل بالنظام؟</h3><ul class="ctx">'; foreach ($c in $ctx) { L "<li>$(Rich $c)</li>" }; L '</ul>' }
            L '</div></details>'
        }
        foreach ($x in @($sus | Where-Object { $_.risk -ne 'Low' })) { & $card $x }
        $lows = @($sus | Where-Object { $_.risk -eq 'Low' })
        if ($lows.Count -gt 0) {
            L "<details class='group'><summary>$(Pill 'info' 'منخفضة الخطورة' 'info') <span>$($lows.Count) عنصر للاطلاع</span>$(Chev)</summary><div class='sus-body'>"
            foreach ($x in $lows) { & $card $x }
            L '</div></details>'
        }
    }
    L '</section>'

    # ---------------------------------------------------------------- hidden processes
    L "<section id='hidden' class='blk' aria-labelledby='t-hid'><h2 class='sec' id='t-hid'>$(Ic 'eye')فحص العمليات المخفية</h2><div class='card'>"
    if ($hid.Count -eq 0) {
        L "<div class='empty'>$(Ic 'check-circle')<div>لم تُرصد عمليات مخفية: كل عملية تستجيب للنواة ظهرت في قوائم النظام.</div></div>"
    } else {
        L "<p class='note' style='margin-top:0'>$(Rich 'الفحص يسأل النواة مباشرة عن كل PID ويقارنه بقوائم النظام. «حيّة» تعني تعمل ولا تظهر في أي قائمة (مؤشر Rootkit). «Zombie» عملية انتهت لكن النواة تحتفظ بها لأن برنامجًا آخر يمسك مقبضها، وهذا يحدث عادةً مع برامج ويندوز نفسها مثل msiexec و mofcomp.')</p>"
        L "<div class='tw'><table><thead><tr><th class='num'>PID</th><th>الحالة</th><th>الملف</th></tr></thead><tbody>"
        foreach ($h in $hid) {
            $st = if ($h.Live) { Pill 'bad' 'حيّة ومخفية' 'error' } elseif ($h.IsWindowsImage) { Pill 'mute' 'Zombie (ملف ويندوز)' } else { Pill 'warn' 'Zombie (ملف خارجي)' 'warn' }
            L "<tr><td class='num'>$($h.Pid)</td><td>$st</td><td class='mono'>$(E $h.Image)</td></tr>"
        }
        L '</tbody></table></div>'
    }
    L '</div></section>'

    # ---------------------------------------------------------------- third-party drivers
    L "<section id='drivers' class='blk' aria-labelledby='t-drv'><h2 class='sec' id='t-drv'>$(Ic 'driver')التعريفات غير التابعة لمايكروسوفت (الشغّالة الآن)</h2>"
    L "<p class='lead'>$(Rich 'تسرّب ذاكرة النواة يأتي في الغالب من تعريف جهة خارجية (كرت شبكة، شاشة، تخزين، VPN، حماية). الأحدث تاريخًا في الأعلى.')</p>"
    $drv = @($d.Drivers3p | Select-Object -First 60)
    if ($drv.Count -eq 0) { L "<div class='card'><div class='empty'>$(Ic 'check-circle')<div>لا توجد تعريفات من جهات خارجية شغّالة.</div></div></div>" }
    else {
        L "<div class='tw'><table><thead><tr><th>الملف</th><th>الشركة / الإصدار</th><th>تاريخ الملف</th><th>التوقيع</th><th>التشغيل</th></tr></thead><tbody>"
        foreach ($x in $drv) {
            $fresh = ''
            try { if ($x.installed -and (((Get-Date) - [datetime]::Parse($x.installed, $script:RI)).TotalDays -le 45)) { $fresh = ' ' + (Pill 'info' 'جديد') } } catch { }
            L "<tr><td class='mono'>$(E $x.file)$fresh</td><td><bdi dir='ltr'>$(E $x.company) $(E $x.version)</bdi></td><td><bdi dir='ltr'>$(E $x.installed)</bdi></td><td>$(TrustPill $x.trust $x.publisher)</td><td>$(E $x.startMode)</td></tr>"
        }
        L '</tbody></table></div>'
    }
    L '</section>'

    # ---------------------------------------------------------------- evidence
    L "<section id='evidence' class='blk' aria-labelledby='t-ev'><h2 class='sec' id='t-ev'>$(Ic 'doc')أدلة إضافية</h2><div class='card'>"
    if ($d.Defender) {
        $df = $d.Defender
        $dSvc = Pill $(if ($df.Enabled) { 'ok' } else { 'bad' }) $(if ($df.Enabled) { 'الخدمة تعمل' } else { 'الخدمة متوقفة' })
        $dRt = Pill $(if ($df.RealTime) { 'ok' } else { 'bad' }) $(if ($df.RealTime) { 'الحماية اللحظية تعمل' } else { 'الحماية اللحظية متوقفة' })
        $dSig = Pill 'mute' "عمر التواقيع: $($df.SignatureAgeDays) يوم"
        $dScan = Pill 'mute' "آخر فحص سريع: قبل $($df.QuickScanAgeDays) يوم"
        L "<h3 style='margin-top:0'>Windows Defender</h3><div class='chips'>$dSvc $dRt $dSig $dScan</div>"
        if (@($df.RecentThreats).Count -gt 0) {
            L "<h3>آخر الاكتشافات</h3><ul class='ctx'>"
            foreach ($t in @($df.RecentThreats)) { L "<li><bdi dir='ltr'>$(E $t.time) - $(E $t.process) - $(E $t.resources)</bdi></li>" }
            L '</ul>'
        }
    } else { L "<h3 style='margin-top:0'>Windows Defender</h3><p class='muted' style='margin:0'>لا تتوفر معلوماته (ربما يوجد برنامج حماية آخر).</p>" }
    L '<h3>أحداث نفاد الذاكرة في سجل النظام</h3>'
    if (@($d.Exhaustion).Count -gt 0) {
        L "<p class='note' style='margin-top:0'>$(Rich 'المصدر Resource-Exhaustion-Detector: يسمّي البرامج التي استهلكت أكبر ذاكرة وقت الحدث.')</p>"
        foreach ($e in @($d.Exhaustion)) { L "<pre class='ev'>$(E $e.time)`n$(E $e.message)</pre>" }
    } else { L "<p class='muted' style='margin:0'>لا توجد أحداث «نفاد ذاكرة» (Event 2004) مسجلة حديثًا.</p>" }
    L '</div></section>'

    # ---------------------------------------------------------------- next steps
    L "<section id='next' class='blk' aria-labelledby='t-next'><h2 class='sec' id='t-next'>$(Ic 'steps')الخطوات المقترحة</h2><ol class='steps'>"
    $steps = @(
        @('إعادة تشغيل حقيقية', 'استخدم «إعادة التشغيل» (Restart) وليس «إيقاف التشغيل» ثم راقب الذاكرة. إن عاد الارتفاع خلال ساعات فالسبب تعريف أو برنامج يبدأ مع النظام.'),
        @('حدّث التعريف المرجَّح', 'إن ظهر وسم/تعريف مرجَّح في جدول Pool tags: حدّثه من موقع المصنّع (كرت الشبكة / الشاشة / اللوحة الأم) أو من Windows Update ← خيارات متقدمة ← تحديثات اختيارية، أو أزل البرنامج الذي ثبّته (VPN، حماية، أدوات تسريع الألعاب).'),
        @('جرّب تعطيل Fast Startup', 'لوحة التحكم ← خيارات الطاقة ← اختيار وظيفة أزرار الطاقة. مع Fast Startup لا تُصفَّر النواة عند «إيقاف التشغيل» فيبقى التسرّب حيًّا.'),
        @('تعمّق بأداة RAMMap', 'نزّل RAMMap من Sysinternals (مايكروسوفت) وراجع تبويب Use Counts: الصفوف Driver Locked و Nonpaged Pool و Mapped File تبيّن النوع بدقة.'),
        @('راجع الملفات المشبوهة', 'افحص SHA-256 على VirusTotal، وشغّل Microsoft Defender Offline scan قبل العزل. العزل ينقل الملف جانبًا ولا يحذفه ويمكن التراجع عنه.'),
        @('عملية «حيّة ومخفية»؟', 'لا تعتمد على ويندوز نفسه؛ استخدم قرص إنقاذ (Defender Offline أو Kaspersky Rescue Disk).')
    )
    foreach ($st in $steps) { L "<li><div><b>$(Rich $st[0])</b><span>$(Rich $st[1])</span></div></li>" }
    L '</ol></section>'
    L '</main>'

    # ---------------------------------------------------------------- footer
    $ic = $d.ItemCounts
    L "<footer><div class='wrap'><div>فُحص: $($ic.Processes) عملية · $($ic.Services) خدمة · $($ic.Tasks) مهمة مجدولة · $($ic.Autoruns) تشغيل تلقائي · $($ic.Drivers) تعريف · $($ic.Wmi) اشتراك WMI مشبوه</div><div>الأداة لا تتصل بالإنترنت ولا يُرسل شيء &middot; RAM Doctor <bdi dir='ltr'>v$(E $d.Version)</bdi></div></div>"
    if (@($d.Warnings).Count -gt 0) { L "<div class='wrap'><ul class='warns'>"; foreach ($w in @($d.Warnings)) { L "<li>$(E $w)</li>" }; L '</ul></div>' }
    L '</footer>'
    L "<script>$($script:ReportJs)</script></body></html>"
    return $sb.ToString()
}
