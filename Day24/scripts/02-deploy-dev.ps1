<#
.SYNOPSIS
    Day 24. Deploys the whole dev environment -- resource group, database,
    Service Bus, registry, identity, the API and the Angular front end -- into
    subscription 85567e22-432e-4648-aa68-ba2714167694 as a deployment stack.

.DESCRIPTION
    One script instead of fifteen commands, because two of those commands cannot
    be reordered without producing an app that starts and then fails its
    readiness probe forever, and the ordering is not obvious from the commands
    themselves.

    WHAT IT WILL NOT DO. It stops before anything destructive or anything that
    spends real money without you seeing it first:
      * it pauses after the what-if so you read the plan before it deploys;
      * it never touches the old subscription;
      * it does not create prod (that is Phase H, and prod is torn down after
        verification -- see the plan);
      * it does not delete anything.

    RESUMABLE. Every step is idempotent. If it fails at step 6 you fix the cause
    and run the whole thing again; steps 1-5 will re-run harmlessly. That is a
    property of the stack, not of this script.

.PARAMETER PlanOnly
    Run steps 1-3 (compile, validate, what-if) and stop. Nothing is created.
    Use this first.

.PARAMETER SkipFrontEnd
    Skip the Angular build. The API deploys without the SPA, so GET / will 404
    while /api/* works. Useful when iterating on infrastructure alone.

.EXAMPLE
    ./Day24/scripts/02-deploy-dev.ps1 -PlanOnly
    ./Day24/scripts/02-deploy-dev.ps1
#>

[CmdletBinding()]
param(
    [switch] $PlanOnly,
    [switch] $SkipFrontEnd,

    [string] $SubscriptionId  = '85567e22-432e-4648-aa68-ba2714167694',
    [string] $StackName       = 'quotes-dev',
    [string] $Location        = 'uaenorth',
    [string] $ResourceGroup   = 'thinkschool-dev-rg',
    [string] $ContainerApp    = 'quotes-api-dev',
    [string] $AzdEnvName      = 'thinkschool-dev',
    [string] $SqlAdminObjectId = 'a59d00a8-a829-49b4-83d1-952727eea166',
    [string] $SqlAdminLogin    = 'vaishalee.singh@s.amity.edu'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Anchored to this script's own location so it does not matter where you run it
# from. Day 24 lost time to `dotnet test Day7/piece2/...` executed from inside
# Day7/piece2, which resolves to a project that does not exist.
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$apiRoot  = Join-Path $repoRoot 'Day7\piece2'
$webRoot  = Join-Path $repoRoot 'Day13\quotes-web'
$verify   = Join-Path $repoRoot 'Day24\verification'
New-Item -ItemType Directory -Force -Path $verify | Out-Null

$step = 0
function Step([string] $Title) {
    $script:step++
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkGray
    Write-Host ("{0}. {1}" -f $script:step, $Title) -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkGray
}
function Ok  ([string] $m) { Write-Host "  OK    $m" -ForegroundColor Green }
function Note([string] $m) { Write-Host "  note  $m" -ForegroundColor Yellow }
function Die ([string] $m) { Write-Host "  FAIL  $m" -ForegroundColor Red; exit 1 }

function Invoke-Checked([string] $What, [scriptblock] $Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { Die "$What (exit $LASTEXITCODE)" }
}

# ---------------------------------------------------------------------------
Step 'Preconditions'
# ---------------------------------------------------------------------------

# DAY 25 REMOVED THE SIGNING KEY FROM THIS SCRIPT.
#
# This block used to generate a JWT_SECRET and pass it into the deployment,
# because modules/api.bicep took the key as a @secure() parameter. It no
# longer does: the key lives in Key Vault, the container app holds a Key Vault
# REFERENCE, and the value is written straight to the vault by
# Day25/scripts/01-seed-jwt-secret.ps1.
#
# Deleting this is not tidying. Left in place it would keep writing the secret
# into the azd environment file on this machine, which is one of the four
# copies Day 25 exists to get rid of -- and it generated the key with
# Get-Random, a seeded pseudo-random source with no business producing a
# signing key.
#
# Nothing needs to be exported before running this script any more.

foreach ($tool in @('az', 'azd', 'dotnet')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Die "$tool is not on PATH." }
}
if (-not $SkipFrontEnd -and -not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Die 'npm is not on PATH. Re-run with -SkipFrontEnd to deploy the API alone.'
}
Ok 'az, azd, dotnet present.'

az account set --subscription $SubscriptionId
$acct = az account show -o json | ConvertFrom-Json
if ($acct.id -ne $SubscriptionId) { Die "Active subscription is $($acct.id)." }
Ok "$($acct.name)  tenant $($acct.tenantId)"

# The stacks alpha feature. Without it azd IGNORES the deploymentStacks block in
# azure.yaml and deploys the old way, silently -- so a run that looks successful
# produces no stack, and the drift and teardown proofs in Phase G have nothing
# to measure.
$azdCfg = (azd config show 2>$null | Out-String)
if ($azdCfg -notmatch 'stacks') {
    Note 'Enabling alpha.deployment.stacks (azd ignores azure.yaml stack config without it).'
    azd config set alpha.deployment.stacks on | Out-Null
}
Ok 'azd deployment-stacks feature enabled.'

Push-Location $apiRoot

try {
    # -----------------------------------------------------------------------
    Step 'Compile the templates (silence is a pass)'
    # -----------------------------------------------------------------------
    Invoke-Checked 'bicep build'        { az bicep build --file infra/main.bicep --stdout | Out-Null }
    Invoke-Checked 'bicep lint'         { az bicep lint  --file infra/main.bicep }
    Invoke-Checked 'dev params compile' { az bicep build-params --file infra/main.dev.bicepparam  --stdout | Out-Null }
    Invoke-Checked 'prod params compile'{ az bicep build-params --file infra/main.prod.bicepparam --stdout | Out-Null }
    Ok 'Template and both parameter files compile.'

    # -----------------------------------------------------------------------
    Step 'Validate the stack (stricter than what-if; surfaces policy denials)'
    # -----------------------------------------------------------------------
    Invoke-Checked 'stack validate' {
        az stack sub validate --name $StackName --location $Location `
            --template-file infra/main.bicep --parameters infra/main.dev.bicepparam `
            --action-on-unmanage deleteAll --deny-settings-mode denyDelete `
            --only-show-errors -o none
    }
    Ok 'Stack validates.'

    # -----------------------------------------------------------------------
    Step 'What-if'
    # -----------------------------------------------------------------------
    $whatIfPath = Join-Path $verify 'what-if-dev.txt'
    az deployment sub what-if --location $Location `
        --template-file infra/main.bicep --parameters infra/main.dev.bicepparam `
        | Tee-Object -FilePath $whatIfPath
    Ok "Saved to $whatIfPath"

    Write-Host ''
    Write-Host '  Read three things in the diff above, not the whole thing:' -ForegroundColor Yellow
    Write-Host '    1. NO "- Delete" lines. This is a new subscription, so everything is "+ Create".'
    Write-Host '    2. The container app image IS the hello-world placeholder. Correct on a first'
    Write-Host '       deployment; on every later run it must show the running image UNCHANGED.'
    Write-Host '    3. Three "Unsupported" diagnostics on the Service Bus and AcrPull role'
    Write-Host '       assignments are EXPECTED, not errors -- what-if cannot evaluate an extension'
    Write-Host '       resource whose ID comes from a reference() resolved at deploy time.'

    if ($PlanOnly) {
        Write-Host ''
        Ok 'PlanOnly: stopping before anything is created.'
        exit 0
    }

    Write-Host ''
    $answer = Read-Host '  Deploy this? (type yes)'
    if ($answer -ne 'yes') { Die 'Cancelled. Nothing was created.' }

    # -----------------------------------------------------------------------
    Step 'Create the deployment stack (infrastructure only)'
    # -----------------------------------------------------------------------
    # The container app comes up on the placeholder image, and that is
    # deliberate: the app is not running the real code yet, so it cannot fail
    # against a database it has no login for -- which is the failure step 7
    # exists to prevent.
    #
    # SQL_CLIENT_IP is read by main.dev.bicepparam and adds ONE firewall rule
    # for this machine. The server's only other rule admits Azure services --
    # the container app and nobody else -- and step 7 connects as a person.
    # The IP is never written into the parameter file: it is personal data in a
    # committed file, and it changes between sessions.
    $env:SQL_CLIENT_IP = (Invoke-RestMethod https://api.ipify.org).Trim()
    Ok "This machine will be allowed through the SQL firewall."

    # ONE QUOTED STRING, NOT TWO ARGUMENTS. az takes this list as a single
    # space-separated value -- see the `--deny-settings-excluded-principals
    # "test1 test2"` example in `az stack sub create --help`. Written as two
    # arguments, only the first binds and the second is rejected as a
    # positional: "unrecognized arguments: Microsoft.Sql/servers/...". This
    # call had that shape and had never been exercised with a SECOND action,
    # which is why it looked fine; the prod promotion hit it immediately.
    # --deny-settings-excluded-actions is the CLI half of the excludedActions
    # list in azure.yaml, and it is NOT optional. Without it the stack's own
    # deny assignment blocks the stack's own deletion of the previous
    # SQL_CLIENT_IP firewall rule, and every later update reports `failed` with
    # DenyAssignmentAuthorizationFailed while an orphan rule accumulates. See
    # the long comment in azure.yaml.
    Invoke-Checked 'stack create' {
        az stack sub create --name $StackName --location $Location `
            --template-file infra/main.bicep --parameters infra/main.dev.bicepparam `
            --action-on-unmanage deleteAll --deny-settings-mode denyDelete `
            --deny-settings-apply-to-child-scopes `
            --deny-settings-excluded-actions `
                'Microsoft.Resources/subscriptions/resourceGroups/delete Microsoft.Sql/servers/firewallRules/delete' `
            --description 'QuotesApi dev - Day 24' --yes -o none
    }
    Ok 'Stack created.'

    # -----------------------------------------------------------------------
    Step 'Read the stack outputs'
    # -----------------------------------------------------------------------
    # THE CASING BELOW IS NOT A TYPO. ARM camel-cases the first segment of every
    # output name, so AZURE_SQL_SERVER_FQDN comes back as azurE_SQL_SERVER_FQDN.
    # JMESPath is case-sensitive, so querying the name as written in main.bicep
    # returns null and whatever consumes it silently receives an empty string.
    function Get-StackOutput([string] $Name) {
        $v = az stack sub show --name $StackName --query "outputs.$Name.value" -o tsv 2>$null
        if ([string]::IsNullOrWhiteSpace($v)) { Die "Stack output '$Name' is empty. Check the camel-casing note in this script." }
        return $v.Trim()
    }
    $sqlFqdn      = Get-StackOutput 'azurE_SQL_SERVER_FQDN'
    $sqlDatabase  = Get-StackOutput 'azurE_SQL_DATABASE_NAME'
    $identityName = Get-StackOutput 'servicE_QUOTES_API_IDENTITY_NAME'
    $acrEndpoint  = Get-StackOutput 'azurE_CONTAINER_REGISTRY_ENDPOINT'
    $sbFqdn       = Get-StackOutput 'azurE_SERVICE_BUS_FQDN'

    Ok "SQL         $sqlFqdn / $sqlDatabase"
    Ok "identity    $identityName"
    Ok "registry    $acrEndpoint"
    Ok "service bus $sbFqdn"

    # -----------------------------------------------------------------------
    Step 'Create the contained database user -- THIS CANNOT MOVE LATER'
    # -----------------------------------------------------------------------
    # sql.bicep provisions an Entra-ONLY server. That gets the managed identity
    # to the SERVER and gives it no user INSIDE the database, which is T-SQL and
    # outside ARM's reach. Deploy the real image before this and the app starts,
    # tries to reach SQL, gets
    #   Login failed for user '<token-identified principal>'
    # and fails /health/ready forever -- an app that is up and permanently
    # unready, with nothing in the deployment logs to explain it.
    #
    # Runs as the signed-in account, which must be the one named in
    # sqlEntraAdminLogin. Anyone else gets a permission error, and that is the
    # Entra-only design working rather than a fault.
    if ($acct.user.name -ne $SqlAdminLogin) {
        Note "Signed in as $($acct.user.name) but the SQL admin is $SqlAdminLogin."
        Note 'This step will fail with a permission error unless they match.'
    }
    Invoke-Checked 'create-sql-user.ps1' {
        & (Join-Path $apiRoot 'scripts\create-sql-user.ps1') `
            -SqlServerFqdn $sqlFqdn -DatabaseName $sqlDatabase -IdentityName $identityName
    }
    Ok 'Managed identity has a database user.'

    # -----------------------------------------------------------------------
    Step 'Build the Angular front end into the API project'
    # -----------------------------------------------------------------------
    # Day 24: there is no Static Web App. Microsoft.Web/staticSites is not
    # offered in ANY region this subscription's policy permits, so the SPA is
    # served by the Container App -- which is what
    # environment.production.ts already assumed (apiBaseUrl = '', same-origin).
    $spaDir = Join-Path $apiRoot 'QuotesApi\spa'
    if ($SkipFrontEnd) {
        Note 'Skipped. GET / will 404 while /api/* works, and the smoke test below expects that.'
    } else {
        Push-Location $webRoot
        try {
            Invoke-Checked 'npm ci'   { npm ci }
            Invoke-Checked 'ng build' { npx ng build }
        } finally { Pop-Location }

        $dist = Join-Path $webRoot 'dist\quotes-web\browser'
        if (-not (Test-Path (Join-Path $dist 'index.html'))) {
            Die "$dist\index.html missing -- the ng build output location moved. Update this script AND day17-api-deploy.yml together."
        }
        # Program.cs skips its whole SPA block SILENTLY when spa/ is absent, so
        # a copy that lands in the wrong place presents as 404 on every non-API
        # route with nothing logged. Hence the assertion rather than trust.
        Remove-Item -Recurse -Force $spaDir -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $spaDir | Out-Null
        Copy-Item -Recurse -Force (Join-Path $dist '*') $spaDir
        if (-not (Test-Path (Join-Path $spaDir 'index.html'))) { Die "index.html did not reach $spaDir" }
        Ok "Staged $((Get-ChildItem -Recurse -File $spaDir).Count) files into QuotesApi\spa"
    }

    # -----------------------------------------------------------------------
    Step 'Build and push the image with azd'
    # -----------------------------------------------------------------------
    $envList = (azd env list -o json 2>$null | ConvertFrom-Json)
    if (-not ($envList | Where-Object { $_.Name -eq $AzdEnvName })) {
        azd env new $AzdEnvName --no-prompt | Out-Null
    }
    azd env select $AzdEnvName | Out-Null

    # azd reads main.parameters.json, never the .bicepparam files. Each of these
    # resolves a ${TOKEN} in it; three of them exist because the template's own
    # DEFAULTS name resources in the dead subscription, so an azd deploy without
    # them would build a different -- and broken -- environment than the one the
    # stack above just built.
    azd env set AZURE_SUBSCRIPTION_ID       $SubscriptionId    | Out-Null
    azd env set AZURE_LOCATION              $Location          | Out-Null
    azd env set AZURE_RESOURCE_GROUP_NAME   $ResourceGroup     | Out-Null
    azd env set AZURE_API_CONTAINER_APP_NAME $ContainerApp     | Out-Null
    azd env set AZURE_CREATE_CAE            true               | Out-Null
    azd env set AZURE_PRINCIPAL_ID          $SqlAdminObjectId  | Out-Null
    azd env set SQL_ENTRA_ADMIN_LOGIN       $SqlAdminLogin     | Out-Null
    # JWT_SECRET deliberately NOT set here any more -- see the Day 25 note above.

    # ---- The outputs azd would normally have written itself ----------------
    #
    # THIS BLOCK EXISTS BECAUSE THE FIRST RUN FAILED HERE, and the error named
    # the symptom rather than the cause:
    #
    #   ERROR: publishing service quotes-api: logging in to registry: could not
    #   determine container registry endpoint, ensure 'registry' has been set in
    #   the docker options or 'AZURE_CONTAINER_REGISTRY_ENDPOINT' environment
    #   variable has been set
    #
    # It reads like a missing setting in azure.yaml. It is not. azd learns the
    # registry endpoint from the OUTPUTS of a deployment IT performed, which it
    # writes into .azure/<env>/.env. Here the stack was created by
    # `az stack sub create`, deliberately -- so azd never ran a provision, never
    # saw an output, and had no idea a registry exists. Everything it needs is
    # sitting in the stack; it just has to be handed over.
    #
    # This is the seam between the two tools, and it only exists because the
    # CLI owns the stack. Had azd owned it (`azd up`), these would be populated
    # automatically -- and there would instead be a second stack fighting the
    # first. This is the cheaper of the two problems.
    azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT $acrEndpoint | Out-Null
    azd env set AZURE_CONTAINER_REGISTRY_NAME     ($acrEndpoint.Split('.')[0]) | Out-Null

    # azd's own convention is AZURE_RESOURCE_GROUP; AZURE_RESOURCE_GROUP_NAME
    # above is this template's parameter token. Both are needed and they are not
    # the same variable, which is easy to stare past.
    azd env set AZURE_RESOURCE_GROUP $ResourceGroup | Out-Null

    # The container app now EXISTS. main.bicep threads this into
    # modules/fetch-container-image.bicep, which is what stops a later
    # infrastructure-only deployment from reverting the running image to the
    # hello-world placeholder. Leaving it false after the app is real is how the
    # idempotency check at the end starts reporting a spurious image change.
    azd env set SERVICE_QUOTES_API_RESOURCE_EXISTS true | Out-Null

    # ---- Push the image directly FIRST, then let azd do its pass -----------
    #
    # WHY BOTH, AND WHY THIS ORDER. `azd deploy` has a hard 1200-second timeout
    # that is not configurable, and on a domestic uplink the FIRST push to a new
    # registry does not fit inside it: the whole .NET base image goes up, not
    # just the app layer. The observed failure was
    #
    #   ERROR: publishing service 'quotes-api' timed out after 1200 seconds
    #
    # after 21m26s, with no error from the build itself -- azd gives no progress
    # output, so a slow push and a hung build look identical from outside.
    #
    # `dotnet publish /t:PublishContainer` does the same work with visible
    # per-layer progress and no cap. It needs no Docker daemon: the .NET SDK
    # pushes straight to the registry using the token `az acr login` wrote into
    # the Docker config. The ACR admin account is not involved.
    #
    # Once those layers exist in the registry, a subsequent `azd deploy` only
    # uploads the changed app layer and finishes well inside the timeout -- so
    # azd remains the deployment mechanism this exercise is about rather than
    # being replaced by a workaround. It runs second, and a failure there is a
    # warning rather than fatal: the image is already pushed and step 10 rolls
    # the app onto it either way.
    # NO DOCKER ANYWHERE IN THIS STEP, and that is a correction rather than a
    # preference. The first attempt used `az acr login`, which drives the Docker
    # CLI, and on a machine without Docker Desktop running it fails with
    #
    #   failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine
    #
    # and then the SDK's own push fails a second time for the same underlying
    # reason, wearing a completely different message:
    #
    #   error CONTAINER1013: Failed to push to the output registry:
    #   CONTAINER1008: Failed retrieving credentials for "<acr>.azurecr.io":
    #   Failed to execute 'docker-credential-desktop.EXE get':
    #   credentials not found in native keychain
    #
    # Neither message says "Docker is not running", and the second actively
    # misleads -- it reads like a registry permissions problem. This is also the
    # most likely explanation for `azd deploy` sitting at 21 minutes and then
    # timing out with no error: it was waiting on the same absent daemon.
    #
    # The SDK does not need a daemon to build or push an image. It reads
    # SDK_CONTAINER_REGISTRY_UNAME / _PWORD directly, and `az acr login
    # --expose-token` returns an ACR refresh token without touching Docker. The
    # username for token auth is the null GUID -- that is ACR's convention, not
    # a placeholder left in by mistake.
    $imageTag = "dev-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $acrName  = $acrEndpoint.Split('.')[0]

    $tokenJson = az acr login --name $acrName --expose-token -o json 2>$null | ConvertFrom-Json
    if (-not $tokenJson.accessToken) { Die "Could not get an ACR token for $acrName." }
    $env:SDK_CONTAINER_REGISTRY_UNAME = '00000000-0000-0000-0000-000000000000'
    $env:SDK_CONTAINER_REGISTRY_PWORD = $tokenJson.accessToken
    Ok 'Got an ACR refresh token (no Docker involved).'

    try {
        Invoke-Checked 'dotnet publish container' {
            dotnet publish QuotesApi/QuotesApi.csproj -c Release /t:PublishContainer `
                -p:ContainerRegistry=$acrEndpoint `
                -p:ContainerRepository=quotes-api `
                -p:ContainerImageTag=$imageTag
        }
    } finally {
        # The token is short-lived, but leaving a registry credential in the
        # session's environment for the rest of the day is still worse than not.
        Remove-Item Env:SDK_CONTAINER_REGISTRY_UNAME -ErrorAction SilentlyContinue
        Remove-Item Env:SDK_CONTAINER_REGISTRY_PWORD -ErrorAction SilentlyContinue
    }
    Ok "Pushed $acrEndpoint/quotes-api:$imageTag"

    azd deploy --no-prompt
    if ($LASTEXITCODE -ne 0) {
        Note 'azd deploy did not succeed, but the image above is already in the registry.'
        Note 'Step 10 will roll the app onto it. Re-run azd deploy later if you want its'
        Note 'own pass to go green -- the layers are cached now, so it will be much faster.'
    } else {
        Ok 'azd deploy succeeded.'
    }

    # -----------------------------------------------------------------------
    Step 'The known packaging correction'
    # -----------------------------------------------------------------------
    # QuotesApi.csproj pins ContainerRepository to `quotes-api` while azd
    # computes a different path, so the container app can end up referencing an
    # image tag that is not the one just pushed. Carried since Day 23 as a
    # packaging bug, not an infrastructure one.
    #
    # This is exactly why denySettings.mode is denyDelete and not
    # denyWriteAndDelete: the stricter mode would refuse this write and the
    # deployment could never be corrected.
    # Prefer the tag this run pushed. Falling back to "newest in the registry"
    # is a guess, and it is the wrong guess if azd pushed under a different
    # repository path -- which is the packaging bug described above.
    $tag = $imageTag
    if (-not $tag) {
        $tag = az acr repository show-tags --name ($acrEndpoint.Split('.')[0]) `
            --repository quotes-api --orderby time_desc --top 1 -o tsv 2>$null
    }
    if ($tag) {
        Invoke-Checked 'containerapp update' {
            az containerapp update --name $ContainerApp --resource-group $ResourceGroup `
                --image "$acrEndpoint/quotes-api:$tag" -o none
        }
        Ok "Container app pinned to quotes-api:$tag"
    } else {
        Note 'No quotes-api tag found in the registry; azd may have pushed under a different repository. Check `az acr repository list` before assuming the deploy failed.'
    }

    # -----------------------------------------------------------------------
    Step 'Wait for the revision to run'
    # -----------------------------------------------------------------------
    # A green deploy only means Azure accepted the request. An unreachable
    # target port, a failed image pull and an unwritable database path all
    # report success and then sit in Activating forever. All three have
    # happened on this project.
    $ready = $false
    foreach ($attempt in 1..30) {
        $state = az containerapp revision list --name $ContainerApp --resource-group $ResourceGroup `
            --query "[?properties.active].properties.runningState | [0]" -o tsv 2>$null
        Write-Host "  attempt $attempt : runningState=$state"
        if ($state -eq 'Running')  { $ready = $true; break }
        if ($state -in 'Failed','Degraded') {
            az containerapp logs show --name $ContainerApp --resource-group $ResourceGroup --type system --tail 50
            Die "The revision reported $state."
        }
        Start-Sleep -Seconds 10
    }
    if (-not $ready) {
        az containerapp logs show --name $ContainerApp --resource-group $ResourceGroup --type system --tail 50
        Die 'The revision did not reach Running within five minutes.'
    }
    Ok 'Revision running.'

    # -----------------------------------------------------------------------
    Step 'Smoke tests'
    # -----------------------------------------------------------------------
    $fqdn   = az containerapp show --name $ContainerApp --resource-group $ResourceGroup `
                --query "properties.configuration.ingress.fqdn" -o tsv
    $origin = "https://$fqdn"
    Write-Host "  $origin"

    # 1. Readiness. This is what fails if step 7 was skipped or ran out of order:
    # the app is up and permanently unready because it has no database login.
    $readyOk = $false
    foreach ($attempt in 1..12) {
        try {
            $r = Invoke-WebRequest "$origin/health/ready" -TimeoutSec 15 -SkipHttpErrorCheck
            Write-Host "  ready attempt $attempt : $($r.StatusCode)"
            if ($r.StatusCode -eq 200) { $readyOk = $true; break }
        } catch { Write-Host "  ready attempt $attempt : $($_.Exception.Message)" }
        Start-Sleep -Seconds 10
    }
    if (-not $readyOk) { Die '/health/ready never returned 200. If step 7 was skipped, the app has no database login -- check the logs for "Login failed for user".' }
    Ok '/health/ready 200'

    # 2. The API, probed with an anonymous side-effect-free call whose 400 body
    # is unmistakably this API's own: AuthEndpointExtensions names "credentials".
    # An HTML response here means the MapFallbackToFile regex in Program.cs is
    # NOT excluding api/, so API 404s are being served as the SPA shell with a
    # 200 -- the exact hazard staticwebapp.config.json used to guard.
    $login = Invoke-WebRequest "$origin/api/auth/login" -Method Post -TimeoutSec 15 `
        -ContentType 'application/json' -Body '{"email":"","password":""}' -SkipHttpErrorCheck
    if ($login.Content -match '(?i)<!doctype') {
        Die 'POST /api/auth/login returned the SPA shell. The fallback regex is not excluding api/.'
    }
    if ($login.Content -notmatch 'credentials') {
        Die "POST /api/auth/login did not return this API's validation problem. Got: $($login.Content.Substring(0, [Math]::Min(200, $login.Content.Length)))"
    }
    Ok 'API answers with its own validation problem.'

    # 3. The SPA, and a deep link. Checked for Angular's own marker rather than
    # a 200: / returns 200 whether it serves index.html or a stray file. The
    # deep link is the whole reason the fallback exists -- /quotes is a client
    # route the server has no knowledge of.
    if (-not $SkipFrontEnd) {
        $root = Invoke-WebRequest "$origin/" -TimeoutSec 15 -SkipHttpErrorCheck
        if ($root.Content -notmatch '<app-root') {
            Die 'GET / did not return the Angular shell. Program.cs skips the SPA block silently when spa/ is absent -- check that it reached the image.'
        }
        Ok 'GET / serves the Angular shell.'

        $deep = Invoke-WebRequest "$origin/quotes" -TimeoutSec 15 -SkipHttpErrorCheck
        if ($deep.StatusCode -ne 200) { Die "GET /quotes returned $($deep.StatusCode). Every deep link and page refresh will 404." }
        Ok 'Deep-link fallback works.'
    }

    # -----------------------------------------------------------------------
    Step 'Idempotency, and proof the image is not reverted'
    # -----------------------------------------------------------------------
    # Two claims land on one command. The template must not drift against
    # resources it just created -- a template that does is the condition under
    # which somebody eventually fixes things in the portal instead. And this run
    # passes no image name, so a naive template would show the running image
    # being replaced by the hello-world placeholder;
    # modules/fetch-container-image.bicep is what prevents that.
    $second = Join-Path $verify 'idempotency-second-what-if.txt'
    az deployment sub what-if --location $Location `
        --template-file infra/main.bicep --parameters infra/main.dev.bicepparam `
        | Tee-Object -FilePath $second | Out-Null
    Ok "Saved to $second"
    Note 'Read it: it must report NO changes, and must NOT show the image reverting to aci-helloworld.'

    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor Green
    Write-Host 'DEV IS DEPLOYED' -ForegroundColor Green
    Write-Host ('=' * 74) -ForegroundColor Green
    Write-Host "  app          $origin"
    Write-Host "  resource grp $ResourceGroup  ($Location)"
    Write-Host "  database     $sqlFqdn / $sqlDatabase"
    Write-Host "  service bus  $sbFqdn"
    Write-Host "  registry     $acrEndpoint"
    Write-Host "  stack        $StackName"
    Write-Host ''
    Write-Host '  Still to do, in order:'
    Write-Host '    1. Migrate the data (SqlPackage export/import), and ROW-COUNT BOTH SIDES.'
    Write-Host '       An import that produced an empty schema looks exactly like a good one.'
    Write-Host '    2. Repository variables for the workflows:'
    Write-Host "         AZURE_RESOURCE_GROUP              = $ResourceGroup"
    Write-Host "         AZURE_CONTAINER_APP               = $ContainerApp"
    Write-Host "         AZURE_CONTAINER_REGISTRY_ENDPOINT = $acrEndpoint"
    Write-Host '    3. GitHub OIDC app registration + the two role assignments (plan, Phase D).'
    Write-Host '    4. Phase G: the drift proof and the deny-settings proof.'
    Write-Host '    5. Merge to main -- that is what makes the workflows deploy.'
    Write-Host ''
}
finally {
    Pop-Location
}
