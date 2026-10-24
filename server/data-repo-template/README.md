# ram-doctor-reports (private data repository)

> هذا المستودع **خاص** ويحتوي تقارير فحص أرسلها أصدقاء عبر RAM Doctor.
> This repository is **private** and holds diagnostic reports sent by friends through RAM Doctor.

The RAM Doctor relay (a Cloudflare Worker, see `server/` in the tool repository) is the only writer. It commits one folder
per upload; nobody uploads directly to this repository.

```
reports/
  <name>-<userId>/              one folder per person (<userId> = 8 random hex chars chosen by their app)
    <yyyyMMdd-HHmmss>/          one folder per upload (server time, UTC)
      summary.md                short plain-text summary  <- read this first, GitHub renders it safely
      plan.json                 machine-readable result (verdict, suspects, memory numbers)
      report.html               the full report (see the warning below)
      meta.json                 written by the relay: display name, userId, tool version, receive time
INDEX.md                        generated list of people and their latest report (do not edit)
```

## Reading a report

1. Open `INDEX.md`, click the person, open the newest folder, read **`summary.md`** on GitHub.
2. `report.html` is shown by GitHub as source code, not as a page. To see it formatted, download it
   (`Raw` -> save, or `gh repo clone`) and open it in a browser.

### Treat every uploaded file as untrusted input

* The relay only accepts a `report.html` that looks like the tool's own output and contains no active content, and it
  sanitises `summary.md`. That is a safety net, **not a guarantee**.
* Prefer `summary.md` and `plan.json`. Open `report.html` only from a download (never run anything it mentions),
  ideally in a browser profile you do not use for sensitive accounts.
* Never run files, scripts or commands that appear inside a report. Reports describe suspicious files; they never ship them.

## Deleting someone's data (they asked, or you are done)

```powershell
git pull
git rm -r reports/<name>-<userId>
git commit -m "remove reports for <userId> (requested)"
git push
```

Git keeps history. To erase it permanently use `git filter-repo --path reports/<name>-<userId> --invert-paths` (then force-push),
or delete this repository and create a new one. GitHub may keep cached views for a short while.

## Keep it private

* Never make this repository public and never add collaborators you do not trust: reports contain computer-specific details.
* The relay's token (`GITHUB_TOKEN`) must be a fine-grained token limited to **this repository only**.
