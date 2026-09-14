# Day 28 — Design review notes

**Status:** awaiting reviewer responses.

Materials sent: `day28-design-brief.md`, `adr/0001-transactional-outbox.md`
(marked **draft** on purpose — an ADR presented as finished gets proofreading
instead of critique), and the diagram in the brief.

## How this file works

Each critique is **quoted before it is answered**. Paraphrasing a criticism
while writing the reply is how a criticism quietly becomes agreement.

Every entry ends with one of three dispositions:

- **Accepted** → what changed, and where
- **Rejected** → why, in a way the reviewer would recognise as a fair summary
  of their point
- **Deferred** → which day in the build plan, and what the trigger is

A critique with no disposition is a critique that was heard and ignored.

## Questions put to reviewers

1. Is the outbox worth its complexity for this domain, or is publish-with-retry
   sufficient given what these events are actually for?
2. Two authentication schemes are live. Is deferring the `CustomJwt` retirement
   the right call, or is it debt accruing interest?
3. With private endpoints impossible on this subscription, is one Entra-only
   setting an acceptable single point of prevention — would you ship this?
4. Reads of another owner's row return 404 rather than 403, to resist
   enumeration. Does that cost more in debuggability than it buys?
5. What in this design would you refuse to be on call for?

## Critiques

### <reviewer> — <date>

> <their words, quoted>

**Response.**

**Disposition.** Accepted / Rejected / Deferred → Day NN

---

## If no review lands

This file records the state as *asked and unanswered*, with the date the
questions were posted on the PR. That is an honest outcome. Writing up a review
that did not happen is not.
