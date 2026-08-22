---
description: Take one approved issue from spec to pull request
argument-hint: <issue number or URL>
---

Deliver this issue end to end: $ARGUMENTS

You are the orchestrator. Specialists do the work; you keep the plan, the gates, and
the honesty.

## 1. Read

- `gh issue view <n>` — the issue is the contract. If it is not `state:ready`, or a
  Question is unanswered, stop and say so.
- `docs/ARCHITECTURE.md`, `docs/GUARDRAILS.md`, `docs/AUTONOMY.md`, and for UI work
  `docs/DESIGN.md` plus the screen's canvas.
- The code the issue names.

## 2. Check the gates before doing anything

Look up this issue's `area:` label in `docs/AUTONOMY.md` and state, in one line each:
who approves the plan, who reviews the PR, who merges. **If plan approval is human,
present the plan and wait.** Don't proceed and mention it afterwards.

## 3. Plan

Produce an ordered task table — this is the artefact a human approves:

| # | Task | Agent | Depends on |
|---|---|---|---|

Group tasks into implementation → tests → docs → verification. Assign each to
`api-engineer`, `ios-engineer`, `infra-engineer` or `testing-engineer`. Tasks with no
dependency between them can run in parallel; say which.

## 4. Branch and implement

- Branch from `main`: `<type>/<issue-number>-<slug>`. Never commit to `main`.
- Dispatch each task to its specialist. Parallel tasks that touch the same files run in
  separate worktrees.
- Commits are atomic and describe intent.

## 5. Verify — you, not the agent that wrote it

Run the verify command for every surface touched:

- `cd api && bun run verify`
- `scripts/verify-mobile.sh`
- `scripts/verify-website.sh`

Then the checkers, per the maker/checker rule — neither may have written the code:

- `testing-engineer` — what behaviour changed with no test, what test passes
  regardless, what acceptance criterion nothing verifies
- `security-engineer` — required for anything touching `api/`, auth, Firestore, rules
  or CI

Fix what they find, then re-verify. A blocking finding that you disagree with goes to
the human, not into the PR.

## 6. Pull request

Open a PR that states: what changed, which acceptance criteria are met and how each was
proved, what verification ran with its result, what is **not** covered, and
`Closes #<n>`. Set the issue to `state:review`.

Then follow the merge gate from step 2 — where it says human, stop there.

## Rules

- Stay inside the issue's scope. Anything else you notice becomes a new `/backlog`
  item, not a bigger diff.
- Update `ARCHITECTURE.md` / `DESIGN.md` in this PR if this change makes them stale.
- Report what you actually verified. "Done" is a claim; the verify output is evidence,
  and only for what it covers.
