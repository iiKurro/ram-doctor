# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.2] - 2026-10-25

### Fixed

- **Switching the language closed the window** (1.1.0 and 1.1.1). Mirroring the frame for Arabic makes Windows
  re-create the window, and the window was shown as a modal dialog, whose loop ends when its window is destroyed. It is
  now run with `Application.Run`, which knows a re-created window is not a closed one.
- `tests/gui/LangSwitch.Test.ps1` (CI desktop job) switches the language the way a user does, from a click that
  returns, and checks that the window is still open after each of three switches. The flow test missed this because
  it drives everything from inside one handler.

## [1.1.1] - 2026-10-25

### Added

- **Sharp at any display scale.** The window makes itself dpi-aware (Per-Monitor V2 on Windows 10 1703+, per-monitor or system
  awareness on older builds) before its first window exists, so Windows no longer stretches a blurry bitmap of it at 125-200 %. Every
  size, font, padding, corner, icon and the custom painting follow the monitor's scale, and the window re-scales itself when it is moved
  to a monitor with another scale.
- **Screen readers.** Every control of the window says what it is: buttons, the "More" and "Technical details" expanders (expanded or
  collapsed), check boxes, the progress bar (with its value), the result bar, the header icon, and the files in the list as check boxes
  named after the file and its risk; decorative icons are hidden. The tour card is a dialog whose counter, title, text and Back / Next /
  Skip buttons can be reached and pressed, and each step is announced. While the tour is open the card has the keyboard: Tab moves
  between its buttons, Enter or Space presses the focused one; the keyboard goes back to the window afterwards.
- Dark-theme pictures of the window and of the tour (`-dark.png`, both languages): the website and the "How to use" page show them
  when the page is dark. `tests/gui/Make-Screenshots.ps1 -Dark` makes them.
