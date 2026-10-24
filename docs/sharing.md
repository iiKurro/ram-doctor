# Sharing a report with your helper · مشاركة التقرير مع من يساعدك

> **العربية أولًا · English below**
>
> هذه الميزة **اختيارية** ولا تعمل إلا إذا نشر المساعد خادم الاستلام (`server/`) ووضع رابطه في `src/share.config.json`.
> بدون ذلك **لا يُرسل شيء من جهازك أبدًا**، ويبقى التقرير ملفًا محليًا تستطيع إرساله بنفسك.
>
> This feature is **optional**: it only works when the helper has deployed the relay (`server/`) and put its URL in
> `src/share.config.json`. Without that, **nothing ever leaves your PC**; the report stays a local file you can send yourself.

---

## العربية

### كيف يعمل (للصديق)

1. تفتح التطبيق وتُجري الفحص كالمعتاد.
2. عند تفعيل المشاركة يرسل التطبيق **نسخة منقّحة** من التقرير إلى خادم صغير يحفظها في مستودع **خاص** لدى من يساعدك، فيقرؤها دون أن ترسل له ملفات.
3. تختار اسمًا مرة واحدة (2–24 حرفًا عربيًا أو لاتينيًا) ويولّد التطبيق **معرّفًا عشوائيًا من 8 خانات** يبقى ثابتًا لك؛
   يظهر تقريرك عند المساعد باسم `الاسم-المعرّف`.
4. لا حساب ولا تسجيل دخول ولا كلمة سر.

### ما الذي يُرسل بالضبط؟

ثلاثة ملفات نصية فقط (ويضيف الخادم رابعًا هو `meta.json`):

| الملف | المحتوى |
|---|---|
| `summary.md` | ملخص قصير بالنص العادي |
| `report.html` | التقرير الكامل (بدون سكربتات خارجية أو اتصال بالإنترنت) |
| `plan.json` | نتيجة الفحص بصيغة مقروءة آليًا (الحكم، الملفات المشبوهة، أرقام الذاكرة) |

الحدود: summary.md ≤ 128 KB، 
eport.html ≤ 512 KB، plan.json ≤ 512 KB، والطلب كله ≤ 2 MB. الروابط المكتوبة كنص في التقرير (أسطر أوامر المشتبه بهم) مقبولة؛ أما الروابط الفعّالة (href/src/url()) فمقيّدة بـ VirusTotal وGitHub فقط.

### ما الذي يُحذف قبل الإرسال؟

يُنقَّح قبل خروجه من جهازك: **اسم مستخدم ويندوز**، **اسم الجهاز**، **عناوين البريد الإلكتروني**، و**الأسرار الظاهرة في سطور الأوامر**
(كلمات سر ومفاتيح ورموز). لا تُرسل قائمة ملفاتك ولا محتوى أي مستند.

### الخصوصية والموافقة

* لا يُرسل شيء إلا بإعداد صريح من المساعد، وبعد أن تختار اسمك؛ التفاصيل التقنية في [`server/README.md`](../server/README.md).
* التقارير تُحفظ في مستودع GitHub **خاص** يقرؤه المساعد وحده. الخادم نفسه **لا يملك أي مسار قراءة**.
* **حذف بياناتك:** اطلب من المساعد حذف مجلد `reports/<اسمك>-<معرّفك>` (يراه في المستودع). يمكنه أيضًا إزالته من السجل نهائيًا بـ `git filter-repo`.

### للمساعد (قراءة الملفات بأمان)

* افتح **`summary.md`** على GitHub أولًا؛ هو آمن للعرض (يُنظَّف قبل الحفظ).
* `report.html` يُقبل فقط إن بدا كمخرجات الأداة ولا يحتوي عناصر نشطة، لكن **تعامل معه كملف غير موثوق**: نزّله وافتحه في المتصفح ولا تشغّل شيئًا مما فيه.
* في الوضع المفتوح (بلا أكواد دعوة) **لا تثق بهوية المرسل**: أي شخص يعرف الرابط يستطيع إرسال تقرير بأي اسم. كل تقرير يُقيَّم وحده.
* يمكنك تفعيل أكواد الدعوة لاحقًا (`INVITE_CODES`) إن ظهر إزعاج، أو إيقاف الاستقبال فورًا (`DISABLED=1`).

