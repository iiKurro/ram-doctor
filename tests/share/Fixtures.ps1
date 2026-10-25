# Shared synthetic fixtures for the share tests (no real machine data: "Friend", "DESKTOP-DEMO").

if (-not (Get-Command Get-Text -CommandType Function -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot '..\..\src\lib\Strings.ps1') }

# -Lang '' = a plan from the Arabic-only releases (no lang field, Arabic texts); 'ar' / 'en' = what the scan writes today
# -Breakdown = the memory object of a scan after 1.1.2 (where the memory Task Manager does not show is), with the numbers of
#              the scan that started the project; one program name carries the user name, to prove it is redacted
function New-TestPlanFiles {
        param([string]$Dir, [string]$HostName = 'DESKTOP-DEMO', [string]$Stamp = '20260101-120000', [int]$ManySuspects = 0, [string]$Lang = '', [switch]$Breakdown)
        $sha1 = ('ab' * 32)
        $suspects = @(
            [ordered]@{ id = 1; risk = 'High'; score = 10; name = 'svch0st.exe'; path = 'C:\Users\Friend\AppData\Local\Temp\svch0st.exe'; trust = 'Unsigned'; publisher = ''
                sha256 = $sha1; reasons = @('يعمل من مجلد مؤقت/عام (Temp) وليس من مجلد تثبيت', 'launched with --token abc123secret99 and mailto friend@example.com')
                procs = @([ordered]@{ pid = 4242; cmd = 'powershell -enc ' + ('QUJD' * 30) })
                autoruns = @([ordered]@{ location = 'Registry::HKEY_USERS\S-1-5-21-1111-2222-3333-1001\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; name = 'Updater'; value = '"C:\Users\Friend\AppData\Local\Temp\svch0st.exe" --api-key=SECRET123XYZ' })
            },
            [ordered]@{ id = 2; risk = 'Medium'; score = 6; name = 'tool.exe'; path = 'C:\Program Files\Tool\tool.exe'; trust = 'Signed'; publisher = 'Example Corp'; sha256 = ('cd' * 32); reasons = @('only one reason'); procs = @(); autoruns = @() }
        )
        for ($i = 0; $i -lt $ManySuspects; $i++) {
            $suspects += [ordered]@{ id = 10 + $i; risk = 'Medium'; score = 5; name = ('very-long-suspicious-file-name-number-{0}-that-keeps-going.exe' -f $i); path = 'C:\Temp\x.exe'; trust = 'Unsigned'
                publisher = ''; sha256 = ('ef' * 32); reasons = @('طويل ' * 60); procs = @(); autoruns = @() }
        }
        $headline = 'السبب الأرجح: تسرّب ذاكرة في تعريف (Driver) على مستوى النواة'
        $obs = @(
            [ordered]@{ Level = 'high'; Title = 'تسرّب محتمل في ذاكرة النواة (Non-paged pool)'; Body = 'مجمّع الذاكرة غير المتصفّح = 9.6 GB' },
            [ordered]@{ Level = 'med'; Title = 'ملفات متوسطة الخطورة (1)'; Body = 'تستحق المراجعة' },
            [ordered]@{ Level = 'info'; Title = 'ذاكرة التخزين المؤقت'; Body = 'ليست مشكلة' }
        )
        if ($Lang -eq 'en') {
            $headline = Get-Text 'verdict.driver' -Lang en
            $suspects[0].reasons[0] = Get-Text 'sig.zone.temp' 'Temp' -Lang en
            $obs = @(
                [ordered]@{ Level = 'high'; Title = (Get-Text 'obs.npp.high.t' -Lang en); Body = 'The non-paged pool = 9.6 GB' },
                [ordered]@{ Level = 'med'; Title = (Get-Text 'obs.med.t' 1 -Lang en); Body = 'Worth reviewing' },
                [ordered]@{ Level = 'info'; Title = (Get-Text 'obs.standby.t' -Lang en); Body = 'Not a problem' }
            )
        }
        for ($i = 0; $i -lt $ManySuspects; $i++) { $obs += [ordered]@{ Level = 'med'; Title = ('ملاحظة رقم {0} ' -f $i) + ('طويلة ' * 30); Body = 'x' } }
        $plan = [ordered]@{
            tool = 'RAM-Doctor'; version = '1.0.0'; host = $HostName; created = '2026-01-01 12:00:00'; isAdmin = $true
            report = "C:\Users\Friend\Desktop\RAM-Doctor-Reports\RAMDoctor-$HostName-$Stamp.html"
            verdict = [ordered]@{ Level = 'high'; Headline = $headline }
            observations = $obs
            memory = [ordered]@{ TotalGB = 15.84; UsedGB = 14.2; AvailGB = 1.64; StandbyGB = 1.1; ModifiedGB = 0.1; ProcPrivateGB = 3.1; ProcSharedGB = 0.9; NonPagedGB = 9.6; PagedGB = 0.8; UnaccountedGB = 0.2; CommittedGB = 16.1; CommitLimitGB = 20; WindowSec = 30; NonPagedGrowthMB = 48; PagedGrowthMB = 1; CommitGrowthMB = 50; UsedGrowthMB = 52 }
            suspects = $suspects
        }
        if ($Breakdown) {
            $plan.memory = [ordered]@{ TotalGB = 31.11; UsedGB = 18.19; AvailGB = 12.92; StandbyGB = 12.91; ModifiedGB = 0.14; ProcPrivateGB = 8.56; ProcSharedGB = 9.88; NonPagedGB = 0.9; PagedGB = 1.29
                PagedResidentGB = 1.17; UnaccountedGB = 0; CommittedGB = 22.45; CommitLimitGB = 37.86; CacheResidentGB = 0.63; DriverResidentGB = 0.06; WindowSec = 31; NonPagedGrowthMB = 1; PagedGrowthMB = 0; CommitGrowthMB = 12; UsedGrowthMB = 9
                HiddenGB = 9.63; SharedUniqueGB = 4.47; DriverReservedGB = 2.26; DriverReservedKnown = $true; DriverReservedGrowthMB = 0; KernelPoolsGB = 2.07; SystemOtherGB = 0.83; UnexplainedGB = 0; UnattributedGB = 2.26
                TopShared = @([ordered]@{ name = 'brave.exe'; count = 32; sharedMB = 5240 }, [ordered]@{ name = 'Friend-sync.exe'; count = 2; sharedMB = 410 })
                DriverReservedCandidates = @('NVIDIA GeForce RTX 4070', 'Parsec Virtual Display Adapter', 'amdkmdag.sys')
            }
        }
        if ($Lang) { $plan.Insert(2, 'lang', $Lang) }   # right after tool / version, as the scan writes it
        $planPath = Join-Path $Dir "Plan-$HostName-$Stamp.json"
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
        $htmlPath = Join-Path $Dir "RAMDoctor-$HostName-$Stamp.html"
        $html = @"
<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><title>RAM Doctor - $HostName</title>
<!-- ram-doctor-report v1.0.0 host=$HostName -->
<style>.card{color:#1a1a1a} /* Friend */</style></head><body>
<p>الجهاز: <b>$HostName</b> - المستخدم: Friend - C:\Users\Friend\AppData\Local\Temp\svch0st.exe</p>
<p>cmd: svch0st.exe --token abc123secret99 &amp;password=hunter2&amp; mail friend@example.com</p>
<p>sha256 $sha1 ip 8.8.8.8 driver netflt64.sys tag EtwB</p>
<script>(function(){var Friend=1;var t=document.documentElement;try{t.setAttribute('data-theme',localStorage.getItem('theme')||'')}catch(e){}})();</script>
</body></html>
"@
        [IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding($true)))
        return [pscustomobject]@{ Plan = $planPath; Html = $htmlPath; Sha = $sha1; Script = '<script>(function(){var Friend=1;var t=document.documentElement;try{t.setAttribute(''data-theme'',localStorage.getItem(''theme'')||'''')}catch(e){}})();</script>' }
    }

function New-RandWord([string]$Prefix, [int]$Len = 8) {
        $chars = 'abcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
        $s = New-Object System.Text.StringBuilder
        [void]$s.Append($Prefix)
        for ($i = 0; $i -lt $Len; $i++) { [void]$s.Append($chars[(Get-Random -Maximum $chars.Length)]) }
        return $s.ToString()
    }
