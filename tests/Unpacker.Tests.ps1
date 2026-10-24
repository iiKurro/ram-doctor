#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# The unpacker is the code that runs, ELEVATED, on a stranger's PC before anything else, so it is tested as shipped:
# the exact command line is lifted out of the built .bat and executed. The tests use the TEST variant (-DevHooks): it has the
# same payload and the same unpack code as the release file, plus hooks to run headless (Build.Tests.ps1 pins that down).
#
# Two modes exist (see the header of the .bat):
#   secure  %ProgramData%\RAM-Doctor-run\<random>, administrators only      <- what a real user always gets
#   temp    %TEMP%\RAM-Doctor-run-<random>                                  <- tests on a NON-admin session only (TEST variant only)
# On an administrator session (CI runners, an elevated console) every test below exercises the secure mode;
# tests tagged 'Elevated' are skipped on a normal session.

BeforeDiscovery {
    $script:Elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestHelpers.ps1')
    $script:Root = Get-RepoRoot
    $script:IsElevated = Test-IsElevated
    $script:Out = New-TempDirectory 'ramdoc-unpack'
    # these tests drive the file through RAMDOC_* hooks, which exist only in the TEST variant (the release file has none)
    $script:Bat = Join-Path $script:Out 'RAM-Doctor.devhooks.bat'
    $null = & (Join-Path $script:Root 'build\Build-SingleFile.ps1') -OutFile $script:Bat -DevHooks 6>$null
    $script:RunParent = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'RAM-Doctor-run'
    $script:RunParentExisted = Test-Path -LiteralPath $script:RunParent
    $script:Trusted = @('S-1-5-18', 'S-1-5-32-544')

    function Get-Residue([string]$PrivateTemp) {
        # the unpack folders a finished run must not leave behind
        if ($script:IsElevated) { if (Test-Path -LiteralPath $script:RunParent) { return @(Get-ChildItem -LiteralPath $script:RunParent -Force | ForEach-Object { $_.Name }) } else { return @() } }
        return @(Get-ChildItem -LiteralPath $PrivateTemp -Force | ForEach-Object { $_.Name })
    }
    function Invoke-BatHeadless([string]$BatPath, [string]$PrivateTemp, [string]$GuiArgs = '-NoSuchSwitchForCi') {
        # RAMDOC_GUI_ARGS makes the window script reject an unknown switch at once, so no window ever opens
        return (Invoke-ChildProcess -FilePath $env:ComSpec -Arguments ('/c ""{0}" min"' -f $BatPath) -TimeoutSec 180 -Environment @{
                TEMP = $PrivateTemp; TMP = $PrivateTemp; RAMDOC_NOELEVATE = '1'; RAMDOC_GUI_ARGS = $GuiArgs
            })
    }
}

AfterAll {
    if ($script:Out) { Remove-TreeForce -Path $script:Out }
    # the run parent is only ours to remove when it did not exist before these tests and is empty again
    if ($script:IsElevated -and -not $script:RunParentExisted -and (Test-Path -LiteralPath $script:RunParent) -and @(Get-ChildItem -LiteralPath $script:RunParent -Force).Count -eq 0) {
        Remove-TreeForce -Path $script:RunParent
    }
}

Describe 'Unpacker command (as shipped in the .bat)' {
    BeforeAll {
        $script:Result = & (Join-Path $script:Root 'build\Expand-SingleFile.ps1') -Bat $script:Bat -SourceRoot $script:Root -PrivateTemp (Join-Path $script:Out 'tmp-expand')
    }
    AfterAll {
        if ($script:Result -and $script:Result.Dest) { Remove-TreeForce -Path $script:Result.Dest }
    }

    It 'uses the mode the session calls for (secure folder when administrator, temp folder otherwise)' {
        $script:Result.Mode | Should -Be $(if ($script:IsElevated) { 'Secure' } else { 'Temp' })
    }

    It 'exits cleanly' {
        $script:Result.ExitCode | Should -Be 0 -Because $script:Result.StdErr
    }

    It 'extracts every file, byte-identical to its source (UTF-8 BOM + CRLF), and nothing else' {
        $script:Result.Problems | Should -BeNullOrEmpty
        $script:Result.Files.Count | Should -BeGreaterThan 3
    }

    It 'writes every file with a UTF-8 BOM (Windows PowerShell 5.1 needs it for Arabic text)' {
        foreach ($rel in $script:Result.Files) {
            $b = [IO.File]::ReadAllBytes((Join-Path $script:Result.Dest $rel))
            ('{0:X2}{1:X2}{2:X2}' -f $b[0], $b[1], $b[2]) | Should -Be 'EFBBBF' -Because $rel
        }
    }

    It 'extracts PowerShell files that still parse without errors' {
        foreach ($rel in ($script:Result.Files | Where-Object { $_ -like '*.ps1' })) {
            $e = $null; $t = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Result.Dest $rel), [ref]$t, [ref]$e)
            @($e).Count | Should -Be 0 -Because $rel
        }
    }

    It 'keeps the folder layout the window script relies on (src\lib next to src\)' {
        Test-Path (Join-Path $script:Result.Dest 'src\RAM-Doctor-GUI.ps1') | Should -BeTrue
        Test-Path (Join-Path $script:Result.Dest 'src\lib\Native.cs') | Should -BeTrue
    }
}

