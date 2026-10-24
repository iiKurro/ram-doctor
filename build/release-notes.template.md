## RAM Doctor {{VERSION}}

**English** - Download `RAM-Doctor.bat`, double-click it, approve the Windows prompt (UAC), then press **Start scan**.
The scan is read-only: nothing is deleted or changed. Quarantine is a separate, reversible step that you confirm yourself.
If SmartScreen warns you, choose *More info -> Run anyway* (the file is plain text; open it in Notepad to read it).

**العربية** - نزّل ملف `RAM-Doctor.bat` ثم انقر عليه مرتين ووافق على نافذة الصلاحيات (نعم)، ثم اضغط **ابدأ الفحص**.
الفحص للقراءة فقط ولا يحذف شيئًا ولا يغيّر شيئًا. العزل خطوة منفصلة وقابلة للتراجع وأنت من يؤكدها.
إذا ظهر تحذير SmartScreen فاختر *مزيد من المعلومات ثم التشغيل على أي حال* (الملف نصي، افتحه بالمفكرة لتقرأ ما يفعله).

### Verify your download / تحقّق من الملف

SHA-256 of `RAM-Doctor.bat`:

```
{{SHA256}}
```

```powershell
(Get-FileHash .\RAM-Doctor.bat -Algorithm SHA256).Hash
```

Build provenance (needs the GitHub CLI) / إثبات المصدر:

```
gh attestation verify RAM-Doctor.bat --repo {{REPO}}
```

---

