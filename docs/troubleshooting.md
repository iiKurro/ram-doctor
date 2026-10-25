# Troubleshooting

Find your symptom, apply the fix. If nothing helps, open a
[bug report](https://github.com/iiKurro/ram-doctor/issues/new?template=bug_report.yml)
**with user and PC names removed**.

* [Windows says "Windows protected your PC" (SmartScreen)](#windows-says-windows-protected-your-pc-smartscreen)
* [The file is blocked / "this file came from another computer"](#the-file-is-blocked)
* [Antivirus flags or deletes RAM-Doctor.bat](#antivirus-flags-or-deletes-ram-doctorbat)
* [The window says it is not running as administrator](#not-running-as-administrator)
* [Nothing happens when I double-click](#nothing-happens-when-i-double-click)
* [PowerShell Constrained Language Mode, AppLocker, WDAC](#constrained-language-mode-applocker-wdac)
* [Arabic, English and other locales](#arabic-english-and-other-locales)
* [The scan is slow, or the progress bar seems stuck](#the-scan-is-slow-or-seems-stuck)
* [The report says everything is fine but the RAM is still full](#the-report-says-everything-is-fine)
* [Quarantine problems](#quarantine-problems)
* [The Share button is missing or fails](#the-share-button-is-missing-or-fails)
* [Run it from source, with logs](#run-it-from-source-with-logs)

## Windows says "Windows protected your PC" (SmartScreen)

RAM Doctor is not code-signed (a certificate costs money), so SmartScreen may
warn about a file downloaded from the internet.

1. Verify the download first:
   `Get-FileHash .\RAM-Doctor.bat -Algorithm SHA256` and compare with
   `SHA256SUMS.txt` on the release page.
2. Click **More info**, then **Run anyway**.

If you do not trust the file, open it in Notepad: it is plain text, and the
scripts it unpacks are the ones in the `src/` folder of this repository.

## The file is blocked

Files from the internet carry a "Mark of the Web". If Windows refuses to run it:

* right-click the file, **Properties**, tick **Unblock**, **OK**; or
* run `Unblock-File .\RAM-Doctor.bat` in PowerShell.

Do not run it from inside a `.zip` preview. Copy it to a normal folder first
(Desktop or Downloads).

## Antivirus flags or deletes RAM-Doctor.bat

RAM Doctor enumerates processes, reads kernel memory statistics, can stop
processes and move files, and is a self-extracting `.bat`. Some products flag
that behaviour even though the file is readable plain text with no obfuscation.

1. Check the SHA-256 against `SHA256SUMS.txt`.
2. Restore it from the antivirus quarantine, or add an exclusion for the file
   you verified (and only that file).
3. Report the false positive to your antivirus vendor, and tell us which
   product flagged it via a bug report.

If you prefer not to run a `.bat` at all, run the scripts from source (below).

## Not running as administrator

The window shows a banner when it was started without administrator rights.
The scan still works but has reduced coverage (some process paths, other users'
startup entries), and quarantine / restore / purge are unavailable.

* Close the window, double-click `RAM-Doctor.bat` again and click **Yes** on the
  UAC prompt.
* If you are a standard user, Windows asks for an administrator's password;
  you need one.
* If you cancelled UAC by mistake, just start it again.

## Nothing happens when I double-click

* The first double-click starts a **minimised** console that requests
  administrator rights; look for the UAC prompt (it may be behind other
  windows or flashing in the taskbar).
* The file must be on a local drive and not in a `.zip`.
* If the window never appears, look for `%TEMP%\ramdoctor-gui-error.log`.
* Running it from a path with unusual characters (`&`, `^`, `%`) can confuse
  `cmd.exe`; move it to `C:\Tools` and retry.

## Constrained Language Mode, AppLocker, WDAC

The tool compiles small C# helpers with `Add-Type`. Under **Constrained
Language Mode** (enforced by AppLocker or WDAC policies) `Add-Type` is blocked.

* The command-line **scan degrades gracefully**: the kernel pool-tag table and
  the hidden-process probe are disabled and the report says so under
  *Warnings*.
* The **GUI cannot run** (its controls are compiled with `Add-Type`). Run the
  scan from the command line:
  `powershell -File src\RAM-Doctor.ps1`.
* On managed corporate PCs, ask IT before running any tool of this kind.

## Arabic, English and other locales

* The window and the report come in **English (LTR)** and **Arabic (RTL)**. The
  tool opens in Arabic when the Windows display language is Arabic and in English
  otherwise; the globe button in the window header switches it live, and
  `-Lang ar|en` forces one from the command line. The scan writes its report in
  the language that was active when you pressed *Start scan*. Technical
  identifiers (pool tags, process names, paths) stay in English. Console and log
  lines are English ASCII on purpose, because Arabic is garbled in a classic console.
* Memory counters are read through **locale-independent WMI classes**, and event
  logs are filtered by provider name and ID, so non-English Windows editions are
  expected to work. The project was developed and tested on English Windows 11,
  so please report any locale-specific problem.
* If Arabic text looks like `Ø§Ù„...` in a script you edit, the file lost its
  **UTF-8 BOM**; see [CONTRIBUTING.md](../CONTRIBUTING.md#coding-rules).

## The scan is slow or seems stuck

A scan takes roughly 40 seconds to 2 minutes. The longest step is *analysing
files and signatures* (it verifies Authenticode signatures of every running
file, service, task and driver). The bar creeps forward during that step.

* Slow disks, a busy antivirus or an offline PC checking certificate
  revocation make it slower.
* The scan waits at least **30 seconds** (the observation window) so it can
  measure growth.
* If it stalls for more than 5 minutes, close the window (the scan is stopped)
  and run from source with logs (below).

## The report says everything is fine

* A scan sees only the moment it runs. **Run it while the RAM is full.**
* Read the *memory* section: "unaccounted" memory and the non-paged pool are
  the leads when no suspect appears. See
  [how-detection-works.md](how-detection-works.md).
* Memory can be held by categories RAM Doctor does not break down (driver-locked,
  AWE, mapped files). Use Sysinternals **RAMMap** (*Use Counts* tab) for that.
* After a long uptime with **Fast Startup**, "Shut down" does not reset the
  kernel. Use **Restart**.

## Quarantine problems

| Message | Meaning / fix |
| --- | --- |
| "needs administrator rights" | Start the tool as administrator. |
| "Plan belongs to another PC" | Plans are tied to the machine that created them. Run a new scan here. |
| "file changed since the scan (hash mismatch)" | The file is not what was scanned. Re-scan. |
| "file is still locked" | A process still holds it. Restart and retry, or retry from Safe Mode. |
| "refusing" / "protected" | The item is a Windows/Microsoft file or a boot-start driver; it is never touched by design. |
| "No restore point created" | System Protection is off, or Windows already made one in the last 24 hours. The quarantine itself still works and is reversible. |
| "stored file missing" during Restore | The batch was purged, or the file was removed by hand. |

Quarantined files live in `C:\ProgramData\RAM-Doctor\Quarantine\<batch>\` and
the log is `C:\ProgramData\RAM-Doctor\actions-<stamp>.log`. **Restore** undoes
a batch; **Purge** deletes it permanently.

## The Share button is missing or fails

* **Missing:** this build has no relay endpoint configured, so the button is
  hidden by design. Use the **Report location** or **Copy summary for sending**
  buttons and send the result to your helper yourself.
* **Fails:** the PC may be offline, a firewall or proxy may block HTTPS, the
  relay may be rate-limiting you or switched off by its maintainer, or the
  bundle may be over the size cap. Nothing is retried in the background. Use
  the manual route and tell your helper.
* **Remove what Share created:** use the **delete my profile** button
  (it removes `%APPDATA%\RAM-Doctor\profile.json`). Ask your helper to delete
  anything already uploaded.

How Share works is documented in [sharing.md](sharing.md); the privacy view is
in [privacy-and-safety.md](privacy-and-safety.md#the-optional-share-button).

## Run it from source, with logs

```powershell
git clone https://github.com/iiKurro/ram-doctor.git
cd ram-doctor

# scan only, plain console output with timestamps
powershell -NoProfile -ExecutionPolicy Bypass -File src\RAM-Doctor.ps1 -NoOpen

# the window, from an elevated prompt
powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\RAM-Doctor-GUI.ps1
```

The window's **details** area shows the same timestamped lines the console
prints. Quarantine writes a log to
`C:\ProgramData\RAM-Doctor\actions-<stamp>.log`.
