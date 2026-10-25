# Contributing to RAM Doctor

> **Code contributions are not accepted.** RAM Doctor is
> [all rights reserved](LICENSE), and the maintainer is the only person who
> writes its code. Pull requests that change code, documentation or tests will
> be closed without merging. Reports and ideas through issues are welcome, and
> they help a lot.

Thanks for helping. RAM Doctor is a security-triage tool that people run with
administrator rights on machines that already have a problem, so the bar is
**correctness, safety and readability** over cleverness. The rest of this guide
documents how the maintainer works, so you can read and review the code.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
Security problems go through the private channel in [SECURITY.md](SECURITY.md),
never a public issue.

## Ways to help

* **False positives / false negatives** are the most valuable reports. Use the
  [false-positive form](https://github.com/iiKurro/ram-doctor/issues/new?template=false_positive.yml).
* Bug reports and feature ideas via the other [issue forms](https://github.com/iiKurro/ram-doctor/issues/new/choose).
  Anything you send there may be used by the maintainer without restriction
  (see section 5 of the [LICENSE](LICENSE)).
* Reading the code and telling the maintainer what you find, including wrong
  or unclear wording in either language (every text is in
  [`src/lib/Strings.ps1`](src/lib/Strings.ps1), see
  [Texts and languages](#texts-and-languages)).

## Project layout

```
src/                  the tool (this is what ships)
  RAM-Doctor-GUI.ps1  Windows 11 style window; only launches the two scripts below
  RAM-Doctor.ps1      read-only scan -> HTML report + plan.json
  RAM-Doctor-Actions.ps1  quarantine / restore / purge / list (the only code that changes the system)
  lib/Native.cs       P/Invoke helpers (pool tags, PID probe, image names, tag search)
  lib/Fluent.cs       Windows 11 style WinForms controls
  lib/Report.ps1      HTML report builder
  lib/Strings.ps1     the one string table (Arabic + English) and Get-Text
  lib/Share.ps1       client of the optional Share button (redaction, bundle, upload)
server/                the relay (Cloudflare Worker) behind the optional Share button
build/Build-SingleFile.ps1   packs src/ into dist/RAM-Doctor.bat
tests/                automated checks (also run by CI)
docs/                 documentation and the project website
```

Read [docs/architecture.md](docs/architecture.md) and
[docs/how-detection-works.md](docs/how-detection-works.md) first.

## Development setup

Requirements: Windows 10/11, **Windows PowerShell 5.1** (`powershell.exe`, not
only PowerShell 7), Git. Optional: PSScriptAnalyzer and Pester.

```powershell
git clone https://github.com/iiKurro/ram-doctor.git
cd ram-doctor

# run the GUI from source (elevated prompt for the full feature set)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\RAM-Doctor-GUI.ps1

# or run only the scan from the command line
powershell -NoProfile -ExecutionPolicy Bypass -File src\RAM-Doctor.ps1 -NoOpen -SampleSeconds 15

# build the single-file release
powershell -NoProfile -File build\Build-SingleFile.ps1      # -> dist\RAM-Doctor.bat
```

### Develop without touching your real system

Point everything at throw-away folders and run the quarantine parts without
elevation (testing mode, user-level changes only):

```powershell
$t = Join-Path $env:TEMP 'rd-dev'
powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\RAM-Doctor-GUI.ps1 `
    -ReportsDir "$t\reports" -QuarantineDir "$t\store" -AllowNonAdmin
```

For end-to-end tests, create a **harmless** test target: compile a tiny console
program with a random-looking name into `%TEMP%`, start it, and register it in
`HKCU\...\Run`. The scan should rate it High and quarantine/restore/purge
should round-trip it. Always clean up afterwards. Never test against real
malware samples.

### Checks to run before opening a PR

```powershell
# 1. every script parses
Get-ChildItem src, build -Recurse -Filter *.ps1 | ForEach-Object {
    $e = $null; $t = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e)
    $e | ForEach-Object { "{0}:{1}  {2}" -f $_.Extent.File, $_.Extent.StartLineNumber, $_.Message }
}

# 2. every .ps1 still starts with a UTF-8 BOM
Get-ChildItem src, build -Recurse -Filter *.ps1 | Where-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName); -not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
} | ForEach-Object { "missing BOM: $($_.FullName)" }

# 3. the single-file build works
powershell -NoProfile -File build\Build-SingleFile.ps1

# 4. automated tests (also run by CI)
Invoke-Pester .\tests
```

CI (`.github/workflows/ci.yml`) runs the same checks on every push and pull
request.

## Coding rules

These exist because each one has bitten this project before.

**PowerShell**

* Target **Windows PowerShell 5.1**. No ternary `?:`, no `??`, no `?.`, no
  `&&` / `||` pipeline chains.
* Every `.ps1` is **UTF-8 with BOM** (`lib/Strings.ps1` holds Arabic text;
  without the BOM Windows PowerShell 5.1 reads it as ANSI and corrupts it).
  Check your editor does not strip it.
* Wrap anything that may return one object in `@(...)` before using `.Count`:
  on a single `[pscustomobject]` `.Count` is `$null` in 5.1.
* `$null | ForEach-Object { ... }` still runs the body once. Guard with `if`.
* `[math]::Max(0, <large int64>)` fails (overload picks `Int32`); use `0.0` and
  cast to `[double]`.
* PowerShell variables are case-insensitive: do not name a variable `$plan`
  when a parameter called `$Plan` exists. Do not name a variable `$pid`.
* Pass number lists to scripts started with `-File` as a **string**
  (`-Select 1,3`): a typed `[int[]]` parameter turns `1,2` into `12`.
* Console and log lines are **English ASCII** (Arabic is garbled in conhost),
  whatever language the window uses; the translated texts are for the GUI, the
  HTML report, the share messages and the copy-summary text.
* **No user-facing literal outside `src/lib/Strings.ps1`**, see
  [Texts and languages](#texts-and-languages).
* **The scan never uses the network and there is no telemetry.** The only
  network code is the optional *Share with my helper* flow
  ([docs/sharing.md](docs/sharing.md)): it does nothing until the user presses
  Share and confirms, it is hidden in builds whose `share.config.json` endpoint
  is empty, it uploads only the redacted three-file bundle (`summary.md`,
  `report.html`, `plan.json`) to the helper's private repository through the
  relay, and the program holds no token or secret (the relay does). Do not add
  telemetry, `Invoke-Expression` on dynamic input, hidden windows, or
  base64/obfuscated payloads. See
  [docs/privacy-and-safety.md](docs/privacy-and-safety.md).
* **Never commit secrets**: GitHub tokens, Worker secrets, `.dev.vars`, invite
  codes. Use `wrangler secret put` for the relay, and see
  [SECURITY.md](SECURITY.md) if you find one.
* Anything that changes the system lives **only** in `RAM-Doctor-Actions.ps1`,
  must be reversible unless it is `Purge`, must re-validate its target
  immediately before acting, and must record an undo entry in the manifest.

**C#** (compiled by `Add-Type` on Windows PowerShell 5.1)

* C# **5** only: no string interpolation, `?.`, `nameof`, expression-bodied
  members or `out var`.
* Read-only helpers belong in `lib/Native.cs`; keep P/Invoke signatures
  minimal and documented.

**Batch** (`build/` header, launchers): ASCII only, CRLF, no parenthesised
blocks that expand paths (a `)` in a file name breaks them), use `goto`.

**General**

* No personal data in code, fixtures, screenshots or docs: use the user
  `Friend` and the host `DESKTOP-DEMO`. Scrub paths, user names and host names
  from any report you attach to an issue.
* Keep the report/plan JSON schema backwards compatible when you can; document
  changes in [docs/architecture.md](docs/architecture.md).
* Add or adjust a test for every bug fix and every new signal.
* **Redaction and the relay need tests too.** Anything that produces text meant
  to leave the PC (the *copy summary* text and the optional upload bundle) must
  come with fixtures (synthetic data only) proving the Windows user name, PC
  name, e-mail addresses and secrets in command lines do not survive. Changes to the
  Worker must cover rate limiting, the 3-file whitelist, the 2 MB cap, report
  sanitising, name sanitising, the kill switch and (when enabled) invite codes. See [server/README.md](server/README.md) for how to run the
  Worker tests and [docs/sharing.md](docs/sharing.md) for the protocol.
* Adding a detection signal? Give it a key, a weight, a reason string (a key in
  both language tables, see below), and an entry in
  [docs/how-detection-works.md](docs/how-detection-works.md).

### Texts and languages

Everything a person can read lives in **one** file, `src/lib/Strings.ps1`: an
`ar` table and an `en` table with the same keys (`area.topic`, e.g.
`obs.npp.high.t`, `rpt.sus.why`, `gui.btn.scan`, `share.msg.offline`). Code asks
for a text with `Get-Text 'key' $arg0 $arg1` (templates use `{0}`, `{1}`;
`\n` is a line break). The language is Arabic when the Windows display
language is Arabic and English otherwise; every script that shows text takes
`-Lang ar|en`, and the window has a button that switches it live. Nothing about
the language is ever saved.

* New or changed text: edit **both** tables in the same commit. Write English
  without apostrophes (the tables are single-quoted strings) and keep a
  template's placeholders identical in both languages.
* The scan writes its observations, reasons and verdict **in the scan language**
  and adds `"lang": "ar|en"` to the plan; the plan schema is otherwise
  unchanged. Plans without `lang` (older releases) count as Arabic.
* The report follows `$data.Lang` (`<html lang dir>`, Arabic RTL / English LTR)
  and must keep the inert-report contract in both languages.
* `tests/Strings.Tests.ps1` fails on a key missing in one language, different
  placeholders, Arabic inside the English table, an untranslated (identical)
  text, a key used in code but not defined, a defined key nobody uses, and any
  Arabic literal outside `Strings.ps1`.
* Layout: the window is mirrored by `RightToLeft` / `RightToLeftLayout`, and the
  `Fluent.cs` controls draw correctly in both directions: do not hard-code
  left/right, use the control's `RightToLeft` (see how `FList` / `FInfoBar`
  do it).

## Commits and pull requests

* [Conventional Commits](https://www.conventionalcommits.org/): `feat:`,
  `fix:`, `docs:`, `refactor:`, `test:`, `build:`, `ci:`, `chore:`. Optional
  scope: `feat(scan): ...`, `fix(actions): ...`, `docs(readme): ...`.
* Keep PRs focused; describe *why*, link the issue, tick the checklist in the
  PR template. Update [CHANGELOG.md](CHANGELOG.md) under **Unreleased**.
* Rebase on `main`; CI must be green.

## Releasing (maintainer)

1. Move **Unreleased** entries to a new version in `CHANGELOG.md`.
2. Tag `vX.Y.Z` and push the tag. The **Release** workflow builds
   `RAM-Doctor.bat`, writes `SHA256SUMS.txt`, and attaches both to the GitHub
   Release.
