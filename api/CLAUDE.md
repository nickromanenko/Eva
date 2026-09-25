# api/ — Eva API

Hono on Bun, deployed to Cloud Run as `eva-api`. Owns auth and all Firestore access.

Read [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) §2–§4 first — the API-mediated
auth decision explains most of the code's shape.

## Commands

```sh
bun install
bun run dev        # hot reload on :3003
bun run typecheck  # tsc --noEmit
bun test
bun run verify     # typecheck + test — must pass before a PR
bun run seed:refdata  # create any missing refdata/ catalogue (--relabel resets labels)
bun run retire:refdata  # apply the declared retirements (never deletes)
bun run purge:events    # delete events past their 30-day recovery window (--dry-run first)
bun run seed:content    # seed content/ — refuses until the copy carries a reviewer (#97)
```

Needs `api/.env` (copy `.env.example`) and Application Default Credentials
(`gcloud auth application-default login`).

`bun run verify` is **not** the strongest run any more. A handful of cases seed and assert
`content/`, which is safe against an emulator's throwaway Firestore and is not safe against
the real project — so they skip under `verify` and run under `scripts/ci-api.sh`, which is
what CI executes. A local green covers less than a CI green; run `scripts/ci-api.sh` too
before a PR that touches `content.ts`.

## Module boundaries — enforced by review

```
index.ts ──► auth.ts · identity-toolkit.ts · providers.ts · rate-limit.ts · users.ts
         ──► events.ts · today.ts · nutrition-profile.ts · refdata.ts · email.ts · email-tokens.ts
         ──► firebase.ts · config.ts
         ──► data-export.ts (leaf; `import type` only)

today.ts ──► events.ts · users.ts · nutrition-profile.ts · content.ts · dashboard-rules.ts · cycle.ts
```

