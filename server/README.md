# RAM Doctor relay — خادم الاستلام (Cloudflare Worker)

> **العربية أولًا · English below**
>
> هذا المجلد **للمساعد (صاحب الأداة) فقط**. المستخدم العادي لا يحتاجه ولا يلمسه.
> لا يُرفع أي شيء من جهاز أي شخص **ما لم تنشر أنت هذا الخادم وتضع رابطه في `src/share.config.json`**.
>
> This folder is for the **helper (the tool's owner)** only. Ordinary users never touch it.
> Nothing is uploaded from anyone's PC **unless you deploy this relay and put its URL in `src/share.config.json`**.

---

## العربية

### ما هذا؟

وسيط صغير (Cloudflare Worker مجاني) يستقبل تقرير RAM Doctor بعد حذف البيانات الشخصية منه، ويحفظه في مستودع GitHub **خاص** باسمك
(`iiKurro/ram-doctor-reports`) داخل مجلد باسم الشخص: `reports/<الاسم>-<المعرّف>/<التاريخ>-<6 أحرف عشوائية>/`. فتقرأ التقرير مباشرة على GitHub.

```
تطبيق صديقك  ──POST (JSON)──▶  Worker (هذا المجلد)  ──Git Data API──▶  مستودع خاص ram-doctor-reports
                                  │ يتحقق · ينظّف · يحدّ المعدل              (أنت فقط تقرأه)
                                  └─ لا يوجد أي مسار للقراءة أو الحذف
```

**الوضع الافتراضي = مفتوح (بدون أكواد دعوة).** أي شخص يعرف الرابط يستطيع إرسال تقرير، لذلك الخادم محمي بعدة طبقات:

| الطبقة | ما تفعله |
|---|---|
| لا مسار قراءة | الخادم **يكتب فقط**. لا قائمة، لا تنزيل، لا حذف، لا تعديل. أسوأ ما يفعله غريب: إرسال تقارير مزعجة محدودة العدد. |
| تحديد المعدل (KV) | لكل IP: 6 في الساعة و20 في اليوم (كل محاولة تُحسب قبل أي عمل). لكل معرّف مستخدم: 10 في الساعة و20 مجلدًا في اليوم، **تُحسب بعد الحفظ الناجح فقط** (عطل GitHub لا يستهلك حصة أحد). **إجباري في الوضع المفتوح**: إن لم يوجد KV يرد الخادم `503` (يفشل مغلقًا). |
| إعادة المحاولة بلا تكرار | إن أرسل التطبيق `requestId` (اختياري) فالطلب نفسه مرة ثانية يحصل على الرد الأول (`"replayed": true`) دون حفظ ثانٍ؛ وأثناء الحفظ الأول `409 in_progress`. إن ضاع رد GitHub على تحديث الفرع، يسأل الخادم GitHub هل وصل المجلد قبل أن يعدّ الرفع فاشلًا. لكل رفع مجلد `<الوقت>-<6 أحرف عشوائية>` فلا يحلّ رفع محل آخر. |
| مفتاح إيقاف | المتغير `DISABLED=1` يوقف الاستقبال فورًا. |
| مخطط صارم | حقول معروفة فقط، 3 أسماء ملفات فقط، حدود أحجام، ‎`plan.json` يجب أن يكون JSON سليمًا بعمق/حجم محدودين. |
| تنظيف `summary.md` | يُسمح بماركداون عادي + `<div dir="rtl">` و`</div>` و`<br>` فقط؛ أي HTML آخر يُعطَّل. |
| فحص `report.html` | يُقبل فقط إن كان شبيهًا بمخرجات الأداة تمامًا **وخاملًا**: يبدأ بـ `<!doctype html>` ثم مباشرة العلامة `<!-- ram-doctor-report v1.0.0 -->` (الإصدار اختياري: `v1` أو `v1.0` أو `v1.0.0`)، وسكربت داخلي واحد ≤ 3KB بلا شبكة/تنفيذ ديناميكي، وبلا `iframe/object/embed/form/base/link`، وبلا `on…=`، وبلا `javascript:`/`data:`. تُفحص الروابط **في الأماكن الفعّالة فقط** (قيم `href/src/srcset/action/xlink:href…` و`url()` و`@import` و`meta refresh`) ولا يُسمح فيها إلا بـ `virustotal.com/gui/file/<64 hex>` و`github.com` و`#fragment`. أما الروابط المكتوبة **كنص** (مثل أسطر أوامر المشتبه بهم: `stratum+tcp://…` أو `https://…/x.ps1`) فهي **مقبولة** لأنها محتوى مشروع في تقرير الفحص. غير ذلك: `400 report_rejected`. |
| أكواد دعوة (اختيارية) | إن وضعت `INVITE_CODES` يصبح الكود إلزاميًا. للتفعيل لاحقًا إن زاد الإزعاج. |

> كن حذرًا عند القراءة: افتح **`summary.md`** على GitHub أولًا. تعامل مع `report.html` كملف غير موثوق (نزّله وافتحه ولا تشغّل شيئًا مما فيه).

**الحدود الدقيقة (بالبايت):** ‎summary.md ≤ 131072 (128 KB) · report.html ≤ 524288 (512 KB) · plan.json ≤ 524288 (512 KB) · أي ملف ≤ 1572864 (1.5 MB) · الطلب كله ≤ 2097152 (2 MB) · السكربت الداخلي ≤ 3072. تجاوزها: 413 too_large.

### الإعداد خطوة بخطوة (مرة واحدة، ~15 دقيقة)

**1) أنشئ المستودع الخاص** (من PowerShell، بعد `gh auth login`):

