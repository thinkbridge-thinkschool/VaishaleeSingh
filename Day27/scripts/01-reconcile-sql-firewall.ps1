<#
.SYNOPSIS
    Sets each SQL server's firewall to exactly the addresses its container apps
    currently egress from, and removes rules that no longer match.

.DESCRIPTION
    WHY THIS EXISTS. On 2026-09-11 the dev API stopped starting. Every
    container crashed on boot with:

      Cannot open server 'sql-quotes-...' requested by the login.
      Client with IP address '20.203.116.141' is not allowed to access the
      server.  (SQL error 40615)

    Day 27's threat model had tightened the SQL firewall to a single rule
    naming the Container Apps environment's outbound address, and recorded
    that address as though it were a fixed property. It is not. The
    environment is Consumption-only, its egress address is not pinned to
    anything, and when Azure moved it from 20.203.119.48 to 20.203.116.141
    the app could no longer reach its database. Prod carried the identical
    stale rule and would have failed the same way the moment it woke.

    So a security control was turned into an availability failure, and the
    failure mode was cruel: SQL 40615 reads like a network problem, the
    container reports CrashLoopBackOff, the revision sits in Activating, and
    the deployment that "succeeded" is nowhere in the story.

    WHAT THIS DOES ABOUT IT. It asks Azure what the apps' outbound addresses
    are right now and makes the firewall say exactly that -- adding what is
    missing and removing what is stale, so the rule list cannot silently grow
    into the collection of forgotten addresses Day 27 spent its morning
    deleting.

    WHY IT IS NOT IN THE BICEP. The rule has to name a value that only exists
    after the container apps are created, and the apps cannot be created
    before the SQL server they connect to. The template would have to
    reference forward. More decisively, the address can change while nothing
    is deploying at all -- which is precisely what happened -- so a value
    fixed at deploy time is the wrong shape for it regardless.

    WHY IT IS NOT IN THE DEPLOY WORKFLOWS. The pipeline holds Contributor on
    the two container apps and AcrPush/Reader on the registry, and nothing at
    all on the SQL server. Giving CI the ability to rewrite database firewall
    rules to save an operator one command is a worse trade than running this
    by hand. Run it after a deploy, and after any 40615.

.EXAMPLE
    ./Day27/scripts/01-reconcile-sql-firewall.ps1 -WhatIf
    ./Day27/scripts/01-reconcile-sql-firewall.ps1
    ./Day27/scripts/01-reconcile-sql-firewall.ps1 -ResourceGroup thinkschool-prod-rg
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # Both environments by default: they share one Container Apps environment,
    # so they share an outbound address, and a change breaks both at once.
    [string[]] $ResourceGroup = @('thinkschool-dev-rg', 'thinkschool-prod-rg'),

    # The rule name is stable and the address lives in its value, deliberately.
    # An earlier fix created 'cae-outbound-20-203-116-141', which is a name that
    # becomes a lie the next time the address moves and leaves a second rule
    # behind when it does.
    [string] $RuleName = 'containerapps-env-outbound'
)

$ErrorActionPreference = 'Stop'

function Ok   ([string] $m) { Write-Host "  OK    $m" -ForegroundColor Green }
function Note ([string] $m) { Write-Host "  note  $m" -ForegroundColor Yellow }
function Die  ([string] $m) { Write-Host "  FAIL  $m" -ForegroundColor Red; exit 1 }

Write-Host ''
Write-Host 'Day 27 -- reconcile SQL firewall with the container apps'' egress' -ForegroundColor Cyan
Write-Host ''

# Invoke az and return parsed JSON, distinguishing "the command failed" from
# "the command succeeded and the answer is empty". Conflating those is how an
# earlier script in this repo reported a missing row as a passing check.
function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $AzArgs)
    $raw = & az @AzArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $text = ($raw | Out-String).Trim()
        Die "az $($AzArgs -join ' ') failed:`n$text"
    }
    $joined = ($raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($joined) -or $joined -eq '[]') { return @() }
    return $joined | ConvertFrom-Json
}

$changed = 0

