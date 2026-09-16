<#
.SYNOPSIS
    Stops any running QuotesPlatform.Host so a build can replace its DLLs.

.DESCRIPTION
    WHY THIS EXISTS. run-host.ps1 refuses to start when the port is already
    held, which is the right behaviour and only covers half the problem. The
    other half is what a LEFT-RUNNING Host does to the next build: MSBuild
    cannot copy any project's assembly into the Host's output directory, so it
    retries ten times per file and fails with MSB3021/MSB3027 across every
    module. That is 28 errors, 148 warnings and about a minute, none of which
    mention that a process is running -- the word "locked" appears only at the
    end of each line.

    It cost three builds on Day 30 before anyone read far enough right to see
    the PID, and the second symptom is worse than the first: with the copy
    blocked, the C# language server keeps resolving against the stale assembly,
    so types added in the current session appear not to exist. That reads as a
    compile error in code that is fine.

    So: one command, run before building, that says plainly whether anything
    was holding the output.

.EXAMPLE
    ./Day29/scripts/stop-host.ps1
    ./Day29/scripts/stop-host.ps1 -WhatIf     # report, do not stop
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'

$hosts = @(Get-Process -Name 'QuotesPlatform.Host' -ErrorAction SilentlyContinue)

if ($hosts.Count -eq 0) {
    Write-Host 'No QuotesPlatform.Host process is running.'
    return
}

foreach ($process in $hosts) {
    # Reported before stopping, because "which one was it" is the question a
    # failed build leaves behind and this is the only place that answers it.
    Write-Host ("Stopping QuotesPlatform.Host (PID {0}), started {1:HH:mm:ss}." -f
        $process.Id, $process.StartTime)

    if ($PSCmdlet.ShouldProcess("QuotesPlatform.Host (PID $($process.Id))", 'Stop')) {
        Stop-Process -Id $process.Id -Force
    }
}

# Stop-Process returns as soon as the request is made, not once the handles are
# released. A build started in the same breath can still lose the race, which
# would reproduce exactly the failure this script exists to prevent.
foreach ($process in $hosts) {
    if (-not $process.HasExited) {
        $null = $process.WaitForExit(10000)
    }
}

$remaining = @(Get-Process -Name 'QuotesPlatform.Host' -ErrorAction SilentlyContinue)

if ($remaining.Count -gt 0) {
    # A Host that comes back after being stopped is being restarted by
    # something -- dotnet watch, or the debugger -- and stopping it again will
    # not help.
    Write-Warning ("QuotesPlatform.Host is still running (PID {0}). Something is restarting it: check for a dotnet watch or an attached debugger." -f
        ($remaining.Id -join ', '))
}
else {
    Write-Host 'Output directory is free; the build can copy into it.'
}
