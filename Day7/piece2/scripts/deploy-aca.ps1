<#
.SYNOPSIS
    SUPERSEDED BY infra/ AS OF DAY 23. Kept as the Day 5 record; not a
    deployment route. Do not run it.

    Automated Azure Container Apps (ACA) Provisioning Script for QuotesApi.
.DESCRIPTION
    Creates the Resource Group, Container Apps Environment, and Container App revision
    with external ingress, target port 8080, health probes, and HTTP autoscaling rules.
.PARAMETER ResourceGroup
    Name of the Azure Resource Group (Default: thinkschool-rg).
.PARAMETER Location
    Azure Region (Default: centralindia).
.PARAMETER EnvironmentName
    Name of the Container Apps Environment (Default: thinkschool-env).
.PARAMETER AppName
    Name of the Container App (Default: quotes-api).
.PARAMETER Image
    Container image to deploy (Default: quotes-api:0.1.0).
.PARAMETER JwtSecret
    JWT signing key (Default: generated 32-character secure secret).

.NOTES
    WHY THIS IS HERE AND WHY IT SHOULD NOT BE RUN

    Day 5 provisioned this application's infrastructure imperatively: this
    script creates a resource group, a Container Apps Environment and a
    container app with `az cli`. Day 23 replaced that with Bicep — see
    ../infra/, and ../../../Day23/docs/day23-bicep-iac-submission.md.

    The problem with running it now is not that it is broken. It is that it
    would work. It creates resources the template does not describe, in a
    resource group the template does not own, and the next
    `az deployment sub what-if` would either report them as drift or not see
    them at all. Two sources of truth for one set of infrastructure is the exact
    condition Day 23 exists to remove — and a repository that keeps a working
    imperative provisioner beside a declarative one has not really removed it.

    It is kept rather than deleted because Day 5's write-up
    (../docs/azure-container-apps.md and ../docs/azd-deployment.md) refers to it
    and describes a real exercise that happened. Deleting it would leave those
    documents referring to a file that never existed. This header is the
    compromise: the history stays readable, and nobody deploys from here by
    accident.

    To deploy, use ../infra/ and the runbook at
    ../../../Day23/docs/day23-deployment-runbook.md.
#>

[CmdletBinding()]
param (
    [string]$ResourceGroup = "thinkschool-rg",
    [string]$Location = "centralindia",
    [string]$EnvironmentName = "thinkschool-env",
    [string]$AppName = "quotes-api",
    [string]$Image = "quotes-api:0.1.0",
    [string]$JwtSecret = "SuperSecretKeyForJwtAuthenticationMustBeAtLeast32BytesLong!"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Azure Container Apps Provisioning Script ===" -ForegroundColor Cyan
Write-Host "Resource Group: $ResourceGroup"
Write-Host "Location:       $Location"
Write-Host "Environment:    $EnvironmentName"
Write-Host "App Name:       $AppName"
Write-Host "Image:          $Image"
Write-Host "------------------------------------------------"

# Step 1: Create Resource Group
Write-Host "[1/4] Creating Resource Group '$ResourceGroup' in '$Location'..." -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location --output table

# Step 2: Create Container Apps Environment
Write-Host "[2/4] Creating Container Apps Environment '$EnvironmentName'..." -ForegroundColor Yellow
az containerapp env create `
    --name $EnvironmentName `
    --resource-group $ResourceGroup `
    --location $Location `
    --output table

# Step 3: Create Container App with Ingress, Scaling Rules, and Environment Variables
Write-Host "[3/4] Deploying Container App '$AppName'..." -ForegroundColor Yellow
az containerapp create `
    --name $AppName `
    --resource-group $ResourceGroup `
    --environment $EnvironmentName `
    --image $Image `
    --ingress external `
    --target-port 8080 `
    --min-replicas 1 `
    --max-replicas 5 `
    --scale-rule-name "http-concurrency-rule" `
    --scale-rule-type "http" `
    --scale-rule-http-concurrency 50 `
    --env-vars "Jwt__Secret=$JwtSecret" "ASPNETCORE_ENVIRONMENT=Production" `
    --output table

# Step 4: Retrieve FQDN & Health Verification Instructions
Write-Host "[4/4] Retrieving App FQDN & Ingress Details..." -ForegroundColor Yellow
$fqdn = az containerapp show --name $AppName --resource-group $ResourceGroup --query "properties.configuration.ingress.fqdn" -o tsv

Write-Host "`n=== Deployment Successful ===" -ForegroundColor Green
Write-Host "App FQDN: https://$fqdn" -ForegroundColor Cyan
Write-Host "Health Endpoint: https://$fqdn/health"
Write-Host "Liveness Probe:  https://$fqdn/health/live"
Write-Host "Readiness Probe: https://$fqdn/health/ready"