### ملخص نموذج الأمان

لا مسار قراءة · مفتاح GitHub دقيق لمستودع واحد فقط · تحديد معدل (6/ساعة و20/يوم لكل IP، 10/ساعة و20/يوم لكل مستخدم) ·
مخطط صارم وأحجام محدودة · تنظيف `summary.md` · قبول `report.html` الخامل فقط · كل المسارات تُبنى من أجزاء مُتحقَّق منها (لا اجتياز مسارات) ·
وقت المجلد من ساعة الخادم · لا أسرار ولا محتوى في السجلات. التفاصيل في [`server/README.md`](../server/README.md#نموذج-التهديد-بصراحة).

---

## English

### How it works (for the friend)

1. You open the app and run the scan as usual.
2. When sharing is enabled, the app sends a **redacted copy** of the report to a tiny server that stores it in a **private** repository owned
   by your helper, so they can read it without you sending files around.
3. You pick a name once (2–24 Arabic or Latin characters). The app generates a **random 8-hex-character id** that stays the same for you;
   your reports appear on the helper's side as `name-id`.
4. No account, no sign-in, no password.

### Exactly what is uploaded

Three text files only (the server adds a fourth, `meta.json`):

| File | Content |
|---|---|
| `summary.md` | short plain-text summary |
| `report.html` | the full report (no external scripts or network access) |
| `plan.json` | machine-readable scan result (verdict, suspects, memory numbers) |

Limits: summary.md <= 128 KB, 
eport.html <= 512 KB, plan.json <= 512 KB, whole request <= 2 MB. URLs shown as plain text inside the report (a suspect's command line) are fine; *active* links (href/src/url()) are limited to VirusTotal and GitHub.

Limits: `summary.md` <= 128 KB, `report.html` <= 512 KB, `plan.json` <= 512 KB, whole request <= 2 MB. URLs shown as plain text inside the report (a suspect's command line) are fine; *active* links (`href`/`src`/`url()`) are limited to VirusTotal and GitHub.

### What is redacted before it leaves your PC

Your **Windows user name**, the **PC name**, **e-mail addresses**, and **secrets that appear in command lines** (passwords, keys, tokens).
Your file list and the contents of your documents are never sent.

### Privacy and consent

* Nothing is sent unless the helper has configured the relay and you have chosen your name; technical details are in [`server/README.md`](../server/README.md).
* Reports live in a **private** GitHub repository only the helper can read. The relay itself has **no read route at all**.
* **Delete your data:** ask the helper to remove the folder `reports/<your-name>-<your-id>` (they can see it in the repository); they can also purge it from history with `git filter-repo`.

### For the helper (reading uploads safely)

* Open **`summary.md`** on GitHub first; it is safe to render (sanitised on arrival).
* `report.html` is accepted only if it looks like the tool's own output and contains no active content, but **still treat it as untrusted**: download it,
  open it in a browser, and never run anything it mentions.
* In open mode (no invite codes) **never trust who a report claims to be from**: anyone who finds the URL can submit under any name. Judge every report on its own.
* You can switch on invite codes later (`INVITE_CODES`) if abuse appears, or stop intake instantly (`DISABLED=1`).

### Security model in one paragraph

No read route · a fine-grained GitHub token for one repository only · rate limits (6/hour and 20/day per IP, 10/hour and 20/day per user) ·
strict schema and size caps · `summary.md` sanitised · only inert `report.html` accepted · every path built from validated parts (no traversal) ·
folder time taken from the server clock · no secrets or contents in logs. Details: [`server/README.md`](../server/README.md#threat-model-honest-version).
