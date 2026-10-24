# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/iiKurro/ram-doctor/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/iiKurro/ram-doctor/releases/tag/v1.0.0