- `index.ts` — routes, validation, HTTP mapping. **No Firestore, no outbound fetch.**
- `auth.ts` — JWT mint/verify + `requireAuth`. The only user of `JWT_SECRET`. It proves a
  token is ours and nothing more; whether the account still exists — and whether the session
  is still current (#76) — is `requireAccount` in `index.ts`, which is where both have to
  live because this file must not reach Firestore. `mintToken` therefore *takes* the token
  version rather than looking it up: every caller already holds it, from `ensureUser` or from
  the bump it just performed. `tokenVersionOf` reads an absent `tv` as `0`, which is the
  claim half of #76's migration — the document half is in `users.ts`, and the two absences
  have to agree.
- `identity-toolkit.ts` — the Firebase Auth account: password *and* provider credentials via
  Google REST (the only user of the web API key — the Admin SDK cannot verify either, which
  is why this exists), and `deleteAuthAccount` via the Admin SDK, which is the only place an
  Auth user is deleted. Two transports, one owner. `signInWithIdp` is the Apple/Google seam
  (#7): Firebase returns the uid it keyed to the provider's `sub`, which is what makes
  "identity is `sub`, and only `sub`" true by construction. Never add an email lookup to it.
  `federatedProvidersOf` answers which Apple/Google identities the Auth account holds *now* —
  the Auth half of every served `User.authProviders` (#117); see `users.ts` below for the
  other half. Also classifies every upstream failure as `email-exists | rejected | unavailable`;
  routes branch on that kind and never on Google's reason string, which must not reach a
  body, a header, or a log line (#32).
- `providers.ts` — the only two calls that go to Apple or Google *directly*, and the only
  user of `GOOGLE_IOS_CLIENT_ID` and the Apple keys (#7): Google's PKCE authorization-code
  exchange (public iOS client, no client secret) and Apple's token revocation for
  `DELETE /me` (an ES256 client secret signed with WebCrypto — no JWT library, and never
  `JWT_SECRET`). Every credential it needs is optional; unconfigured is a `503` on that one
  capability, never a boot failure, and never a failed delete. Writes no log line.
- `rate-limit.ts` — attempt counters behind the `/auth/*` throttle, and `DELETE /me`'s
  per-account one (#119: keyed by the token's uid, deliberately no per-IP dimension). In-memory, so the
  limit is per Cloud Run instance — the guarantee, and what would have to change to make
  it real, are written out at the top of the file and in ARCHITECTURE §3. It never sees
  whether an account exists, and it never logs a key (they are addresses and IPs).
  It also holds the two authenticated throttles: `consumeDeleteAttempt` for `DELETE /me` (#119),
  and `consumeExportAttempt` for `GET /me/export`
  (#58): per IP, then per **uid** — the account is the identity an export spends, and a uid
  joins the keys that are never logged.
- `users.ts` — the only module that touches `users/`. `markUserDeleted` stamps the
  tombstone that starts an account delete (#8): while it is set `getUser` answers `null`
  and `ensureUser` refuses to revive the document, which is what stops a deleted account
  coming back through a sign-in or through a pre-delete token.
  **`tokenVersion` is the account's session generation (#76)**, and `bumpTokenVersion` is
  the written-down rule for what ends a session — a password reset always, activation's
  claim path, a provider unlink when such a route exists; not a link, not a sign-in, not an
  ordinary write. Read that comment before adding a call site or leaving one out. It travels
  in `Account` beside the `User` rather than on it, because `GET /me` serves `User` verbatim
  and a session counter is not the client's business — the same reasoning that keeps
  `lastUserChangeAt` off that shape. Every reader gets it from a snapshot it was already
  loading: `getAccount` for the gate, `ensureUser` for the two sign-in routes.
  **It serves `UserRecord`, never `User` (#117).** `User.authProviders` is assembled per
  response by `servedUser`: `password` from the stored `authProviders` (`passwordChosen` — an
  Eva fact; Firebase also lists the random password a claim sets, so it cannot answer it),
  `apple.com`/`google.com` from `federatedProvidersOf`, handed in by the route. The federated
  entries in the stored array are **dormant**: still written by `ensureUser` so a rollback to
  the pre-#117 build keeps Apple revocation working, never read, never deleted (a human
  call). Do not start reading them again. A route that returns a `User` reads Auth beside its
  own Firestore call (`requireServedAccount` for `GET /me`); a route that does not must not
  read it at all.
- `events.ts` — the only module that touches `users/{uid}/events/`. Calendar entries:
  create, range read by `localDate`, edit, soft delete. Never log a payload — health data.
  `positiveTest` (#80) is the second fact stored here that **nothing reads**, and the first
  that is its own type rather than a field: a `CyclePayload` arm would have demanded flow on
  a day that has none, shared one one-per-day document with a spotting entry, and put the
  fact inside the only mapping `cycle.ts` reads. Its payload is empty and the route refuses
  every key on it, so there is no field for a later reader to start branching on.
  A soft delete is recoverable for `RETENTION_DAYS` (30) and then purged: `restoreEvent`
  is the Undo behind `POST /me/events/{id}/restore`, `purgeUserEvents` is the job behind
  the promise, driven by `scripts/purge-events.ts` (a script, not a route — ARCHITECTURE
  §4 "Retention" says why, and what a human still has to create for it to run).
  `deleteAllUserEvents` is the exception that proves the rule: account deletion takes
  soft-deleted entries too, because a recovery window inside a deleted account is a
  promise to nobody. `exportEvents` (#58) is the same rule on the read side: every stored
  entry, soft-deleted included, in `toEvent`'s shape, a page at a time ordered by document
  id — never by `localDate`, because an ordered query drops a document missing the field and
  an export may not lose an entry silently.
- `email-tokens.ts` — the only module that touches `authTokens/`. The tokens behind
  activation and password-reset links (#6): 32 random bytes handed out once, stored only
  as a SHA-256, single-use, spent in a transaction, each with its own TTL (24h / 60min).
  Issuing a reset token invalidates every unused one the account already has. A token issued
  before its account exists carries `uid: null` (#120), so `deleteTokensForAccount` can sweep
  by **address as well as uid** — a uid query alone cannot see the pre-account rows. The delete
  route always supplies the uid, but supplies the address only for a live account when Auth
  says it was proven, and bounds that sweep to rows created before deletion began. An
  unproven, movable address, a tombstoned retry, or an overlapping delete is not authority
  to delete the next holder's in-flight link (#139). Writes nothing to the console — a raw
  token or its hash in a log line is the link itself.
- `email.ts` — the only user of `POSTMARK_API_KEY`, and the only outbound mail. Postmark
  over REST with `fetch`, no SDK (GUARDRAILS 25). Two messages, no personalisation: a
  link, how long it lasts, and what to do if you did not ask for it. `EMAIL_TRANSPORT=log`
  prints the link instead of sending it — local only; `config.ts` refuses it under
  `NODE_ENV=production`.
- `refdata.ts` — the only module that touches `refdata/`. The client's option lists
  (symptom chips, sport activities, appointment types) with a content-hash `version`.
  Codes are permanent; options are retired, never deleted. Seed with
  `bun run seed:refdata` (see `scripts/seed-refdata.ts` for why a script, not a route);
  remove with `bun run retire:refdata`, which keeps the record of what went and why.
- `dashboard-rules.ts` — the Today card's priority ladder (#96, slice D1 of #10). A day's
  inputs in, the card's *subject* out: rung, template id, slot values, confidence wording
  class. **No text** — `content.ts` holds the words that template id resolves to — and no
  Firestore, no clock, no `fetch`: every input is passed in, `now` included. It is the only
  place a rung is chosen, so D3's card module and D9's phrasing take its output and never
  pick a different subject. Rung 2's thresholds (A32, #26) arrive as configuration and it
  throws `PatternRuleUnsetError` rather than answering without them; the ≥3-cycle gate and
  the irregularity band arrive as C11's own answers, so no number here can drift from the one
  the calendar draws. Its single import is an `import type` from `content.ts`, erased at
  compile time — see ARCHITECTURE §3 for why the vocabulary is shared and the module is not.
  **`CycleEstimate.irregularity` is a union, not a flag (#190)**, and rung 4 selects `home_c`
  for `cycles-vary` alone: that card says "Your recent cycle lengths vary significantly", and
  C11 also withholds for a spread resting on one interval it could not count — one missed
  period start, for six cycles — where the sentence is false. `uncountable-cycle` reaches no
  phase card and falls through to the educational one, because the card that would explain it
  is not drawn (#177). `speakablePhase` gates on `!== 'none'`, so a reason added later
  suppresses by default.
  **It also chooses the banner rail (`selectBanners`, #102, D7)**, beside the subject the rail
  must not repeat, and pure on the same terms. Filter, rank, cut, never pad: eligible is
  `active` + `mode` equal to today's **exactly** (the parser's `'any'` default is not a
  wildcard for a banner — an untagged row reaches no rail) + not tagged in `subjects` with the
  card's template id + a title, a meta line and an `https://` URL equal to its own
  `new URL(url).href` (what is served is exactly what was checked — a URL the parser would
  repair is refused, never normalised); ranked by how many of her
  focus areas a row carries, then `order`, then id; at most three, and fewer is fewer. **A row
  with no article is not served** — the tap opens the URL — so with every seeded `url` still
  empty, no environment shows a rail today. **The cycle phase is not an input**: no row carries
  a within-cycle phase tag, and #102 limits banner tags to topic, mode and focus area; that tag
  is the content reviewer's to add, and ranks below focus areas when it exists.
- `today.ts` — the only module that touches `users/{uid}/today/`: the Today card, one
  document per the user's local date (#98, slice D3 of #10). It is the *join* between the
  three modules above it — it gathers the ladder's inputs from `events.ts` and `users.ts`,
  asks `dashboard-rules.ts` for the subject, fills the template `content.ts` holds for that
  id, and caches the result. It is therefore the one module that calls sideways, and it does
  so through exported functions only; the reads it needed (`lastEventChangeAt`,
  `lastLoggedDate`, `lastUserChangeAt`) were added to the owning modules rather than
  performed here. ARCHITECTURE §3 says why the join has nowhere better to live.
  - **The banner rail is chosen once, with the card, and stored in the same document (#102).**
    `selectBanners` gets D1's `subject.templateId` — never the phraser's card — the mode, and
    focus areas only from a *finished* Nutrition setup (`complete`, i.e. `completedSetup`; PRD
    §Nutrition coach, nothing suggested from partial data). The stored items are copies —
    `{ id, title, meta, url }`, the routing tags left behind — so the rail is stable across
    opens and renders offline. `lastNutritionProfileChangeAt` is a third "her data moved"
    instant beside events and the profile, because the rail is built from it. Rows come from
    `getSignedContent`, which yields no banners at all for an unsigned document. A day stored
    before D7 is served `banners: []`, never back-filled on a refresh.
  - **The card's subject is not the phraser's to choose.** `Phraser` returns *text*; the
    stored card's `templateId` and `rung` are copied from D1's `Subject`, so neither this
    phraser nor D9's model one can name a different card (PRD §Dashboard: "the message
    subject is never free-generated"). `TemplatePhraser` also treats confidence as a
    **filter**, not a preference — a hedged subject cannot be rendered by plain copy — and
    drops any line whose slot has no value rather than showing `{category}` or inventing a
    placeholder.
  - **A refresh is not a change.** The stored document is returned untouched unless her own
    data moved after it was built; new copy in `content/` is deliberately not such a change.
    The comparison is against a stored `dataChangedAt`, not against `generatedAt` — see
    ARCHITECTURE §4 for why that distinction is the whole rule.
  - Never log a card, a slot value or a signal, and never the template id: which card a user
    was about to see is derived from her logs, so `late_period` in a log line is a health
    fact about a named request (GUARDRAILS 12).
  - **It re-exports the refusals `GET /me/today` answers 503 to**, and `index.ts` imports
    them from here rather than from `dashboard-rules.ts` and `cycle.ts` — which is what
    keeps the diagram above true. All three are reachable since #179: `CycleRulesUnsetError`
    was mapped one issue early (#181), because the day it became reachable is the day an
    unset `CYCLE_*` group turns a 503 into a 500, and that group is unset in every
    environment today. `today.test.ts` boots a server per arm, and pins separately that every
    exported refusal has one — so the next refusal added fails the suite until it is mapped,
    before anything can throw it.
  - **It is the seam the cycle maths is read through (#179), for both readers.**
    `cycleEstimate` hands
    `analyzeCycles` the logged `cycle` entries, the caller's local date and the profile, and
    projects the answer with `toCycleEstimate`; no gate, band or threshold is re-decided
    here. `cycleAnalysisFor` (#205) is the calendar's half: the same window, the same
    `toCycleDay` mapping and the same `analyzeCycles` call, returning the **`CycleAnalysis`**
    rather than D1's projection — `CycleEstimate` carries no `cycles` list, so "unusual
    length" and the fertile window's own dates cannot surface through it, which is why
    `GET /me/cycle/predictions` reads the analysis and the Today card reads the estimate. A
    second gathering path is the drift this one function exists to prevent; if a third reader
    appears it calls this, it does not re-read `users/{uid}/events/`.
    Two things in that mapping are load-bearing and neither fails loudly if dropped:
    `toCycleDay` carries #75's `periodEnd` mark, which `cycle.ts` is the one reader of, and
    the event read is widened to `(historyCycles + 2) × maxCycleLengthDays` days — derived
    from the constants, never a number — because a window shorter than the maths' own reach
    answers "regular" over a truncated history rather than failing. Body signals stay on rung
    2's much shorter span: a year of them is a year of health data in memory for no answer.

- `cycle.ts` — the cycle maths (C11, #176). Logged flow days in; the periods they group
  into, counted cycles, a next-period date, a fertile window and a confidence band out.
  **What one period is comes from `minPeriodGapDays` (#186)**: a run of logged days ends
  where that many days in a row carry nothing, so one missed tap is no longer two periods.
  It used to be — a period logged 1, 2, 4, 5 moved the anchor, the cycle day, the predicted
  date and the phase, and after #181 withheld the prediction outright behind a reason that
  was false (#180, #190). A logged spotting day still keeps a run open; only days with
  nothing logged are a gap. **The menstrual phase ends a period the same way (#197)**: the
  run is over once `minPeriodGapDays` days in a row carry nothing, today included. Ending it
  on the run's last *logged* day made a woman bleeding on cycle day 3 who had not logged that
  morning `follicular` — the one phase rung 4 speaks for — so she was told she was likely
  approaching ovulation and might train harder, which is #184's sentence reached through the
  phase instead of the rung. The other side of that trade is bounded by the same constant:
  never menstrual more than `minPeriodGapDays - 1` days past the last day she logged.
  This is also the **one reader of #75's `periodEnd`**, for one
  decision: whether a later flow day continues the period she marked as ended — within the
  gap the mark is stale and the period continues, at or beyond it a new period starts and
  the mark stands. Never an end date, a period length or a cycle length. **Pure, like
  `dashboard-rules.ts` and for the same reasons**: no Firestore, no clock, no `fetch`, no
  log line — `today` is an argument, and its two imports are `import type`. Every number it
  uses arrives in `CycleRules` from `config.ts` (A25–A27) and there is no default anywhere:
  `analyzeCycles` throws `CycleRulesUnsetError` rather than estimating, exactly as rung 2
  refuses without A32's thresholds. Every gate fails closed — under `minCyclesForEstimate`
  counted cycles, over the FIGO band for her age, or with her age unknown and the variation
  over the *tightest* band, there is no prediction and no window at all. An out-of-range
  cycle is excluded from the estimate **and still returned, flagged** `unusual-length`;
  dropping it from the output is the failure A25 names. **The median and the gate read
  different samples, deliberately**: the median takes the counted cycles only, so a 60-day
  interval cannot drag a predicted date, while the variation takes *every* interval between
  them, so that interval still closes the gate. A25 item 2's literal "over the last 6
  counted cycles" would hand a woman whose cycles alternate 28 and 60 days a fertile window
  over a variation of zero — the fail-open §Phase 1 rules 4 and 5 and #176's Risks each
  forbid. **That spread closes the gate on two different facts, and since #190 it names
  which**: `irregularity` is `none | cycles-vary | uncountable-cycle`, the last being exactly
  one interval in the window outside the countable range with her counted cycles inside her
  band. Both withhold — the gate is unchanged and the alternating case is still refused as
  `cycles-vary` — but only the first may be stated as a fact about her cycles, and it was
  being stated for six cycles after one missed period start merged two of them into 56 days.
  One, because two out-of-range intervals is FIGO's infrequent menstruation rather than a
  mislog, and erring toward `irregular-cycles` errs toward the reason whose card points at
  care. The *duration* of the suppression is deliberately unchanged and is pinned from both
  sides in `cycle.test.ts`: narrowing the gate to give that user her window back is the
  fail-open #181 closed, and #190's Scope puts the gate itself out.
  Age is read in `bandForAge` and nowhere else, which is what made #81
  (`profile.age` → `dateOfBirth`) one function's worth of change: the date arrives in the
  profile and the age is derived there, against the caller's own `today`. A date of birth it
  cannot read — nonsense, or one that makes her over 99 — is *unknown*, because the bands at
  both ends are the permissive ones and a corrupted value must never be trusted more than a
  missing one. **An age under 18 is the one exception and throws** (`ImpossibleAgeError`,
  #187): Eva is 18+ and `parseProfile` enforces it, so under the floor means a bug or a minor
  past the account check, and neither is a thing to clamp. It is deliberately not re-exported
  from `today.ts`, so it is a 500 through `app.onError` rather than one of the route's 503s —
  nothing about it resolves by retrying. `ageYearsOn` is the other half of #81 and the only
  other export: `parseProfile` reads it through `today.ts` so the floor and the band measure
  an age the same way, which they do not if each spells the arithmetic itself (29 February).
  `toCycleEstimate` projects the result into the `CycleEstimate` D1 already consumes.
- `nutrition-profile.ts` — the only module that touches `users/{uid}/nutrition/` (#221, S1 of
  #25): the Nutrition coach's setup answers — goal, focus areas (max 3), meal pattern, target
  weight, the hide-numbers preference (#212) — and the setup-progress marker `step`. **The
  field list is exactly those answers**: no disordered-eating field (#212), no "Meal fit"
  score (S8); the route refuses an unknown key rather than dropping it, and the test pins the
  key set. **`complete` is derived on every read, never stored** — `completedSetup` is the one
  definition (step `done` *and* every required answer present) and the only function that
  hands out a goal paired with its target weight, so a partial profile cannot feed the engine
  (PRD line 677). Goal codes are the engine's own `NutritionGoal` (`import type`); focus areas
  are permanent codes with a total `FOCUS_AREA_PRD_ITEM` table back to the PRD numbers the
  engine's fibre rule reads. `hideNumbers` changes only when a request names it, and it is
  **the hide-numbers preference's only home**: #252's `users/{uid}.nutritionQualitativeOnly`
  and `PUT /me/nutrition-settings` were retired by #283, and a value still stored on a user
  document is dormant — never read, never written, never deleted (a human call). Deleted by
  `DELETE /me` before the user document. Logs nothing. `lastNutritionProfileChangeAt` is
  `today.ts`'s regeneration signal (#102): the banner rail ranks by a finished setup's focus
  areas, so saving the profile is new data for the Today document.
- `nutrition.ts` — the nutrition targets engine (S2 of #25, #222). Her body metrics, goal,
  target weight and focus areas in; the day's calorie target, the macronutrient split, the
  clamp that bound the target and the timeline that follows from it out. **Pure on the
  strictest terms in this repo: it imports nothing at all**, not even an `import type`, so
  the source scan in its test file is an empty list. Every dose arrives in `NutritionRules`
  from `config.ts` and there is no default anywhere — `planDailyTargets` throws
  `NutritionRulesUnsetError` rather than estimating, and whatever route first serves a target
  maps that to a 503 in the same PR (#181's lesson; nothing serves one today).
  **It takes no cycle phase and no calendar mode**, which is what makes "cycle-agnostic" a
  property of the type rather than a claim in a comment: S12's luteal and mode adjustments
  wrap this module and cannot arrive as a `phase?:` parameter with a default. It does not take
  `Profile` either. `ActivityBand` is declared here as a closed four-member union and the
  factor table is a `Record` over it, so a band with no factor is a compile error; since #221
  `users.ts` re-exports this same array as `ACTIVITY_BAND_CODES`, `parseProfile` refuses
  anything outside it, and `Profile.lifestyle` is `ActivityBand | null` (null = a pre-#221
  label that matched none of the four, read — never rewritten — by `storedLifestyle`).
  `nutrition-profile.test.ts` scans `src/` for a factor lookup with a `??`/`||` fallback.
  **Every clamp is a floor on calories, never a cut**: PRD line 754's rate cap is expressed as
  the calories the cap leaves, so hitting it raises the target and lengthens the timeline
  (canvas `sRate`), and the timeline is derived from the *clamped* target so a target and a
  timeline cannot disagree. The two target-weight guards (A29's BMI 18.5 floor and the 15%
  per-plan cap) are **returned, not thrown**, each with the value to offer — and with one
  offered value that satisfies both rules, because an offer the guard would refuse is a second
  refusal. Goals 4 and 5 carry no `targetWeightKg` *in the type*. Writes no log line: a goal or
  a target weight in one is a health fact about a named request.
- `firebase.ts` — Admin SDK singleton. Never initialize a second app.
- `config.ts` — required env vars, fail-fast. It carries two imports that point *up* this
  list — `cycleRulesProblem` from `cycle.ts` and `nutritionRulesProblem` from `nutrition.ts` —
  so the range checks the boot refuses and the ones the maths refuses are one implementation
  rather than two copies that can drift. Both cost nothing at runtime: `cycle.ts` imports only
  types and `nutrition.ts` imports nothing.
- `data-export.ts` — the body of `GET /me/export` (#58). Pure leaf: the account (the served
  `User` from `requireServedAccount`, exactly `GET /me`'s — never the gate's `UserRecord`, #117), the
  nutrition profile (`getNutritionProfile`, read by the route before the headers, #221) and the
  page generators `exportEvents` (`events.ts`) and `exportTodayCards` (`today.ts`) in, a
  `ReadableStream` of one JSON document out, pulling the next page only when the response
  wants more bytes. Two properties are the design and each has a test: it reads the **first
  page of both collections before it returns**, so a Firestore down at the start is an
  ordinary `500` rather than a `200` with half a body; and it writes the closing `]}` last,
  so a body cut short by a later failure is never valid JSON. That failure errors the stream
  with a constant `ExportAbortedError` — Bun prints a stream's error, and Firestore's message
  can carry a uid — and hands the real one to the route's `onAbort`, which logs its class
  name only. What the export leaves out (session generation, cache bookkeeping, link-token
  hashes) is listed in ARCHITECTURE §4 "Data export".
- `request-timeout.ts` — the per-request timeout that names a hung request in the log before
  Bun's `idleTimeout` kills the connection (#225). Pure leaf: wraps the handler in a timer,
  reads no clock and no Firestore, and logs only the route path — no payload, address or
  token (GUARDRAILS 12).

## Rules

- Errors are always `{ error: { code, message } }`. Codes are a client contract:
  adding is fine, renaming is breaking. Current set: `VALIDATION`, `EMAIL_EXISTS`,
  `INVALID_CREDENTIALS`, `UNAUTHORIZED`, `NOT_FOUND`, `FUTURE_DATE_NOT_ALLOWED`,
  `BACKDATE_LIMIT_EXCEEDED`, `UNKNOWN_SYMPTOM_CODE`, `WEAK_PASSWORD`, `RATE_LIMITED`,
  `SERVICE_UNAVAILABLE`, `DAY_ALREADY_LOGGED`, `NOT_ACTIVATED`, `INVALID_TOKEN`,
  `TOKEN_EXPIRED`, `PROVIDER_ALREADY_LINKED`, `INTERNAL`.
- Every authenticated route carries `requireAuth, requireAccount` — the second is what
  makes a deleted account's still-valid token useless, and since #76 what makes a session
  superseded by a password reset useless too. `DELETE /me` is the one exception, so an
  interrupted delete can be retried with the same token — but it checks the token version
  by hand, because "a reset invalidates every session" cannot be false on the route that
  destroys the account. It checks only while a document still exists, so the retry (which
  happens after the tombstone) is untouched. It is throttled per account (#119,
  `RATE_LIMIT_DELETE_PER_ACCOUNT`) so one token cannot replay it for thirty days; the budget
  is several retries wide, and the route stays idempotent inside it.
- **Every body is read through `readBody` (#119).** Never `c.req.json()` in a handler.
  Absent or unparseable is `{}`; valid JSON that is not an object throws
  `BodyNotAnObjectError`, which `app.onError` answers `400 VALIDATION` without a log line —
  the one throw it recognises by class. `unhandled-errors.test.ts` lists every body-reading
  route; add a new one there.
- **`users/{uid}.email` is the Auth account's address, and no route mints a session on a
  document that says otherwise (#119).** `sameAddress` is the comparison; `/auth/idp`,
  `/auth/password/reset` and `/auth/signin` each refuse with the answer they already give a
  bad credential. `/auth/idp` compares with the Auth account (`addressOfAuthAccount`), never
  with `signInWithIdp`'s `email` — that is the provider's claim, and it legitimately differs
  for a linked relay — except on a first sign-in, where there is no document and the claim
  must equal the Auth address before one is written. Every check reads before anything is
  written. Refuse, never refresh. ARCHITECTURE §3 has the reasoning and the cost.
- **A password reset ends every other session (#76).** `POST /auth/password/reset` bumps
  `tokenVersion` **before** `setPassword`, deliberately: bump-then-fail signs everyone out
  and leaves the old password working, set-then-fail changes the password and leaves the
  attacker's session alive. Annoying beats insecure. It then mints the caller's new token at
  the new generation, which is the whole of how the device that performed the reset is kept
  signed in — it is identified by being the one the token is handed to, not by a device id
  this API does not have. A stale token answers exactly what an expired one answers; adding a
  code for it would be a client change for a state the client already handles.
- `app.onError` is the floor: any throw no route answered for is `500 INTERNAL` with a
  fixed message and a `ref`. Never the thrown error's text, in the body or the log —
  ARCHITECTURE §3 says why that is the point of it.
- Validate at the route edge (`normalizeEmail`, `parseProfile`), not deeper.
- Every behavior change gets a test in `test/`.
- **Every file that makes a live round trip sets `setDefaultTimeout(20_000)`** (#31) — every
  one of them, with no count written down here to go stale. A per-case timeout is **not** a
  substitute, because it does not reach a hook: that is how `email-tokens.test.ts` carried a
  timeout on all seventeen cases while its `afterAll` swept Firestore on the 5000ms default.
  A hook that times out is reported against an unrelated test *and* leaves its sweep
  unfinished, which is rows stranded in the real project on top of an unreadable red run.
  The suite
  runs against the real project, so a case that inherits Bun's 5000ms default is one cold
  connection away from a red run nobody can distinguish from a regression, which is how a
  suite that gates every merge teaches people to re-run instead of read. 20s is a ceiling,
  not a measurement: nothing honest reaches it, and a genuine hang still fails.
  `setDefaultTimeout` is file-scoped and does not override a per-test timeout, so a case
  that needs longer still says so where it is.
  - Bun names the two failures differently, and that is worth knowing before reading a red
    run: an assertion prints `error: expect(received).toBe(expected)` with both values; a
    timeout prints `^ this test timed out after 20000ms.` and no assertion at all.
- Never log passwords, tokens, profile contents, or event payloads (health data).
- New env var → `config.ts` + `.env.example` (placeholder only).
- No refresh tokens in v1. Adding them is an architecture change, not a task.
- **`POST /auth/signup` creates nothing (#120).** No Auth user, no document, no credential —
  it takes an address, issues an activation token and sends a link. `POST /auth/activate`
  takes that token **and a password** and creates the account, so the address is proven and
  the credential set in the same request. The invariant: *a password only works if the person
  who set it proved the address.* Sign-up used to create the Auth user with the caller's
  password, which reserved the address and put a working credential on it before anyone had
  proved it — the hole every defence below was written to live with.
  - It still answers `409 EMAIL_EXISTS` for an address whose owner is **activated**
    (ARCHITECTURE §3 says why sign-up discloses that deliberately). An unproven reservation is
    not ownership and does not block anyone.
  - A password in the body is **ignored, not refused**, so an un-updated client does not break
    outright.
- `POST /auth/signin` answers `403 NOT_ACTIVATED` for an unproven account, and that gate sits
  **after** Identity Toolkit has verified the password — answering earlier would tell any
  caller which addresses have Eva accounts. Since #120 the normal flow cannot reach it: there
  is no password before activation. It still guards accounts predating #120 and addresses
  reserved directly at Identity Toolkit. `/auth/activation/resend` and
  `/auth/password/forgot` answer `200 { sent: true }` for every well-formed address,
  registered or not, for the same reason.
- **A valid activation link on an already-activated account is a dead link (#120).** It used
  to answer `200` idempotently, which was right while activation only stamped a flag. The link
  sets a password now, so honouring a stale one would turn every activation email anybody ever
  saw into a password-reset primitive.
- **This code never matches on email; Firebase does (#7).** `POST /auth/idp` acts on the
  uid `signInWithIdp` returns and performs no lookup of its own — never add one. Whether a
  shared address resolves to one account or two is the console's
  *"Link accounts that use the same email"* setting, and it is set to link. A relay address
  from Hide My Email matches nothing and so still creates a new account; joining that one
  to an existing account is `POST /me/auth/providers`, deliberate and authenticated.
- **`/auth/idp` claims an unproven account before it mints a session (#7).** Sign-up
  creates the Auth user before the address is confirmed, and the Firebase web API key is
  public, so anyone can pre-register an address and attach their own provider identity to
  it directly at Identity Toolkit. `claimUnprovenAccount` overwrites the password, unlinks
  every *federated* provider except the one that just signed in, and revokes refresh
  tokens. `password` is overwritten rather than unlinked — an account with no password
  provider has nothing for forgot-password to reset, and the two cannot be asked for in
  one `updateUser` anyway. It asks
  `adminAuth.getUser`, never `users/{uid}`, because the mirror cannot see an Auth user
  whose document was never written. Gated on `activatedAt` being null alone.
- **Unlinking is half of it; the address test is the other half.** Stripping defends only
  the ordering where the victim signs in first, and the attacker can always choose to go
  first — nothing is stripped when `password` and their own provider are the only two, and
  activation then disarms the claim forever. So on an account whose address nobody has
  proved (`emailVerified` false), the provider signing in must carry that account's own
  address (the fact that made Firebase merge it). The trigger is `emailVerified` and never
  "has a password": a password entry is derived, client-mutable, and set by this function's
  own write, and an attacker can point a federated-only account at a victim's address
  without ever attaching one. Otherwise `claimUnprovenAccount` returns `refused` and the route
  answers 401 **without activating**. Fails closed on a missing provider address; a fresh
  provider account has no password and never reaches that branch, so Hide My Email is safe.
  Removing any part of this re-opens an account takeover; ARCHITECTURE §3 walks it through.
- **Some refusals from Identity Toolkit arrive as a 200 (#7).** `needConfirmation` (an
  account already holds this address and the credential has not proved it owns it),
  `emailRecycled` (the provider reassigned the address to a different `sub`), and an MFA
  challenge all answer 200 with the *other* account's `localId` and **no `idToken`**. Two
  were found in consecutive review rounds, so `requireSignedIn` names those and then
  requires `idToken` on any sign-in response for the shapes not met yet. Both halves are
  needed — `emailRecycled` *does* carry a token — and it runs in **both** transports,
  `call` and `signInWithIdp`. Never read `localId` before it.
- **Proving an address retracts what was attached while it was not (#7).** `/auth/activate`
  and `/auth/password/reset` call `retractUnprovenIdentities` on the transition to activated
  — only the transition, so a deliberately linked provider survives a later reset — and
  **before** stamping `activatedAt`, because the stamp is what disarms the claim gate.
  Without it the `/auth/idp` claim is simply outwaited: an attacker attaches a provider to a
  reserved address and signs in the moment the real owner activates.
- **`markCredentialsProven` runs last, after `markActivated` — at every call site (#120,
  #127).** `emailVerified` is what turns off `claimUnprovenAccount`'s address test;
  `activatedAt` is what turns off the claim itself. Any window in which the first is set and
  the second is not is the one combination that claims unconditionally, so the account is
  created *without* `emailVerified` (`createAccountWithPassword`) and the flag is set at the
  very end. Failing the other way leaves an activated account with the merge-wipe still
  armed, which costs its owner a password on a later provider sign-in and is recoverable
  through reset. `/auth/password/reset` was the one exception until #127 — unexploitable
  there because it retracts first, and fixed anyway, because a stated invariant with a live
  counter-example is read as advice. Both call sites swallow a throw from this last step
  rather than failing a request whose real work is already done; each logs its own event
  (`credentials_unproven_after_activation`, `credentials_unproven_after_reset`) and nothing
  else (GUARDRAILS 12).
- **A link proves its own address, never a uid's later address (#140).** Reset compares the
  token's address with the current Auth address before changing the password; a mismatch is
  a dead link. Both activation and reset then pass that token address to
  `markCredentialsProven`, which writes the address and `emailVerified` together. That
  closes the narrower race after the comparison: an earlier concurrent move is restored to
  the proved address, and a later move clears the flag again. Eva has no address-change
  route; the supported recovery from a mismatch is a fresh link for the current address.
  The issue's “no new round trip” premise was stale: reset previously held only the token's
  values, not the current Auth address. The one authoritative lookup must precede the
  password write, because detecting a mismatch afterwards is already too late.
- **Both paths through `/auth/activate` share one set of guards.** The `email-exists` race
  and the ordinary "account already exists" branch both fall through the same
  `deleted` / `activated` refusals and the same tail. They were separate once, and the race
  branch skipped both — two unspent links for one address could overwrite each other's
  password.
- **`markCredentialsProven` is called from both the reset route and activation (#120).** It
  sets Firebase's `emailVerified`, which Identity Toolkit also uses to decide whether to wipe
  `passwordHash` on a merge. Activation withheld it under #7, deliberately, so that wipe
  stayed armed against a pre-registering attacker's password — the subtlest call in that
  issue. #120 removes the reason: the only credential an account can have at activation is
  the one supplied in that same request by whoever proved the address.
- **`/auth/idp` reads before it writes (#7).** `ensureUser` unions the provider into the
  stored `authProviders`, so calling it before the claim gate left a refused credential's
  provider on a stranger's document — which is what the app read to decide whether to offer
  "Connect Apple". Use `readUser` to decide, `ensureUser` only once the claim says
  `claimed`. Since #117 the served federated entries come from Auth, where a refused identity
  stays linked; it still never reaches the owner, because a refusal mints nothing and leaves
  the account unactivated, and every path to a session on an unactivated account
  (activation, reset, a successful claim) unlinks federated identities first. Read the
  federated half of a response **after** any step that changes Auth — the claim, the
  retraction, the link — never beside the read that precedes it.
- A provider session comes back already activated, stores no display name, and adds no
  field to `users/{uid}`.
- CORS is on exactly the two routes the website's link pages call (`/auth/activate`,
  `/auth/password/reset`), for exactly `config.publicWebOrigin`. Never `*`, never a third
  route: an allowed origin is a page that can spend a token it was handed.
- **A link token never travels in a URL.** Both link routes are POST with the token in the
  body, and the emailed link carries it in the fragment (`#token=`), which browsers do not
  send. A query string would put a live credential into Cloud Run's and Hosting's request
  logs. Do not add a `GET` convenience route.

## Style

Arrow-function consts, no semicolons, single quotes, 2-space indent, 100-col-ish.
`interface` for exported shapes, `type` for unions. Explicit return types on exported
functions. Match `src/users.ts` if unsure.

The above is enforced, not remembered: `biome.json` holds it and
`bunx biome format --write src test scripts` applies it. It is the single source of truth —
the prose here is a summary; if they disagree, `biome.json` wins and this paragraph is the
bug.