- Tests: `tests/Dpi.Tests.ps1` (scaling helpers, fonts, the tour card at 100-200 %), `tests/gui/Scale.Test.ps1` (the real window at
  100, 125, 150, 175 and 200 % in both languages: nothing cut off or overlapping, the tour card fits, a simulated monitor change), and
  UI Automation checks in `tests/gui/Flow.Test.ps1` (through `tests/gui/Uia-Probe.ps1`: the tour card's buttons are found by name and
  pressed, the window's controls have names and roles).

### Changed

- First use shows one calm message instead of two blue bars: the "Ready to scan" bar itself offers the tour ("Start the tour" and a
  close button) until the tour is taken, the offer is closed or a scan starts. The tour step about that bar says so.
- `-UiScale` (developer switch of the window): draw it as at a given display scale on any screen, for tests.

## [1.1.0] - 2026-10-25

### Added

- **English interface.** The window, the HTML report, the texts the scan writes (observations, verdict, suspect reasons), the share
  messages and the chat summary now exist in English (left-to-right) as well as Arabic (right-to-left). RAM Doctor opens in Arabic when the
  Windows display language is Arabic and in English otherwise; `-Lang ar|en` on the window, the scan and the share script overrides it.
  A language button in the window header switches the open window live (text, layout direction, mirrored frame; the findings and the
  selection are kept). Nothing is saved: no settings file, no profile entry.
- `src/lib/Strings.ps1`: the one string table (`ar` + `en`, `Get-Text 'key' args`). No other source file holds a user-facing literal.
- The plan gets an additive `lang` field (`ar` or `en`); the schema is otherwise unchanged. Plans without it count as Arabic.
- The English report keeps the inert-report contract (marker, one tiny script, no external URLs) and is accepted by the relay's validator.
- English screenshots (`docs/assets/en/`) for the README and the website; the website shows them in English mode and keeps the Arabic
  pictures in Arabic mode. `tests/gui/Make-Screenshots.ps1 -Lang en|ar` regenerates them (the report pictures with a headless Edge/Chrome).
- Tests: `Strings.Tests.ps1` (both tables in step, no untranslated text, no stray literals), both languages in `Test-ReportSafety.ps1`,
  the share client and CLI (`-Lang`), the plan `lang` field, and `tests/gui/Flow.Test.ps1` now runs the whole window flow in Arabic and in
  English, including the live language switch.
- `TRADEMARKS.md`: the name "RAM Doctor" and the logo are not covered by the
  licence and may not be used for other builds.
- **Guided tour for beginners.** A "How to use" button in the window header starts a one-minute tour: the window is dimmed, one
  real part at a time is lit (Start scan, progress, result colours, report / summary / share buttons, the list of files and its risk
  labels, Quarantine, More, Technical details, language, help) and a small card explains it in one to three plain sentences, with a step
  counter and Back / Next / Skip (Enter or Space = next, Esc = close, the arrows follow the reading direction). Parts that only appear
  after a scan are explained on a centred card; the "More" section is opened for its step and closed again. Arabic right-to-left and
  English left-to-right, light and dark; it follows the window when it is moved or resized. The tour never starts a scan or presses
  anything (keys and clicks meant for the window are caught while it is shown) and saves nothing. `src/lib/Tour.ps1` holds the tour,
  `Fluent.FCoach` (in `src/lib/Fluent.cs`) the overlay.
- On the very first use (no report in the reports folder yet) a small banner offers the tour; it can be closed and goes away once a scan
  starts. No settings file is written.
- Website: an illustrated "How to use" page (`docs/guide.html`, Arabic and English, light and dark) built from pictures of the tour
  (`docs/assets/tour/`, `docs/assets/en/tour/`, made by `tests/gui/Make-Screenshots.ps1 -Only tour` and `-Only tour-banner`), linked
  from the home page and from both READMEs.
- Tests: `tests/Tour.Tests.ps1` (steps, texts, keys, card placement, scrolling, first use), and `tests/gui/Flow.Test.ps1` now opens the
  tour from the banner and from the header, walks every step in both languages, goes back, uses the keys (Space on the focused "Start
  scan" button must not start a scan), resizes the window, skips, and checks that the window is exactly as before.

- `src/lib/Store.ps1`: crash-safe JSON storage (`Write-JsonAtomic`,
  `Read-JsonSafe` with `.bak` fallback and a `schema` field; 1.0.x files are
  read as schema 1) and an inter-process lock (`Use-StoreLock`).
- Relay: optional `requestId`. The same id again returns the first answer
  (`"replayed": true`) instead of committing a second time; a retry during the
  first commit gets `409 in_progress`. Such answers do not count against the
  per-IP limit.

### Changed

- **Licence: all rights reserved from now on.** Everything after v1.0.1 is under
  the new `LICENSE` (free personal use, no copying, modifying or selling, no
  outside code). Versions 1.0.0 and 1.0.1 stay under the MIT License as
  published; its text is kept in `LICENSE-MIT-v1.0.x.txt`.
- The README, the website and the package metadata no longer call the project
  "open source": the code stays visible for review.
- `CONTRIBUTING.md` now says that code contributions are not accepted; issues
  and false-positive reports are still welcome.
- The share client's `summary.md` omits the right-to-left block for English plans (the relay only keeps `<div dir="rtl">`).
- Docs: Arabic is no longer described as the only language; the roadmap item "English interface" is done.
- Plainer words in the window for first-time users: after a scan the status line says the result is *below* (it said above), the
  driver hint no longer mentions "Pool tags", the progress steps say "hidden programs" and "hidden auto-start entries" instead of
  "processes" and "subscriptions", the administrator bar says what to answer, and the share dialog no longer says "repository" or
  "plan". The header subtitle is shorter so that it fits next to the new "How to use" button.

### Fixed

- Quarantine: the undo record (`manifest.json`) is written before the first
  change and around every step, atomically, with a `.bak` copy. A power cut,
  a full disk or a killed process can no longer lose the undo data of removed
  startup entries or changed services, and a truncated record is recovered
  from its backup. A batch whose record is damaged or missing is listed and can
  still be purged instead of being hidden with its files.
- Restore tells the truth: an item that cannot be put back (a refused or
  missing quarantined file, an unknown operation from a newer version) is a
  failure, the batch stays restorable, the window says "finished with
  problems", and a second try only retries what is not back yet. The target of
  every file is recorded before it is moved back, so an interrupted restore is
  finished by the next run. A record that another program holds open is refused
  for the moment instead of being replaced by its older backup copy.
- Purge reports what it really did; batches dated in the future (wrong clock)
  are handled; "Undo the last quarantine" picks the newest batch by a sequence
  number instead of the clock.
- Two actions can no longer run on the quarantine store at the same time (per
  store lock whose name a non-elevated program cannot know; the second one
  answers "busy"); the window ignores clicks while
  it waits for a helper process.
- The scan writes its report and plan crash-safe, never prunes the plan it just
  wrote (clock behind), and the window picks this PC's plan by its stamp. A damaged plan no longer breaks
  every start of the window.
- Share: one `requestId` per upload, the same on every retry (no duplicate
  folders when an answer is lost); `409 in_progress` is waited for; a relay
  without the field gets the report again without it. The profile is saved
  crash-safe and a damaged one is reported (its user id is kept) instead of
  being silently replaced by a new identity; an unreadable saved invite code is
  reported as such.
- The redacted share preview is written to a fresh, randomly named private
  folder instead of a fixed folder in `%TEMP%` that an elevated process could
  be tricked into following (junction).
- When elevated, batch folders and undo records are created with locked
  permissions from the first moment, and a batch whose folders or records give
  an allow-rule to anybody but SYSTEM / Administrators is not trusted.
- The single-file edition no longer deletes the unpack folder of a copy that has
  been running for more than a day (`in-use.lock`).
- The window retries deleting the output files of its helper processes and
  sweeps them again later, so none is left in `%TEMP%`; action logs are pruned
  to the newest 30.- Relay: a failed upload (GitHub error) no longer counts against the per-user
  limit; the quota is counted only after a successful commit.
- Relay: two uploads of one user in the same second no longer share a folder
  (the second silently replaced the first). Folders are now
  `<yyyyMMdd-HHmmss>-<6 random chars>`; the data repo's `index.yml` template
  understands both forms.
- Relay: when GitHub's answer to the final ref update is lost, the relay checks
  whether the commit landed instead of answering `502` (which made clients
  upload the report again).

## [1.0.1] - 2026-10-25

### Added

- **One-click sharing is switched on**: the app is connected to the relay (src/share.config.json), so the Share button, the profile
  dialog and the confirm dialog appear. Nothing is sent unless the user presses Share and confirms; the scan itself still never uses the network.
- Tests: a cross-component contract test (the real report must pass the relay's validator) and a version-consistency check.

### Fixed

- Relay rejected every genuine report: its CSS rule mistook `scroll-behavior` for the legacy IE `behavior:` property.
- Relay rejected the report's theme toggle (`setAttribute('href', ...)`): the toggle now switches two icons with CSS and no longer sets attributes.
- Relay now cleans a secret that picked up stray whitespace/invisible characters while being pasted (GitHub answers a malformed `Authorization` header with a bare 400), and its log says which API step failed.

## [1.0.0] - 2026-10-24

First public release.

### Added

- **Scan engine** (`src/RAM-Doctor.ps1`): read-only triage of "RAM is full but
  Task Manager shows nothing".
  - Memory accounting (private working sets, shared/mapped memory, non-paged
    pool, modified list, standby, unaccounted remainder) and growth sampling
    over a configurable observation window.
  - Kernel pool-tag table (`NtQuerySystemInformation`, class 22) with
    heuristic mapping of the biggest and fastest-growing tags to the running
    driver files that contain them.
  - Inventory of processes, services (including `svchost` `ServiceDll`),
    scheduled tasks, Run/RunOnce keys for all loaded user hives, startup
    folders, permanent WMI event subscriptions, and running kernel drivers.
  - Hidden-process probe: direct kernel PID probe compared against
    `Get-Process` and WMI, with zombie (terminated-but-referenced) vs. live
    classification.
  - Signal-based scoring (Authenticode trust, location, random names,
    masquerading/look-alike names, suspicious command lines, miner indicators,
    unusual parents, mining-port connections, growth) grouped per file, with
    Low / Medium / High risk levels.
  - Evidence: Microsoft Defender status and recent detections, Windows
    Resource-Exhaustion events, Winlogon / IFEO / AppInit anomalies, Fast
    Startup + uptime advice.
  - Arabic (RTL) HTML report and a machine-readable plan file; only two small
    files per scan, newest three scans kept.
- **Actions** (`src/RAM-Doctor-Actions.ps1`): reversible quarantine (stop
  process, disable service/task/driver start, remove startup entries, move the
  file to a quarantine store), `Restore`, `Purge` (the only destructive step),
  and `List`. Re-validates every item before touching it (host match, SHA-256,
  protected paths, Microsoft signature), creates a System Restore point.
- **Windows 11 style GUI** (`src/RAM-Doctor-GUI.ps1`): one window with scan,
  results, quarantine, restore, purge and cleanup; follows the system theme.
- **Sending a report to the person helping you.** Always-available manual
  route: a *report location* button opens the report in Explorer, selected,
  ready to attach, and a *copy summary for sending* button copies a short
  **redacted** plain-text summary to paste into a chat.
- **Optional one-click *Share with my helper*.** The user picks a permanent
  username once; after pressing Share and confirming, a **redacted** bundle
  (`summary.md`, `report.html`, `plan.json`; Windows user name, PC name,
  e-mail addresses and secrets in command lines removed) is uploaded through a
  small relay (Cloudflare Worker, `server/`, see `docs/sharing.md`) to the
  helper's **private** GitHub repository. The scan never uses the network and
  there is no telemetry; the program holds no token; the button is hidden in
  builds whose `share.config.json` endpoint is empty. A profile file
  (`%APPDATA%\RAM-Doctor\profile.json`: display name, random id, optional
  DPAPI-protected code) is created only if Share is used and can be deleted
  from the GUI.
- **Single-file release** (`build/Build-SingleFile.ps1`): `RAM-Doctor.bat`,
  a readable self-extracting file that unpacks into a locked-down folder
  (Administrators and SYSTEM only) under ProgramData and removes it on exit.
- Documentation, issue forms (including a false-positive form), CI and
  release workflows.

[Unreleased]: https://github.com/iiKurro/ram-doctor/compare/v1.1.2...HEAD
[1.1.2]: https://github.com/iiKurro/ram-doctor/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/iiKurro/ram-doctor/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/iiKurro/ram-doctor/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/iiKurro/ram-doctor/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/iiKurro/ram-doctor/releases/tag/v1.0.0
