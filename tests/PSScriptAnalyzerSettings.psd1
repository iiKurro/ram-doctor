@{
    # Errors fail the gate (tests/Invoke-Checks.ps1); warnings are reported as annotations and fail only with -FailOnWarning.
    Severity     = @('Error', 'Warning')

    # Rules switched off on purpose. Every entry is a deliberate design decision of this project, not a way to hide problems.
    ExcludeRules = @(
        # The desktop window runs the scan/actions scripts as child processes and shows the timestamped lines they
        # print to the console as progress. Write-Host is that contract; Write-Output would pollute return values.
        'PSAvoidUsingWriteHost',

        # Probing code is best-effort by design: reading an optional registry key, a file another process may hold,
        # a CIM class absent on older builds. A failed probe must never abort a scan, and failures that matter are
        # reported explicitly through Warn()/Log() before the catch.
        'PSAvoidUsingEmptyCatchBlock',

        # Helper functions are internal to a script (Say, Warn, Guard, Handle-Line, Poll-Task, Info-Box ...). None is
        # exported as a cmdlet, so verb/noun conventions add churn without benefit.
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',

        # Same reason: these are not cmdlets. Anything that changes the system (stop process, disable service,
        # move file) is gated by an explicit, typed or dialog confirmation and logged, which is stricter than -WhatIf.
        'PSUseShouldProcessForStateChangingFunctions',

        # False positives with WinForms event handlers and scriptblocks: parameters/variables are consumed inside
        # nested scriptblocks that the analyzer does not follow.
        'PSReviewUnusedParameter',
        'PSUseDeclaredVarsMoreThanAssignments',

        # The report-sharing redactor takes the machine name as a parameter so it can scrub it from a report; its
        # tests pass synthetic names. The rule is meant to catch scripts that hard-code the real host they run on;
        # that risk is covered instead by the personal-data scan in tests\Invoke-Checks.ps1.
        'PSAvoidUsingComputerNameHardcoded'
    )

    Rules        = @{
        # The product targets Windows PowerShell 5.1 only (the one built into every Windows 10/11).
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
    }
}
