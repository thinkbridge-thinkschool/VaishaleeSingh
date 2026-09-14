# Build plan — Day 29 onward

Not invented work. Every item below is an open finding already recorded in
`Day27/docs/day27-threat-model.md` or `day27-submission.md`. The plan's job is
to order them and give each one an exit criterion somebody else could check.

## How this is ordered

**Detection before hardening.** The cheapest item is first because it protects
everything after it: with no private endpoint possible, one SQL setting is the
entire wall, and nothing currently notices if it moves.

**Reversibility next.** Work that can be undone with a revert goes ahead of
work that cannot.

**Debt with a decision attached last.** Retiring an auth scheme is a day, and
doing it badly is worse than deferring it honestly.

## Exit criteria are observable or they are not criteria

A day whose exit criterion is "improved X" has no exit criterion. Each one
below is something that can be run, seen, or counted.

---

### Day 29 — Detection for the single point of prevention

**Goal.** Alert when `azureADOnlyAuthentication` changes on either SQL server,
and stop relying on a human to run the firewall reconciliation.

**Why first.** The data tier is on the public network path by necessity. Entra-only
authentication is what makes that acceptable. One setting change removes it and
today nothing would notice — that is the largest gap in the system, and it is
also one of the cheapest to close.

**Exit criteria**

- An Azure Monitor activity-log alert exists on both servers, and it **fired
  once during a deliberate test change that was then reverted**. An alert
  nobody has seen fire is a configuration, not a control.
- `01-reconcile-sql-firewall.ps1` runs on a schedule and logs a no-op run.
- The runbook says what to do when it fires, in two lines.

**Rollback.** Delete the alert rule and the schedule. Nothing in the
application changes.

**Estimate.** Half a day. Most of it is testing that the alert actually fires,
which is the only part that matters.

---

### Day 30 — `SQLitePCLRaw` NU1903

**Goal.** Clear the high-severity advisory that every build has warned about.

**Why not first.** Real, but low exposure: it reaches the tree transitively and
production runs SQL Server, not the SQLite provider. It is ahead of the auth
work because it is a version bump with a test suite behind it.

**Exit criteria**

- `dotnet build` produces **no NU1903**.
- 192 unit + 66 integration tests green.
- If the bump breaks the SQLite-backed tests, the finding is **re-recorded with
  the reason** rather than forced through. A dependency that cannot be upgraded
  is a known risk; a test suite bent to accommodate one is a hidden risk.

**Rollback.** Revert the package reference.

**Estimate.** Half a day, mostly test runs.

---

### Day 31 — Resolve the two-auth-scheme debt

**Goal.** One authentication scheme live, or a written, dated acceptance of two.

**The work if we retire `CustomJwt`.** Migrate the SPA to MSAL, rework sign-in
and refresh, decide what happens to the `Users` table and existing refresh
tokens, and keep the integration tests meaningful throughout.

**Exit criteria** — one of:

- `AuthSchemeSelector` handles a single scheme; tests updated; sign-in works in
  dev and in prod; **or**
- **ADR-0003** recording the acceptance, its reasons, and an **expiry date** at
  which it must be revisited. An accepted risk with no expiry is a forgotten
  risk.

**Rollback.** Revert; both schemes are live today, so reverting restores a
working state rather than a broken one.

**Estimate.** A full day for the migration; an hour for the ADR. Choosing which
is itself the day's decision.

---

### Day 32 — Make the promotion script clean up after itself

**Goal.** `05-promote-prod.ps1` removes the SQL firewall rule it adds for the
deploying machine.

**Why it matters more than it looks.** Day 27 deleted three stale operator IP
rules that had been open for weeks. This script is how a fourth one appears.

**Exit criteria**

- Firewall rule count on the prod server is **identical before and after** a
  full promotion run.
- The cleanup runs even when the deployment fails — otherwise the failure path
  becomes the leak.

**Rollback.** Revert the script; behaviour returns to today's, which leaves a
rule behind.

**Estimate.** Two hours, most of it on the failure path.

---

### Day 33 onward — Capstone finishing

Driven by the course's remaining brief rather than guessed at here. Two items
carry forward and should not be lost:

- **COEP.** Deliberately not set; the reasoning is in
  `nginx/security-headers.conf`. If the app ever needs `SharedArrayBuffer` or
  precise timers, that decision reopens.
- **Consumers run in the API process.** Simple and cheap today; it couples
  worker throughput to API scaling. Moving them out is the trigger named in
  **ADR-0001** for revisiting the outbox design.

---

## What this plan does not claim

Dates are estimates, stated as estimates. A plan that projects certainty makes
the same mistake as an ADR that presents its decision as inevitable — it hides
the judgement instead of exposing it to challenge.

If the design review changes the priority order, the review wins. The order
above is an argument, not a schedule.