foreach ($rg in $ResourceGroup) {

    Write-Host "Resource group: $rg" -ForegroundColor White

    if ((& az group exists -n $rg) -ne 'true') {
        Note "$rg does not exist -- skipping. (Prod is torn down between exercises.)"
        Write-Host ''
        continue
    }

    $servers = Invoke-AzJson @('sql', 'server', 'list', '-g', $rg, '--query', '[].name', '-o', 'json')
    if (-not $servers -or $servers.Count -eq 0) { Note "No SQL server in $rg -- skipping."; Write-Host ''; continue }

    $apps = Invoke-AzJson @('containerapp', 'list', '-g', $rg, '--query', '[].name', '-o', 'json')
    if (-not $apps -or $apps.Count -eq 0) { Note "No container apps in $rg -- skipping."; Write-Host ''; continue }

    # Every distinct outbound address across every app in the group. Plural on
    # purpose: one address is what this deployment happens to have, not a
    # guarantee, and assuming a single address is the assumption that broke.
    $addresses = @()
    foreach ($app in $apps) {
        $ips = Invoke-AzJson @('containerapp', 'show', '-n', $app, '-g', $rg, '--query', 'properties.outboundIpAddresses', '-o', 'json')
        foreach ($ip in @($ips)) { if ($ip) { $addresses += $ip } }
    }
    $addresses = @($addresses | Sort-Object -Unique)

    if ($addresses.Count -eq 0) {
        Note "Could not read an outbound address for any app in $rg. Leaving the firewall untouched."
        Note 'Removing rules on the strength of an empty answer would lock the apps out of the database.'
        Write-Host ''
        continue
    }

    Ok "Apps egress from: $($addresses -join ', ')"

    foreach ($server in $servers) {

        $existing = Invoke-AzJson @('sql', 'server', 'firewall-rule', 'list', '-g', $rg, '-s', $server,
                                    '--query', "[?starts_with(name, '$RuleName')]", '-o', 'json')

        # One rule per address, named <RuleName> for the first and
        # <RuleName>-N after it, so the set is recognisable and prunable.
        $wanted = @{}
        for ($i = 0; $i -lt $addresses.Count; $i++) {
            $name = if ($i -eq 0) { $RuleName } else { "$RuleName-$($i + 1)" }
            $wanted[$name] = $addresses[$i]
        }

        foreach ($name in $wanted.Keys) {
            $ip      = $wanted[$name]
            $current = @($existing) | Where-Object { $_.name -eq $name } | Select-Object -First 1

            if ($current -and $current.startIpAddress -eq $ip -and $current.endIpAddress -eq $ip) {
                Ok "$server / $name already allows $ip"
                continue
            }

            $verb = if ($current) { 'update' } else { 'create' }
            if ($PSCmdlet.ShouldProcess("$server / $name", "$verb -> $ip")) {
                $null = Invoke-AzJson @('sql', 'server', 'firewall-rule', $verb, '-g', $rg, '-s', $server,
                                        '-n', $name, '--start-ip-address', $ip, '--end-ip-address', $ip, '-o', 'json')
                Ok "$server / $name ${verb}d -> $ip"
                $changed++
            }
        }

        # Prune rules this script owns that no longer name a current address.
        # Only rules matching the managed prefix are touched: an operator's own
        # 'client-...' rule is somebody else's decision.
        foreach ($rule in @($existing)) {
            if ($wanted.ContainsKey($rule.name)) { continue }
            if ($PSCmdlet.ShouldProcess("$server / $($rule.name)", "delete stale rule ($($rule.startIpAddress))")) {
                $null = & az sql server firewall-rule delete -g $rg -s $server -n $rule.name 2>&1
                if ($LASTEXITCODE -ne 0) { Note "Could not delete stale rule $($rule.name) on $server." }
                else { Ok "$server / $($rule.name) removed (stale: $($rule.startIpAddress))"; $changed++ }
            }
        }
    }

    Write-Host ''
}

if ($changed -eq 0) {
    Ok 'Nothing to change: every server already allows exactly the current egress addresses.'
} else {
    Note "$changed rule change(s) applied."
    Note 'A container that was already crash-looping on SQL 40615 will not retry immediately.'
    Note 'Restart it rather than waiting out the backoff:'
    Note '  az containerapp revision restart -n <app> -g <group> --revision <active revision>'
}
Write-Host ''
