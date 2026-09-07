<#
.SYNOPSIS
    Creates the contained database user for the API's managed identity.

.DESCRIPTION
    THE ONE STEP THE BICEP CANNOT DO.

    infra/modules/sql.bicep provisions an Azure SQL server with Entra-only
    authentication and no SQL login. That gets the app's managed identity to the
    server. It does not give it a user inside the database, because that is
    T-SQL and ARM has no verb for it.

    This script is the honest name for that gap: a post-deploy imperative step
    the deployment depends on. It is written down, checked in, and named in the
    Day 23 submission rather than left for whoever hits the login failure.

    It is idempotent — run it as many times as you like.

    TWO TRANSPORTS, TRIED IN ORDER
    Neither sqlcmd nor winget existed on the machine this was first run on, so
    the script no longer assumes either. It prefers the SqlServer PowerShell
    module, which installs per-user with no administrator rights, and falls back
    to sqlcmd where that is already present. Both authenticate as the caller's
    Entra identity; neither needs a password, because the server has none.

    Alternative considered and rejected: a
    Microsoft.Resources/deploymentScripts resource running this inside the
    template. It works, and it needs its own managed identity, a storage account
    and a forceUpdateTag to control re-runs. Judged more machinery than the gap
    is worth for a training deployment — recorded as a trade in the Day 23
    submission rather than silently made.

.PARAMETER SqlServerFqdn
    e.g. sql-quotes-neufxknr54rza.database.windows.net
    (the azurE_SQL_SERVER_FQDN deployment output — ARM camel-cases the name).

.PARAMETER DatabaseName
    e.g. quotes (azurE_SQL_DATABASE_NAME).

.PARAMETER IdentityName
    The user-assigned managed identity's NAME, not its client or object ID —
    FROM EXTERNAL PROVIDER resolves it by display name
    (servicE_QUOTES_API_IDENTITY_NAME).

.EXAMPLE
    ./create-sql-user.ps1 `
        -SqlServerFqdn 'sql-quotes-neufxknr54rza.database.windows.net' `
        -DatabaseName  'quotes' `
        -IdentityName  'id-quotes-api-neufxknr54rza'

.NOTES
    Run as the Entra principal that sql.bicep named as the SQL administrator.
    Anyone else gets "Principal ... does not have permission", which is the
    Entra-only design working, not a bug.

    The dev database is serverless with a 60-minute auto-pause. If it has gone
    to sleep, the first connection pays a resume of roughly a minute and may
    time out once. Run it again.

    THE MACHINE RUNNING THIS NEEDS A FIREWALL RULE. The server's only other
    rule is AllowAzureServices, which lets the container app in and nobody
    else. "Client with IP address '...' is not allowed to access the server"
    means the rule is missing — and the fix is a redeploy, not a portal edit:

        $env:SQL_CLIENT_IP = (Invoke-RestMethod https://api.ipify.org)
        az deployment sub create -l centralindia -f infra/main.bicep -p infra/main.dev.bicepparam

    sqlAllowedClientIpAddresses in main.dev.bicepparam reads that variable. A
    rule added with `az sql server firewall-rule create` instead would be
    invisible to the template and reported as drift by the next what-if.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SqlServerFqdn,
    [Parameter(Mandatory)] [string] $DatabaseName,
    [Parameter(Mandatory)] [string] $IdentityName
)

$ErrorActionPreference = 'Stop'

# QUOTENAME rather than string concatenation: the identity name arrives from a
# deployment output, and building T-SQL by pasting a name into it is how an
# injection gets in even when nobody malicious is involved.
$tsql = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$IdentityName')
BEGIN
    DECLARE @create nvarchar(max) =
        N'CREATE USER ' + QUOTENAME(N'$IdentityName') + N' FROM EXTERNAL PROVIDER;';
    EXEC sp_executesql @create;
    PRINT 'Created user $IdentityName';
END
ELSE
    PRINT 'User $IdentityName already exists';

DECLARE @member nvarchar(max) = QUOTENAME(N'$IdentityName');

-- sp_executesql takes a VARIABLE, never an expression. Passing it
-- (N'ALTER ROLE ... ' + @member + N';') parses as a parenthesised expression in
-- the argument position and fails with "Incorrect syntax near 'ALTER ROLE ...'"
-- -- which reads like the T-SQL inside the string is wrong when the string is
-- fine and the CALL is wrong. Hence a variable to assign into.
DECLARE @grant nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm
    JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
    JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'db_datareader' AND m.name = N'$IdentityName')
BEGIN
    SET @grant = N'ALTER ROLE db_datareader ADD MEMBER ' + @member + N';';
    EXEC sp_executesql @grant;
    PRINT 'Granted db_datareader';
END

IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm
    JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
    JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'db_datawriter' AND m.name = N'$IdentityName')
BEGIN
    SET @grant = N'ALTER ROLE db_datawriter ADD MEMBER ' + @member + N';';
    EXEC sp_executesql @grant;
    PRINT 'Granted db_datawriter';
END

-- db_ddladmin is here because the app runs EF Core migrations on startup. If
-- migrations ever move to a deployment step, drop it: a running app has no
-- business being able to alter its own schema.
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm
    JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
    JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'db_ddladmin' AND m.name = N'$IdentityName')
BEGIN
    SET @grant = N'ALTER ROLE db_ddladmin ADD MEMBER ' + @member + N';';
    EXEC sp_executesql @grant;
    PRINT 'Granted db_ddladmin';
END
"@

Write-Host "Server:   $SqlServerFqdn"
Write-Host "Database: $DatabaseName"
Write-Host "Identity: $IdentityName"
Write-Host ''

$invokeSqlcmd = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
$sqlcmdExe = Get-Command sqlcmd -ErrorAction SilentlyContinue

if (-not $invokeSqlcmd -and -not $sqlcmdExe) {
    Write-Host 'Neither Invoke-Sqlcmd nor sqlcmd found. Installing the SqlServer module for the current user.'
    Write-Host '(Per-user scope: no administrator rights, and nothing is installed machine-wide.)'
    Write-Host ''
    Install-Module SqlServer -Scope CurrentUser -Force -AllowClobber
    Import-Module SqlServer
    $invokeSqlcmd = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
}

if ($invokeSqlcmd) {
    # An access token from the az CLI session, so this reuses whatever `az login`
    # already established rather than opening a second interactive sign-in. The
    # resource is the SQL Database service, not the management plane — a
    # management token is refused by the server with a confusing error.
    Write-Host 'Transport: Invoke-Sqlcmd with an Entra access token'

    $token = az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw 'Could not get an access token. Run `az login` first.'
    }

    # -ErrorAction Stop matters: without it Invoke-Sqlcmd reports a T-SQL error
    # as a non-terminating error, $ErrorActionPreference notwithstanding, and
    # this script cheerfully printed "Done. The container app can now
    # authenticate" immediately after three failed GRANTs. A script that lies
    # about success is worse than one that fails.
    Invoke-Sqlcmd -ServerInstance $SqlServerFqdn `
                  -Database $DatabaseName `
                  -AccessToken $token `
                  -Query $tsql `
                  -Verbose `
                  -ErrorAction Stop
}
else {
    # -G authenticates with Entra interactively; no password anywhere.
    Write-Host 'Transport: sqlcmd -G'

    sqlcmd -S $SqlServerFqdn -d $DatabaseName -G -Q $tsql
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd failed with exit code $LASTEXITCODE"
    }
}

Write-Host ''
Write-Host 'Done. The container app can now authenticate to SQL as its managed identity.'