Describe 'Header ACL helpers (pieces P1-P3 of the header, run exactly as shipped)' {
    BeforeAll {
        $script:LockedProbe = "'RESULT:' + (@{ locked = (Test-LockedDir '__DIR__') } | ConvertTo-Json -Compress)"
        $script:AclProbe = @'
$d = '__DIR__'
New-LockedDir $d
$i = New-Object IO.DirectoryInfo($d)
$a = $i.GetAccessControl()
$rules = @($a.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { @{ sid = $_.IdentityReference.Value; rights = [string]$_.FileSystemRights; inherit = [string]$_.InheritanceFlags; type = [string]$_.AccessControlType } })
'RESULT:' + (@{ protected = $a.AreAccessRulesProtected; owner = $a.GetOwner([Security.Principal.SecurityIdentifier]).Value; rules = $rules; locked = (Test-LockedDir $d) } | ConvertTo-Json -Depth 4 -Compress)
'@
    }

    It 'New-LockedDir creates the folder already locked: inheritance off, FullControl for SYSTEM and Administrators only' {
        $dir = Join-Path $script:Out 'acl-probe'
        try {
            $r = Invoke-HeaderSnippet -Bat $script:Bat -Code $script:AclProbe.Replace('__DIR__', $dir)
            $r.ExitCode | Should -Be 0 -Because $r.StdErr
            $res = Get-SnippetResult -Run $r
            $res.protected | Should -BeTrue
            $rules = @($res.rules)
            $rules.Count | Should -Be 2
            ($rules | ForEach-Object { $_.sid } | Sort-Object) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
            foreach ($x in $rules) {
                $x.rights | Should -Be 'FullControl'
                $x.type | Should -Be 'Allow'
                $x.inherit | Should -Be 'ContainerInherit, ObjectInherit'
            }
        }
        finally { Remove-TreeForce -Path $dir }
    }

    It 'Test-LockedDir accepts that folder only when its owner is SYSTEM/Administrators (true for an elevated session, false for a normal user)' {
        $dir = Join-Path $script:Out 'acl-owner'
        try {
            $res = Get-SnippetResult -Run (Invoke-HeaderSnippet -Bat $script:Bat -Code $script:AclProbe.Replace('__DIR__', $dir))
            $res.locked | Should -Be $script:IsElevated
            if ($script:IsElevated) { $script:Trusted | Should -Contain $res.owner }
            else { $script:Trusted | Should -Not -Contain $res.owner }
        }
        finally { Remove-TreeForce -Path $dir }
    }

    It 'Test-LockedDir rejects an ordinary folder (inherited permissions)' {
        $dir = Join-Path $script:Out 'acl-plain'
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $r = Invoke-HeaderSnippet -Bat $script:Bat -Code $script:LockedProbe.Replace('__DIR__', $dir)
            (Get-SnippetResult -Run $r).locked | Should -BeFalse
        }
        finally { Remove-TreeForce -Path $dir }
    }

    It 'Test-LockedDir rejects a junction, even one that points at a properly locked folder' {
        $target = Join-Path $script:Out 'acl-junction-target'
        $link = Join-Path $script:Out 'acl-junction'
        try {
            $null = Invoke-HeaderSnippet -Bat $script:Bat -Code $script:AclProbe.Replace('__DIR__', $target)
            & cmd.exe /c mklink /J "$link" "$target" | Out-Null
            Test-Path -LiteralPath $link | Should -BeTrue
            $r = Invoke-HeaderSnippet -Bat $script:Bat -Code $script:LockedProbe.Replace('__DIR__', $link)
            (Get-SnippetResult -Run $r).locked | Should -BeFalse
        }
        finally { Remove-TreeForce -Path $link; Remove-TreeForce -Path $target }
    }

    It 'Test-LockedDir rejects a folder that does not exist' {
        $r = Invoke-HeaderSnippet -Bat $script:Bat -Code $script:LockedProbe.Replace('__DIR__', (Join-Path $script:Out 'nope'))
        (Get-SnippetResult -Run $r).locked | Should -BeFalse
    }
}

