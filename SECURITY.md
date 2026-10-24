# Security Policy

RAM Doctor runs with administrator rights and can stop processes, disable
services and move files. Security reports are taken seriously.

## Supported versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

Only the latest release receives fixes. Please reproduce on the latest release
(or on `main`) before reporting.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting:

1. Open the [Security tab](https://github.com/iiKurro/ram-doctor/security) of this repository.
2. Choose **Report a vulnerability**
   ([direct link](https://github.com/iiKurro/ram-doctor/security/advisories/new)).
3. Describe the problem, the affected version, and how to reproduce it. A
   proof of concept helps but is not required.

You will get an acknowledgement as soon as the maintainer can respond, and
updates when a fix is in progress. Please give a reasonable time to fix the
problem before any public disclosure. Reporters are credited in the release
notes unless they prefer to stay anonymous.

No email address is published on purpose; all communication goes through the
GitHub advisory so that it stays private and traceable.

## Scope

In scope:

* Vulnerabilities in the tool itself, for example: privilege escalation or
  arbitrary file/registry changes caused by crafted input (plan files,
  quarantine manifests, command-line arguments, file names), unsafe temp-file
  handling, unsafe handling of the quarantine store, or the single-file
  unpacker.
* A way to make the tool modify or delete a file it promises never to touch
  (anything under `%WINDIR%` or signed by Microsoft).
* A way to make the tool use the network during a scan or without an explicit
  user action. The scan never uses the network and there is no telemetry; the
  only network feature is the **Share** button, which does nothing until the
  user presses it and confirms, and then uploads only the documented redacted
  bundle (see
  [docs/privacy-and-safety.md](docs/privacy-and-safety.md#the-optional-share-button)).
* Vulnerabilities in the **relay** (`server/`, a Cloudflare Worker deployed by
  the maintainer) or in the Share flow: bypassing the rate limits, the
  3-file whitelist, the 2 MB cap, the kill switch or (when enabled) invite-code
  checks; getting active or non-inert content through the report sanitising;
  any way to *read* stored reports through the relay; path traversal or
  injection through the user name or other fields into the helper's data
  repository; redaction failures that leak the Windows user name, PC name,
  e-mail addresses or secrets from command lines (also in the *copy summary*
  text); or any exposure of the relay's secrets. See
  [docs/sharing.md](docs/sharing.md) and [server/README.md](server/README.md).

Out of scope:

* Findings that require an attacker who already has administrator rights.
* The tool reporting a legitimate program as suspicious, or missing malware.
  That is a detection-quality matter: use the
  [false-positive form](https://github.com/iiKurro/ram-doctor/issues/new?template=false_positive.yml)
  or a normal bug report.
* Social-engineering a user into running a modified copy. Only download
  `RAM-Doctor.bat` from this repository's
  [Releases](https://github.com/iiKurro/ram-doctor/releases) and verify it
  against `SHA256SUMS.txt`.

## Secrets must never be committed

The program itself contains **no token or secret**. The relay holds the only
credential (a GitHub token with access to the helper's private data repository)
as a Cloudflare Worker secret. Nobody should ever commit a GitHub token, a
Worker secret, a `.dev.vars` file, an invite code or any other credential, in
code, tests, docs, issues or screenshots.

If you find a secret anywhere in this repository or its history, **report it
privately** (see above) instead of opening an issue or pull request, so it can
be revoked and rotated first.

## Antivirus heuristics

RAM Doctor is an unsigned PowerShell/batch tool that enumerates processes,
reads kernel memory statistics through `ntdll`, and (on request) stops
processes and moves files. Some antivirus products flag that *behaviour* even
though the source is fully readable. To keep that risk low the release file is
plain text (no base64, no obfuscation, no `Invoke-Expression`, no hidden
window). The scan never uses the network and there is no telemetry; the only
network feature is the **Share** button, which does nothing until the user
presses it and confirms. If a product flags a release:

1. Compare the SHA-256 of your download with `SHA256SUMS.txt` on the release page.
2. Read the file in Notepad; it unpacks only the scripts you see in `src/`.
3. Submit it as a false positive to the vendor, and tell us which product and
   version flagged it by opening a bug report (no sensitive details needed).

See also [docs/privacy-and-safety.md](docs/privacy-and-safety.md) and
[docs/troubleshooting.md](docs/troubleshooting.md).
