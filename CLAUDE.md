# Eva

Eva — an AI assistant built for women: it accounts for physiology, hormonal cycle,
emotional state, habits and goals. iOS app + API + landing site.

**Read before changing anything:**

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the system fits together and why
- [docs/DESIGN.md](docs/DESIGN.md) — the implemented design system (tokens, components)
- [docs/GUARDRAILS.md](docs/GUARDRAILS.md) — hard rules; violating one fails review
- [docs/AUTONOMY.md](docs/AUTONOMY.md) — which decisions need a human
- [Eva app _ PRD v1.md](<Eva app _ PRD v1.md>) — product requirements

## Layout

| Folder | What | Stack | Local CLAUDE.md |
|---|---|---|---|
| `api/` | Backend API | Hono + Bun → Cloud Run | [api/CLAUDE.md](api/CLAUDE.md) |
| `mobile/` | iOS app | SwiftUI, iOS 18+, XcodeGen | [mobile/CLAUDE.md](mobile/CLAUDE.md) |
| `website/` | Landing site | Astro (static) → Firebase Hosting | — |
| `docs/` | Written intent + specs | — | — |
| `scripts/` | e2e and verification | — | — |
| root | Firebase config & rules | — | — |

## Commands

```sh
cd api && bun install && bun run dev        # API, http://localhost:3003
cd website && bun install && bun run dev    # site, http://localhost:4321
cd mobile && xcodegen generate && open Eva.xcodeproj
```

Verification — run the one for the surface you touched, before opening a PR:

```sh
cd api && bun run verify        # typecheck + tests (= scripts/verify-api.sh)
scripts/verify-mobile.sh        # xcodegen + build + UI tests (needs a simulator)
scripts/verify-website.sh       # astro build
scripts/e2e.sh                  # full stack against real Firebase (slow, creates accounts)
scripts/verify.sh               # everything above except e2e
```

## Conventions

- **Bun, not npm/node.** `bun install`, `bun test`, `bun run`.
- **Never edit `mobile/Eva.xcodeproj`** — it is generated. Edit `mobile/project.yml`,
  then `xcodegen generate`.
- The iOS app talks only to the Eva API, never to Firebase directly.
- No secrets in the repo. New env var → `api/src/config.ts` **and** `api/.env.example`.
- One issue → one branch → one PR. No direct commits to `main`.
- Stay in scope. Found something else broken? File it; don't fix it here.
- Update the docs above in the same PR that makes them stale.

## Working style

- Say what you actually verified and what you didn't. "Done" is a claim; a passing
  verify command is evidence for exactly what it covers.
- Prefer editing an existing file over adding one; prefer an existing component over a
  new one.
- Match the surrounding code — comment density, naming, idiom. Comments explain *why*,
  not *what*.
