# ------------------------------------------------------------------------------------------
#  Synthetic, anonymised report data for RAM Doctor (used by the screenshots in docs/ and by
#  tests/fixtures/Test-ReportSafety.ps1).  Same schema as the $data object built by
#  src/RAM-Doctor.ps1.  Nothing here comes from a real machine: user "Friend", host
#  "DESKTOP-DEMO", fictional driver "netflt64.sys", IPs from the documentation range 203.0.113.0/24.
#
#  Usage:   . tests\fixtures\Demo-ReportData.ps1
#           $data = Get-DemoReportData -Scenario leak      # leak | miner | clean
#           . src\lib\Report.ps1 ; New-RamReportHtml $data | Set-Content demo.html -Encoding UTF8
#
#  UTF-8 WITH BOM (Arabic text).
# ------------------------------------------------------------------------------------------

function New-DemoRow([hashtable]$h) { [pscustomobject]$h }

function Get-DemoReportData {
    param([ValidateSet('leak', 'miner', 'clean')][string]$Scenario = 'leak')

    $sys = New-DemoRow @{
        Host = 'DESKTOP-DEMO'; User = 'Friend'; OS = 'Microsoft Windows 11 Pro (10.0.26100)'
        Cpu = 'Intel(R) Core(TM) i5-12400F'; Gpus = 'NVIDIA GeForce RTX 3060'
        InstalledGB = 16; UsableGB = 15.84; ReservedGB = 0.16; Uptime = '12d 4h 31m'; UptimeDays = 12.2
        FastStartup = $true; Hypervisor = $false; IsAdmin = $true; Culture = 'ar-SA'
    }
    $counts = New-DemoRow @{ Processes = 142; Services = 258; Tasks = 61; Autoruns = 12; Drivers = 187; Wmi = 0 }

    $byProgram = @(
        (New-DemoRow @{ name = 'chrome.exe'; count = 14; privMB = 1480; commitMB = 2210; trust = 'Signed'; publisher = 'Google LLC' }),
        (New-DemoRow @{ name = 'msedgewebview2.exe'; count = 9; privMB = 410; commitMB = 780; trust = 'MS'; publisher = 'Microsoft Corporation' }),
        (New-DemoRow @{ name = 'Code.exe'; count = 6; privMB = 335; commitMB = 640; trust = 'Signed'; publisher = 'Microsoft Corporation' }),
        (New-DemoRow @{ name = 'Discord.exe'; count = 6; privMB = 262; commitMB = 520; trust = 'Signed'; publisher = 'Discord Inc.' }),
        (New-DemoRow @{ name = 'MsMpEng.exe'; count = 1; privMB = 214; commitMB = 390; trust = 'MS'; publisher = 'Microsoft Corporation' }),
        (New-DemoRow @{ name = 'svchost.exe'; count = 62; privMB = 205; commitMB = 530; trust = 'OS'; publisher = 'Microsoft Windows' }),
        (New-DemoRow @{ name = 'steamwebhelper.exe'; count = 5; privMB = 188; commitMB = 410; trust = 'Signed'; publisher = 'Valve Corp.' }),
        (New-DemoRow @{ name = 'explorer.exe'; count = 1; privMB = 141; commitMB = 260; trust = 'OS'; publisher = 'Microsoft Windows' }),
        (New-DemoRow @{ name = 'Memory Compression'; count = 1; privMB = 96; commitMB = 12; trust = 'OS'; publisher = 'Windows kernel' })
    )
    $topProcs = @(
        (New-DemoRow @{ pid = 7412; name = 'chrome.exe'; privMB = 612; wsMB = 790; commitMB = 905; handles = 2210; growthMB = 3; trust = 'Signed'; publisher = 'Google LLC'; path = 'C:\Program Files\Google\Chrome\Application\chrome.exe' }),
        (New-DemoRow @{ pid = 9120; name = 'chrome.exe'; privMB = 318; wsMB = 420; commitMB = 560; handles = 1480; growthMB = 1; trust = 'Signed'; publisher = 'Google LLC'; path = 'C:\Program Files\Google\Chrome\Application\chrome.exe' }),
        (New-DemoRow @{ pid = 4488; name = 'MsMpEng.exe'; privMB = 214; wsMB = 266; commitMB = 390; handles = 1020; growthMB = 0; trust = 'MS'; publisher = 'Microsoft Corporation'; path = 'C:\ProgramData\Microsoft\Windows Defender\Platform\4.18\MsMpEng.exe' }),
        (New-DemoRow @{ pid = 11204; name = 'Code.exe'; privMB = 198; wsMB = 301; commitMB = 366; handles = 940; growthMB = 2; trust = 'Signed'; publisher = 'Microsoft Corporation'; path = 'C:\Users\Friend\AppData\Local\Programs\Microsoft VS Code\Code.exe' }),
        (New-DemoRow @{ pid = 6032; name = 'Discord.exe'; privMB = 171; wsMB = 233; commitMB = 301; handles = 760; growthMB = 0; trust = 'Signed'; publisher = 'Discord Inc.'; path = 'C:\Users\Friend\AppData\Local\Discord\app-1.0.9\Discord.exe' }),
        (New-DemoRow @{ pid = 3264; name = 'explorer.exe'; privMB = 141; wsMB = 240; commitMB = 260; handles = 2840; growthMB = 0; trust = 'OS'; publisher = 'Microsoft Windows'; path = 'C:\Windows\explorer.exe' }),
        (New-DemoRow @{ pid = 2120; name = 'Memory Compression'; privMB = 96; wsMB = 96; commitMB = 12; handles = 0; growthMB = 0; trust = 'OS'; publisher = 'Windows kernel'; path = '' })
    )
    $drivers3p = @(
        (New-DemoRow @{ name = 'netflt64'; display = 'Example Network Filter Driver'; file = 'netflt64.sys'; path = 'C:\Windows\System32\drivers\netflt64.sys'; trust = 'Signed'; publisher = 'Example Network Technologies Ltd.'; company = 'Example Network Technologies'; version = '12.4.0.88'; installed = '2026-09-02 09:14:00'; startMode = 'Auto' }),
        (New-DemoRow @{ name = 'nvlddmkm'; display = 'NVIDIA Windows Kernel Mode Driver'; file = 'nvlddmkm.sys'; path = 'C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf\nvlddmkm.sys'; trust = 'Signed'; publisher = 'NVIDIA Corporation'; company = 'NVIDIA Corporation'; version = '32.0.15.6094'; installed = '2026-08-11 18:02:10'; startMode = 'Manual' }),
        (New-DemoRow @{ name = 'RTKVHD64'; display = 'Realtek HD Audio Driver'; file = 'RTKVHD64.sys'; path = 'C:\Windows\System32\drivers\RTKVHD64.sys'; trust = 'Signed'; publisher = 'Realtek Semiconductor Corp.'; company = 'Realtek Semiconductor Corp.'; version = '6.0.9500.1'; installed = '2026-03-20 11:45:31'; startMode = 'Manual' }),
        (New-DemoRow @{ name = 'iaStorAC'; display = 'Intel Rapid Storage Technology'; file = 'iaStorAC.sys'; path = 'C:\Windows\System32\drivers\iaStorAC.sys'; trust = 'Signed'; publisher = 'Intel Corporation'; company = 'Intel Corporation'; version = '19.5.1.1040'; installed = '2025-12-04 08:00:00'; startMode = 'Boot' })
    )
    $exhaustion = @()
    $defender = New-DemoRow @{ Enabled = $true; RealTime = $true; SignatureAgeDays = 0; QuickScanAgeDays = 1; RecentThreats = @() }

    switch ($Scenario) {
        'leak' {
            $memory = New-DemoRow @{
                TotalGB = 15.84; UsedGB = 14.9; AvailGB = 0.94; FreeGB = 0.12; StandbyGB = 0.82; ModifiedGB = 0.11
                ProcPrivateGB = 3.1; ProcSharedGB = 1.9; NonPagedGB = 9.6; PagedGB = 0.9; PagedResidentGB = 0.8; UnaccountedGB = 0.19
                CommittedGB = 17.8; CommitLimitGB = 24.3; CacheResidentGB = 0.9; DriverResidentGB = 0.1; WindowSec = 32
                NonPagedGrowthMB = 118; PagedGrowthMB = 4; CommitGrowthMB = 126; UsedGrowthMB = 131
            }
            $verdict = New-DemoRow @{ Level = 'high'; Headline = 'السبب الأرجح: تسرّب ذاكرة في تعريف (Driver) على مستوى النواة' }
            $obs = @(
                (New-DemoRow @{ Level = 'high'; Title = 'تسرّب محتمل في ذاكرة النواة (Non-paged pool)'; Body = 'حجم مجمّع الذاكرة غير المتصفّح يبلغ 9.6 GB والطبيعي أقل من نحو 1 GB. هذا أقوى مؤشر على تسرّب ذاكرة من تعريف (Driver)، ولا يُنسب في مدير المهام لأي برنامج. أكبر مستهلك داخل المجمّع هو الوسم [ExNf] بحجم 7424 MB (قد يتبع: netflt64.sys).' }),
                (New-DemoRow @{ Level = 'high'; Title = 'التسرّب نشط الآن'; Body = 'خلال 32 ثانية فقط زاد Non-paged بمقدار 118 MB و Paged بمقدار 4 MB. راجع جدول الوسوم (Pool tags) الأسرع نموًا.' }),
                (New-DemoRow @{ Level = 'med'; Title = 'التشغيل السريع (Fast Startup) مفعّل والجهاز شغّال منذ مدة'; Body = 'مدة التشغيل 12d 4h 31m. مع Fast Startup خيار «إيقاف التشغيل» لا يصفّر النواة، فأي تسرّب يبقى بعد الإطفاء. استخدم «إعادة التشغيل» (Restart) أو عطّل Fast Startup.' })
            )
            $mk = { param($t, $mb, $d, $al, $known, $cands) New-DemoRow @{ tag = $t; mb = $mb; deltaMB = $d; allocs = $al; known = $known; candidates = @($cands); tooGeneric = $false } }
            $exnf = New-DemoRow @{ file = 'netflt64.sys'; path = 'C:\Windows\System32\drivers\netflt64.sys'; trust = 'Signed'; publisher = 'Example Network Technologies Ltd.' }
            $poolNon = @(
                (& $mk 'ExNf' 7424 118 3812344 '' @($exnf)),
                (& $mk 'EtwB' 78 0 412 'مخازن ETW لتتبّع الأحداث - نواة ويندوز' @()),
                (& $mk 'NVRM' 64 0 3310 'تعريف NVIDIA للشاشة (nvlddmkm.sys)' @()),
                (& $mk 'smNp' 49 0 912 'مدير المخزن / ضغط الذاكرة (Store Manager) - نواة ويندوز' @()),
                (& $mk 'File' 33 0 88120 'كائنات الملفات (File objects) - نواة ويندوز' @()),
                (& $mk 'Thre' 24 0 9120 'كائنات الخيوط (Threads) - نواة ويندوز' @()),
                (& $mk 'Even' 22 0 41200 'كائنات الأحداث (Events) - نواة ويندوز' @())
            )
            $poolPaged = @(
                (& $mk 'MmSt' 202 1 1022 '' @()),
                (& $mk 'CM25' 61 0 22110 '' @()),
                (& $mk 'ObNm' 44 0 18400 '' @())
            )
            $poolGrow = @((& $mk 'ExNf' 7424 118 3812344 '' @($exnf)))
            $suspects = @(); $topGrowers = @(); $hidden = @()
            $exhaustion = @((New-DemoRow @{ time = '2026-10-23 22:41:07'; message = "Windows successfully diagnosed a low virtual memory condition. The following programs consumed the most virtual memory: System (4) consumed 9961472000 bytes, chrome.exe (7412) consumed 905969664 bytes and MsMpEng.exe (4488) consumed 408944640 bytes." }))
            $drv = $drivers3p; $pa = $true
        }
        'miner' {
            $memory = New-DemoRow @{
                TotalGB = 15.84; UsedGB = 12.4; AvailGB = 3.44; FreeGB = 0.9; StandbyGB = 2.4; ModifiedGB = 0.14
                ProcPrivateGB = 7.2; ProcSharedGB = 3.6; NonPagedGB = 0.74; PagedGB = 0.82; PagedResidentGB = 0.7; UnaccountedGB = 0.72
                CommittedGB = 14.9; CommitLimitGB = 24.3; CacheResidentGB = 1.4; DriverResidentGB = 0.1; WindowSec = 31
                NonPagedGrowthMB = 2; PagedGrowthMB = 1; CommitGrowthMB = 431; UsedGrowthMB = 420
            }
            $verdict = New-DemoRow @{ Level = 'high'; Headline = 'تم رصد مؤشرات تستحق التدقيق العاجل (قد تكون برمجية خبيثة)' }
            $obs = @(
                (New-DemoRow @{ Level = 'high'; Title = 'ملفات عالية الخطورة (1)'; Body = 'مؤشرات متعددة اجتمعت على: svch0st.exe. هذه مؤشرات وليست حكمًا نهائيًا؛ راجع التفاصيل قبل أي إجراء.' }),
                (New-DemoRow @{ Level = 'med'; Title = 'ملفات متوسطة الخطورة (1)'; Body = 'تستحق المراجعة: powershell.exe' }),
                (New-DemoRow @{ Level = 'med'; Title = 'برنامج تتضخّم ذاكرته الآن'; Body = 'svch0st.exe (PID 6124) زادت ذاكرته الخاصة 412 MB خلال 31 ثانية.' })
            )
            $poolNon = @(); $poolPaged = @(); $poolGrow = @()
            $remote = @('203.0.113.50:3333')
            $suspects = @(
                (New-DemoRow @{
                        id = 1; risk = 'High'; score = 17; name = 'svch0st.exe'; path = 'C:\Users\Friend\AppData\Local\Temp\svch0st.exe'; fileExists = $true; protectedFile = $false
                        sha256 = ('9f2c1b7a' * 8)
                        sizeBytes = 3817472; created = '2026-10-21 03:12:44'; trust = 'Unsigned'; sigStatus = 'NotSigned'; publisher = ''; company = ''; description = ''
                        reasons = @('اسمه (svch0st.exe) يشبه عملية النظام svchost بفارق حرف واحد', 'اتصال بمنفذ شائع لمجمّعات التعدين (203.0.113.50:3333)', 'يعمل من مجلد مؤقت/عام (Temp) وليس من مجلد تثبيت', 'حجم ذاكرته الخاصة زاد 412 MB خلال فترة الفحص', 'الملف غير موقّع رقميًا', 'مضبوط على التشغيل التلقائي (خدمة / مهمة مجدولة / تشغيل عند الإقلاع) فيعود بعد إعادة التشغيل')
                        procs = @((New-DemoRow @{ pid = 6124; start = '2026-10-24 21:03:10'; cmd = ''; privMB = 868; growthMB = 412; remote = $remote }))
                        services = @(); tasks = @()
                        autoruns = @((New-DemoRow @{ via = 'Registry'; location = 'Registry::HKEY_USERS\S-1-5-21-1111111111-2222222222-3333333333-1001\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; name = 'WindowsUpdateHelper'; value = ''; file = '' }))
                        drivers = @(); wmi = @()
                    }),
                (New-DemoRow @{
                        id = 2; risk = 'Medium'; score = 6; name = 'powershell.exe'; path = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; fileExists = $true; protectedFile = $true
                        sha256 = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90'; sizeBytes = 450560; created = '2026-04-02 10:00:00'; trust = 'OS'; sigStatus = 'Valid'; publisher = 'Microsoft Windows'; company = 'Microsoft Corporation'; description = 'Windows PowerShell'
                        reasons = @('سطر الأوامر مشفّر أو يحمّل ويشغّل كودًا (PowerShell مشفّر / Download cradle)', 'أداة سكربت تشغّل ملفًا من مجلد مؤقت/AppData')
                        procs = @(); services = @()
                        tasks = @((New-DemoRow @{ taskPath = '\'; taskName = 'OneDriveSync Helper'; state = 'Ready'; cmd = '' }))
                        autoruns = @(); drivers = @(); wmi = @()
                    }),
                (New-DemoRow @{
                        id = 3; risk = 'Low'; score = 4; name = 'GameBoostTray.exe'; path = 'C:\Users\Friend\AppData\Local\GameBoost\GameBoostTray.exe'; fileExists = $true; protectedFile = $false
                        sha256 = 'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00'; sizeBytes = 1523712; created = '2026-08-30 17:21:09'; trust = 'Unsigned'; sigStatus = 'NotSigned'; publisher = ''; company = 'GameBoost'; description = 'GameBoost Tray'
                        reasons = @('يعمل من مجلد بيانات المستخدم (AppData) وليس من Program Files', 'الملف غير موقّع رقميًا')
                        procs = @((New-DemoRow @{ pid = 8820; start = '2026-10-24 08:41:55'; cmd = ''; privMB = 48; growthMB = 0; remote = @() })); services = @(); tasks = @(); autoruns = @(); drivers = @(); wmi = @()
                    })
            )
            $topGrowers = @((New-DemoRow @{ pid = 6124; name = 'svch0st.exe'; growthMB = 412; commitMB = 905; trust = 'Unsigned' }))
            $hidden = @()
            $drv = $drivers3p | Select-Object -Skip 1; $pa = $true
            $byProgram = @((New-DemoRow @{ name = 'svch0st.exe'; count = 1; privMB = 868; commitMB = 905; trust = 'Unsigned'; publisher = '' })) + $byProgram
            $topProcs = @((New-DemoRow @{ pid = 6124; name = 'svch0st.exe'; privMB = 868; wsMB = 880; commitMB = 905; handles = 96; growthMB = 412; trust = 'Unsigned'; publisher = ''; path = 'C:\Users\Friend\AppData\Local\Temp\svch0st.exe' })) + $topProcs
        }
        default {
            $memory = New-DemoRow @{
                TotalGB = 15.84; UsedGB = 7.3; AvailGB = 8.54; FreeGB = 3.1; StandbyGB = 5.44; ModifiedGB = 0.1
                ProcPrivateGB = 4.2; ProcSharedGB = 2.6; NonPagedGB = 0.62; PagedGB = 0.71; PagedResidentGB = 0.6; UnaccountedGB = 0
                CommittedGB = 9.1; CommitLimitGB = 24.3; CacheResidentGB = 1.1; DriverResidentGB = 0.1; WindowSec = 30
                NonPagedGrowthMB = 0; PagedGrowthMB = 1; CommitGrowthMB = 6; UsedGrowthMB = 4
            }
            $verdict = New-DemoRow @{ Level = 'ok'; Headline = 'لا يوجد تسرّب أو مؤشر خبيث واضح في هذه اللحظة' }
            $obs = @((New-DemoRow @{ Level = 'info'; Title = 'ذاكرة التخزين المؤقت (Standby/Cached)'; Body = 'حوالي 5.44 GB. هذي ذاكرة مُخزَّنة للتسريع ويحرّرها ويندوز فورًا عند الحاجة، فهي ليست مشكلة حتى لو ظهرت كاستخدام.' }))
            $mk = { param($t, $mb, $known) New-DemoRow @{ tag = $t; mb = $mb; deltaMB = 0; allocs = 1000; known = $known; candidates = @(); tooGeneric = $false } }
            $poolNon = @((& $mk 'EtwB' 78 'مخازن ETW لتتبّع الأحداث - نواة ويندوز'), (& $mk 'NVRM' 64 'تعريف NVIDIA للشاشة (nvlddmkm.sys)'), (& $mk 'smNp' 49 'مدير المخزن / ضغط الذاكرة (Store Manager) - نواة ويندوز'))
            $poolPaged = @((& $mk 'MmSt' 120 ''), (& $mk 'CM25' 40 ''))
            $poolGrow = @(); $suspects = @(); $topGrowers = @()
            $hidden = @(
                (New-DemoRow @{ Pid = 7692; Live = $false; Image = '\Device\HarddiskVolume3\Windows\SysWOW64\wbem\mofcomp.exe'; IsWindowsImage = $true }),
                (New-DemoRow @{ Pid = 10180; Live = $false; Image = '\Device\HarddiskVolume3\Windows\System32\msiexec.exe'; IsWindowsImage = $true })
            )
            $drv = $drivers3p | Select-Object -Skip 1; $pa = $true
        }
    }

    New-DemoRow @{
        Tool = 'RAM-Doctor'; Version = '1.0.0'; Created = '2026-10-24 21:44:30'; Sys = $sys; Memory = $memory; Verdict = $verdict
        Observations = @($obs); TopProcesses = @($topProcs); ByProgram = @($byProgram); TopGrowers = @($topGrowers)
        PoolNonPaged = @($poolNon); PoolPaged = @($poolPaged); PoolGrowing = @($poolGrow); PoolAvailable = $pa
        Suspects = @($suspects); Drivers3p = @($drv); Hidden = @($hidden); Defender = $defender; Exhaustion = @($exhaustion)
        Warnings = @(); ItemCounts = $counts
    }
}
