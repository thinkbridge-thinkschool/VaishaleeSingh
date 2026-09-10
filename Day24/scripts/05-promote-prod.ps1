<#
.SYNOPSIS
    Promotes dev to prod: preflight, deployment stack, image import, the two
    steps ARM cannot do, then verification.

.DESCRIPTION
    WHY THIS IS A SCRIPT AND NOT A COMMAND. `az stack sub create` against
    main.prod.bicepparam produces a complete prod environment running
    Microsoft's hello-world container and authenticating nobody. Four things
    stand between that and a working promotion, and every one of them was
    learned by hitting it in dev:

      1. THE IMAGE. Prod gets its own registry (the name derives from a
         resource token in main.bicep), and CI only ever pushes to dev's. With
         quotesApiExists = false the template resolves the image to
         mcr.microsoft.com/azuredocs/aci-helloworld:latest. So the images must
         be imported from the dev registry -- imported, not rebuilt, so the
         bytes that were tested are the bytes that run.

      2. THE VAULT IS EMPTY BY DESIGN. keyvault.bicep creates no secrets, so
         the first deploy of a fresh environment ALWAYS fails once: the
         container app cannot resolve its jwt-secret reference. Deploy, seed,
         redeploy. Day 25 discovered this the hard way and it is not a bug --
         a template that carries the secret is a template that has the secret.

      3. THE SQL USER IS T-SQL. An Entra-only server grants the managed
         identity access to the SERVER; the contained user inside the DATABASE
         is not something ARM can create. Skipping it produces an app that
         starts and never becomes ready.

      4. ENTRA. main.bicep no longer defaults azureAdClientId / TenantId /
         Audience, because the defaults pointed at a dead tenant and an
         audience that was really a scope -- so prod would have deployed
         cleanly and validated no token. Prod needs its OWN registration.

    IT ALSO COSTS MONEY CONTINUOUSLY, and unlike dev it does not stop when
    nobody is using it. The cost block below prints before anything is created
    and the run stops there unless -IAcceptTheCost is passed. That switch
    exists so that spending is a decision somebody made, not a side effect of
    running a script called "promote".

.PARAMETER WhatIf
    Runs every read-only preflight and `az stack sub validate`, then stops.
    This is the useful default for reviewing a promotion.

.EXAMPLE
    ./Day24/scripts/05-promote-prod.ps1 -WhatIf
    ./Day24/scripts/05-promote-prod.ps1 -IAcceptTheCost
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SubscriptionId   = '85567e22-432e-4648-aa68-ba2714167694',
    [string] $ExpectedTenant   = '8d46a076-d093-416d-a57b-8692cde13bf8',

    [string] $StackName        = 'quotes-prod',

    # READ FROM THE PARAMETER FILE WHEN NOT GIVEN, rather than defaulted here.
    # It was defaulted to 'koreacentral' while main.prod.bicepparam said
    # 'uaenorth', and the preflight then reported both as fine in the same run:
    #
    #   OK  Region koreacentral is available to this subscription
    #   OK  Shared environment cae-… is in UAE North, matching prod's location
    #
    # Two sources of truth for one value, disagreeing, with a green tick on
    # each. --location only sets where the stack RESOURCE is recorded, so the
    # deployment would still have worked -- which is worse, because the drift
    # would have survived unnoticed. One source of truth instead.
    [string] $Location         = '',
    [string] $ResourceGroup    = 'thinkschool-prod-rg',
    [string] $ApiContainerApp  = 'quotes-api-prod',
    [string] $WebContainerApp  = 'quotes-web-prod',

    # Where the tested images live.
    [string] $DevResourceGroup = 'thinkschool-dev-rg',
    [string] $DevRegistry      = 'cr7mo4cimyk4vnk',

    # ONE TAG PER APP, NOT ONE TAG PER RELEASE, and the first run of this
    # script is what proved the difference.
    #
    # The API and the front end are built by SEPARATE workflows with separate
    # path filters, deliberately: an Angular change must not rebuild and
    # redeploy the API. So a commit that touches only Day7/piece2 produces
    # quotes-api:<sha> and NO quotes-web:<sha> -- which means there is no
    # single tag both images share, and a promotion keyed on one commit sha
    # fails on whichever half the release did not touch. It did:
    #
    #   OK    quotes-api:b2ee57546f24 exists in the dev registry
    #   FAIL  quotes-web:b2ee57546f24 is not in the dev registry
    #
    # Empty means "whatever that app is running in dev right now", read off the
    # live container app. That is also the better answer than a sha: the
    # running image is the only artifact that has actually been exercised, and
    # "prod now runs what dev runs" is what promoting dev to prod means.
    [string] $ApiTag           = '',
    [string] $WebTag           = '',

    [switch] $IAcceptTheCost
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$infra    = Join-Path $repoRoot 'Day7\piece2\infra'
$paramFile = Join-Path $infra 'main.prod.bicepparam'

