# Day 23 — Bicep IaC: implementation plan

## Detailed task prompt

> Describe your infra as code. Author Bicep modules (parameterized) for the API,
> SQL, and Service Bus, with separate dev/prod parameter files. No portal
> click-ops.

## What changed once it was built

The plan below is kept as written. Ten things came out differently, and two of
them contradict what the plan (and the task prompt) said explicitly. Items 7 and
8 were caught by a compiler; 9 and 10 only by deploying the thing and planning
again. None of them was caught by reading it.

**1. `main.parameters.json` could not be left unchanged.** The prompt said it
stays exactly as it is so `azd up` keeps working. That was wrong the moment
`jwtSecret`, `sqlEntraAdminObjectId` and `sqlEntraAdminLogin` became required
parameters with no defaults: azd passes only what that file lists, so an
unlisted required parameter fails the deployment rather than falling back. It
now carries three more entries, resolved from `JWT_SECRET`,
`AZURE_PRINCIPAL_ID` (which azd sets itself) and `SQL_ENTRA_ADMIN_LOGIN`. The
*claim* the prompt was protecting still holds — azd still reads only this file
and still ignores both `.bicepparam` files — but "unchanged" was not true.

**2. Eight modules, not seven.** The Container Apps Environment needed its own
module. It cannot stay in `main.bicep`: `main.bicep` is subscription-scoped and
creating an environment needs resource-group scope, and the create-or-reference
switch needs a conditional `existing` resource, which needs a file of its own to
resolve the two branches into one `environmentId` output.

**3. The API module owns the JWT secret after all.** The plan had the
environment-variable array composed entirely by `main.bicep`, module fully
generic. That cannot hold for a secret: `env` is a plain `array` parameter, and
a secure value passed through it appears in plain text in deployment history.
`jwtSecret` is therefore a `@secure() string` parameter on `api.bicep`, which
builds the Container Apps secret and the `secretRef` itself and concatenates it
onto the caller's `env`. Slightly less generic, and the alternative was a
secret in the deployment log.

**4. `quotesApiExists` is declared and deliberately unused.** azd passes it, and
an undeclared parameter is a hard deployment error — but nothing in the template
needs it, because the placeholder-image ternary already reads the "no image yet"
condition off `quotesApiImageName` directly. With `no-unused-params` turned up
to error in `bicepconfig.json`, this needs an explicit
`#disable-next-line`. The pre-Day-23 template had the same dead parameter and
said nothing about it.

**5. The image-path bug was NOT fixed, and stays a documented gap.** §3 of the
prompt gave two options — fix it, or state it. It is stated. The cause is in
`QuotesApi.csproj` (`ContainerRepository: quotes-api`) rather than in the
infrastructure, and changing the image path is a packaging change that would
need its own verification against a real `azd deploy`. Bundling it into an
infrastructure refactor would have made both harder to review. So `azd up` still
needs one corrective `az containerapp update --image ...`, and the submission
says so.

**6. The prod parameter file describes an environment that cannot be created
today.** `createContainerAppsEnvironment = true` and a dedicated resource group
are both blocked by the same one-environment-per-region quota that shaped the
original template. This is deliberate: the parameter file is where a constraint
belongs, and a prod file that quietly reused the dev environment would have made
the two files differ by less than the environments actually do. It also means
the prod `what-if` is a plan, not a rehearsal — stated in the file's own header.

**7. `environment` is not a legal module symbol.** `environment()` is a Bicep
built-in function, so a module symbol of that name shadows it. Renamed to
`containerAppsEnvironment`. The module file is still `modules/environment.bicep`
— the collision is on the symbol, not the path.

**8. A `.bicepparam` file cannot omit a required parameter, and cannot be
combined with `-p name=value`.** Both halves of the original plan for `jwtSecret`
were wrong: leaving it out of the parameter files fails at *compile* time, not
at deploy time, and `az` refuses to mix a `.bicepparam` with inline overrides.
The bicepparam-native answer is `readEnvironmentVariable('JWT_SECRET', '')`.

It took three attempts, each corrected by a compiler rather than by reasoning:

| Attempt | Fails how |
|---|---|
| Omit `jwtSecret` from the parameter files entirely | Required parameter missing — compile error |
| `readEnvironmentVariable('JWT_SECRET')` | **BCP427** when the variable is unset: the editor is red for anyone who merely opens the file |
| `readEnvironmentVariable('JWT_SECRET', '')`, with `@minLength(32)` on `main.bicep`'s parameter | **BCP333** — Bicep validates length constraints on a `.bicepparam` assignment at *compile* time, not at deploy time |

What works: the empty fallback, with `@minLength(32)` moved off `main.bicep`'s
pass-through parameter and onto `modules/api.bicep`'s, where the value is
consumed. Bicep cannot statically prove the length of a value arriving through a
parameter, so the check moves to deployment, where ARM enforces it before a
single resource is touched.

The lesson is not about `readEnvironmentVariable`. It is that a constraint on a
pass-through parameter is checked at a different time — and against a different
input — than a constraint on the parameter that consumes the value, and that
"stricter" and "fails earlier" turned out to mean "unopenable" twice in a
row.

**9. The image had to be resolved outside `api.bicep`.** The first `what-if`
showed the running image being replaced by the hello-world placeholder on a
deployment that changed nothing about the application — an outage produced by an
infrastructure change. The placeholder fallback is correct exactly once, on
first creation, and silently destructive every time after. Hence a ninth file,
`fetch-container-image.bicep`: an explicitly supplied image, else the one the app
is already running, else the placeholder. `api.bicep` now has no fallback of its
own, because a module cannot see the running app.

