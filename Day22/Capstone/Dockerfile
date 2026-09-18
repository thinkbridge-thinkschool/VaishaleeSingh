# Multi-stage: the SDK builds, the runtime ships. The published image carries no
# compiler, no NuGet cache and no source -- roughly 200MB instead of 800MB, and
# nothing in it can rebuild anything.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# COPY THE PROJECT FILES FIRST, RESTORE, THEN COPY THE SOURCE.
#
# Docker caches each layer against the files it copied. Restore depends only on
# the .csproj/.slnx files, so putting them in their own layer means editing a
# .cs file re-runs the build but NOT the restore -- which is the slow half.
# Copying everything at once would invalidate the restore layer on every source
# change, and the difference shows up on every single deploy.
COPY QuotesPlatform.slnx ./

# Directory.Build.props is imported IMPLICITLY by every project in the tree, so
# nothing references it and it is easy to leave out of a Dockerfile. Leaving it
# out does not fail loudly: the build succeeds with different LangVersion,
# Nullable and warning settings than the developer's machine, which is a worse
# outcome than an error.
COPY Directory.Build.props ./
COPY src/QuotesPlatform.SharedKernel/*.csproj            src/QuotesPlatform.SharedKernel/
COPY src/QuotesPlatform.Contracts/*.csproj               src/QuotesPlatform.Contracts/
COPY src/QuotesPlatform.Host/*.csproj                    src/QuotesPlatform.Host/
COPY src/Modules/Catalog/QuotesPlatform.Modules.Catalog.Domain/*.csproj                 src/Modules/Catalog/QuotesPlatform.Modules.Catalog.Domain/
COPY src/Modules/Catalog/QuotesPlatform.Modules.Catalog.Application/*.csproj            src/Modules/Catalog/QuotesPlatform.Modules.Catalog.Application/
COPY src/Modules/Catalog/QuotesPlatform.Modules.Catalog.Infrastructure/*.csproj         src/Modules/Catalog/QuotesPlatform.Modules.Catalog.Infrastructure/
COPY src/Modules/Curation/QuotesPlatform.Modules.Curation.Domain/*.csproj               src/Modules/Curation/QuotesPlatform.Modules.Curation.Domain/
COPY src/Modules/Curation/QuotesPlatform.Modules.Curation.Application/*.csproj          src/Modules/Curation/QuotesPlatform.Modules.Curation.Application/
COPY src/Modules/Curation/QuotesPlatform.Modules.Curation.Infrastructure/*.csproj       src/Modules/Curation/QuotesPlatform.Modules.Curation.Infrastructure/
COPY src/Modules/Moderation/QuotesPlatform.Modules.Moderation.Domain/*.csproj           src/Modules/Moderation/QuotesPlatform.Modules.Moderation.Domain/
COPY src/Modules/Moderation/QuotesPlatform.Modules.Moderation.Application/*.csproj      src/Modules/Moderation/QuotesPlatform.Modules.Moderation.Application/
COPY src/Modules/Moderation/QuotesPlatform.Modules.Moderation.Infrastructure/*.csproj   src/Modules/Moderation/QuotesPlatform.Modules.Moderation.Infrastructure/
COPY src/Modules/Publishing/QuotesPlatform.Modules.Publishing.Domain/*.csproj           src/Modules/Publishing/QuotesPlatform.Modules.Publishing.Domain/
COPY src/Modules/Publishing/QuotesPlatform.Modules.Publishing.Application/*.csproj      src/Modules/Publishing/QuotesPlatform.Modules.Publishing.Application/
COPY src/Modules/Publishing/QuotesPlatform.Modules.Publishing.Infrastructure/*.csproj   src/Modules/Publishing/QuotesPlatform.Modules.Publishing.Infrastructure/

# The Host only. The test projects are not in this image and must not be: they
# reference Testcontainers, which would try to reach a Docker daemon that does
# not exist inside a container.
RUN dotnet restore src/QuotesPlatform.Host/QuotesPlatform.Host.csproj

COPY src/ src/
RUN dotnet publish src/QuotesPlatform.Host/QuotesPlatform.Host.csproj \
    -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app

# NON-ROOT. The aspnet images ship an unprivileged `app` user (uid 1654); using
# it means a container escape lands somewhere that cannot write to the image.
# It costs one line and it is the cheapest hardening available here.
USER app

# Container Apps routes to whatever port the ingress says, and the default
# ASP.NET Core container port is 8080. Stated explicitly because a mismatch
# between this and --target-port presents as a revision that never goes
# healthy, with no error anywhere -- the request simply has nowhere to land.
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

# NO MIGRATION ON STARTUP, deliberately, and this is the one thing in this file
# worth arguing about. Migrations are a deployment step: two replicas starting
# at once would both try to migrate, and a schema change racing itself is a
# genuinely bad morning. 02-deploy.ps1 applies them from outside, before the
# new revision takes traffic.
COPY --from=build /app .
ENTRYPOINT ["dotnet", "QuotesPlatform.Host.dll"]
