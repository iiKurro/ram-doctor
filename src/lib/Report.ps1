# HTML report builder for RAM Doctor. Self-contained (no external files, no scripts, no network).

function E($s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }

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

function TrustClass([string]$t) {
    switch ($t) {
        { $_ -in 'OS', 'MS' } { 'ok' }
        { $_ -in 'Signed', 'Unknown' } { 'info' }
        { $_ -in 'Unsigned', 'Script' } { 'low' }
        default { 'high' }
    }
}

function LevelAr([string]$l) {
    switch ($l) { 'high' { 'عالٍ' } 'med' { 'متوسط' } 'low' { 'منخفض' } 'ok' { 'سليم' } default { 'معلومة' } }
}

function RiskKey([string]$r) { switch ($r) { 'High' { 'high' } 'Medium' { 'med' } default { 'low' } } }

function New-RamReportHtml($d) {
    $sb = New-Object System.Text.StringBuilder
    function L([string]$t) { [void]$sb.AppendLine($t) }

    $m = $d.Memory
    $s = $d.Sys

    L '<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">'
    L '<meta name="viewport" content="width=device-width, initial-scale=1">'
    L "<title>تقرير RAM Doctor - $(E $s.Host)</title>"
    L @'
<style>
:root{--bg:#f4f6f8;--card:#fff;--text:#1b2733;--muted:#5d6b78;--line:#dfe5ea;--high:#c62828;--high-bg:#fdecea;--med:#b26a00;--med-bg:#fff4e0;--low:#1565c0;--low-bg:#e8f1fb;--ok:#2e7d32;--ok-bg:#e8f5e9;--info:#546e7a;--info-bg:#eceff1;
--c1:#3b82f6;--c2:#93c5fd;--c3:#8b5cf6;--c4:#f59e0b;--c5:#ef4444;--c6:#94a3b8;--c7:#d1d5db}
@media (prefers-color-scheme:dark){:root{--bg:#10161c;--card:#18212a;--text:#e6edf3;--muted:#9fb0bf;--line:#2a3743;--high:#ff8a80;--high-bg:#3a1c1c;--med:#ffcc80;--med-bg:#3a2e17;--low:#90caf9;--low-bg:#172a3d;--ok:#a5d6a7;--ok-bg:#173021;--info:#b0bec5;--info-bg:#212d37}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.7 "Segoe UI",Tahoma,Arial,sans-serif}
main{max-width:1100px;margin:0 auto;padding:20px 16px 60px}
h1{font-size:24px;margin:0 0 4px}h2{font-size:18px;margin:30px 0 10px;border-inline-start:4px solid var(--c1);padding-inline-start:10px}h3{font-size:15px;margin:16px 0 6px}
.meta{color:var(--muted);font-size:13px}.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin:10px 0}
.verdict{border-width:2px}.verdict.high{border-color:var(--high);background:var(--high-bg)}.verdict.med{border-color:var(--med);background:var(--med-bg)}.verdict.low{border-color:var(--low);background:var(--low-bg)}.verdict.ok{border-color:var(--ok);background:var(--ok-bg)}
.verdict .hl{font-size:19px;font-weight:700;margin-bottom:6px}
.badge{display:inline-block;padding:1px 9px;border-radius:99px;font-size:12px;font-weight:700;margin-inline-end:6px;white-space:nowrap}
.badge.high{background:var(--high-bg);color:var(--high)}.badge.med{background:var(--med-bg);color:var(--med)}.badge.low{background:var(--low-bg);color:var(--low)}.badge.ok{background:var(--ok-bg);color:var(--ok)}.badge.info{background:var(--info-bg);color:var(--info)}
.bar{display:flex;height:30px;border-radius:7px;overflow:hidden;border:1px solid var(--line);margin:10px 0 6px}.bar div{min-width:2px}
.legend{display:flex;flex-wrap:wrap;gap:6px 18px;font-size:13px;color:var(--muted)}.legend i{display:inline-block;width:11px;height:11px;border-radius:3px;margin-inline-end:5px;vertical-align:-1px}
table{width:100%;border-collapse:collapse;font-size:13.5px;background:var(--card)}th,td{padding:6px 9px;border-bottom:1px solid var(--line);text-align:start;vertical-align:top}th{background:var(--info-bg);font-weight:600;white-space:nowrap}
.tw{overflow-x:auto;border:1px solid var(--line);border-radius:8px}.num{text-align:end;font-variant-numeric:tabular-nums;white-space:nowrap}
code,.mono{font-family:Consolas,"Cascadia Mono",monospace;font-size:12.5px;direction:ltr;unicode-bidi:embed;word-break:break-all}
ul{margin:6px 0;padding-inline-start:22px}li{margin:3px 0}details>summary{cursor:pointer;font-weight:600;padding:6px 0}
.sus{border-inline-start:6px solid var(--line)}.sus.high{border-inline-start-color:var(--high)}.sus.med{border-inline-start-color:var(--med)}.sus.low{border-inline-start-color:var(--low)}
.kv{display:grid;grid-template-columns:130px 1fr;gap:3px 10px;font-size:13.5px}.kv b{color:var(--muted);font-weight:600}.kv>span{display:block;text-align:right;min-width:0}
.note{color:var(--muted);font-size:13px}.warn{color:var(--med)}
a{color:var(--low)}
@media print{body{background:#fff}.card{break-inside:avoid}}
</style></head><body><main>
'@

    # ---- header
    L "<h1>تقرير تشخيص الذاكرة <span class='meta'>RAM Doctor v$(E $d.Version)</span></h1>"
    L "<div class='meta'>الجهاز: <b>$(E $s.Host)</b> · المستخدم: $(E $s.User) · $(E $s.OS) · $(E $d.Created) · مدة التشغيل: <span dir='ltr'>$(E $s.Uptime)</span> · صلاحيات المدير: $(if ($s.IsAdmin) { 'نعم' } else { '<span class=warn>لا (نتائج ناقصة)</span>' })</div>"
    L "<div class='meta'>المعالج: <span dir='ltr'>$(E $s.Cpu)</span> · الشاشة: <span dir='ltr'>$(E $s.Gpus)</span></div>"

    # ---- verdict
    $vl = $d.Verdict.Level
    L "<div class='card verdict $vl'><div class='hl'>$(E $d.Verdict.Headline)</div>"
    $top = @($d.Observations | Where-Object { $_.Level -ne 'info' } | Select-Object -First 6)
    if ($top.Count -eq 0) { L "<div>لم يتجاوز أي مقياس الحدود المعتادة. إن كانت المشكلة موجودة فعلًا فأعد الفحص وقت ظهورها (عندما تكون الذاكرة ممتلئة)، لأن الفحص يلتقط حالة اللحظة فقط.</div>" }
    else { L '<ul>'; foreach ($o in $top) { L "<li><span class='badge $($o.Level)'>$(LevelAr $o.Level)</span><b>$(E $o.Title)</b> - $(E $o.Body)</li>" }; L '</ul>' }
    L "<div class='note'>هذه مؤشرات تقنية وليست حكمًا قطعيًا. لم يتم حذف أو تعديل أي شيء على الجهاز.</div></div>"

    # ---- memory map
    L '<h2>أين تذهب الذاكرة؟</h2><div class="card">'
    $segs = @(
        @{ n = 'عمليات (ذاكرة خاصة)'; v = $m.ProcPrivateGB; c = 'c1' },
        @{ n = 'ذاكرة مشتركة داخل العمليات'; v = $m.ProcSharedGB; c = 'c2' },
        @{ n = 'نواة: Non-paged pool'; v = $m.NonPagedGB; c = 'c3' },
        @{ n = 'Modified (بانتظار الكتابة للقرص)'; v = $m.ModifiedGB; c = 'c4' },
        @{ n = 'غير منسوبة لأي عملية'; v = $m.UnaccountedGB; c = 'c5' },
        @{ n = 'Standby (مخزنة، قابلة للتحرير)'; v = $m.StandbyGB; c = 'c6' },
        @{ n = 'حرة'; v = $m.FreeGB; c = 'c7' }
    )
    $sum = ($segs | ForEach-Object { [double]$_.v } | Measure-Object -Sum).Sum
    if ($sum -le 0) { $sum = 1 }
    L '<div class="bar">'
    foreach ($g in $segs) { $w = [math]::Round(100 * [double]$g.v / $sum, 2).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture); L "<div style='width:$w%;background:var(--$($g.c))' title='$(E $g.n): $($g.v) GB'></div>" }
    L '</div><div class="legend">'
    foreach ($g in $segs) { L "<span><i style='background:var(--$($g.c))'></i>$(E $g.n) <b dir='ltr'>$($g.v) GB</b></span>" }
    L '</div>'
    L "<p class='note'>الإجمالي المتاح لويندوز <b dir='ltr'>$($m.TotalGB) GB</b> · المستخدم فعليًا (غير المتاح) <b dir='ltr'>$($m.UsedGB) GB</b>. التقسيم تقريبي: «الذاكرة المشتركة» قد تتكرر بين عمليات، و«غير المنسوبة» = المستخدم − مجموع Working Sets − Non-paged − Modified.</p>"
    L '<div class="tw"><table><tr><th>المقياس</th><th class="num">القيمة</th><th>المعنى</th></tr>'
    $rows = @(
        @('Non-paged pool', "$($m.NonPagedGB) GB", 'ذاكرة النواة الثابتة. الطبيعي أقل من ~1 GB. ارتفاعها = تسرّب تعريف.'),
        @('Paged pool', "$($m.PagedGB) GB", 'ذاكرة النواة القابلة للترحيل. الطبيعي أقل من ~1.5 GB.'),
        @('System cache (مخزن في Working Set)', "$($m.CacheResidentGB) GB", 'كاش ملفات نشط؛ طبيعي.'),
        @('Committed', "$($m.CommittedGB) / $($m.CommitLimitGB) GB", 'الذاكرة الافتراضية المحجوزة مقابل الحد (RAM + Pagefile).'),
        @('غير منسوبة لأي عملية', "$($m.UnaccountedGB) GB", 'إن كانت كبيرة فالسبب خارج مدير المهام (تعريف/AWE/RAM disk/مخفي).')
    )
    foreach ($r in $rows) { L "<tr><td>$(E $r[0])</td><td class='num' dir='ltr'>$(E $r[1])</td><td>$(E $r[2])</td></tr>" }
    L '</table></div>'
    L "<h3>النمو خلال فترة الفحص ($($m.WindowSec) ثانية)</h3><div class='tw'><table><tr><th>Non-paged</th><th>Paged</th><th>Committed</th><th>المستخدم</th></tr><tr><td class='num' dir='ltr'>$($m.NonPagedGrowthMB) MB</td><td class='num' dir='ltr'>$($m.PagedGrowthMB) MB</td><td class='num' dir='ltr'>$($m.CommitGrowthMB) MB</td><td class='num' dir='ltr'>$($m.UsedGrowthMB) MB</td></tr></table></div>"
    L '</div>'

    # ---- observations (all)
    $rest = @($d.Observations)
    if ($rest.Count -gt 0) {
        L '<h2>كل الملاحظات</h2><div class="card"><ul>'
        foreach ($o in $rest) { L "<li><span class='badge $($o.Level)'>$(LevelAr $o.Level)</span><b>$(E $o.Title)</b> - $(E $o.Body)</li>" }
        L '</ul></div>'
    }

    # ---- consumers
    L '<h2>أكبر المستهلكين</h2><h3>حسب البرنامج (مجمّعة، كما لا يفعل مدير المهام دائمًا)</h3><div class="tw"><table><tr><th>البرنامج</th><th class="num">العمليات</th><th class="num">ذاكرة خاصة MB</th><th class="num">Commit MB</th><th>التوقيع</th></tr>'
    foreach ($p in $d.ByProgram) { L "<tr><td dir='ltr'>$(E $p.name)</td><td class='num'>$($p.count)</td><td class='num'>$($p.privMB)</td><td class='num'>$($p.commitMB)</td><td><span class='badge $(TrustClass $p.trust)'>$(TrustAr $p.trust)</span> $(E $p.publisher)</td></tr>" }
    L '</table></div>'
    L '<h3>أكبر 15 عملية</h3><div class="tw"><table><tr><th>PID</th><th>العملية</th><th class="num">خاصة MB</th><th class="num">Working Set MB</th><th class="num">Commit MB</th><th class="num">Handles</th><th class="num">نمو MB</th><th>التوقيع</th></tr>'
    foreach ($p in $d.TopProcesses) { L "<tr><td class='num'>$($p.pid)</td><td dir='ltr' title='$(E $p.path)'>$(E $p.name)</td><td class='num'>$($p.privMB)</td><td class='num'>$($p.wsMB)</td><td class='num'>$($p.commitMB)</td><td class='num'>$($p.handles)</td><td class='num'>$($p.growthMB)</td><td><span class='badge $(TrustClass $p.trust)'>$(TrustAr $p.trust)</span></td></tr>" }
    L '</table></div>'
    if (@($d.TopGrowers).Count -gt 0) {
        L '<h3>الأسرع نموًا أثناء الفحص</h3><div class="tw"><table><tr><th>PID</th><th>العملية</th><th class="num">النمو MB</th><th class="num">Commit MB</th><th>التوقيع</th></tr>'
        foreach ($p in $d.TopGrowers) { L "<tr><td class='num'>$($p.pid)</td><td dir='ltr'>$(E $p.name)</td><td class='num'>$($p.growthMB)</td><td class='num'>$($p.commitMB)</td><td><span class='badge $(TrustClass $p.trust)'>$(TrustAr $p.trust)</span></td></tr>" }
        L '</table></div>'
    }

    # ---- pool tags
    L '<h2>ذاكرة النواة: الوسوم (Pool tags)</h2><div class="card">'
    if (-not $d.PoolAvailable) {
        L "<p>تعذّر قراءة جدول الوسوم (يحتاج صلاحيات المدير). شغّل <code>1-Scan.bat</code> بالنقر المزدوج.</p>"
    } else {
        L "<p class='note'>كل جزء من ذاكرة النواة يحمل وسمًا من 4 حروف يضعه التعريف الذي حجزه. الربط بالملف يتم بالبحث عن الوسم داخل ملفات التعريفات الشغّالة، فهو <b>ترجيح</b> وليس يقينًا (قد يتطابق الوسم مع أكثر من ملف).</p>"
        $tagTable = {
            param($rows, $title)
            L "<h3>$title</h3><div class='tw'><table><tr><th>الوسم</th><th class='num'>الحجم MB</th><th class='num'>نمو MB</th><th>الجهة المحتملة</th></tr>"
            foreach ($r in $rows) {
                $who = ''
                if ($r.known) { $who = E $r.known }
                elseif ($r.tooGeneric) { $who = '<span class="note">الوسم عام ويظهر في ملفات كثيرة - لا يمكن الجزم</span>' }
                elseif (@($r.candidates).Count -gt 0) { $who = (@($r.candidates) | ForEach-Object { "<span dir='ltr'>$(E $_.file)</span> <span class='badge $(TrustClass $_.trust)'>$(TrustAr $_.trust)</span>$(E $_.publisher)" }) -join '<br>' }
                else { $who = '<span class="note">غير معروف</span>' }
                L "<tr><td class='mono'>$(E $r.tag)</td><td class='num'>$($r.mb)</td><td class='num'>$($r.deltaMB)</td><td>$who</td></tr>"
            }
            L '</table></div>'
        }
        & $tagTable $d.PoolNonPaged 'أكبر وسوم Non-paged'
        & $tagTable $d.PoolPaged 'أكبر وسوم Paged'
        if (@($d.PoolGrowing).Count -gt 0) { & $tagTable $d.PoolGrowing 'الوسوم الأسرع نموًا أثناء الفحص (التسرّب النشط)' }
    }
    L '</div>'

    # ---- suspects
    L '<h2>الملفات المشبوهة</h2>'
    $sus = @($d.Suspects)
    if ($sus.Count -eq 0) { L "<div class='card'>لم يُرصد أي ملف يصل مجموع مؤشراته للحد الأدنى. (فحصنا: $($d.ItemCounts.Processes) عملية، $($d.ItemCounts.Services) خدمة، $($d.ItemCounts.Tasks) مهمة مجدولة، $($d.ItemCounts.Autoruns) عنصر تشغيل تلقائي، $($d.ItemCounts.Drivers) تعريف.)</div>" }
    else {
        L "<p class='note'>الرقم # هو رقم العنصر في <code>2-Quarantine.bat</code>. العناصر «عالية» و«متوسطة» تُعرض هناك افتراضيًا. لا يُنفَّذ شيء إلا بعد اختيارك وتأكيدك.</p>"
        foreach ($x in $sus) {
            $rk = RiskKey $x.risk
            $open = if ($rk -eq 'low') { '' } else { ' open' }
            L "<details class='card sus $rk'$open><summary><span class='badge $rk'>$(LevelAr $rk)</span> #$($x.id) · <span dir='ltr'>$(E $x.name)</span> <span class='note'>(نقاط الخطر: $($x.score))</span></summary>"
            L "<div class='kv'><b>المسار</b><span class='mono'>$(E $x.path)</span>"
            L "<b>التوقيع</b><span><span class='badge $(TrustClass $x.trust)'>$(TrustAr $x.trust)</span> $(E $x.publisher)</span>"
            if ($x.company -or $x.description) { L "<b>الوصف</b><span dir='ltr'>$(E $x.company) $(E $x.description)</span>" }
            if ($x.fileExists) { L "<b>الحجم / التاريخ</b><span dir='ltr'>$([math]::Round($x.sizeBytes / 1KB, 0)) KB · $(E $x.created)</span>" }
            if ($x.sha256) { L "<b>SHA-256</b><span class='mono'>$(E $x.sha256) <a href='https://www.virustotal.com/gui/file/$(E $x.sha256)' target='_blank' rel='noopener'>فحص في VirusTotal ↗</a></span>" }
            L '</div>'
            if ($x.protectedFile) { L "<p class='note'>🛡 الملف نفسه تابع لويندوز/مايكروسوفت: لن يُعزل أبدًا، والإجراء الممكن هو إيقاف هذه العملية أو إلغاء هذا الأمر من التشغيل التلقائي فقط.</p>" }
            L '<h3>لماذا هو مشبوه؟</h3><ul>'
            foreach ($r in $x.reasons) { L "<li>$(E $r)</li>" }
            L '</ul>'
            $ctx = New-Object System.Collections.Generic.List[string]
            foreach ($p in @($x.procs)) { $rem = if (@($p.remote).Count) { ' · اتصال: ' + (@($p.remote) -join ', ') } else { '' }; $ctx.Add("عملية شغّالة PID $($p.pid) - ذاكرة خاصة $($p.privMB) MB، نمو $($p.growthMB) MB$rem") }
            foreach ($p in @($x.services)) { $ctx.Add("خدمة: $($p.name) ($($p.display)) - $($p.startMode)/$($p.state)") }
            foreach ($p in @($x.tasks)) { $ctx.Add("مهمة مجدولة: $($p.taskPath)$($p.taskName) - $($p.state)") }
            foreach ($p in @($x.autoruns)) { $loc = ([string]$p.location) -replace '^Registry::HKEY_USERS\\S-1-5-21-[\d-]+', 'HKEY_USERS\<SID>'; $ctx.Add("تشغيل تلقائي ($($p.via)): $loc → $($p.name)") }
            foreach ($p in @($x.drivers)) { $ctx.Add("تعريف نواة: $($p.name) - $($p.startMode)") }
            foreach ($p in @($x.wmi)) { $ctx.Add("اشتراك WMI: $($p.class) / $($p.name)") }
            if ($ctx.Count -gt 0) { L '<h3>أين يتصل بالنظام؟</h3><ul>'; foreach ($c in $ctx) { L "<li>$(E $c)</li>" }; L '</ul>' }
            L '</details>'
        }
    }

    # ---- hidden processes
    L '<h2>فحص العمليات المخفية</h2><div class="card">'
    $hid = @($d.Hidden)
    if ($hid.Count -eq 0) { L "<p>✔ لم تُرصد عمليات مخفية: كل عملية تستجيب للنواة ظهرت في قوائم النظام.</p>" }
    else {
        L "<p class='note'>الفحص يسأل النواة مباشرة عن كل PID ويقارنه بقوائم النظام. «حيّة» تعني تستجيب وتعمل ولا تظهر في أي قائمة (مؤشر Rootkit). «Zombie» تعني عملية انتهت لكن النواة ما زالت تحتفظ بها لأن برنامجًا آخر يمسك مقبضها - وهذا يحدث عادةً مع برامج ويندوز نفسها كـ msiexec وmofcomp.</p>"
        L '<div class="tw"><table><tr><th>PID</th><th>الحالة</th><th>الملف</th></tr>'
        foreach ($h in $hid) {
            $st = if ($h.Live) { "<span class='badge high'>حيّة ومخفية</span>" } elseif ($h.IsWindowsImage) { "<span class='badge info'>Zombie (ملف ويندوز)</span>" } else { "<span class='badge med'>Zombie (ملف خارجي)</span>" }
            L "<tr><td class='num'>$($h.Pid)</td><td>$st</td><td class='mono'>$(E $h.Image)</td></tr>"
        }
        L '</table></div>'
    }
    L '</div>'

    # ---- third-party drivers
    L '<h2>التعريفات غير التابعة لمايكروسوفت (الشغّالة الآن)</h2><div class="card">'
    L "<p class='note'>تسرّب ذاكرة النواة يأتي في الغالب من تعريف جهة خارجية (كرت شبكة، شاشة، تخزين، VPN، حماية). الأحدث تثبيتًا في الأعلى.</p>"
    L '<div class="tw"><table><tr><th>الملف</th><th>الشركة / الإصدار</th><th>تاريخ الملف</th><th>التوقيع</th><th>التشغيل</th></tr>'
    foreach ($x in (@($d.Drivers3p) | Select-Object -First 60)) { L "<tr><td class='mono'>$(E $x.file)</td><td dir='ltr'>$(E $x.company) $(E $x.version)</td><td dir='ltr'>$(E $x.installed)</td><td><span class='badge $(TrustClass $x.trust)'>$(TrustAr $x.trust)</span> $(E $x.publisher)</td><td>$(E $x.startMode)</td></tr>" }
    L '</table></div></div>'

    # ---- defender / events
    L '<h2>أدلة إضافية</h2><div class="card">'
    if ($d.Defender) {
        $df = $d.Defender
        L "<p><b>Windows Defender:</b> الخدمة $(if ($df.Enabled) { 'تعمل' } else { '<span class=warn>متوقفة</span>' }) · الحماية اللحظية $(if ($df.RealTime) { 'تعمل' } else { '<span class=warn>متوقفة</span>' }) · عمر قاعدة التواقيع $($df.SignatureAgeDays) يوم · آخر فحص سريع قبل $($df.QuickScanAgeDays) يوم.</p>"
        if (@($df.RecentThreats).Count -gt 0) { L '<ul>'; foreach ($t in $df.RecentThreats) { L "<li dir='ltr'>$(E $t.time) - $(E $t.process) - $(E $t.resources)</li>" }; L '</ul>' }
    } else { L '<p><b>Windows Defender:</b> لا تتوفر معلوماته (ربما يوجد برنامج حماية آخر).</p>' }
    if (@($d.Exhaustion).Count -gt 0) {
        L '<p><b>أحداث نفاد الذاكرة في سجل النظام</b> (Resource-Exhaustion-Detector) - تسمّي البرامج التي استهلكت أكبر ذاكرة وقت الحدث:</p>'
        foreach ($e in $d.Exhaustion) { L "<pre class='mono' style='white-space:pre-wrap'>$(E $e.time)`n$(E $e.message)</pre>" }
    } else { L '<p class="note">لا توجد أحداث «نفاد ذاكرة» (Event 2004) مسجلة حديثًا.</p>' }
    L '</div>'

    # ---- next steps
    L @'
<h2>الخطوات المقترحة</h2><div class="card"><ol>
<li><b>إعادة تشغيل حقيقية</b> (Restart وليس Shut down) ثم راقب الذاكرة. إن عاد الارتفاع خلال ساعات فالسبب تعريف أو برنامج يبدأ مع النظام.</li>
<li>إن ظهر وسم/تعريف مرجّح في جدول Pool tags: <b>حدّث التعريف</b> من موقع المصنّع (كرت الشبكة/الشاشة/اللوحة الأم) أو من Windows Update ← خيارات متقدمة ← تحديثات اختيارية، أو أزل البرنامج الذي ثبّته (VPN، حماية، أدوات تسريع الألعاب).</li>
<li>إن كان Fast Startup مفعّلًا فجرّب تعطيله: لوحة التحكم ← خيارات الطاقة ← اختيار وظيفة أزرار الطاقة.</li>
<li>للتفصيل الأعمق نزّل <b>RAMMap</b> من Sysinternals (مايكروسوفت) وراجع تبويب <i>Use Counts</i>: الصفوف <i>Driver Locked</i> و<i>Nonpaged Pool</i> و<i>Mapped File</i> تبيّن النوع بدقة.</li>
<li>إن ظهرت ملفات «عالية الخطورة»: افحصها بالـ SHA-256 على VirusTotal، ثم شغّل <b>2-Quarantine.bat</b> لعزلها (لا حذف نهائي). تشغيل <i>Microsoft Defender Offline scan</i> خطوة جيدة قبل ذلك.</li>
<li>إن وُجدت عملية «حيّة ومخفية» فلا تعتمد على ويندوز نفسه؛ استخدم قرص إنقاذ (Defender Offline أو Kaspersky Rescue Disk).</li>
</ol></div>
'@

    # ---- scan info
    L "<h2>معلومات الفحص</h2><div class='card note'>تم فحص $($d.ItemCounts.Processes) عملية، $($d.ItemCounts.Services) خدمة، $($d.ItemCounts.Tasks) مهمة مجدولة، $($d.ItemCounts.Autoruns) عنصر تشغيل تلقائي، $($d.ItemCounts.Drivers) تعريف نواة، $($d.ItemCounts.Wmi) اشتراك WMI مشبوه. لا يوجد أي اتصال بالإنترنت من الأداة، ولا يُرفع شيء."
    if (@($d.Warnings).Count -gt 0) { L '<ul>'; foreach ($w in $d.Warnings) { L "<li class='warn'>$(E $w)</li>" }; L '</ul>' }
    L '</div>'
    L '</main></body></html>'
    return $sb.ToString()
}
