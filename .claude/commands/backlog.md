---
description: Turn an explored idea into a structured GitHub issue
argument-hint: <idea or the conclusion of /explore>
---

Turn this into a durable backlog item — a GitHub issue someone (or an agent) can pick
up cold, weeks from now, without this conversation.

Input: $ARGUMENTS

## Rules

- If the idea hasn't been explored yet, explore it first (`/explore`). Do not write a
  spec from assumptions.
- One issue = one shippable change. If it doesn't fit, split it and say how the parts
  depend on each other.
- Acceptance criteria must be checkable by a command or an observation, not by opinion.
- Unknowns go in **Questions**. Never resolve an unknown by guessing.

## Issue body — use exactly these sections

```markdown
## Context
Why this matters and what the current state is. Link the files.

## Scope
**In:** …
**Out:** …

## Acceptance criteria
- [ ] Checkable statements — the command that proves each one where possible

## Risks
What could go wrong, and what verification would miss.

## Questions
What needs a human answer. Omit the section if there are none.

## Dependencies
Issues or work this needs first. Omit if none.
```

## Labels

Apply exactly one `area:` and one `state:` label.

- `area:api` · `area:mobile` · `area:website` · `area:infra` · `area:docs`
- `state:new` — captured, not yet refined
- `state:refining` — being investigated
- `state:needs-answer` — blocked on a human
- `state:ready` — spec complete, no open questions, safe to implement
- `state:implementing` · `state:review` · `state:done`

New items land as `state:ready` only if the spec is genuinely complete and no question
is open; otherwise `state:new` or `state:needs-answer`.

## Create it

```
gh issue create --title "<imperative, specific>" --body-file <file> --label "area:…,state:…"
```

Then print the issue URL and a one-line summary. Per `docs/AUTONOMY.md`, issue
refinement is AI-autonomous on every surface — you don't need approval to file it, but
you do need the spec to be honest about what is unknown.