```powershell
gh repo create iiKurro/ram-doctor-reports --private --add-readme --description "RAM Doctor reports (private)"
git clone https://github.com/iiKurro/ram-doctor-reports.git "$env:USERPROFILE\GitHub\ram-doctor-reports"
robocopy server\data-repo-template "$env:USERPROFILE\GitHub\ram-doctor-reports" /E
cd "$env:USERPROFILE\GitHub\ram-doctor-reports"
git add -A ; git commit -m "chore: add README and index workflow" ; git push
```
(الخيار `--add-readme` ضروري كي يوجد الفرع `main` قبل أول رفع.)

**2) أنشئ مفتاح وصول دقيق (Fine-grained PAT) لهذا المستودع وحده:**
GitHub ← Settings ← Developer settings ← Personal access tokens ← **Fine-grained tokens** ← Generate new token:
الاسم `ram-doctor-relay` · الصلاحية الزمنية 90 يومًا · Resource owner `iiKurro` · **Only select repositories** ← `ram-doctor-reports` ·
Repository permissions ← **Contents: Read and write** (لا شيء آخر). انسخ المفتاح مرة واحدة.

> **لا تستخدم** مفتاح `gh` ولا مفتاحًا كلاسيكيًا (`repo`): هذان يعطيان وصولًا لكل مستودعاتك الخاصة. المفتاح الدقيق إن تسرّب
> يكشف هذا المستودع فقط، ويمكنك إلغاؤه فورًا.

**3) انشر الـ Worker على Cloudflare** (حساب مجاني يكفي):

```powershell
cd server\worker
npx wrangler login
npx wrangler kv namespace create RATE        # يطبع id: ضعه في wrangler.toml (احذف # من سطور kv_namespaces)
npx wrangler secret put GITHUB_TOKEN         # الصق المفتاح الدقيق
npx wrangler deploy
```
(مع Wrangler 3 الأمر `npx wrangler kv:namespace create RATE`.) ثم افحص: `Invoke-RestMethod https://ram-doctor-relay.<نطاقك>.workers.dev/v1/health` ← `ok=True`.

**4) اربط التطبيق بالخادم:** ضع الرابط في `src/share.config.json` ثم أعد البناء:

```json
{ "endpoint": "https://ram-doctor-relay.<نطاقك>.workers.dev" }
```
```powershell
powershell -File build\Build-SingleFile.ps1
```

### التشغيل والصيانة

* **إيقاف طارئ:** `npx wrangler secret put DISABLED` ثم اكتب `1` (لإعادة التشغيل: احذفه `npx wrangler secret delete DISABLED`).
* **تدوير المفتاح:** أنشئ مفتاحًا دقيقًا جديدًا ← `npx wrangler secret put GITHUB_TOKEN` ← احذف القديم من GitHub.
* **حذف بيانات شخص:** راجع `README.md` داخل المستودع الخاص (`git rm -r reports/<الاسم>-<المعرّف>`).
* **بعد تحديث الخادم إلى نسخة المجلدات ذات اللاحقة:** انسخ `server/data-repo-template/.github/workflows/index.yml` إلى المستودع الخاص؛
  النسخة القديمة لا ترى المجلدات الجديدة في `INDEX.md` (التقارير نفسها تُحفظ في الحالتين).