if ([string]::IsNullOrWhiteSpace($Location)) {
    if (-not (Test-Path $paramFile)) { Write-Host "  FAIL  $paramFile not found." -ForegroundColor Red; exit 1 }
    if ((Get-Content $paramFile -Raw) -match "(?m)^param\s+location\s*=\s*'([^']+)'") {
        $Location = $Matches[1]
    } else {
        Write-Host '  FAIL  main.prod.bicepparam does not set `location`, and none was given.' -ForegroundColor Red
        exit 1
    }
}

function Step ([string] $m) { Write-Host ''; Write-Host $m -ForegroundColor Cyan }
function Ok   ([string] $m) { Write-Host "  OK    $m" -ForegroundColor Green }
function Note ([string] $m) { Write-Host "  note  $m" -ForegroundColor Yellow }
function Die  ([string] $m) { Write-Host "  FAIL  $m" -ForegroundColor Red; exit 1 }

# Native stderr is TERMINATING under ErrorActionPreference = 'Stop', even with
# 2>$null, and several az commands write to stderr on success. Lowering the
# preference around each native call is the fix; forgetting it killed
# 01-github-oidc.ps1 immediately after it had created the app registration.
function Invoke-AzText {
    param([Parameter(Mandatory)] [string[]] $AzArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw  = & az @AzArgs 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ Text = (($raw | Out-String).Trim()); ExitCode = $code }
}
function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $AzArgs)
    $r = Invoke-AzText $AzArgs
    # FAILURE AND EMPTINESS ARE DIFFERENT ANSWERS. A helper that returns $null
    # for both makes "the query broke" indistinguishable from "there is nothing
    # there", and Day 26 spent most of a day on a verdict produced that way.
    if ($r.ExitCode -ne 0) { return $null }
    if ([string]::IsNullOrWhiteSpace($r.Text) -or $r.Text -eq '[]') { return @() }
    try { return $r.Text | ConvertFrom-Json } catch { return $null }
}

# Set when step 4's recovery seeds the vault, so step 6 does not rotate it.
$script:secretAlreadySeeded = $false

Write-Host ''
Write-Host 'Day 24 -- promote dev to prod' -ForegroundColor Cyan

# ===========================================================================
Step '1. Preflight (read-only)'
# ===========================================================================
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Die 'az is not on PATH.' }

$null = Invoke-AzText @('account', 'set', '--subscription', $SubscriptionId)
$acct = Invoke-AzJson @('account', 'show', '-o', 'json')
if ($null -eq $acct) { Die 'Could not read the signed-in account. Run az login.' }
if ($acct.tenantId -ne $ExpectedTenant) {
    Die "Signed in to tenant $($acct.tenantId), expected $ExpectedTenant."
}
Ok "Subscription $($acct.name) in tenant $($acct.tenantId)"

