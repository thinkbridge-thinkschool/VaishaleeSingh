# Day 28 — Design review + ADR: the plan

**Task.** Mentor + peer critique of the capstone design. Write the ADR for the
one decision that matters most (the trade-off, the alternatives, why), and plan
the build day by day.

## What this day actually is, and how it fails

Twenty-seven days built a system. Today writes down *why* it is shaped the way
it is, and submits that to people who will disagree.

Almost nothing executes today, so the usual failure — breaking the app — is not
the risk. The three real ones are:

1. **Describing the system from memory.** A brief that describes what we
   *intended* invites critique of a system that does not exist. Every structural
   claim in the brief is checked against the running deployment first. This is
   not caution for its own sake: Day 27 spent an afternoon on a container
   running an image the pipeline never built, and on a comment that said the
   SPA is served by the API when it has not been for four days.
2. **An ADR that argues for the decision already made.** An ADR whose
   "alternatives" section exists to make the chosen option look inevitable is
   worse than no ADR, because it launders a guess as a judgement. The test
   applied below: each alternative must be stated well enough that someone
   could reasonably have picked it.
3. **A review with nothing at stake.** "Any feedback?" produces "looks good".
   Reviewers are given specific, answerable questions, including two where the
   honest answer would embarrass the design.

## Ground rules

1. **Documentation only.** No application code, no Bicep, no workflow changes.
   If today surfaces a code change worth making, it becomes a dated entry in
   the build plan — not an edit made while writing prose.
2. **Branch as usual:** `day28-design-review` off `dev`, PR into `dev`, then
   `dev` → `main` with **Rebase and merge**.
3. **Nothing is asserted that was not checked.** Every number, endpoint and
   setting in the brief traces to a command in step 0 or a file in the repo.
4. **Feedback is recorded verbatim before it is answered.** Paraphrasing a
   critique while writing the response is how a critique becomes agreement.

## Step 0 — Establish ground truth before describing anything (30 min)

The brief describes the deployed system. So the deployed system is asked first.

```powershell
# What is actually running, in both environments
foreach ($rg in 'thinkschool-dev-rg','thinkschool-prod-rg') {
  az containerapp list -g $rg --query "[].{app:name,image:properties.template.containers[0].image,minReplicas:properties.template.scale.minReplicas,ingress:properties.configuration.ingress.external}" -o table
}

# The data tier, as configured rather than as remembered
az sql server list --query "[].{name:name,adOnly:administrators.azureADOnlyAuthentication}" -o table
foreach ($rg in 'thinkschool-dev-rg','thinkschool-prod-rg') {
  $srv = az sql server list -g $rg --query "[0].name" -o tsv
  az sql server firewall-rule list -g $rg -s $srv -o table
}

# Messaging and identity
az servicebus namespace list --query "[].{name:name,localAuth:disableLocalAuth}" -o table
az containerapp show -n quotes-api-dev -g thinkschool-dev-rg --query "identity.type" -o tsv
```

Two facts to carry into the brief because they are load-bearing and easy to
misstate: dev and prod **share one Container Apps environment** (the
subscription allows exactly one), and prod runs the **same image** dev tested,
promoted by digest rather than rebuilt.

**Deliverable:** a scratch note of the outputs. It is the brief's source, and
disagreements between it and memory are themselves worth reporting.

## Step 1 — The design brief reviewers will read (60–90 min)

One page. Reviewers who must read ten pages give shallow feedback on the first
two.

**Contents, in this order:**

- **What the system does**, in three sentences, in domain terms.
- **One diagram.** Components, the trust boundary, and the direction of every
  arrow. Mermaid in the markdown so it renders in the PR and stays diffable —
  an image would go stale silently, which is exactly the failure mode this
  project keeps hitting.
- **The five decisions that shaped it**, one line each, with the ADR-worthy one
  marked. Enough for a reviewer to say "wait, why that?" — which is the point.
- **Where it is weak.** Written by us, before anyone else says it: two live auth
  schemes, no private endpoint, a single-point-of-prevention setting with no
  alert, per-IP rate limiting only. Naming your own weaknesses moves the review
  from finding them to judging them, which is the more valuable hour.
- **What is explicitly out of scope**, so critique lands on the design rather
  than on the exercise's boundaries.

**File:** `Day28/docs/day28-design-brief.md`

## Step 2 — Choosing the one decision (30 min)

"The one that matters most" is a judgement, so it is made against stated
criteria rather than taste. Score each candidate 1–3:

| Criterion | Why it counts |
|---|---|
| **Blast radius** | How much of the system changes if this is reversed |
| **Irreversibility** | Cost of changing it in six months, not today |
| **Contestedness** | Would a competent engineer have chosen differently? |
| **Consequences already felt** | Has it already cost or saved us something real? |

**Candidates** (all real decisions in this repo):

| Decision | Notes |
|---|---|
| **Transactional outbox for domain events** (Day 20) | Highest blast radius: it defines what "the write succeeded" means. Alternatives are genuinely viable — dual write, publish-then-commit, CDC — and each fails differently. Consequences felt: the outbox is why a Service Bus outage cannot lose a quote. |
| **Promotion by image import, not rebuild per environment** (Day 24/26) | Cheap to state, expensive to reverse, and it is the reason "tested" means anything about prod. |
| **Public data tier with Entra-only auth, because private endpoints are impossible here** (Day 27) | Forced by the subscription, so partly not a decision — but *how* we responded to the constraint was. |
| **SPA in its own nginx container rather than served by the API** (Day 24) | Real trade-off, already reversed once, which is evidence. |