* **أكواد دعوة (اختياري، لا حاجة لها افتراضيًا):**
  `powershell -File server\scripts\New-InviteCode.ps1 -Label ali` يطبع كودًا وسطر JSON؛ ثم
  `npx wrangler secret put INVITE_CODES`. بعدها يصبح الكود إلزاميًا للجميع. للإلغاء احذف الكود من JSON وأعد الأمر،
  أو `-Revoke <code>`. (مع `INVITE_CODES` يصبح KV اختياريًا؛ ومع ذلك يُنصح به.)

### نموذج التهديد (بصراحة)

| من | ماذا يستطيع | ماذا لا يستطيع |
|---|---|---|
| غريب يعرف الرابط | إرسال تقارير سليمة الشكل لكن محدودة المعدل (6/ساعة، 20/يوم لكل IP). قد يملأ المستودع بالمزعج ببطء، أو يستهلك حصة كتابة KV (1000/يوم) فيعطّل الخدمة مؤقتًا (503). | القراءة، الحذف، التعديل، رؤية أي تقرير، تنفيذ شيء عندك (التقارير تُفحص وتُنظَّف)، معرفة المفتاح. |
| غريب ينتحل `userId` شخص آخر | إضافة مجلد جديد باسمه (لا يستطيع الكتابة فوق القديم؛ الاسم من ساعة الخادم مع لاحقة عشوائية). | إثبات الهوية: **لا تثق بهوية المرسل** في الوضع المفتوح. |
| مفتاح GitHub (PAT) تسرّب | قراءة/كتابة هذا المستودع فقط. | أي مستودع آخر. ألغِه وأنشئ بدلًا منه. |
| تقرير خبيث يحاول إصابتك عند القراءة | يمر فقط إن بدا كمخرجات الأداة وكان خاملًا؛ وإلا يُرفض. | تشغيل سكربت عن بعد من `report.html` (ممنوع شبكة/تنفيذ ديناميكي/عناصر نشطة). ومع ذلك: اقرأ `summary.md` أولًا. |

**حدود الطبقة المجانية:** Workers Free = 100,000 طلب/يوم و**10ms CPU للطلب** (التقرير العادي ~50KB خفيف جدًا؛ تقرير قريب من 2MB قد يتجاوز الحد
فيفشل بـ 1102). KV Free = 100,000 قراءة و**1,000 كتابة/يوم**: كل رفع ناجح يكتب مرتين، وأربع مرات إن حمل `requestId`، فالسقف العملي ≈ 250 إلى 500 رفعة/يوم. إن امتلأ يرد الخادم `503`
(بدون كشف أي شيء). في Cloudflare يمكنك إضافة قاعدة Rate Limiting/WAF مجانية أمامه كطبقة إضافية.

### الاختبار محليًا

```powershell
cd server
node --test          # لا يحتاج npm install ولا شبكة؛ يحاكي GitHub
npx wrangler dev     # تشغيل محلي (اختياري)
```

---

## English

### What is this?

A tiny Cloudflare Worker (free tier) that receives a **redacted** RAM Doctor report and commits it to a **private** GitHub repository
(`iiKurro/ram-doctor-reports`) under `reports/<name>-<userId>/<yyyyMMdd-HHmmss>-<6 random chars>/`, so you can read it on GitHub.

**Default = OPEN mode (no invite codes).** Anyone who finds the URL can POST, so the relay defends itself in depth:

