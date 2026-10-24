# Tests and checks

Everything here runs on **Windows PowerShell 5.1** (`powershell.exe`, built into Windows 10/11): that is the only host the
product supports, so it is also the only host the tests use. No admin rights are needed and nothing outside a temp folder
is touched.

## One command

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-Checks.ps1
```

It runs, in order, and exits `1` if anything fails:

| # | Check | What it catches |
|---|-------|-----------------|
| 1 | PowerShell files parse | syntax errors in `src/`, `build/`, `tests/` |
| 2 | Encodings | Arabic text without a UTF-8 BOM (PowerShell 5.1 would garble it), `.bat` files that are not ASCII + CRLF, BOMs or tabs where they break tooling |
| 3 | C# compiles | `src/lib/*.cs` in a fresh `powershell.exe` (so only C# 5 features are allowed) |
| 4 | Personal data and secrets | local user/PC names, personal paths and e-mail, GitHub/Cloudflare/AWS/Slack tokens, private keys |
| 5 | Leftovers | unfinished-work markers and merge-conflict markers |
| 6 | `src/share.config.json` | parses and has `endpoint`, `helperName`, `maxBytes` (an empty `endpoint` is fine) |
| 7 | `build/VERSION` | valid `x.y.z`, and mentioned in `CHANGELOG.md` |
| 8 | PSScriptAnalyzer | rules in [`PSScriptAnalyzerSettings.psd1`](PSScriptAnalyzerSettings.psd1) (every exclusion is justified there) |
| 9 | Pester | every `tests/**/*.Tests.ps1` except `tests/gui/` |

Useful switches: `-SkipPester`, `-SkipAnalyzer`, `-SkipCompile`, `-FailOnWarning`, `-InstallMissing` (installs Pester 5 /
PSScriptAnalyzer from the PowerShell Gallery for the current user), `-ResultsDir <folder>` (NUnit XML is written there).

A fake token that must stay in a test fixture can opt out of the secret scan by putting the text `allow-secret-scan` on the
same line (in a comment).

## Pester

Pester **5.5 or newer** is required (Windows ships 3.4, which cannot run these files).

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path tests -ExcludeTagFilter Gui        # or just run Invoke-Checks.ps1
```

CI pins the exact version through the `RAMDOC_PESTER_VERSION` environment variable (currently 5.7.1); set it locally to
reproduce CI exactly.