**10. Two real drifts, found only by deploying and planning again.** The
`$Default` Service Bus rule Day 19 declared turned out to be deleted by the
service the moment `content-changes-only` was created, so every deployment would
recreate and lose it forever — Day 19's stated reasoning about `$Default` is
contradicted by observed behaviour, and the rule is gone. And the HTTP scale rule
was declared as `custom:` with `type: 'http'`, which Container Apps normalises
into a native `http` rule, so the template described a resource the service
cannot store. Both are detailed in the submission and in
`../verification/idempotency-analysis.txt`.

## Branch base

Branched off `main` at `e9dfc26`, which contains Day 22 (PR #51 merged).

## Goal

`Day7/piece2/infra/resources.bicep` was 13 KB of every resource this application
uses, in one file, with no parameters beyond a name and a location. Day 23 turns
it into a parameterized module graph, adds the two resources that were missing
entirely (SQL) or written and then orphaned (Service Bus), and produces dev and
prod parameter files that differ only in values.

The measurable claim at the end is idempotency: deploy, then `what-if` again and
get "no changes". A template that still shows drift against the resources it
just created is the condition under which someone eventually fixes it in the
portal — which is the thing the task forbids.

## Starting point, verified

- `Microsoft.Sql` appears in **zero** templates in this repository. The deployed
  container app has never had a `ConnectionStrings__DefaultConnection` set, so it
  has been running on the SQLite file baked into its image.
- `Day19/infra/servicebus.bicep` is referenced by **nothing**. It describes a
  topology no deployment ever created.
- `resources.bicep` carries a literal JWT signing key as a Container Apps secret
  value, in source control, with a comment acknowledging it.
- The Container Apps Environment is an `existing` reference to a resource in
  another resource group, created outside this template.

## Plan

### Step 1 — linter first

`bicepconfig.json` with `no-unused-params`, `no-unused-vars`,
`outputs-should-not-contain-secrets`, `secure-parameter-default` and
`prefer-interpolation` at error. Turning the linter up *before* the refactor
means it flags mistakes as they are made rather than in a cleanup pass at the
end.

### Step 2 — the mechanical extractions

`monitoring`, `registry`, `identity`. These carry no new logic, which is the
point: they de-risk the module-boundary mechanics (what goes in a parameter,
what comes back as an output, where a role assignment can legally be declared)
on resources where a mistake is obvious.

The AcrPull assignment moves into `registry.bicep`, not `identity.bicep`,
because a `roleAssignment`'s `scope:` needs a symbolic reference to the resource
being granted on. Its `guid()` seeds are preserved byte-for-byte: change what
you feed `guid()` and the next deployment creates a second assignment instead of
recognising the first.

### Step 3 — `environment`

The create-or-reference switch. See item 2 above.

### Step 4 — `api`

Where sizing becomes parameters and the environment-variable array becomes an
input. See item 3 above for what could not be an input.

### Step 5 — `servicebus`

A move and a parameterization, not a rewrite. Day 19's comments are load-bearing
— particularly the `$Default` TrueFilter overwrite — and are kept verbatim
wherever the code they explain is unchanged.

Decision: the two subscriptions stay explicit rather than becoming a loop over a
`subscriptions array`. A loop would have to carry the `$Default` overwrite as a
conditional nested resource, and burying that specific trap inside a loop to
save a dozen lines is a bad trade. Generality was available; clarity was worth
more.

### Step 6 — `sql`, from scratch

Entra-only authentication (`azureADOnlyAuthentication: true`, no
`administratorLogin`, no password parameter). This is the decision that makes
the whole exercise tractable: a SQL admin password would have to exist,
differently, in two parameter files in source control. With Entra-only auth
there is no password to place anywhere.

The gap it cannot close: the contained database user is T-SQL.
`scripts/create-sql-user.ps1`, idempotent, named in the submission as a
post-deploy step. The alternative — a `deploymentScripts` resource running
`sqlcmd` inside the template — works and needs its own managed identity, a
storage account and a `forceUpdateTag`. Judged more machinery than the gap is
worth here, and recorded as a trade rather than made silently.

### Step 7 — `main.bicep` and the parameter files

`main.bicep` becomes orchestration only. Two `.bicepparam` files, typed against
it via `using`. `main.parameters.json` stays azd's entrypoint — see item 1 for
what that actually required.

### Step 8 — delete `resources.bicep`

Only after `main.bicep` no longer references it and `what-if` shows no
unintended deletions. Moving a resource between modules is a no-op to ARM, which
keys on resource name and type rather than module path — but any incidental
rename is a destroy-and-recreate, and `what-if`'s `Delete` lines are the only
thing that catches it.

### Step 9 — CI

A `bicep build` + `lint` + `build-params` job. `what-if` is not in CI: it needs
a subscription and credentials this repository does not hold.

## What is deliberately out of scope

Private endpoints and VNet integration; a Key Vault module (the `@secure()`
parameter is the interim answer); Redis; moving CI's solution path from
`Day5/piece2` to `Day7/piece2`; multi-region. Each is named in the submission so
a reader can tell a decision from an oversight.

## What has since been verified

This section originally said that nothing here had been compiled — the machine
these templates were written on has no `az`, no `bicep` and no network to install
either, so every claim was a claim about code that had been read carefully and
never built.

That is no longer true, and the difference is the point of keeping this
paragraph rather than deleting it. The templates now compile and lint clean, the
dev environment is deployed, and the plan-after-deploy is captured in
`../verification/`. Ten things came out differently from this plan. Six of them
were found by a compiler or by the cloud, and would not have been found by
reading the file again — including two that only a deployed environment could
have shown.