| Layer | What it does |
|---|---|
| No read route | The Worker only **appends**. No list, download, delete or modify route exists. The worst a stranger can do is send rate-limited junk. |
| KV rate limits | Per IP: 6/hour and 20/day (every attempt counts, before any work). Per userId: 10/hour and 20 folders/day, **counted only after a successful commit** (a GitHub outage costs nobody their quota). **Mandatory in open mode**: without the KV binding it answers `503` (fails closed), except `/v1/health`. |
| Safe retries | When the client sends the optional `requestId`, the same request again gets the first answer (`"replayed": true`) and no second commit; while the first one is still committing it gets `409 in_progress`. If GitHub's answer to the ref update is lost, the relay checks whether the folder landed before calling the upload failed. Every upload gets its own `<stamp>-<6 random chars>` folder, so none can replace another. |
| Kill switch | `DISABLED=1` makes uploads answer `503` immediately. |
| Strict schema | Known fields only, exactly three file names, size caps (summary 128 KB, report 512 KB, plan 512 KB, body 2 MB), `plan.json` must be a JSON object with the expected keys and bounded depth/size. |
| `summary.md` sanitised | Plain Markdown plus `<div dir="rtl">`, `</div>`, `<br>` only; any other HTML is neutralised. |
| `report.html` inspected | Accepted only if it looks like the tool's own output **and is inert**: it starts with `<!doctype html>` immediately followed by the marker `<!-- ram-doctor-report v1.0.0 -->` (version optional: `v1`, `v1.0`, `v1.0.0`), has at most one inline `<script>` ≤ 3 KB without network/dynamic-code/navigation APIs, no `iframe/object/embed/form/base/link`, no `on…=` attributes, no `javascript:`/`data:` URLs. URLs are checked **in active contexts only** (values of `href/src/srcset/action/xlink:href…`, CSS `url()`/`@import`, `<meta http-equiv>`), where only `https://www.virustotal.com/gui/file/<64 hex>`, `https://github.com/…` and `#fragments` are allowed. URLs shown as plain **text** (a suspect's command line such as `stratum+tcp://pool.example:3333` or `https://evil.example/x.ps1`) are **accepted**: they are legitimate content of a malware-triage report. Anything else: `400 report_rejected`. |
| Invite codes (optional) | Set `INVITE_CODES` and a valid code becomes mandatory. Switch it on later if abuse appears. |

> As a reader: open **`summary.md`** on GitHub first. Treat `report.html` as untrusted (download it, never run anything it mentions).

**Exact limits (bytes):** summary.md <= 131072 (128 KB) · report.html <= 524288 (512 KB) · plan.json <= 524288 (512 KB) · any single file <= 1572864 (1.5 MB) · whole request <= 2097152 (2 MB) · inline script <= 3072. Exceeding any: 413 too_large.

### Setup, step by step (once, ~15 minutes)

**1) Create the private repository** (after `gh auth login`):

```powershell
gh repo create iiKurro/ram-doctor-reports --private --add-readme --description "RAM Doctor reports (private)"
git clone https://github.com/iiKurro/ram-doctor-reports.git "$env:USERPROFILE\GitHub\ram-doctor-reports"
robocopy server\data-repo-template "$env:USERPROFILE\GitHub\ram-doctor-reports" /E
cd "$env:USERPROFILE\GitHub\ram-doctor-reports"
git add -A ; git commit -m "chore: add README and index workflow" ; git push
```
(`--add-readme` matters: the `main` branch must exist before the first upload.)

**2) Create a fine-grained PAT limited to that one repository:**
GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token: name `ram-doctor-relay`,
expiry 90 days, resource owner `iiKurro`, **Only select repositories** → `ram-doctor-reports`, Repository permissions →
**Contents: Read and write** (nothing else). Copy it once.

> **Do not** use your `gh` token or a classic `repo` token: both reach all your private repositories. If a fine-grained token leaks it
> exposes this one repository only, and you can revoke it instantly.

**3) Deploy the Worker** (a free Cloudflare account is enough):

```powershell
cd server\worker
npx wrangler login
npx wrangler kv namespace create RATE        # prints an id: paste it in wrangler.toml (uncomment the kv_namespaces block)
npx wrangler secret put GITHUB_TOKEN         # paste the fine-grained token
npx wrangler deploy
```
(Wrangler 3: `npx wrangler kv:namespace create RATE`.) Check: `Invoke-RestMethod https://ram-doctor-relay.<your-subdomain>.workers.dev/v1/health` → `ok=True`.

**4) Point the app at it:** put the URL into `src/share.config.json`, then rebuild:

```json
{ "endpoint": "https://ram-doctor-relay.<your-subdomain>.workers.dev" }
```
```powershell
powershell -File build\Build-SingleFile.ps1
```

### Operating it