**Recommendation, to be confirmed in the review rather than assumed:** the
**transactional outbox**. It scores highest on blast radius and contestedness,
its alternatives are textbook and defensible, and it is the decision whose
"why" a reviewer is most likely to challenge — which makes it the one worth
writing down. The data-tier decision is the runner-up and belongs in the
backlog as ADR-0002.

If the mentor names a different decision, that choice wins. Their disagreement
about *what matters most* is itself the most useful output of the day.

## Step 3 — Writing the ADR (90 min)

Set up the record properly, because this is the first one:

```
Day28/docs/adr/
  README.md            # index + how to add one + status meanings
  0000-template.md     # so the second ADR costs ten minutes
  0001-<decision>.md
```

**Structure** (MADR-shaped, adapted):

- **Status** — Accepted, with the date. Statuses change by *adding* a
  superseding ADR, never by editing history.
- **Context** — the forces, stated without the answer in them. If the context
  paragraph can only lead to one conclusion, it has been written backwards.
- **Decision** — one sentence, active voice.
- **Alternatives considered** — each with what it costs, what it buys, and
  **the specific condition under which it would have won**. That last clause is
  the honesty test: an alternative with no winning condition was never
  considered, only listed.
- **Consequences** — split into *what we accept* and *what we now owe*. The
  outbox buys atomicity and owes a dispatcher, a poison-message path,
  at-least-once semantics and therefore idempotent consumers.
- **Evidence** — where the code lives, and what proves it works.
- **What would change our mind** — the trigger that should reopen this. An ADR
  without one is a monument rather than a decision record.

**Not in the ADR:** an implementation walkthrough. It records *why*; the code
records *how*, and duplicating it guarantees the two disagree.

## Step 4 — Running the review (60 min + response time)

**Send in advance:** the brief, the draft ADR, and the diagram — with the ADR
marked **draft**. An ADR presented as finished gets proofreading rather than
critique.

**Ask specific questions**, including the uncomfortable ones:

1. Is the outbox worth its complexity here, or is publish-with-retry adequate
   for this domain's actual consistency needs?
2. Two auth schemes are live. Is deferring the migration the right call, or
   accumulating debt with interest?
3. With no private endpoint possible, is one Entra-only setting an acceptable
   single point of prevention — and would you ship this?
4. Read paths return 404 for another owner's row to prevent enumeration. Does
   that cost more in debuggability than it buys?
5. What in this design would you refuse to be on call for?

**Capture:** `Day28/docs/day28-review-notes.md` — reviewer, date, the critique
**quoted**, then one of *accepted → what changed*, *rejected → why*, or
*deferred → which day*. A critique with no disposition is a critique that was
heard and ignored.

**If no mentor session lands today**, this is not a blocker: the questions are
posted on the PR and the notes file records the state as awaiting response.
Recording "asked, unanswered" is honest; pretending the review happened is not.

## Step 5 — The build plan, day by day (45 min)

Grounded in the real backlog rather than invented work. The open items from
Days 24–27 are the source.

**Format per day:** goal in one sentence, exit criterion that is *observable*,
rollback, and estimated cost. A day whose exit criterion is "improved X" has no
exit criterion.

**Sequencing principle:** detection before hardening, and reversibility first.
The highest-value item is the cheapest — an alert on the one setting the data
tier depends on — and it goes first because it protects everything after it.

| Day | Goal | Exit criterion |
|---|---|---|
| 29 | Alert on `azureADOnlyAuthentication` changing; automate firewall reconciliation | Alert fires on a deliberate test change; reconcile runs on a schedule and logs a no-op |
| 30 | `SQLitePCLRaw` NU1903 bump | Build clean of NU1903; 258 tests green |
| 31 | Retire `CustomJwt` or formally accept it, with an ADR either way | One auth scheme live, or ADR-0003 recording the acceptance and its expiry date |
| 32 | Promotion script cleans up its own SQL firewall rule | Rule count unchanged before and after a promotion |
| 33+ | Capstone finishing per the course's remaining brief | — |

Dates are estimates; the plan records that explicitly, because a plan that
pretends to certainty is the same failure as an ADR that pretends to
inevitability.

**File:** `Day28/docs/day28-build-plan.md`

## Verification gates

| After | Gate |
|---|---|
| Step 0 | Every figure in the brief traces to a command output |
| Step 1 | The Mermaid diagram renders in the GitHub PR preview |
| Step 3 | Each alternative has a stated condition under which it would have won |
| Step 3 | The ADR's context paragraph, read alone, does not give away the decision |
| Step 4 | Every captured critique has a disposition |
| Before merge | `git status` clean of stray files; no code, infra or workflow files in the diff |

## What this day produces

- `Day28/docs/day28-design-brief.md` — one page and one diagram
- `Day28/docs/adr/README.md`, `0000-template.md`, `0001-<decision>.md`
- `Day28/docs/day28-review-notes.md` — critiques quoted, each with a disposition
- `Day28/docs/day28-build-plan.md` — day by day, with observable exit criteria
- `Day28/docs/day28-submission.md` — the ADR, the critique, and the plan

## The one thing to keep in view

The ADR is not documentation of the build. It is a message to whoever inherits
this and wonders why it is not simpler. It should be readable by someone who
disagrees, and it should still be honest six months from now when the trade-off
has aged — which is why "what would change our mind" is a required section and
not a flourish.
