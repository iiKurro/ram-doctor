# Privacy and safety

RAM Doctor looks deep into a machine, so what it reads, stores, sends and
changes must be explicit. This page states it precisely.

## The short version

* **The scan never uses the network and there is no telemetry.** It is
  read-only. Nothing is installed: no service, no scheduled task, no startup
  entry, no registry setting.
* **Anything that changes the system is explicit and reversible**, except
  `Purge` (deleting quarantined files for good), which asks separately.
* **The only network feature is the optional *Share with my helper* button.**
  It does nothing until you press it and confirm. It uploads a **redacted**
  bundle (`summary.md`, `report.html`, `plan.json`) through a small relay to
  the helper's **private** GitHub repository. The program itself holds no
  token or secret. The button is hidden in builds where no relay endpoint is
  configured.
* You can always send the report **by hand** instead (see
  [below](#sending-your-report-to-someone-who-is-helping-you)).

## What the scan reads

All read-only, on the local machine:

* Memory counters and per-process memory (WMI performance classes), the kernel
  pool-tag table (`NtQuerySystemInformation`), process lists and a direct
  kernel PID probe.
* Process paths, parents, **command lines**, start times, signatures of the
  executables (file reads for hashing and signature checks, driver binaries for
  pool-tag mapping).
* Services, scheduled tasks, Run/RunOnce keys of loaded user hives, startup
  folders, permanent WMI event consumers, running kernel drivers.
* The table of established TCP connections to public addresses.
* Microsoft Defender status and recent detections, Windows Resource-Exhaustion
  events, a few registry anomaly checks (Winlogon, IFEO, AppInit_DLLs).

It does **not** read the contents of your documents, browser data, saved
passwords, e-mail or chat history, and it does not capture network traffic.

## What the tool stores on your PC

| Location | What | When | Size |
| --- | --- | --- | --- |
| `C:\ProgramData\RAM-Doctor-run\<random>\` | The unpacked scripts of the one-file release, in a folder only Administrators and SYSTEM can write to | While the window is open; deleted on exit | ~550 KB |
| `%TEMP%\ramdoctor-*.out/.err` | Output of the child processes | Deleted after each task | tiny |
| `Desktop\RAM-Doctor-Reports\` | `RAMDoctor-<host>-<stamp>.html` and `Plan-<host>-<stamp>.json` | Every scan; the newest 3 scans are kept | ~45 KB per scan |
| `C:\ProgramData\RAM-Doctor\` | `Quarantine\<batch>\files\*.quar`, `manifest.json`, `actions-<stamp>.log` | Only after a quarantine | size of the quarantined files |
| System restore point | "RAM-Doctor before quarantine" | Before each quarantine, if System Protection is on | managed by Windows |
| `%APPDATA%\RAM-Doctor\profile.json` | Display name, random 8-hex id, optionally a DPAPI-protected code | **Only if you use the Share button**; the GUI can delete it | < 1 KB |

Nothing else. Windows PowerShell's `Add-Type` compiler may leave small
temporary files in `%TEMP%` (standard OS behaviour, cleaned by Windows).
The GUI's *clear my reports* button deletes the reports folder.

## What a report contains (and why it is sensitive)

The **local** report and plan are not redacted. They contain:

* your Windows **user name** and **PC name** (they appear in paths and in the
  header),
* the process list and installed-software hints (program and folder names),
* **command lines** of suspect processes, tasks, services and startup entries,
  which can occasionally contain secrets such as tokens passed as arguments,
* SHA-256 hashes, signer names, and remote addresses of suspect connections.

Treat reports as private. Do **not** post them in a public issue. The issue
forms in this repository ask you to redact them; the redacted summary and the
Share bundle exist so you do not have to do that by hand.

## Sending your report to someone who is helping you

Three routes, from most manual to most convenient:

1. **Report location** button (Arabic label: مكان ملف التقرير): opens Explorer
   with the report file selected. Attach it to an e-mail or chat. This file is
   **not redacted**: only send it to someone you trust.
2. **Copy summary for sending** button (نسخ ملخص للإرسال): copies a short
   **redacted** plain-text summary to the clipboard. Paste it into a chat.
   Redaction is best-effort: read it before you send it.
3. **Share with my helper** (optional, below): one click, uploads the redacted
   bundle to your helper's private repository.

## The optional Share button

### Consent and visibility

* The button exists only in builds whose `share.config.json` contains a relay
  endpoint (the maintainer fills it in before a release). Where the endpoint is
  empty it is hidden.
* **Nothing is sent until you press the button and confirm.** The scan, the
  report and the other buttons never use the network. There is no background
  upload, no retry queue and no telemetry.
* The first time you use it you choose a **permanent username** (users do not
  need an invite code). Whether your PC name is included is controlled by a
  checkbox.

### What is uploaded

Exactly three files, from the scan you just ran:

| File | Content |
| --- | --- |
| `summary.md` | A short human-readable summary. |
| `report.html` | The report. |
| `plan.json` | The plan (suspects with their evidence). |

**Redaction** applied before upload: the Windows user name, the PC name (unless
you tick the checkbox), e-mail addresses, and secrets in command lines are
removed. Redaction is **best-effort**: anything not in that list can remain, for
example program names, folder names or remote addresses of suspect
connections. Quarantined files, documents and system files are never uploaded.

### Where it goes and who can see it

```
your PC ──HTTPS──▶ relay (Cloudflare Worker) ──▶ helper's PRIVATE GitHub repo
                                                  reports/<name>-<id>/<timestamp>/
```

* The **helper** (the owner of the data repository) can read the bundles. So
  can the infrastructure they run on (Cloudflare for the relay, GitHub for the
  repository). Nobody else can: the repository is private and the relay has no
  route that returns stored reports.
* It is **not end-to-end encrypted**: do not use Share with someone you would
  not give the report file to.
* The **program contains no token or secret**. The relay holds the only
  credential, so extracting the program yields nothing that can read or write
  the helper's repository.

### The `profile.json` file

Created **only if you use Share**, in `%APPDATA%\RAM-Doctor\`: your display
name, a random 8-hex id (it makes your folder name unique), and, only if the
helper has required one, an invite code **protected with Windows DPAPI** (bound
to your Windows account). It is saved crash-safe: the previous version is kept
as `profile.json.bak`, and a copy that cannot be read is renamed to
`profile.json.damaged-<time>` instead of being silently replaced. The GUI has a
**delete my profile** button that removes the file, its backup and any damaged
copies.

### Deleting data

* **Local**: the delete-profile button removes `profile.json` (with its backup
  and damaged copies); the clear-reports button removes the reports folder. The
  redacted preview / summary files are written to a fresh, randomly named
  folder `%TEMP%\RAM-Doctor-share-<random>` that the window deletes when it is
  done.
* **Uploaded**: bundles live in the helper's repository, which RAM Doctor
  cannot delete from. Ask your helper to remove `reports/<name>-<id>/`; they
  control it.

### Relay protections, in brief

The relay is open to anyone who has the app, so it is built defensively. In
short: **rate limits**; a **three-file whitelist** and a **2 MB cap**; reports
are **sanitised so that only inert content is stored**; **no read route**; a
**kill switch** for the maintainer; and **invite codes can optionally be
required**. These are the relay's responsibilities, documented in
[sharing.md](sharing.md) and [../server/README.md](../server/README.md); they
are not repeated or re-specified here.

### Threat model summary

| Threat | Mitigation | Residual risk |
| --- | --- | --- |
| Someone abuses the open endpoint (spam, huge uploads) | Rate limits, whitelist, size cap, optional invite codes, kill switch | A determined abuser can still waste some quota until the kill switch is used |
| Someone extracts the program to steal credentials | The program holds none | None in the program |
| Malicious content in an uploaded report targets the helper | Reports are sanitised/inert; only three file types | The helper should still open reports in a browser, not trust them blindly |
| Eavesdropping in transit | HTTPS | Not end-to-end encrypted |
| Redaction misses something personal | Best-effort redaction, a confirmation step, manual routes | The user must judge what they share |
| The relay or the helper's GitHub account is compromised | Private repo, secret held only by the relay | Uploaded reports would be exposed; user PCs would not be |

## Safety model for changes to your system

Only `RAM-Doctor-Actions.ps1` changes anything, and only after you choose items
and confirm. Guards:

| Guard | What it does |
| --- | --- |
| Plan host check | Refuses a plan created on another PC. |
| Plan age | Warns when the plan is older than 24 hours; everything is re-verified live anyway. |
| Hash re-check | The file's SHA-256 must still equal the plan's, otherwise that item is skipped. |
| Protected paths | Never moves files under `%WINDIR%`, Defender folders, Microsoft `WindowsApps` packages, the tool's own folder, or the quarantine store. |
| Microsoft signature | Never moves a file with a valid Microsoft signature. |
| PID reuse guard | A process is stopped only if its PID **and** start time (within 3 s) match the plan. |
| Drivers | Only third-party, non-boot, non-system-start drivers can be disabled. |
| Backups | Run values and service start types are recorded; WMI definitions are saved. |
| Restore point | A System Restore point is requested first (needs System Protection; Windows allows one per 24 h by default). |
| Reversibility | Everything except `Purge` can be undone with **Restore**, in reverse order, with conflicts kept (`.restored`). |
| Purge | The only destructive step, separate, with its own confirmation. |
| Confirmations | A typed `YES` / `DELETE` in the command line; an explicit dialog in the GUI. |

Command-line switches that skip confirmations (`-Yes`) exist for scripting and
are used by the GUI after its own dialog.

## Known limitations

* The plan (`Plan-*.json`) and the quarantine manifest are **trusted local
  inputs**. They are validated (host, hashes, protected paths, signatures) but
  not cryptographically signed. If malware already runs as your user it could
  tamper with the plan before you press *Quarantine*; in that case you have a
  bigger problem than this tool can solve. Only quarantine from a plan you just
  created.
* Quarantining a file does not remove the cause if the file was only a symptom
  (for example a dropper that re-creates it). Re-scan after a restart.
* A clean scan is not a guarantee. See
  [how-detection-works.md](how-detection-works.md#what-is-not-detected).
* RAM Doctor is **not an antivirus**. Use it alongside one, not instead of one.

## Verifying a download

Releases include `SHA256SUMS.txt`:

```powershell
Get-FileHash .\RAM-Doctor.bat -Algorithm SHA256
```

Compare the result with the line for `RAM-Doctor.bat`. The file is plain text:
open it in Notepad to read exactly what it does.