* **Emergency stop:** `npx wrangler secret put DISABLED` → `1` (re-enable: `npx wrangler secret delete DISABLED`).
* **Rotate the PAT:** create a new fine-grained token → `npx wrangler secret put GITHUB_TOKEN` → delete the old one on GitHub.
* **Delete someone's data:** see the data repo's own `README.md` (`git rm -r reports/<name>-<userId>`).
* **After upgrading to the relay with suffixed folders:** copy `server/data-repo-template/.github/workflows/index.yml` into the data repo;
  the old copy leaves the new folders out of `INDEX.md` (the reports themselves are stored either way).
* **Invite codes (optional, not needed by default):** `powershell -File server\scripts\New-InviteCode.ps1 -Label ali` prints a code and the JSON;
  then `npx wrangler secret put INVITE_CODES`. From then on every upload needs a code. Revoke by removing it from the JSON and re-putting the
  secret (or `-Revoke <code>`). With `INVITE_CODES` set, KV becomes optional (still recommended).

### Threat model (honest version)

| Who | Can | Cannot |
|---|---|---|
| A stranger who finds the URL | POST well-formed, sanitised, rate-limited reports (6/h, 20/day per IP); slowly litter the repo; burn the KV write quota (1,000/day) so the service answers `503` for a while. | Read, list, modify or delete anything; see any report; run anything on your machine (content is inspected/sanitised); learn the token. |
| Someone spoofing another person's `userId` | Add a *new* folder under that id (the name comes from the server clock plus a random suffix, so existing folders can't be overwritten). | Prove identity — **never trust who a report claims to be from** in open mode. |
| A leaked PAT | Read/write that single repository. | Anything else. Revoke it and rotate. |
| A malicious report trying to hit you while you read it | Passes only if it looks like tool output and is inert; otherwise rejected. | Remote script execution through `report.html` (no network/dynamic code/active elements). Still: read `summary.md` first. |

**Free-tier limits:** Workers Free = 100,000 requests/day and **10 ms CPU per request** (a normal ~50 KB report is tiny; an upload near the 2 MB cap
may exceed it and fail with Cloudflare error 1102). KV Free = 100,000 reads and **1,000 writes/day**; each accepted upload writes twice (four times
when it carries a `requestId`), so the practical ceiling is ≈ 250-500 uploads/day. When exhausted the relay answers `503` and reveals nothing. You can add a free Cloudflare WAF/rate-limit rule in front as one more layer.

### Run the tests locally

```powershell
cd server
node --test          # no npm install, no network; GitHub is mocked
npx wrangler dev     # optional local run
```

### Protocol v1 (for client authors)

`POST {endpoint}/v1/reports`, `Content-Type: application/json`, body:
`{"v":1,"displayName":"2-24 chars","userId":"8 hex","code":"(optional)","requestId":"(optional) 16-64 of A-Z a-z 0-9 -","tool":{"name":"RAM-Doctor","version":"1.0.0"},"createdAt":"ISO-8601 UTC","host":"<PC name or the literal <PC>>","files":[{"name":"summary.md|report.html|plan.json","content":"UTF-8 text"}]}`.
Any other field is rejected (`400 invalid_request`, `field: unknown_field`).
`200 {"ok":true,"folder":"reports/<slug>-<userId>/<yyyyMMdd-HHmmss>-<6 of a-z0-9>","url":"https://github.com/…"}`; an answer repeated for a known
`requestId` adds `"replayed":true`. Errors: `400 invalid_request|report_rejected`, `401 unauthorized` (code mode), `409 in_progress` (+`Retry-After`:
the first attempt with this `requestId` is still committing), `413 too_large`, `429 rate_limited` (+`Retry-After`), `502 upstream_error`,
`503 unavailable|disabled`, `500 server_error`. `GET /v1/health` → `{"ok":true,"v":1}`.

**Retries.** Generate one `requestId` per upload (a GUID is fine) and send it unchanged on every retry of that upload. Retry network errors and
`5xx`; on `409 in_progress` wait `Retry-After` seconds and ask again. The relay remembers a `requestId` for 24 hours, per `userId`, in KV
(eventually consistent between Cloudflare locations, so this is best effort; a retry normally reaches the same location). Without the KV binding
(code mode) the field is accepted but not honoured. Clients without `requestId` keep working; each request is then a new upload.
The RAM Doctor client sends `requestId`; against a relay deployed before this field (`400 unknown_field`) it sends the same body
once more without it, so uploads keep working, but **deploy this relay before shipping that client** to get the protection.
