# How detection works

RAM Doctor answers two questions:

1. **Where is the memory going?** (memory accounting, kernel pool, growth)
2. **Is something on this PC suspicious?** (signals, scoring, persistence,
   hidden processes)

Everything is a **heuristic indicator**, not a verdict. A *High* rating means
"several independent warning signs coincide, look at it", never "this is
malware". This page is honest about what is and is not covered.

Contents: [memory accounting](#memory-accounting) ·
[verdict thresholds](#verdict-thresholds) ·
[kernel pool tags](#kernel-pool-tags) ·
[signals and weights](#signals-and-weights) ·
[trust classes](#trust-classes) · [locations](#locations) ·
[grouping and risk](#grouping-persistence-and-risk) ·
[hidden processes](#hidden-process-probe) · [network](#network) ·
[limits](#what-is-not-detected)

## Memory accounting

```
Used        = TotalVisible - Available                 (Available = free + standby)
SumWS       = sum of Working Set of all processes      (includes shared pages)
SumPrivate  = sum of Private Working Set               (what Task Manager shows)
Shared      = max(0, SumWS - SumPrivate)               (upper bound: shared pages repeat)
Unaccounted = max(0, Used - SumWS - NonPagedPool - Modified)
```

* **Non-paged pool** and **paged pool** are kernel memory that belongs to no
  process. A driver leak shows up here.
* **Unaccounted** is what is *not* inside any process working set and not
  non-paged pool or the modified list: driver-locked memory, AWE, RAM disks,
  hardware-reserved regions, or a hidden process. Earlier versions compared
  against *private* working sets only and mis-reported large shared regions
  (games, browsers, file cache) as "missing"; comparing against full working
  sets avoids that false alarm.
* **Standby / cached** memory is reclaimable and is *not* a problem even though
  it counts as "used" in some views.
* Hardware-reserved memory (installed minus usable) is reported as information.

A second snapshot is taken after an observation window (default 30 s, at least
that long since snapshot 1). Deltas are computed per process (private bytes),
for the pools, commit, used memory and per pool tag.

## Verdict thresholds

`R` = usable RAM. `-ThresholdScale` multiplies every byte threshold below
(for example `0.5` to be twice as sensitive).

| Observation | Level | Condition |
| --- | --- | --- |
| Kernel leak: non-paged pool | high | `NonPaged >= max(3 GB, 12% of R)` |
| Non-paged pool above normal | med | `NonPaged >= max(1.5 GB, 6% of R)` |
| Paged pool bloat | high | `Paged >= max(3 GB, 12% of R)` |
| Large memory outside any process | high | `Unaccounted >= max(4 GB, 20% of R)` |
| Memory partly unattributed | med | `Unaccounted >= max(2 GB, 10% of R)` |
| Leak is active right now | high | non-paged or paged grew >= 30 MB during the window |
| A process is growing | med | top grower gained >= 100 MB during the window |
| Biggest consumer | info / med | one program >= 30% of used memory (med if not signed) |
| Near the commit limit | med | `Committed >= 90%` of the commit limit |
| Fast Startup + long uptime | med | Fast Startup on and uptime >= 7 days (shutdown does not reset the kernel) |
| Defender real-time off / recent detections | med | from `Get-MpComputerStatus` / `Get-MpThreatDetection` |
| Hidden live process | high | see [hidden processes](#hidden-process-probe) |
| Zombie of a non-Windows binary | med | terminated process still referenced |
| Winlogon `Shell`/`Userinit` changed, AppInit_DLLs on | high | registry |
| IFEO `Debugger` set | med | registry |
| Standby >= 25% of R | info | explains "used" memory that is reclaimable |
| Hardware reserved >= 1 GB | info | BIOS / integrated graphics |

The **headline** is chosen in this order: hidden live process or any High
suspect, then kernel-pool thresholds, then unaccounted memory, then any medium
observation, otherwise "no clear leak or malicious indicator right now".
A scan only sees **the moment it runs**; run it while the problem is visible.

## Kernel pool tags

`NtQuerySystemInformation(SystemPoolTagInformation)` returns, per 4-character
tag, allocations, frees and bytes in paged and non-paged pool. RAM Doctor:

* shows the top 12 non-paged, top 6 paged, and up to 6 tags that **grew by at
  least 1 MB** during the window;
* describes about fifteen well-known Windows tags (`File`, `MmCa`, `EtwB`,
  `NVRM`, ...) from a built-in dictionary;
* maps the remaining printable tags to **candidate drivers** by scanning the
  binaries of the running drivers for the 4 raw bytes. A tag found in more than
  8 files is reported as "too generic to attribute".

Limits: this is the same heuristic people use with `findstr` on
`System32\drivers`. A tag string can occur by chance in an unrelated file, and
a driver can build its tag at run time. Treat the mapping as a lead, then
confirm with PoolMon, RAMMap, or by updating/removing the suspect driver and
measuring again.

## Signals and weights

Each inventory item (process, service, task, autorun, driver, WMI consumer) is
scored independently, then merged per file. A signal has a *key*; when several
items of the same file raise the same key, the highest value counts once.

"Weak trust" below means the file is `Unsigned`, `Untrusted`, `Tampered`,
`Script` or `Missing` (see [trust classes](#trust-classes)).

| Key | Points | When |
| --- | ---: | --- |
| `missing` | +5 | A **running process** whose file is gone from disk (deleted after launch / in-memory). A dangling startup entry for an uninstalled program is *not* scored. |
| `unsigned` | +2 | No Authenticode signature. |
| `untrusted` | +3 | Signature present but not trusted (`NotTrusted`, `UnknownError`, ...). |
| `tampered` | +8 | `HashMismatch`: the file was modified after signing. |
| `zone` | +3 | Weak trust and running from `Temp`, `Public` (incl. Recycle Bin, PerfLogs) or `Downloads`. |
| `zone` | +2 | Weak trust and running from `AppData` or `ProgramData`. |
| `zone` | +1 | Weak trust and running from `AppData\Local\Programs` (the standard per-user install folder). |
| `zone` | +2 | *Validly signed* by a third party but running from `Temp` / `Public`. |
| `random` | +2 | Weak trust and a random-looking file name (hex strings, consonant-heavy names, long alphanumerics with digits). |
| `verinfo` | -1 | Weak trust but complete version info (company, product, description): real software usually has it. |
| `masq` | +8 | Not Microsoft-trusted, named like a core Windows process (`svchost`, `lsass`, `explorer`, ...) and located **outside** `%WINDIR%`. |
| `lookalike` | +7 | Not trusted and one edit away from a core name (`svchosts.exe`, `scvhost.exe`). Names of at least 5 characters. |
| `miner` | +8 | Command line matches miner indicators (`xmrig`, `stratum+tcp`, `--donate-level`, pool names, `-o host:port -u`, ...). |
| `encoded` | +3 / +6 | Encoded or download-and-run PowerShell patterns (`-enc`, `FromBase64String`, `DownloadString`, `IEX (`, ...). **+3 for a running process, +6 when wired into startup.** |
| `lolbin` | +6 / +7 | `mshta` / `regsvr32` / `certutil` / `bitsadmin` / `msiexec` with a URL or `-urlcache` / `scrobj`. Running / startup. |
| `urlcmd` | +1 / +3 | A scripting host (`powershell`, `wscript`, `mshta`, `rundll32`, ...) with an `http(s)://` argument. |
| `argpath` | +1 / +3 | A scripting host launching something from `Temp`, `AppData`, `ProgramData` or `Public`. |
| `parent` | +6 | `svchost.exe` not started by `services.exe`; `lsass.exe` / `services.exe` not started by `wininit.exe`. |
| `dup` | +8 | More than one `lsass.exe`. |
| `netmine` | +6 | Established connection to a common mining-pool port (3333, 4444, 5555, 7777, 14433, 14444, 45560, 45700). |
| `netunsigned` | +1 | Unsigned/untrusted/tampered process with an established connection to a public address. |
| `growth` | +2 | Private bytes grew by >= 200 MB during the window (not for Windows/Microsoft binaries). |
| `wmi` | +6 | A permanent WMI event consumer other than the built-in *SCM Event Log Consumer* (a classic fileless-persistence technique). |
| `persist` | +1 | The same file is also wired into a service, task, autorun, driver or WMI consumer, **and** the score is already >= 4 (so it comes back after a restart). |

Why a running process weighs less than the same command in startup: many
legitimate apps start PowerShell/cmd with odd arguments, whereas an encoded
command wired into a scheduled task or Run key is a much stronger indicator.

The tool never scores its own process chain (the powershell/cmd that launched
it).

### Trust classes

| Class | Meaning |
| --- | --- |
| `OS` | Valid Microsoft signature (catalog or embedded) **and** located under `%WINDIR%`. Also assigned to kernel pseudo-processes without a file (`System`, `Registry`, `Memory Compression`, `Secure System`, `vmmem`). |
| `MS` | Valid Microsoft signature elsewhere (for example Defender, Edge). |
| `Signed` | Valid signature from another publisher. |
| `Unsigned` | `NotSigned`. |
| `Tampered` | `HashMismatch`. |
| `Script` | File type that cannot carry a signature (`.bat`, `.cmd`, `.lnk`). |
| `Untrusted` | Any other signature status. |
| `Missing` | Path does not exist. |
| `Unknown` | No path could be determined (shown neutrally, never scored). |

Signature checking uses `Get-AuthenticodeSignature`, which also validates
**catalog-signed** Windows files. Paths of protected processes are recovered
from the kernel (`GetImageName`) when the normal query is denied.

### Locations

| Zone | Examples |
| --- | --- |
| `Windows` | `%WINDIR%\...` (except `%WINDIR%\Temp`, which is `Temp`) |
| `Temp` | any `...\Temp\...` folder, `%WINDIR%\Temp` |
| `Public` | `C:\Users\Public`, `$Recycle.Bin`, `C:\PerfLogs` |
| `Downloads` | `...\Downloads\...` |
| `UserPrograms` | `...\AppData\Local\Programs\...` |
| `AppData` | other `...\AppData\...` |
| `ProgramData` | `C:\ProgramData\...` |
| `ProgramFiles` | `C:\Program Files*\...` |
| `Other` | everything else |

## Grouping, persistence and risk

1. Items that point to the **same file** are merged into one *suspect*; its
   contexts (processes, services, tasks, autoruns, drivers, WMI) are listed
   together so one action can cover them all.
2. Windows/Microsoft-signed binaries (`powershell.exe`, `cmd.exe`) are shared
   by countless innocent commands, so each item is judged **separately**, and
   the file itself is never offered for quarantine (`protectedFile = true`).
3. The score is the sum of the unique signals (plus `persist`).

| Score | Risk | Offered by default for quarantine |
| ---: | --- | --- |
| >= 8 | **High** | yes (pre-selected in the GUI) |
| 5-7 | **Medium** | yes |
| 3-4 | **Low** | no (`-IncludeLow` on the command line) |
| < 3 | not reported | n/a |

Typical examples (synthetic): an unsigned program in `AppData` with a normal
name is `Low`; an unsigned, randomly named program in `Temp` that is also in a
Run key is `High` (3 + 2 + 2 + 1 = 8).

## Hidden-process probe

A rootkit can unlink a process from the lists that `Get-Process`, WMI and Task
Manager use while it still runs. The probe asks the kernel directly:

1. Take the process lists (`Get-Process`, `Win32_Process`).
2. Walk PIDs `4, 8, 12, ... 400000` with
   `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`.
   `opened + still running` is **A**; `access denied` is **D**.
3. Take the lists again (so processes that started during the probe are not
   mistaken for hidden ones).
4. A PID that is in the probe but in neither list is a *candidate*. Re-probe
   after 2 seconds; only persistent candidates remain.
5. Ask the kernel for the image name (`SystemProcessIdInformation`).

Classification:

* **Live and hidden**: `A` and not listed. A strong rootkit indicator (*high*).
  A rootkit that hooks `OpenProcess` itself can still hide from this.
* **Zombie**: `D` and not listed. A process that **already exited** but whose
  kernel object is kept alive because another program holds a handle to it.
  This is common and harmless: on a clean Windows 11 machine you typically see
  a few `msiexec.exe` / `mofcomp.exe` zombies. They are listed in the report;
  only zombies of non-Windows binaries raise a medium observation.

## Network

Established TCP connections to **public** addresses (loopback, link-local,
RFC 1918 and unique-local ranges are ignored) are mapped to owning processes.
They feed `netmine` and `netunsigned` and appear in a suspect's details. Only
the current connection table is read; nothing is captured or sent.

## What is NOT detected

Be skeptical of a clean result in these situations:

* **A single snapshot.** If the leak is intermittent, scan while it is visible.
* **Kernel rootkits that also hook the probe**, boot-level malware, firmware
  implants. Use offline scanners (Microsoft Defender Offline, a rescue disk).
* **Signed malware, stolen certificates, living-off-the-land use of legitimate
  tools** without the suspicious command-line patterns above.
* **Malware inside legitimate processes** (injected code, malicious browser
  extensions): the process looks normal; module/handle/memory inspection is
  not performed.
* **Exact attribution of a pool leak**. Tag-to-driver mapping is a heuristic.
* **GPU/VRAM, hypervisor and container memory** beyond what shows in the
  process list (`vmmem`).
* **Memory-type breakdown** like RAMMap's *Use Counts* (driver-locked, AWE,
  mapped-file categories). RAM Doctor tells you the remainder exists and sends
  you to RAMMap for the category.
* **Windows editions or locales** other than the English Windows 11 it was
  developed on are expected to work (counters are read through locale-neutral
  WMI classes) but have had less testing.

Scoring weights were tuned on a small number of machines. If a weight
misfires on your system, please file a
[false-positive report](https://github.com/iiKurro/ram-doctor/issues/new?template=false_positive.yml).
