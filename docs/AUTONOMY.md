# Eva — Autonomy Policy

Who approves what, per surface. This is the control panel: it is meant to change, but
only deliberately — never mid-task to unblock yourself.

**Legend** — `AI` = agent decides and proceeds · `human` = stop and ask Nick.

| Gate | `website/` | `api/` | `mobile/` | rules / auth / infra |
|---|---|---|---|---|
| Issue refinement | AI | AI | AI | AI |
| Question resolution | AI | AI | AI | **human** |
| Plan approval | AI | AI | AI | **human** |
| Implementation | AI | AI | AI | **human** |
| PR review | AI† | AI† | AI† | **human** |
| Merge | AI† | AI† | AI† | **human** |
| Deploy | AI (on merge) | AI‡ | AI‡ | AI‡ |

**Plan approval moved to `AI` for `api/` and `mobile/` on 2026-09-16**, on Nick's direct
instruction — like the Deploy row below, a decision rather than a ratchet advance. What it
changes in practice: `/goal` no longer stops to have a plan approved before implementing a
`state:ready` issue on those surfaces. What it does not change: `state:ready` still means
no Question is open, the Always-human list below still stops a plan that lands on it, and
the four merge conditions still gate the PR that comes out the other end. A plan nobody
approved still cannot merge itself.

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

‡ **Deploying, including re-running a failed deploy.** Granted for `api/` on 2026-09-05, after a
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

**The whole Deploy row moved to `AI` on 2026-09-16, on Nick's direct instruction.** Not by
the ratchet below — no verify command earned it — so it is recorded here as what it is: a
decision, revocable the same way it was made. Two carve-outs survive it, because they are
GUARDRAILS and this file does not overrule that one.

**Deploying a rules loosening moved with it**, and GUARDRAILS 6 was changed in the same
commit rather than left to contradict this table: it required human plan approval, human
review *and human deploy*, and now requires the first two. That is a real loosening of the
most sensitive surface in the repo, so what remains is worth stating plainly. Implementation
for `rules / auth / infra` is still `human`. "Loosening `firestore.rules` or
`storage.rules`" is still on the Always-human list below. So an agent still cannot *author*
the change it is deploying, and still cannot approve or review it — the cell grants the
button on a rules change **a human wrote and a human approved**, and nothing else.

**`deploy-rules.yml` stays `workflow_dispatch`-only.** GUARDRAILS 7 forbids adding any
automatic trigger to it, and that is untouched: what moved is *who may press the manual
button*, not whether the button can be replaced by a push. Reading the `AI` in that cell as
licence to add a trigger is a guardrail violation, and the workflow's own header says so.

**`mobile/` has no deploy mechanism yet.** There is no `deploy-mobile.yml`; a deploy there
is a TestFlight or App Store submission, made by hand. The cell is a statement of intent
until one exists. When it does, note that submission is public and slow to retract — the
Deploy ratchet below is the thing that judges it, and it is the row's only real brake.

**Secret Manager stays on the Always-human list below.** Creating `eva-postmark-key` on
2026-09-05 was done on an explicit instruction for that one secret, not under a standing
grant, and one authorisation is not a policy. If that should change, change it here.

If the deploy gate ever needs to be real rather than nominal, the change is a
manual-approval environment on the deploy job, not a line in this file.

## Ratchet rule

A cell moves from **human** to **AI** only after that surface's verify command has
caught a real regression that a human would otherwise have missed. Coverage earns
autonomy; confidence doesn't.

**Two rows were moved outside this rule on 2026-09-16** — Plan approval and Deploy, both on
Nick's direct instruction. The rule is not suspended and it is not rewritten to make those
moves look earned; it simply did not apply, because the owner of the control panel changed
it directly. It still governs every cell that moves for a reason other than being told to,
and it still governs all of them on the way back.

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