# --- The Entra parameters, which are now required ---
$paramText = ''
if (Test-Path $paramFile) { $paramText = (Get-Content $paramFile -Raw) }
if ([string]::IsNullOrWhiteSpace($paramText)) { Die "$paramFile is missing or empty." }

$missingEntra = @()
foreach ($name in @('azureAdTenantId', 'azureAdClientId', 'azureAdAudience')) {
    if ($paramText -notmatch "(?m)^param\s+$name\s*=") { $missingEntra += $name }
}
if ($missingEntra.Count -gt 0) {
    Note "main.prod.bicepparam does not set: $($missingEntra -join ', ')"
    Note 'main.bicep has no defaults for these any more, deliberately: the old'
    Note 'defaults named a dead tenant and an audience that was really a scope,'
    Note 'so prod would have deployed cleanly and authenticated nothing.'
    Note ''
    Note 'Create prod its own registration and write them in:'
    Note '  ./Day25/scripts/02-entra-app-registrations.ps1 -Environment prod'
    Die 'Prod Entra parameters are not set.'
}
Ok 'Prod sets all three Entra parameters'

# Sharing dev's registration is the mistake this checks for. It is not caught
# by anything else: the deployment succeeds and both environments then accept
# each other's tokens.
$devParamText = (Get-Content (Join-Path $infra 'main.dev.bicepparam') -Raw)
if ($devParamText -match "(?m)^param\s+azureAdClientId\s*=\s*'([^']+)'") {
    $devClientId = $Matches[1]
    if ($paramText -match "(?m)^param\s+azureAdClientId\s*=\s*'([^']+)'" -and $Matches[1] -eq $devClientId) {
        Die "Prod is using dev's app registration ($devClientId). A token minted for dev would then be valid against production. Re-run the Entra script with -Environment prod."
    }
}
Ok 'Prod uses its own app registration, not dev''s'

# --- The SQL administrator group has to exist before the server is created ---
if ($paramText -match "(?m)^param\s+sqlEntraAdminObjectId\s*=\s*'([^']+)'") {
    $adminObjectId = $Matches[1]
    $group = Invoke-AzJson @('ad', 'group', 'show', '--group', $adminObjectId, '-o', 'json')
    if ($null -eq $group) {
        Die "sqlEntraAdminObjectId $adminObjectId is not a group in this tenant. The SQL server creation fails on it, after the resource group and registry already exist."
    }
    Ok "SQL admin group: $($group.displayName)"
} else {
    Note 'sqlEntraAdminObjectId is not set in the prod parameters; skipping that check.'
}

# --- The region has to be permitted by policy ---
$loc = Invoke-AzJson @('account', 'list-locations', '--query', "[?name=='$Location']", '-o', 'json')
if ($null -eq $loc -or @($loc).Count -eq 0) {
    Note "$Location is not in this subscription's location list. Day24/scripts/01-region-fit.ps1 is the check that matters here; policy denial appears at deployment, not now."
} else {
    Ok "Region $Location (from main.prod.bicepparam) is available to this subscription"
}

# --- The Container Apps environment quota, which is what actually stopped this ---
#
# THIS CHECK EXISTS BECAUSE EVERY OTHER PREFLIGHT PASSED AND THE DEPLOYMENT
# FAILED ANYWAY. The region checks above answer "does this region exist for
# this subscription" and "is this region permitted by policy". Neither answers
# the question that mattered:
#
#   MaxNumberOfGlobalEnvironmentsInSubExceeded
#   The subscription cannot have more than 1 Container App Environments.
#
# One per SUBSCRIPTION, not one per region -- and main.bicep's own description
# said "per region", which is what led main.prod.bicepparam to ask for a second
# environment in a second region and expect that to work. A quota is not
# avoided by deploying somewhere else.
#
# It costs one list call, it is read-only, and it would have saved a create
# that reached Azure, built a resource group and then rolled back.
$envs = Invoke-AzJson @('containerapp', 'env', 'list', '--query',
                        '[].{name:name, rg:resourceGroup, location:location}', '-o', 'json')