| File | Covers |
|------|--------|
| `Build.Tests.ps1` | structure and reproducibility of the **release** `dist/RAM-Doctor.bat`: plain ASCII header, no BOM, version stamp, markers, size, deterministic bytes, `SHA256SUMS.txt`, `-Verify`; **no environment-controlled behaviour** (no `RAMDOC_` text, no `-TestScript` pass-through, PowerShell reads only `$env:SELF`, cmd.exe reads only an allow-list of variables, planted hooks are caught); and that the `-DevHooks` test variant stays in step with it (identical payload and secure-folder code) |
| `Unpacker.Tests.ps1` | the unpack command of the **test variant** (`-DevHooks`): every file byte-identical to its source (UTF-8 BOM + CRLF); the header's ACL helpers (SYSTEM + Administrators only, junctions and foreign owners rejected); headless runs (paths with spaces, damaged package, old leftovers swept, nothing left behind). On an administrator session it exercises the *secure* mode (`%ProgramData%\RAM-Doctor-run\<random>`); its `Elevated`-tagged tests also check the real folder and parent ACLs |
| `PlanSchema.Tests.ps1` | the plan JSON contract between the scan (writer) and the actions script / window (readers) |
| `Heuristics.Tests.ps1` | pure helper functions of the scan engine, lifted out with the parser (the scan is not run) |
| `Actions.Tests.ps1` | quarantine -> restore -> purge on a harmless fixture, plus the safety invariants (other-PC plans refused, changed files skipped, protected files never moved) |
| `Elevated.Tests.ps1` | **administrator only** (25 tests, skipped cleanly otherwise): the locked-down store at `C:\ProgramData\RAM-Doctor` (ACL, re-verification, junction / foreign-owner handling), the quarantine -> restore -> purge cycle on the real default store, forged-manifest refusals, service start-type changes (test services are created and deleted), the native-helper loader (ACL'd compiler folder, `csc.exe` fallback) |
| `Gate.Tests.ps1` | proves the static gate catches what it claims to (12 planted problems, a planted `RAMDOC_` hook in a packed script, a release workflow that builds with `-DevHooks` or publishes anything but the two release files) and accepts a clean repository |
| `Report.Tests.ps1` | the HTML report is inert and well-formed (wraps `fixtures/Test-ReportSafety.ps1`) |
| `share/` | the opt-in report-sharing feature (unit + integration against a local mock relay) |

## Tests that need an administrator session

They are tagged `Elevated`. A normal console skips them (so `Invoke-Checks.ps1` stays green for contributors); CI runs them in the `elevated` job, and you can run them yourself from *Windows PowerShell (Admin)*:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-ElevatedTests.ps1
```

That runner exits `2` on a non-admin session and `1` when too few tests really ran, so a skipped suite can never look green. Everything the tests create is named `RamDoctorCiTest-*` and is removed again; an existing `C:\ProgramData\RAM-Doctor` is never modified beyond what a normal run does. `Invoke-Checks.ps1 -ExcludeTag Elevated` leaves them out (CI's `checks` job does, because `elevated` covers them).

## The release file and the test variant

`dist/RAM-Doctor.bat` runs as administrator, so **nothing the environment can set steers it**: no `RAMDOC_*` switch, no script pass-through. Tests that have to drive a `.bat` headless (skip the UAC prompt, only unpack, hand arguments to the window) use a **separate test-only file**, built on request and never published:

```powershell
.\build\Build-SingleFile.ps1                # dist\RAM-Doctor.bat            release: no environment hooks
.\build\Build-SingleFile.ps1 -DevHooks      # dist\RAM-Doctor.devhooks.bat   banner "TEST BUILD - not for distribution"
```

Both carry a byte-identical payload and share the same secure-unpack code, so the tests of the test variant exercise the release logic; the build refuses to write the test variant under the release name. The release file is protected by:

* `Build-SingleFile.ps1 -Verify` (and `Get-ReleaseHygieneProblems` in `build/BuildCommon.ps1`): fails on any `RAMDOC_`, `-TestScript`, environment API or unexpected `%variable%` in the header, and on a `RAMDOC_*` name in the payload other than the sharing secrets the window hands to its own child process;
* `Invoke-Checks.ps1` stages 7b (builds the release and inspects it) and 7c (`release.yml` builds without `-DevHooks`, publishes only `RAM-Doctor.bat` + `SHA256SUMS.txt`; no workflow uploads the test build);
* `Build.Tests.ps1` (above), which also plants hooks and checks they are rejected.

## Scripts used by CI

| Script | Purpose |
|--------|---------|
| `tests/Invoke-ScanSmoke.ps1` | checks the built release `.bat` (no hooks), builds the test variant into a temp folder and checks its payload is byte-identical, unpacks it, runs a real read-only scan (`-SampleSeconds 5`), asserts what it wrote (report + plan, plan contract, light footprint) |
| `build/Build-SingleFile.ps1 -Verify` | builds `dist/RAM-Doctor.bat` and `dist/SHA256SUMS.txt`, checks the release has no hooks, then unpacks the test variant's copy of the payload and compares every file with its source |
| `build/Expand-SingleFile.ps1` | runs the real unpack command of a **test-variant** `.bat` in unpack-only mode (secure folder when elevated, a private temp folder otherwise) and compares the result with the sources (used by the tests; it refuses the release file, which has no unpack-only mode) |
| `tests/Invoke-ElevatedTests.ps1` | runs every `Elevated`-tagged test; refuses to run unelevated (exit 2) and fails when fewer than 20 of them passed |
| `tests/gui/Flow.Test.ps1` | optional end-to-end test of the window; needs an interactive desktop, so CI treats it as non-blocking |

## The relay worker (Node)

```powershell
cd server
node --check worker/src/index.js
node --test            # Node 20 or newer
```

## Adding a test

* Put a `*.Tests.ps1` file in `tests/` (Pester 5 syntax: `BeforeAll`, `Describe`, `It`).
* Use synthetic data only; the repository is public and `Invoke-Checks.ps1` fails on personal data.
* Do not stop processes or touch services in a test. Work inside `New-TempDirectory` (see `helpers/TestHelpers.ps1`).
