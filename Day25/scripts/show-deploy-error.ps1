<#
.SYNOPSIS
    Day 25. Finds the actual error behind "At least one resource deployment
    operation failed" by walking the nested deployments ARM hides it in.

.DESCRIPTION
    A deployment stack over a subscription-scoped template with modules
    produces three levels: the STACK reports DeploymentStackDeploymentFailed,
    the subscription DEPLOYMENT reports DeploymentFailed with an empty details
    array, and the real message lives in an operation on a nested resource
    group deployment two levels down. The top-level output tells you to "list
    deployment operations for details" and does not say which of the four
    deployments to list, which is how a two-minute diagnosis becomes twenty.

    This walks it. Given nothing at all it finds the most recent failed
    subscription deployment by itself, then recurses into every nested
    deployment it created, and prints only the operations that actually failed
    with the resource, the code and the message.

    Written as a script rather than handed over as a pasteable pipeline for the
    reason Day 24 recorded: multi-line PowerShell with backtick continuations
    went wrong twice in that session, once because the shell swallowed a
    continuation and once because a previous transcript was pasted back in.

.PARAMETER DeploymentName
    A specific subscription-scoped deployment, e.g. quotes-dev-26090904fifru.
    Omit to take the most recent failed one.

.EXAMPLE
    ./Day25/scripts/show-deploy-error.ps1
    ./Day25/scripts/show-deploy-error.ps1 -DeploymentName quotes-dev-26090904fifru
#>

[CmdletBinding()]
param(
    [string] $SubscriptionId = '85567e22-432e-4648-aa68-ba2714167694',
    [string] $ResourceGroup  = 'thinkschool-dev-rg',
    [string] $DeploymentName = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $AzArgs)
    $raw = & az @AzArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $joined = ($raw -join "`n")
    if ([string]::IsNullOrWhiteSpace($joined) -or $joined.Trim() -eq '[]') { return $null }
    try { return $joined | ConvertFrom-Json } catch { return $null }
}

function Has { param($o, [string] $n) if ($null -eq $o) { return $false } return ($o.PSObject.Properties.Name -contains $n) }

az account set --subscription $SubscriptionId 2>$null | Out-Null

Write-Host ''
if ([string]::IsNullOrWhiteSpace($DeploymentName)) {
    $recent = Invoke-AzJson @('deployment', 'sub', 'list', '--query',
        "[?properties.provisioningState=='Failed'].{name:name,ts:properties.timestamp}", '-o', 'json')
    if ($null -eq $recent) { Write-Host '  No failed subscription deployments found.' -ForegroundColor Green; exit 0 }
    $DeploymentName = (@($recent) | Sort-Object -Property ts -Descending)[0].name
    Write-Host "Most recent failed subscription deployment: $DeploymentName" -ForegroundColor Cyan
} else {
    Write-Host "Subscription deployment: $DeploymentName" -ForegroundColor Cyan
}
Write-Host ''

$findings = 0

function Show-Failures {
    param([string] $Scope, [string] $Name, [int] $Depth)

    $indent = '  ' * ($Depth + 1)

    $ops = if ($Scope -eq 'sub') {
        Invoke-AzJson @('deployment', 'operation', 'sub', 'list', '--name', $Name, '-o', 'json')
    } else {
        Invoke-AzJson @('deployment', 'operation', 'group', 'list', '-g', $ResourceGroup, '--name', $Name, '-o', 'json')
    }
    if ($null -eq $ops) { return }

    foreach ($op in @($ops)) {
        if (-not (Has $op 'properties')) { continue }
        $p = $op.properties
        if (-not (Has $p 'provisioningState') -or $p.provisioningState -ne 'Failed') { continue }

        $resName = if ((Has $p 'targetResource') -and (Has $p.targetResource 'resourceName')) { $p.targetResource.resourceName } else { '(unknown)' }
        $resType = if ((Has $p 'targetResource') -and (Has $p.targetResource 'resourceType')) { $p.targetResource.resourceType } else { '' }

        # A failed nested deployment is a POINTER, not the error. Recurse into
        # it rather than printing "DeploymentFailed" a third time.
        if ($resType -eq 'Microsoft.Resources/deployments') {
            Write-Host ("{0}v {1}" -f $indent, $resName) -ForegroundColor DarkGray
            Show-Failures -Scope 'group' -Name $resName -Depth ($Depth + 1)
            continue
        }

        $code = ''
        $message = ''
        if ((Has $p 'statusMessage') -and (Has $p.statusMessage 'error')) {
            $err = $p.statusMessage.error
            if (Has $err 'code')    { $code = $err.code }
            if (Has $err 'message') { $message = $err.message }
        }

        $script:findings++
        Write-Host ("{0}FAILED  {1}" -f $indent, $resName) -ForegroundColor Red
        if ($resType) { Write-Host ("{0}        {1}" -f $indent, $resType) -ForegroundColor DarkGray }
        if ($code)    { Write-Host ("{0}        {1}" -f $indent, $code) -ForegroundColor Yellow }
        if ($message) {
            # Wrapped, because these messages arrive as one long line and the
            # useful half is usually at the end.
            $wrapped = $message -split '(?<=\G.{110})'
            foreach ($line in $wrapped) {
                if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Host ("{0}        {1}" -f $indent, $line.Trim()) }
            }
        }
        Write-Host ''
    }
}

Show-Failures -Scope 'sub' -Name $DeploymentName -Depth 0

if ($script:findings -eq 0) {
    Write-Host '  Walked the tree and found no failed leaf operation.' -ForegroundColor Yellow
    Write-Host '  That usually means the failure is on the STACK rather than the deployment —' -ForegroundColor DarkGray
    Write-Host '  most often a deny-assignment refusal while cleaning up a resource that left' -ForegroundColor DarkGray
    Write-Host '  the template. Check:' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '    az stack sub show -n quotes-dev --query "{state:provisioningState,failed:failedResources}" -o json' -ForegroundColor Cyan
    Write-Host ''
}
