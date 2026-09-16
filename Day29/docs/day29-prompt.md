# Day 29 — Build day 1: foundation + happy path (task prompt)

## Task, as given

> **Build day 1: foundation + happy path**
>
> Build the foundation and the happy path end to end. Small, reviewable
> commits with clean messages; the main flow works against real infra by EOD.

## Where this picks up

Day 22 scaffolded `Day22/Capstone` as a modular monolith — four modules
(Catalog, Curation, Publishing, Moderation), a rich `Collection` aggregate with
its eight invariants, and architecture tests that fail the build on a boundary
violation. Days 23–27 went a different direction (IaC, deployment, security
hardening for the existing `quotes-api`). Day 28 reviewed that design and wrote
the ADR for the transactional outbox, using the capstone's own decision as the
subject.

What Day 22 did **not** produce — by its own stated scope ("kickoff", not
build) — is anything that runs: no EF configurations, no migrations, no
repository implementations, no endpoints, no outbox wiring, no cross-module
messaging. Every `*ModuleRegistration.cs` says so directly: *"registered here
as they are written... today is the scaffold."* `Program.cs` still points at a
local SQLite file, and the only mapped route is `/health`.

Day 29 is the first day that makes any of it real. "Foundation" is what the
happy path needs to run at all; "happy path" is one flow, start to finish,
against real SQL Server and a real Service Bus namespace — not the design, not
every branch, one lap around the whole system.

## Answer

The implementation plan for today: [`day29-plan.md`](day29-plan.md)