if ($null -eq $envs) {
    Note 'Could not list Container Apps environments; skipping the quota check.'
} else {
    $envList = @($envs)
    foreach ($e in $envList) { Ok "Existing environment: $($e.name) in $($e.rg) ($($e.location))" }

    if ($paramText -match "(?m)^param\s+createContainerAppsEnvironment\s*=\s*true" -and $envList.Count -ge 1) {
        Note 'Prod asks to CREATE an environment and one already exists.'
        Note 'This subscription allows exactly one in total, so the deployment'
        Note 'will fail at preflight with MaxNumberOfGlobalEnvironmentsInSubExceeded'
        Note 'after creating the resource group. Set in main.prod.bicepparam:'
        Note '  param createContainerAppsEnvironment = false'
        Note "  param containerAppsEnvironmentName = '$($envList[0].name)'"
        Note "  param containerAppsEnvironmentResourceGroup = '$($envList[0].rg)'"
        Die 'Prod would ask for a second Container Apps environment.'
    }

    # SHARING AN ENVIRONMENT PINS THE REGION. Container apps run in their
    # environment's region, so prod's data resources must be in that region too
    # or every request becomes a cross-region round trip to its own database.
    if ($paramText -match "(?m)^param\s+containerAppsEnvironmentName\s*=\s*'([^']+)'") {
        $sharedName = $Matches[1]
        $shared = $envList | Where-Object { $_.name -eq $sharedName }
        if ($null -eq $shared) {
            Die "main.prod.bicepparam references environment '$sharedName', which does not exist. Existing: $(($envList | ForEach-Object { $_.name }) -join ', ')."
        }
        $sharedRegion = ($shared.location -replace '\s', '').ToLower()
        $prodRegion = ''
        if ($paramText -match "(?m)^param\s+location\s*=\s*'([^']+)'") { $prodRegion = $Matches[1].ToLower() }
        if ($sharedRegion -ne $prodRegion) {
            Die "Prod's location is '$prodRegion' but the shared environment '$sharedName' is in '$($shared.location)'. Container apps run in their environment's region, so prod's SQL, Service Bus and vault would sit in a different region from its own apps."
        }
        Ok "Shared environment $sharedName is in $($shared.location), matching prod's location"
    }
}

# --- Resolve each app's tag from what dev is running, then verify it ---
function Get-RunningTag {
    param([Parameter(Mandatory)] [string] $DevApp)
    $r = Invoke-AzText @('containerapp', 'show', '-n', $DevApp, '-g', $DevResourceGroup,
                         '--query', 'properties.template.containers[0].image', '-o', 'tsv')
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Text)) { return '' }
    # Matched from the END, because the registry host contains no colon but a
    # port would: cr….azurecr.io/quotes-api:abc123 -> abc123.
    if ($r.Text -match ':([^:/]+)$') { return $Matches[1] }
    return ''
}

# image name, dev app, prod app, and the tag for this promotion.
$promotions = @(
    [pscustomobject]@{ Image = 'quotes-api'; DevApp = 'quotes-api-dev'; ProdApp = $ApiContainerApp; Tag = $ApiTag }
    [pscustomobject]@{ Image = 'quotes-web'; DevApp = 'quotes-web-dev'; ProdApp = $WebContainerApp; Tag = $WebTag }
)