Describe 'Whole .bat, run headless' {

    It 'unpacks, hands over to the window script, and leaves no unpack folder behind' {
        $priv = New-TempDirectory 'ramdoc-bat-temp'
        try {
            $before = @(Get-Residue $priv)
            $r = Invoke-BatHeadless -BatPath $script:Bat -PrivateTemp $priv
            $r.TimedOut | Should -BeFalse
            ($r.StdOut + $r.StdErr) | Should -Not -Match 'Could not unpack'
            # proof that the script was found and started: PowerShell itself complained about our bogus switch
            ($r.StdOut + $r.StdErr) | Should -Match 'NoSuchSwitchForCi'
            @(Get-Residue $priv) | Should -Be $before
        }
        finally { Remove-TreeForce -Path $priv }
    }

    It 'works from a folder with spaces and parentheses, for a file called "RAM-Doctor (1).bat" (how browsers rename a second download)' {
        $priv = New-TempDirectory 'ramdoc-bat-temp'
        $dir = Join-Path $script:Out 'my downloads (new)'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $copy = Join-Path $dir 'RAM-Doctor (1).bat'
        Copy-Item -LiteralPath $script:Bat -Destination $copy
        try {
            $before = @(Get-Residue $priv)
            $r = Invoke-BatHeadless -BatPath $copy -PrivateTemp $priv
            $r.TimedOut | Should -BeFalse
            ($r.StdOut + $r.StdErr) | Should -Not -Match 'Could not unpack'
            ($r.StdOut + $r.StdErr) | Should -Match 'NoSuchSwitchForCi'
            @(Get-Residue $priv) | Should -Be $before
        }
        finally { Remove-TreeForce -Path $priv }
    }

    It 'fails closed when the package is damaged: says so, exits with 1, runs nothing, leaves nothing' {
        $priv = New-TempDirectory 'ramdoc-bat-temp'
        $broken = Join-Path $script:Out 'broken.bat'
        $text = [IO.File]::ReadAllText($script:Bat)
        $cut = [regex]::Match($text, '(?m)^#@@FILE ').Index
        [IO.File]::WriteAllText($broken, $text.Substring(0, $cut), (New-Object System.Text.UTF8Encoding($false)))    # header only, no payload
        try {
            $before = @(Get-Residue $priv)
            $r = Invoke-BatHeadless -BatPath $broken -PrivateTemp $priv
            $r.TimedOut | Should -BeFalse
            $r.ExitCode | Should -Be 1
            ($r.StdOut + $r.StdErr) | Should -Match 'Could not unpack RAM Doctor'
            ($r.StdOut + $r.StdErr) | Should -Not -Match 'NoSuchSwitchForCi'
            @(Get-Residue $priv) | Should -Be $before
        }
        finally { Remove-TreeForce -Path $priv }
    }

    It 'removes unpack folders older than a day and keeps recent ones' {
        $priv = New-TempDirectory 'ramdoc-bat-temp'
        $planted = @()
        try {
            if ($script:IsElevated) {
                $r0 = Invoke-BatHeadless -BatPath $script:Bat -PrivateTemp $priv        # also makes sure the locked parent exists
                if ($r0.ExitCode -ne 0) { Set-ItResult -Skipped -Because 'an existing, unsafe ProgramData\RAM-Doctor-run folder blocks the unpacker (that is tested separately)'; return }
                $parent = $script:RunParent
                $old = Join-Path $parent ('ci-old-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
                $new = Join-Path $parent ('ci-new-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            }
            else {
                $old = Join-Path $priv 'RAM-Doctor-run-ciold01'
                $new = Join-Path $priv 'RAM-Doctor-run-cinew01'
            }
            foreach ($d in $old, $new) { New-Item -ItemType Directory -Path $d | Out-Null; $planted += $d }
            (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-3)
            $r = Invoke-BatHeadless -BatPath $script:Bat -PrivateTemp $priv
            ($r.StdOut + $r.StdErr) | Should -Match 'NoSuchSwitchForCi'
            Test-Path -LiteralPath $old | Should -BeFalse -Because 'leftovers older than a day are swept on start'
            Test-Path -LiteralPath $new | Should -BeTrue -Because 'a recent folder (maybe a second copy still running) must be left alone'
        }
        finally { foreach ($d in $planted) { Remove-TreeForce -Path $d }; Remove-TreeForce -Path $priv }
    }

    It 'with the "min" argument it does not relaunch itself in a second window' {
        $text = [IO.File]::ReadAllText($script:Bat)
        $text | Should -Match '(?m)^if /i "%~1"=="min" goto :started'
    }
}

Describe 'Secure unpack folder (administrator session only)' -Tag 'Elevated' -Skip:(-not $script:Elevated) {

    It 'unpack folder and its parent are owned by SYSTEM/Administrators, not junctions, inheritance off, allow-rules for SYSTEM + Administrators only' {
        $null = & (Join-Path $script:Root 'build\Build-SingleFile.ps1') -OutFile (Join-Path $script:Out 'sec\RAM-Doctor.devhooks.bat') -DevHooks 6>$null
        $x = & (Join-Path $script:Root 'build\Expand-SingleFile.ps1') -Bat (Join-Path $script:Out 'sec\RAM-Doctor.devhooks.bat') -Mode Secure
        try {
            $x.ExitCode | Should -Be 0 -Because $x.StdErr
            $x.Dest | Should -Not -BeNullOrEmpty
            $x.Dest.StartsWith($script:RunParent + '\', [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
            foreach ($dir in @($x.Dest, $script:RunParent, (Join-Path $x.Dest 'src'))) {
                $di = New-Object IO.DirectoryInfo($dir)
                ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Be 0 -Because "$dir must not be a junction"
                $acl = $di.GetAccessControl()
                $script:Trusted | Should -Contain $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
                $allow = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' } | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
                $allow | Should -Be @('S-1-5-18', 'S-1-5-32-544') -Because "$dir must grant access to SYSTEM and Administrators only"
                if ($dir -ne (Join-Path $x.Dest 'src')) { $acl.AreAccessRulesProtected | Should -BeTrue -Because "$dir must not inherit permissions" }
            }
            # an extracted file inherits the same two entries and nothing else
            $file = Join-Path $x.Dest 'src\RAM-Doctor-GUI.ps1'
            $facl = (Get-Item -LiteralPath $file).GetAccessControl()
            @($facl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' } | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
        }
        finally { if ($x -and $x.Dest) { Remove-TreeForce -Path $x.Dest } }
    }

    It 'refuses to unpack when ProgramData\RAM-Doctor-run already exists but is NOT locked down (a user could have created it)' {
        if ($script:RunParentExisted) { Set-ItResult -Skipped -Because 'ProgramData\RAM-Doctor-run existed before the tests; the test will not touch it'; return }
        $priv = New-TempDirectory 'ramdoc-bat-temp'
        try {
            New-Item -ItemType Directory -Path $script:RunParent | Out-Null          # plain folder: inherits the permissive ProgramData ACL
            $r = Invoke-BatHeadless -BatPath $script:Bat -PrivateTemp $priv
            $r.ExitCode | Should -Be 1
            ($r.StdOut + $r.StdErr) | Should -Match 'Could not unpack RAM Doctor'
            ($r.StdOut + $r.StdErr) | Should -Match 'not locked down'
            ($r.StdOut + $r.StdErr) | Should -Not -Match 'NoSuchSwitchForCi' -Because 'nothing may run from an untrusted folder'
            @(Get-ChildItem -LiteralPath $script:RunParent -Force).Count | Should -Be 0
        }
        finally { Remove-TreeForce -Path $script:RunParent; Remove-TreeForce -Path $priv }
    }

    It 'refuses to unpack when ProgramData\RAM-Doctor-run is a junction' {
        if ($script:RunParentExisted) { Set-ItResult -Skipped -Because 'ProgramData\RAM-Doctor-run existed before the tests; the test will not touch it'; return }
        $priv = New-TempDirectory 'ramdoc-bat-temp'
        $target = Join-Path $script:Out 'junction-target'
        New-Item -ItemType Directory -Path $target | Out-Null
        try {
            & cmd.exe /c mklink /J "$($script:RunParent)" "$target" | Out-Null
            $r = Invoke-BatHeadless -BatPath $script:Bat -PrivateTemp $priv
            $r.ExitCode | Should -Be 1
            ($r.StdOut + $r.StdErr) | Should -Match 'not locked down'
            @(Get-ChildItem -LiteralPath $target -Force).Count | Should -Be 0 -Because 'nothing may be unpacked through the junction'
        }
        finally { Remove-TreeForce -Path $script:RunParent; Remove-TreeForce -Path $target; Remove-TreeForce -Path $priv }
    }

    It 'Test-LockedDir rejects a folder owned by SYSTEM/Administrators that grants access to somebody else' {
        $dir = Join-Path $script:Out 'acl-extra-rule'
        try {
            $code = @'
$d = '__DIR__'
New-LockedDir $d
$i = New-Object IO.DirectoryInfo($d)
$before = Test-LockedDir $d
$a = $i.GetAccessControl()
$a.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-11')), 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
$i.SetAccessControl($a)
'RESULT:' + (@{ before = $before; after = (Test-LockedDir $d) } | ConvertTo-Json -Compress)
'@
            $res = Get-SnippetResult -Run (Invoke-HeaderSnippet -Bat $script:Bat -Code $code.Replace('__DIR__', $dir))
            $res.before | Should -BeTrue
            $res.after | Should -BeFalse -Because 'an allow-rule for Authenticated Users (S-1-5-11) means a normal program could write there'
        }
        finally { Remove-TreeForce -Path $dir }
    }
}
