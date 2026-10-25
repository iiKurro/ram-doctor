# How detection works

RAM Doctor answers two questions:

1. **Where is the memory going?** (memory accounting, kernel pool, growth)
2. **Is something on this PC suspicious?** (signals, scoring, persistence,
   hidden processes)

Everything is a **heuristic indicator**, not a verdict. A *High* rating means
"several independent warning signs coincide, look at it", never "this is
malware". This page is honest about what is and is not covered.

Contents: [memory accounting](#memory-accounting) ·
[driver-reserved memory](#driver-reserved-memory-pool-tag-cont) ·
[verdict thresholds](#verdict-thresholds) ·
[kernel pool tags](#kernel-pool-tags) ·
[signals and weights](#signals-and-weights) ·
[trust classes](#trust-classes) · [locations](#locations) ·
[grouping and risk](#grouping-persistence-and-risk) ·
[hidden processes](#hidden-process-probe) · [network](#network) ·
[limits](#what-is-not-detected)

## Memory accounting

The question behind the tool is "my RAM is full, why does Task Manager show
nothing?". Task Manager's default **Memory** column shows each process's
**private working set** only, so everything else that is in use is invisible
there. RAM Doctor splits the memory in use into parts that add up exactly:

```
Used        = TotalVisible - Available                 (Available = free + standby)
Private     = sum of Private Working Set               (what Task Manager shows)
SharedSum   = sum of (Working Set - Private WS)        (a page counts once per process that maps it: an upper bound)
Hidden      = Used - Private                           (what Task Manager does not show)
  Kernel      = Non-paged pool + Paged pool resident
  System      = System cache resident + pageable driver code resident + Modified list
  Drivers     = driver-reserved contiguous memory      (pool tags ConT / Cont, see below)
  Shared      = min(what is left, SharedSum)           ESTIMATE: shared memory of programs, each page once
  Unexplained = what is left beyond SharedSum
Unattributed = Drivers + Unexplained                   (the corrected "not attributed to any process")
Unaccounted  = max(0, Used - SumWS - NonPagedPool - Modified)   (formula of 1.0-1.1.2, kept in the plan)
```

Each part takes at most what is left of `Hidden`, in the order listed, so
sampling noise (the counters are read a few milliseconds apart) can never make
the parts add up to more than the memory in use, and no part is negative.

* **Shared** is an estimate. Windows has no counter for "shared pages, each
  counted once" (only RAMMap's page-by-page walk has that), so it is what is
  left after everything measurable is taken out, capped by `SharedSum`. It also
  holds small kernel structures that have no counter (page tables, kernel
  stacks). Browsers and launchers with many processes hold most of it: the
  consumers table shows `Working Set - Private` per program (summed over its
  processes, so it overcounts too; it is for ranking, not adding up).
* **Non-paged pool** and **paged pool** are kernel memory that belongs to no
  process. A driver leak shows up here.
* **Unexplained** is what is left even if every shared page were counted once
  per process: driver-locked pages the tag table does not record
  (`MmAllocatePagesForMdl`), AWE, RAM disks, or a hidden process.
* **Why the old "not attributed" said 0 on the PC that started this project.**
  Its formula subtracted the *summed* working sets. With 30 browser processes
  mapping the same DLLs that sum is far larger than the real shared memory, so
  it cancelled out 2.3 GB of driver reservations: Used 18.19 GB, private 8.56,
  `SharedSum` 9.88, non-paged 0.9, modified 0.14 gives
  `18.19 - 18.44 - 0.9 - 0.14 < 0`, so 0. The breakdown measures the driver
  reservations on their own: Hidden 9.63 = shared ~4.47 + drivers 2.26 +
  kernel pools 2.07 + cache, driver code and modified 0.83 + unexplained 0.
  `UnaccountedGB` stays in the plan for older readers; the report, the summaries
  and the observations use the corrected values.
* **Standby / cached** memory is reclaimable and is *not* a problem even though
  it counts as "used" in some views. It is not part of `Used` above.
* Hardware-reserved memory (installed minus usable) is reported as information.

### Driver-reserved memory (pool tag `ConT`)

Drivers that need physically contiguous memory (DMA buffers, graphics rings and
frame buffers, capture and virtual-display devices) call
`MmAllocateContiguousMemory*`. In the Windows Research Kernel sources the
memory manager serves a small request from the non-paged pool under the tag
`MmCm` (that memory *is* in the pool counter), and otherwise takes free pages
straight from the physical page lists and only *records* them in the pool tag
table with `ExInsertPoolTag` under `Cont`. Windows 10 and 11 record them under
`ConT`. Those bytes appear in PoolMon and in the report's tag table but are not
part of **Pool Nonpaged Bytes**, and they belong to no process, so Task Manager
cannot show them anywhere. On the scan that started this project `ConT` held
2310 MB while the whole non-paged pool counter was 0.9 GB, which is only
possible because they are outside it.

What counts, precisely:

* The tags `ConT` and `Cont`, compared case-sensitively (pool tags are). On the
  development PC (Windows 11, one discrete GPU) they hold 7 MB (347 live
  blocks, about 21 KB each) and 6 MB (405 live blocks, about 16 KB each):
  multi-page blocks, as contiguous allocations are. `MmCa` (control areas of
  mapped files), `MmCm` and every driver's own tag are ordinary pool memory and
  are already inside the pool counters, so they are not in this class.
* A check against the counter (`Get-DriverReservedBytes`): when the *other*
  non-paged tags already explain at least half of the counter, at most
  `counter - others` of the contiguous bytes could hide inside it, so they count
  in full (the documented case). Otherwise only the part the counter provably
  cannot hold (`others + contiguous - counter`) counts. A Windows build that did
  put them inside the pool is therefore never counted twice by much.
* Without the tag table (the native helper failed) the value is unknown, not 0:
  `DriverReservedKnown` is `false`, the report and the summaries say so, and any
  such memory ends up in the shared estimate.

The tag is written by the memory manager on behalf of whichever driver asked,
so it **cannot name the driver** (and the byte search used for other tags would
only find chance matches, so it is skipped for these two). The observation
lists **candidates** honestly as candidates: the display adapters (from
`Win32_VideoController`, trademark marks removed) and running graphics,
capture, virtual-display or virtual-machine drivers whose file is not
Microsoft's. The company in the file's version information decides that, not
the signature, because graphics drivers are WHQL-signed by Microsoft. The usual
causes and fixes: an integrated GPU that is enabled although the monitor is on
the discrete card (disable it in the BIOS/UEFI), outdated graphics drivers,
virtual display or capture software that is no longer used. RAMMap's
*Use Counts* tab (row *Driver Locked*) confirms memory that drivers hold
outside the pools.

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
| A hardware driver keeps reserving memory | high | `Drivers >= 2 GB` **and** the contiguous tags grew by >= 30 MB during the window |
| Memory reserved by a hardware driver | med | `Drivers >= 512 MB` |
| Large memory outside any process | high | `Unexplained >= max(4 GB, 20% of R)` |
| Memory partly unattributed | med | `Unexplained >= max(2 GB, 10% of R)` |
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

Why these driver-reservation thresholds: contiguous allocations are normally a
handful of DMA buffers (13 MB on the development PC), so 512 MB is far above
normal and still catches the case that started this project (2.3 GB) as
*medium*, worded as "memory reserved by a hardware driver, not a virus". A
large but **stable** reservation is a driver setting or a second graphics
adapter, not a leak, so it never becomes *high* on its size alone: that needs
2 GB **and** growth during the window (30 MB, the same rule as the kernel-pool
leak). `-ThresholdScale` scales 512 MB and 2 GB like the other byte thresholds.
The "unattributed" rows use `Unexplained`, which no longer counts the kernel
pools, the cache or the driver reservations (they have their own rows) and no
longer hides behind double-counted shared pages.

The **headline** is chosen in this order: hidden live process or any High
suspect, then kernel-pool thresholds, then a growing driver reservation, then
unexplained memory. Then, when no observation is High, the headline answers the
user's real question with the two biggest parts of the memory Task Manager does
not show (only when at least 1 GB is hidden), for example *"No leak found: most
of the memory Task Manager does not show (9.6 GB) is shared memory of open
programs (~4.5 GB) and memory reserved by hardware drivers (~2.3 GB)"*,
followed by *"; other findings are listed below"* when there are medium
findings. "No leak found" is left out while a program is growing by 100 MB or
more during the window (the sentence then starts with "Most of the memory").
Otherwise any medium observation, otherwise "no clear leak or malicious
indicator right now". The verdict
**level** is still the highest observation level, so the window's bar keeps its
colour. Observations of the same level keep the order in which they were found:
the memory explanations (kernel pool, driver reservation, unexplained memory)
come before the security findings (suspicious files, Defender history).
A scan only sees **the moment it runs**; run it while the problem is visible.

## Kernel pool tags

`NtQuerySystemInformation(SystemPoolTagInformation)` returns, per 4-character
tag, allocations, frees and bytes in paged and non-paged pool. RAM Doctor:

* shows the top 12 non-paged, top 6 paged, and up to 6 tags that **grew by at
  least 1 MB** during the window;
* describes about fifteen well-known Windows tags (`File`, `MmCa`, `EtwB`,
  `NVRM`, `ConT`, ...) from a built-in dictionary (tags are compared
  case-sensitively: `ConT` and `cont` are different tags);
* adds the contiguous tags `ConT` / `Cont` to the
  [driver-reserved memory](#driver-reserved-memory-pool-tag-cont), because they
  are recorded outside the pool counters;
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
* **An exact memory-type breakdown** like RAMMap's *Use Counts*. RAM Doctor
  separates private memory, kernel pools, cache, driver reservations recorded
  in the pool tag table and the rest, but the shared part is an estimate, and
  driver-locked pages that the tag table does not record (`MmAllocatePagesForMdl`,
  AWE) are only visible as "unexplained" (or inside the shared estimate when
  the shared working sets are large). RAMMap walks every page and settles it.
* **Which driver** reserved contiguous memory: the tag is written by Windows
  for the caller, so the report lists candidates only.
* **Windows editions or locales** other than the English Windows 11 it was
  developed on are expected to work (counters are read through locale-neutral
  WMI classes) but have had less testing.

Scoring weights were tuned on a small number of machines. If a weight
misfires on your system, please file a
[false-positive report](https://github.com/iiKurro/ram-doctor/issues/new?template=false_positive.yml).
