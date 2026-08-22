---
description: Investigate an idea against the codebase — no code changes
argument-hint: <idea, question, or issue URL>
---

Explore this idea. **Do not write or change any code.** The output is understanding,
not a diff.

Idea: $ARGUMENTS

## Do

1. Read the relevant written intent first: `docs/ARCHITECTURE.md`, `docs/DESIGN.md`
   (§9 drift matters for anything visual), `docs/GUARDRAILS.md`, and the PRD section
   this touches.
2. Read the actual code the idea would affect. Name files and line numbers.
3. Work out what already exists, what would have to change, and what it depends on.
4. **Challenge the assumptions.** State the ones the idea rests on, and say which you
   could not confirm. If the idea is wrong, or a smaller change achieves the same
   thing, say that plainly.

## Report

- **Context** — what's happening now, in this codebase, with references
- **What would change** — components, files, contracts
- **Constraints** — from the architecture, the guardrails, the autonomy policy
- **Risks** — what could go wrong, including what verification would not catch
- **Open questions** — what a human has to answer before this can be built
- **Recommendation** — build it as asked / build something smaller / don't build it

Keep it to what you actually verified. Mark anything inferred as inferred.

When the picture is clear, offer `/backlog` to turn it into a work item.