foreach ($p in $promotions) {
    if ([string]::IsNullOrWhiteSpace($p.Tag)) {
        $p.Tag = Get-RunningTag $p.DevApp
        if ([string]::IsNullOrWhiteSpace($p.Tag)) {
            Die "Could not read the image $($p.DevApp) is running, and no tag was given for $($p.Image)."
        }
        Ok "$($p.Image): promoting $($p.Tag), the tag $($p.DevApp) is running"
    } else {
        Ok "$($p.Image): promoting $($p.Tag) (given)"
    }

    # THE GATE, and it is one query. An image only reaches the dev registry if
    # the dev pipeline built it, and that pipeline only builds after the unit
    # and integration tests pass -- so "is this tag in the dev registry" is
    # exactly "was this artefact tested".
    $tags = Invoke-AzJson @('acr', 'repository', 'show-tags', '--name', $DevRegistry,
                            '--repository', $p.Image, '-o', 'json')
    if ($null -eq $tags) { Die "Could not list tags for $($p.Image) in $DevRegistry." }
    if (@($tags) -notcontains $p.Tag) {
        Die "$($p.Image):$($p.Tag) is not in the dev registry, so it was never built or tested."
    }
    Ok "$($p.Image):$($p.Tag) exists in the dev registry"

    # A placeholder in dev is not something to promote. Without this check the
    # hello-world image would be imported into prod and rolled out as if it
    # were the app -- green the whole way.
    if ($p.Tag -eq 'latest') {
        Die "$($p.DevApp) is running a ':latest' tag, which is unversioned and cannot be rolled back to. Refusing to promote it."
    }
}

# ===========================================================================
Step '2. Validate the template against prod'
# ===========================================================================
Push-Location (Join-Path $repoRoot 'Day7\piece2')
try {
    $v = Invoke-AzText @('stack', 'sub', 'validate', '--name', $StackName, '--location', $Location,
                         '--template-file', 'infra/main.bicep', '--parameters', 'infra/main.prod.bicepparam',
                         '--action-on-unmanage', 'deleteAll', '--deny-settings-mode', 'denyDelete',
                         # NO --yes HERE. `stack sub validate` does not accept it -- only
                         # `create` does, where it skips the confirmation prompt. Passing it
                         # fails as "unrecognized arguments: --yes", which reads like the
                         # template is wrong rather than the command line.
                         '-o', 'none')
    if ($v.ExitCode -ne 0) {
        Write-Host $v.Text
        Die 'Validation failed. Nothing was created.'
    }
    Ok 'Template validates against the prod parameters'
} finally { Pop-Location }

# ===========================================================================
Step '3. What this will cost, continuously'
# ===========================================================================
Write-Host @'
  Prod is deliberately NOT dev. These four differences are the ones that bill
  whether or not anybody uses the app:

    apiMinReplicas = 2              two replicas always on; dev is 0
    sqlAutoPauseDelayMinutes = -1   serverless SQL never pauses; dev pauses
                                    after 60 minutes. 2 vCores, continuous
    sqlBackupStorageRedundancy Geo  geo-redundant backup storage; dev is Local
    logDailyQuotaGb = -1            NO ingestion cap. Dev has 1 GB -- and this
                                    project has already blown that cap once
                                    with a log flood, which in prod would have
                                    had no ceiling at all

  Every one of those is correct for a real production environment. All of them
  are continuous spend on a subscription with finite credits. `azd down` or
  `az stack sub delete --name quotes-prod --action-on-unmanage deleteAll`
  removes the lot when you are done -- which is the reason this exercise uses
  deployment stacks in the first place.
'@ -ForegroundColor Yellow

if (-not $IAcceptTheCost) {
    Write-Host ''
    Note 'Stopping here. Everything above is read-only and nothing was created.'
    Note 'Re-run with -IAcceptTheCost to create the prod stack.'
    exit 0
}

if (-not $PSCmdlet.ShouldProcess($StackName, 'create the prod deployment stack')) {
    Note 'WhatIf: would create the stack now; stopping.'
    exit 0
}

# ===========================================================================
Step '4. Create the stack'
# ===========================================================================
Note 'The first create of a fresh environment is EXPECTED to leave the API'
Note 'unhealthy: the vault is created empty, so the jwt-secret reference'
Note 'cannot resolve yet. Steps 6 and 8 are what fix it. This is by design --'
Note 'see the header.'

