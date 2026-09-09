<#
.SYNOPSIS
    Day 25. Writes (or rotates) the JWT signing key directly into Key Vault,
    so the value never passes through a template, a parameter file, or a
    deployment.

.DESCRIPTION
    WHY A SCRIPT AND NOT A BICEP RESOURCE.

    Bicep can create a secret. Doing so would mean the value arrives as a
    @secure() parameter, and "@secure() is not logged" is a narrower promise
    than it sounds. The value still exists in plain text everywhere the
    deployment is launched from:

      * the operator's shell history, and the azd .env on their laptop;
      * the CI runner's process environment, and whatever that runner logs on
        a verbose day;
      * the request body sent to the ARM deployment API.

    None of those is the vault, and every one of them is somewhere the secret
    can be read. Day 24's parameter files read JWT_SECRET from the environment
    for precisely this reason. Cutting that chain is most of what Day 25 buys,
    and it cannot be cut by a template that still needs the value handed to it.

    So the path is: operator -> vault. Nothing in between. The template only
    ever names the secret's URI, and infra/modules/keyvault.bicep creates the
    vault empty.

    WHAT IT DOES
      1. Checks you can actually write to the vault (Key Vault Secrets Officer
         or better), and says so plainly if you cannot -- a 403 from the data
         plane otherwise reads like the vault does not exist.
      2. Generates a 64-character key from a CRYPTOGRAPHIC random source. Not
         Get-Random, which is seeded pseudo-randomness and is not fit for a
         signing key.
      3. Writes it as a new VERSION of the secret. Key Vault versions secrets,
         so a rotation is additive and the previous version stays readable
         until you disable it -- which matters, because tokens signed with the
         old key stay valid until they expire.
      4. Prints the URI, never the value.

    ROTATION IS THE DEFAULT READING OF THIS SCRIPT, NOT AN EXTRA MODE. Run it
    again and you have rotated. The one thing to understand before you do:
    every access token this API has already issued was signed with the old key
    and stops validating the moment the app picks up the new one. That is the
    correct behaviour for a key you believe is compromised -- and the current
    one IS compromised, because a literal for it is in this repository's git
    history -- but it signs out every user, so do it deliberately.

.PARAMETER VaultName
    The vault to write to. Defaults to discovery from the resource group, so
    the resource token does not have to be typed.

.PARAMETER SecretName
    Defaults to 'jwt-secret', which is the name modules/api.bicep references.

.PARAMETER WhatIf
    Report what would be written, generate nothing, change nothing.

.EXAMPLE
    ./Day25/scripts/01-seed-jwt-secret.ps1 -WhatIf
    ./Day25/scripts/01-seed-jwt-secret.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SubscriptionId = '85567e22-432e-4648-aa68-ba2714167694',
    [string] $ResourceGroup  = 'thinkschool-dev-rg',
    [string] $VaultName      = '',
    [string] $SecretName     = 'jwt-secret'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Ok   ([string] $m) { Write-Host "  OK    $m" -ForegroundColor Green }
function Note ([string] $m) { Write-Host "  note  $m" -ForegroundColor Yellow }
function Die  ([string] $m) { Write-Host "  FAIL  $m" -ForegroundColor Red; exit 1 }

Write-Host ''
Write-Host 'Day 25 -- seed the JWT signing key into Key Vault' -ForegroundColor Cyan
Write-Host ''

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Die 'az is not on PATH.' }

az account set --subscription $SubscriptionId 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Die 'Could not select the subscription. Run az login.' }

