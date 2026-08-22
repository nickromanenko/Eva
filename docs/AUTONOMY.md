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
| PR review | AI (+ spot-check) | **human** | **human** | **human** |
| Merge | AI | **human** | **human** | **human** |
| Deploy | AI (on merge) | **human** | **human** | **human** |

## Ratchet rule

A cell moves from **human** to **AI** only after that surface's verify command has
caught a real regression that a human would otherwise have missed. Coverage earns
autonomy; confidence doesn't.

Move it back the moment an agent PR ships a defect that verification should have caught.

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