Push-Location (Join-Path $repoRoot 'Day7\piece2')
try {
    # --deny-settings-excluded-actions is not optional. Without it the stack's
    # own deny assignment blocks the stack's own deletion of the previous
    # SQL firewall rule, and every later update reports `failed` with
    # DenyAssignmentAuthorizationFailed while orphan rules accumulate.
    # THE EXCLUDED ACTIONS GO AS ONE QUOTED, SPACE-SEPARATED STRING.
    #
    # This took two wrong fixes. Passed as two arguments -- whether splatted
    # through a helper or written out with backtick continuation -- only the
    # first bound to the flag and the second became a positional:
    #
    #   ERROR: unrecognized arguments: Microsoft.Sql/servers/firewallRules/delete
    #
    # I blamed the splatting helper, then blamed the call style. Both were
    # guesses. `az stack sub create --help` settles it, in an example rather
    # than in the parameter description:
    #
    #   --deny-settings-excluded-principals "test1 test2"
    #
    # The list is ONE value containing spaces, not several values. Every
    # example in that help passes a single item, which is why the shape is
    # easy to get wrong and stays wrong silently until a second item is added.
    $excludedActions = 'Microsoft.Resources/subscriptions/resourceGroups/delete Microsoft.Sql/servers/firewallRules/delete'

    function Invoke-StackCreate {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & az stack sub create --name $StackName --location $Location `
                --template-file infra/main.bicep --parameters infra/main.prod.bicepparam `
                --action-on-unmanage deleteAll --deny-settings-mode denyDelete `
                --deny-settings-apply-to-child-scopes `
                --deny-settings-excluded-actions $excludedActions `
                --description 'QuotesApi prod - Day 24 promotion' --yes -o none 2>&1
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previous }
        return [pscustomobject]@{ Text = (($out | Out-String).Trim()); ExitCode = $code }
    }

    $create = Invoke-StackCreate

    # THE FIRST FAILURE IS THE EXPECTED ONE, AND THIS SCRIPT USED TO DIE ON IT.
    #
    # The vault is created empty by design, so the API's revision cannot
    # resolve its jwt-secret reference and the deployment fails:
    #
    #   Field 'configuration.secrets' is invalid ... unable to fetch secret
    #   'jwt-secret' using Managed identity '.../id-quotes-api-...'
    #
    # The header of this script documents that failure as expected and then the
    # code called Die on it -- so it never reached step 6, which is the cure.
    # Documenting a deterministic failure and then aborting on it is not
    # handling it. Seed and retry once, here, where the state is known.
    if ($create.ExitCode -ne 0 -and
        ($create.Text -match 'jwt-secret' -or $create.Text -match 'configuration\.secrets')) {

        Note 'Expected first failure: the vault exists but holds no jwt-secret yet.'
        Note 'Seeding it and retrying the create once.'

        # The stack is in a failed state, so `stack sub show --query outputs`
        # has nothing to give. The vault is in the resource group either way.
        $vaultProbe = Invoke-AzText @('keyvault', 'list', '-g', $ResourceGroup, '--query', '[0].name', '-o', 'tsv')
        if ($vaultProbe.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($vaultProbe.Text)) {
            Write-Host $create.Text
            Die "The create failed on the empty vault, but no vault was found in $ResourceGroup to seed."
        }
        $seedVault = $vaultProbe.Text.Trim()
        Ok "Vault to seed: $seedVault"

        & (Join-Path $repoRoot 'Day25\scripts\01-seed-jwt-secret.ps1') `
            -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -VaultName $seedVault
        if ($LASTEXITCODE -ne 0) { Die 'Seeding the signing key failed.' }
        $script:secretAlreadySeeded = $true
        Ok 'Signing key seeded.'

        $create = Invoke-StackCreate
    }

    if ($create.ExitCode -ne 0) {
        Write-Host $create.Text
        Note 'Day25/scripts/show-deploy-error.ps1 walks the nested deployments to find the failed leaf.'
        Note 'For a preflight rejection there is no nested deployment to walk; use:'
        Note '  az deployment operation sub list --name <deployment> --query [?properties.provisioningState==FAILED].properties.statusMessage -o json'
        Note '  (quote the --query value in your shell, and use single quotes around Failed)'
        Die 'Stack create failed.'
    }
} finally { Pop-Location }
Ok 'Stack created.'

