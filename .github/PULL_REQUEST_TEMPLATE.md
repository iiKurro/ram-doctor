> **Code contributions are not accepted** (the project is all rights reserved,
> see [LICENSE](LICENSE) and [CONTRIBUTING.md](CONTRIBUTING.md)). Please open an
> issue instead; pull requests that change code will be closed without merging.

## Summary

<!-- What does this change and why? Link the issue: "Closes #123". -->

## Type of change

- [ ] fix (bug fix)
- [ ] feat (new capability)
- [ ] detection (new/changed signal, weight or threshold)
- [ ] docs / website
- [ ] build / CI
- [ ] refactor / chore

## How was it tested?

<!-- Commands you ran, Windows version, elevated or not. For detection changes: which synthetic fixtures. -->

## Checklist

- [ ] Follows the [coding rules](../CONTRIBUTING.md#coding-rules) (PowerShell 5.1, UTF-8 **BOM** on every `.ps1`, C# 5, English ASCII console output).
- [ ] All scripts parse and `build/Build-SingleFile.ps1` succeeds; CI is green.
- [ ] Tests added or updated (bug fix, new signal, redaction, or relay change).
- [ ] Anything that changes the system lives only in `RAM-Doctor-Actions.ps1`, re-validates its target first, and records an undo entry.
- [ ] The scan still **never uses the network** and there is no telemetry; the only network feature is the Share button (nothing happens until the user presses it and confirms), and no token or secret is added.
- [ ] Anything that produces text meant to leave the PC (copy summary, upload bundle) is redacted and covered by a test with synthetic data.
- [ ] No personal data in code, fixtures, screenshots or docs (use `Friend` / `DESKTOP-DEMO`).
- [ ] Docs updated ([how-detection-works](../docs/how-detection-works.md) for signals, [architecture](../docs/architecture.md) for schema changes).
- [ ] `CHANGELOG.md` updated under **Unreleased**.
