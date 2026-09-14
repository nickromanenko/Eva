# Eva — Autonomy Policy

Who approves what, per surface. This is the control panel: it is meant to change, but
only deliberately — never mid-task to unblock yourself.

**Legend** — `AI` = agent decides and proceeds · `human` = stop and ask Nick.

| Gate | `website/` | `api/` | `mobile/` | rules / auth / infra |
|---|---|---|---|---|
| Issue refinement | AI | AI | AI | AI |
| Question resolution | AI | AI | AI | **human** |
| Plan approval | AI | **human** | **human** | **human** |
| Implementation | AI | AI | AI | **human** |
| PR review | AI† | AI† | AI† | **human** |
| Merge | AI† | AI† | AI† | **human** |
| Deploy | AI (on merge) | AI‡ | **human** | **human** |

† **Review and merge without a human, and what it is conditional on.** Granted
2026-09-05. Both cells move together deliberately: merging without waiting for Nick *is*
reviewing without him, and a table that granted one and withheld the other would be
describing a gate nobody stops at. The checkers are the review.

I review and merge a PR on `website/`, `api/` or `mobile/` only when **all four** hold:

1. CI is green on the PR — which since #67 means the suites actually ran, not that someone
   remembered to run them;
2. `security-engineer` has reviewed the diff and reports nothing blocking;
3. `testing-engineer` has reviewed the diff and reports nothing blocking;
4. nothing in the change touches the **Always human** list below.

Any one missing and it stops for a human. A checker that cannot run is a failed
precondition, not an absent one — "the agent errored" is not "no findings".

**Why the checkers and not just CI**, stated because the temptation will be to drop them
for speed: in the review that immediately preceded this grant, #7 passed 216/216 on both
API paths and 204 mobile tests while `POST /auth/idp` still let an attacker inherit a
victim's account. The takeover, a silently dead Apple revocation path, and a wrong client
id were all found by a reviewer reading the diff. Two of the tests in that PR asserted a
bug was correct. Green suites did not catch any of it and would have merged all three.

So the thing that earned this cell is the maker/checker step, not the test count. Dropping
condition 2 or 3 does not make merging faster; it makes it mean something different.

‡ **Deploying the API, including re-running a failed deploy.** Granted 2026-09-05, after a
`Deploy API` run failed on a missing Secret Manager entry and sat failed for three days —
taking #6's password reset and activation with it. Production ran a revision from 2026-08-29
the whole time. Nobody decided that; it happened because the person who could press the
button did not know it needed pressing.

This mostly writes down what was already true. `Deploy API` triggers on push to `main`, so
merging an `api/` PR was already deploying it — the row used to say `human` while meaning
"no human presses deploy", which is not the same claim and read as more supervision than
existed. What actually stands between a merge and a bad revision is `Test API` gating the
deploy job (#67), plus the four conditions above, which apply to the merge that triggers it.

What this adds is the ability to **re-run a failed deploy and to trigger one**, which is the
operation that was missing. Cloud Run keeps the previous revision serving until a new one is
healthy, and a failed deploy changes nothing — so the downside of trying is a red run, and
the downside of not trying is what happened above.

Still human, and deliberately not covered by this: `mobile/` — a deploy there is a
TestFlight or App Store submission, which is public, slow to retract, and nothing about
re-running an API deploy implies it. And `rules / auth / infra`, which is not merely
withheld but **forbidden**: GUARDRAILS 7 makes `deploy-rules.yml` `workflow_dispatch`-only
and says adding any automatic trigger is a guardrail violation, and GUARDRAILS 6 makes
loosening rules fully supervised. That cell cannot move without changing a guardrail
first, which is a separate decision made deliberately and not in passing.

**Secret Manager stays on the Always-human list below.** Creating `eva-postmark-key` on
2026-09-05 was done on an explicit instruction for that one secret, not under a standing
grant, and one authorisation is not a policy. If that should change, change it here.

If the deploy gate ever needs to be real rather than nominal, the change is a
manual-approval environment on the deploy job, not a line in this file.

## Ratchet rule

A cell moves from **human** to **AI** only after that surface's verify command has
caught a real regression that a human would otherwise have missed. Coverage earns
autonomy; confidence doesn't.

Move it back the moment an agent PR ships a defect that verification should have caught.

That applies to the Merge row above with one addition: move it back if a defect ships that
**a checker should have caught**, not only one a test should have. The preconditions are
the coverage that earned the cell, so they are what the ratchet judges.

For the Deploy cell the ratchet is different, because deploying is not what finds
defects — merging is. Move it back if a *deploy* is what goes wrong: a bad revision left
serving, a failed run not noticed, or a deploy run on a merge that should not have been
merged.

## Always human, regardless of surface

- Loosening `firestore.rules` or `storage.rules`
- Anything touching `JWT_SECRET`, the Firebase web API key, or Secret Manager
- Adding a dependency
- Deleting data, or any change to the `users/{uid}` schema
- Changing an existing API error `code` (breaks the iOS client)
- Anything the issue didn't ask for

## Maker / checker

The agent that writes a change never reviews it. Implementation and review are
different agents, always — see `.claude/agents/`.