# ===========================================================================
Step '5. Read the stack outputs'
# ===========================================================================
# ARM camel-cases the first segment of every output name, so
# AZURE_KEY_VAULT_NAME comes back as azurE_KEY_VAULT_NAME. Not a typo.
function Get-StackOutput {
    param([Parameter(Mandatory)] [string] $Name)
    $r = Invoke-AzText @('stack', 'sub', 'show', '--name', $StackName, '--query', "outputs.$Name.value", '-o', 'tsv')
    if ($r.ExitCode -ne 0) { return '' }
    return $r.Text
}

$prodRegistry = Get-StackOutput 'azurE_CONTAINER_REGISTRY_NAME'
$prodRegistryHost = Get-StackOutput 'azurE_CONTAINER_REGISTRY_ENDPOINT'
$vaultName    = Get-StackOutput 'azurE_KEY_VAULT_NAME'
$sqlFqdn      = Get-StackOutput 'azurE_SQL_SERVER_FQDN'
$identityName = Get-StackOutput 'servicE_QUOTES_API_IDENTITY_NAME'
$databaseName = Get-StackOutput 'azurE_SQL_DATABASE_NAME'
if ([string]::IsNullOrWhiteSpace($databaseName)) { $databaseName = 'quotes' }

foreach ($pair in @(@('registry', $prodRegistry), @('vault', $vaultName), @('sql', $sqlFqdn))) {
    if ([string]::IsNullOrWhiteSpace($pair[1])) {
        Note "Stack output for $($pair[0]) came back empty. Check: az stack sub show --name $StackName --query outputs"
    } else {
        Ok "$($pair[0]): $($pair[1])"
    }
}

# ===========================================================================
Step '6. Seed the JWT signing key into prod''s vault'
# ===========================================================================
# A SEPARATE KEY FROM DEV, and this is not tidiness. One signing key across
# both environments means a token issued by dev is accepted by production.
#
# SKIPPED IF STEP 4 ALREADY SEEDED IT. Re-running the seed script is a
# ROTATION, not an idempotent write: it generates a new key and every token
# signed with the old one stops validating. Running it twice in one promotion
# would invalidate the key the deployment just succeeded with.
if ($script:secretAlreadySeeded) {
    Ok 'Already seeded during step 4; not re-running (a re-run rotates the key).'
} elseif ([string]::IsNullOrWhiteSpace($vaultName)) {
    Note 'No vault name; skipping. Run Day25/scripts/01-seed-jwt-secret.ps1 by hand.'
} else {
    & (Join-Path $repoRoot 'Day25\scripts\01-seed-jwt-secret.ps1') `
        -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -VaultName $vaultName
    Ok 'Signing key seeded (its value was never printed and is not in this repo).'
}

# ===========================================================================
Step '7. Import the tested images into prod''s registry'
# ===========================================================================
if ([string]::IsNullOrWhiteSpace($prodRegistry)) {
    Die 'No prod registry name; cannot import. Read it from the stack outputs and re-run with the import step by hand.'
}
foreach ($p in $promotions) {
    # Server-side copy: no pull, no push, digest preserved. Cross-region is
    # fine, which matters because prod is in a different region from dev.
    $i = Invoke-AzText @('acr', 'import', '--name', $prodRegistry,
                         '--source', "$DevRegistry.azurecr.io/$($p.Image):$($p.Tag)",
                         '--image', "$($p.Image):$($p.Tag)", '--force')
    if ($i.ExitCode -ne 0) { Write-Host $i.Text; Die "Importing $($p.Image):$($p.Tag) failed." }
    Ok "Imported $($p.Image):$($p.Tag)"
}

# ===========================================================================
Step '8. Create the contained SQL user ARM cannot create'
# ===========================================================================
if ([string]::IsNullOrWhiteSpace($sqlFqdn) -or [string]::IsNullOrWhiteSpace($identityName)) {
    Note 'Missing SQL FQDN or identity name; run Day7/piece2/scripts/create-sql-user.ps1 by hand.'
} else {
    & (Join-Path $repoRoot 'Day7\piece2\scripts\create-sql-user.ps1') `
        -SqlServerFqdn $sqlFqdn -DatabaseName $databaseName -IdentityName $identityName
    Ok 'Contained user created for the managed identity.'
}