# ---------------------------------------------------------------------------
# 1. Find the vault
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($VaultName)) {
    $found = az keyvault list -g $ResourceGroup --query "[].name" -o tsv 2>$null
    $names = @($found | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($names.Count -eq 0) {
        Die "No key vault in $ResourceGroup. Deploy the stack first -- infra/modules/keyvault.bicep creates it empty, and this script fills it."
    }
    if ($names.Count -gt 1) {
        Die "More than one vault in $ResourceGroup ($($names -join ', ')). Pass -VaultName."
    }
    $VaultName = $names[0]
}
Ok "Vault: $VaultName"

# ---------------------------------------------------------------------------
# 2. Confirm we can write, before generating anything
# ---------------------------------------------------------------------------
# The vault uses RBAC rather than access policies, so writing needs Key Vault
# Secrets Officer (or Administrator) on the vault. Being subscription Owner is
# NOT sufficient by itself and this surprises people every time: management
# plane ownership does not grant data plane access, and the refusal comes back
# as a flat 403 Forbidden that reads like the secret does not exist.
$signedInId = az ad signed-in-user show --query id -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($signedInId)) {
    Note 'Could not resolve the signed-in user; skipping the pre-flight permission check.'
} else {
    $vaultId = az keyvault show -n $VaultName --query id -o tsv 2>$null
    $roles = az role assignment list --assignee $signedInId --scope $vaultId --query "[].roleDefinitionName" -o tsv 2>$null
    $roleList = @($roles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $canWrite = @($roleList | Where-Object { $_ -in @('Key Vault Secrets Officer', 'Key Vault Administrator') }).Count -gt 0
    if ($canWrite) {
        Ok "You hold: $($roleList -join ', ')"
    } else {
        Note "You do not appear to hold Key Vault Secrets Officer on this vault (found: $(if ($roleList.Count) { $roleList -join ', ' } else { 'no direct assignments' }))."
        Note 'If the write below fails with 403, this is why. Grant it with:'
        Write-Host ''
        Write-Host "    az role assignment create --role `"Key Vault Secrets Officer`" --assignee $signedInId --scope $vaultId" -ForegroundColor Cyan
        Write-Host ''
        Note 'An inherited assignment from a group or a higher scope will not show above; the check is advisory, not a gate.'
    }
}

# ---------------------------------------------------------------------------
# 3. Is this a first seed or a rotation? Say which, out loud.
# ---------------------------------------------------------------------------
# Deliberately reads only the METADATA. `az keyvault secret show` would return
# the value, and this script has no reason to hold it -- not even in a variable
# it never prints, because a variable is one Write-Host away from a transcript.
$existing = az keyvault secret list --vault-name $VaultName --query "[?name=='$SecretName'].id" -o tsv 2>$null
$isRotation = -not [string]::IsNullOrWhiteSpace($existing)

if ($isRotation) {
    Note "'$SecretName' already exists. This will add a NEW VERSION -- a rotation."
    Note 'Every access token already issued was signed with the previous key and will stop validating once the app picks this up. That signs out every user.'
} else {
    Ok "'$SecretName' does not exist yet. This is the first seed."
}

# ---------------------------------------------------------------------------
# 4. Generate, and write
# ---------------------------------------------------------------------------
# RandomNumberGenerator, not Get-Random. Get-Random is a seeded pseudo-random
# generator intended for sampling and shuffling; its output is predictable
# given the seed and it has no business producing a signing key. 48 bytes of
# CSPRNG output becomes 64 base64 characters, comfortably past the 32 that
# JwtOptions enforces and past the 256 bits HMAC-SHA256 actually uses.
if (-not $PSCmdlet.ShouldProcess("$VaultName/$SecretName", 'write a new secret version')) {
    Note 'WhatIf: nothing was generated and nothing was written.'
    exit 0
}

$bytes = New-Object byte[] 48
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$value = [Convert]::ToBase64String($bytes)

# --value on the command line puts the secret in this process's argument list,
# which is readable by other processes on some systems and lands in PSReadLine
# history if a human ever retypes it. --file avoids both. The temp file is
# written outside the repository, and removed in a finally block so it does not
# survive a failure.
$tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("jwt-" + [Guid]::NewGuid().ToString("N") + ".txt")
try {
    # -NoNewline matters: a trailing newline becomes part of the secret, and
    # the resulting signature mismatch is invisible -- the key is "right", the
    # tokens just do not validate.
    [System.IO.File]::WriteAllText($tempFile, $value)

    $secretId = az keyvault secret set `
        --vault-name $VaultName `
        --name $SecretName `
        --file $tempFile `
        --description 'QuotesApi JWT signing key. Written directly to the vault; never present in a template, parameter file or deployment.' `
        --query id -o tsv 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($secretId)) {
        Die "Writing the secret failed. If this was a 403, see the role assignment command printed above."
    }

    Ok "Written."
    Write-Host ''
    Write-Host "  Secret id (safe to share -- it is an address, not a value):" -ForegroundColor Cyan
    Write-Host "    $secretId"
    Write-Host ''
} finally {
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    # The value is still in memory until this scope goes away. Clearing the
    # variable is hygiene rather than a guarantee -- .NET strings are immutable
    # and the original may survive in the heap until GC -- but it costs nothing
    # and it keeps the value out of any later transcript of this session.
    $value = $null
}

# ---------------------------------------------------------------------------
# 5. What has to happen next, because the secret alone is not enough
# ---------------------------------------------------------------------------
# The container app resolves a Key Vault reference when a REVISION IS CREATED,
# not on every request. A rotation therefore does not reach a running app: the
# revision keeps the value it resolved at start-up. That is not a bug to work
# around -- it is why rotation is a deployment rather than a database update --
# but it does mean the app is still signing with the old key until it rolls.
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host '  1. Deploy the stack, so the container app picks up the Key Vault reference.'
Write-Host '  2. If the app was already running, roll it -- a Key Vault reference is'
Write-Host '     resolved when a revision is created, so a rotation does not reach a'
Write-Host '     revision that is already running:'
Write-Host ''
Write-Host '       az containerapp revision restart -n quotes-api-dev -g ' -NoNewline
Write-Host $ResourceGroup
Write-Host ''
Write-Host '  3. Re-run Day25/scripts/00-prove-no-secrets.ps1 (no -Baseline).'
Write-Host ''