# ===========================================================================
Step '9. Roll both apps onto the imported images'
# ===========================================================================
foreach ($p in $promotions) {
    $u = Invoke-AzText @('containerapp', 'update', '-n', $p.ProdApp, '-g', $ResourceGroup,
                         '--image', "$prodRegistryHost/$($p.Image):$($p.Tag)", '-o', 'none')
    if ($u.ExitCode -ne 0) { Write-Host $u.Text; Die "Rolling $($p.ProdApp) failed." }
    Ok "$($p.ProdApp) -> $($p.Image):$($p.Tag)"
}

# ===========================================================================
Step '10. Verify'
# ===========================================================================
$fqdn = (Invoke-AzText @('containerapp', 'show', '-n', $ApiContainerApp, '-g', $ResourceGroup,
                         '--query', 'properties.configuration.ingress.fqdn', '-o', 'tsv')).Text
if (-not [string]::IsNullOrWhiteSpace($fqdn)) {
    # /health exercises the database check, so one 200 proves both that the
    # vault reference resolved (JwtOptions has ValidateOnStart and MinLength,
    # so a missing key is a startup failure) and that EF Core authenticated to
    # an Entra-only server over the managed identity.
    $code = (Invoke-AzText @('rest', '--method', 'get', '--url', "https://$fqdn/health", '--skip-authorization-header')).ExitCode
    if ($code -eq 0) { Ok "https://$fqdn/health answered" } else { Note "health did not answer yet; give the revision a minute and retry" }
}

Note 'Now prove prod holds no secrets, the same way dev did:'
Note "  ./Day25/scripts/00-prove-no-secrets.ps1 -ResourceGroup $ResourceGroup -ApiContainerApp $ApiContainerApp -WebContainerApp $WebContainerApp -KeyVaultName $vaultName"

# ===========================================================================
Step 'Remaining, and none of it is optional'
# ===========================================================================
Write-Host @"
  1. Flip the exists flags in main.prod.bicepparam:
       param quotesApiExists = true
       param webAppExists    = true
     Until they are true, the NEXT prod deploy resolves the image to the
     hello-world placeholder and reverts everything step 9 just did.

  2. Grant the pipeline access to what now exists:
       ./Day26/scripts/01-github-oidc.ps1 -ProdRegistry $prodRegistry
     Trust was registered earlier; this is the access half.

  3. Set the repository variables prod-deploy.yml reads:
       AZURE_PROD_CONTAINER_REGISTRY_ENDPOINT  $prodRegistryHost
       AZURE_PROD_RESOURCE_GROUP               $ResourceGroup

  4. Create the GitHub Environment named 'production' with a required
     reviewer, and the 'production' branch. Advance it by FAST-FORWARD only:
       git checkout production && git merge --ff-only main && git push
     A merge commit there has a sha no image carries, and prod-deploy.yml
     refuses it on purpose.

  5. When you are finished with prod, tear it down -- it bills continuously:
       az stack sub delete --name $StackName --action-on-unmanage deleteAll --yes
"@ -ForegroundColor Cyan
Write-Host ''
