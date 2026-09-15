# Requests for user data — law enforcement and third parties

**Decision A19 (2026-08-30):** Eva answers requests for a user's data only to valid legal
process, tells the user unless a court forbids it, and publishes how often it was asked.
This document is the policy that decision names. It is published in user-facing words at
`website/src/pages/transparency.astro` (`/transparency`), linked from `/privacy`, and one
sentence of it sits in the app's Privacy & security footer (`docs/DESIGN.md` §9a).

Why it exists: `docs/LAUNCH.md` §2.4. Since *Dobbs* (2022), period, pregnancy and
pregnancy-loss records have been sought in criminal investigations, and some US states now
forbid cooperating with out-of-state inquiries about care that is legal locally. Eva stores
exactly those records. What Eva can hand over, and to whom, is therefore a product property,
not a paragraph on the website.

**It is not legal advice.** Every sentence that asserts what the law requires or permits is
marked *(counsel)*. Under A24 there is no retained counsel: each such sentence is a
position the product owner has taken from the primary sources at the end, and it needs a
lawyer licensed in the relevant jurisdiction to confirm before it is relied on. A marker is
a flag, not a citation of advice received.

**The entity.** Gate L1 (`docs/LAUNCH.md` §0) is not started, so this document says "the
Eva entity" wherever the operator's legal name belongs. Until an entity exists there is
nothing to serve process on, and the address for service on `/transparency` is a
placeholder. Fill both in the same PR that records L1.

---

## 1. What this policy covers

Any request, from anyone other than the user herself, to see, copy, preserve or be told
about data Eva holds on an identifiable person. That includes:

- law enforcement and prosecutors, US and foreign, at any level of government;
- courts and parties to litigation — a subpoena in a civil case, a discovery request, a
  custody or divorce proceeding;
- private parties asking directly — a partner, a family member, an employer, an insurer,
  a school, a clinic;
- regulators, other than a request about Eva's own conduct that names no user;
- "emergency" or "exigent" requests made without process.

It does not cover the user's own access to her data (export, #58), a request she makes
about herself through support, or the processors Eva has under contract (§2.4).

## 2. What Eva holds

A request can only reach what exists. The data model is `docs/ARCHITECTURE.md` §4; this
section restates it as the categories a request could name, so that the response to any
request can be checked against it. If §4 changes, this section changes in the same PR.

### 2.1 Categories

| Category | Where | What a request could obtain |
|---|---|---|
| **Account** | `users/{uid}` | The email address; which sign-in providers are used (`password`, `apple.com`, `google.com`); whether and when the address was confirmed; when the account was created and last updated. During a deletion, a tombstone timestamp. |
| **Profile** | `users/{uid}.profile` | Only if the questionnaire was completed: age (date of birth once A8 lands), weight, height, goals, conditions, medications, lifestyle, sports. |
| **Calendar entries** | `users/{uid}/events/` | Every logged entry by type — `cycle` (flow), `bodySignals` (energy, mood, sleep, symptoms with severity), `sport`, `appointment` (with notes, uncapped) — each with the user's local date and time, a note, and whether the user or Eva created it. `sex`, and the pregnancy events (positive test, loss, delivery), join this list when their slices ship. An entry the user deleted stays here, marked, for up to 30 days (#28). |
| **Link tokens** | `authTokens/` | For each activation or reset link that has not yet expired: the email address it went to, when it was issued, and whether it was used. The token itself is stored only as a hash and cannot be recovered. |
| **Devices and notifications** *(planned, A3/A9)* | `users/{uid}/devices/`, `users/{uid}/notifications/` | A push token and the device's time zone; which reminders were scheduled, sent and read — a reference to what each pointed at, never its content. |
| **Backups** *(A23 — decided, not yet scheduled: #89)* | Firestore backups | **Nothing today.** `docs/ARCHITECTURE.md` §7: no Firestore backup is scheduled, so no category above survives leaving the live database. A23 decided daily backups kept 30 days; once #89 schedules them, anything above may persist for up to 30 days after it leaves the live database, and this row and §2.3 change with it. Backups are never selectively restored, for a request or for anyone. |
| **Processors** | outside Eva's databases | See §2.4. |

### 2.2 What Eva does not hold

- **No name.** Nothing stores a display name; Apple's and Google's name fields are not
  kept (`api/src/index.ts`, #7).
- **No location, ever.** No GPS, no coarse location, no geofence; the only region signal
  is the device region the app reads locally for units and emergency guidance.
- **No IP address in Eva's databases.** The sign-in throttle keys on IP in memory only
  and forgets it within its window (`api/src/rate-limit.ts`). Google Cloud's own request
  log for the API records the caller's IP, the path and the time of each request for
  Google's retention period; it carries no health data (GUARDRAILS 12) and no token
  (GUARDRAILS 12a), but it is a record Eva's operator can be compelled to produce and
  Eva's *(counsel)* review must treat it as in scope.
- **No provider refresh token.** Apple's is used once and discarded (#7).
- **No analytics or advertising SDK, no crash breadcrumbs** (A34). There is no
  third-party record of what a user did in the app.
- **No message history with Eva Chat** until A5 ships; when it does, what is retained
  and for how long is recorded here before the first release that keeps it.

### 2.3 What deletion does to all of this

`DELETE /me` removes the account, the profile, every calendar entry including the ones
inside their 30-day window, and every link token, immediately (#8). After it, Eva holds
nothing on the person except what a backup still carries. **Today that is nothing**: no
backup is scheduled (#89, `docs/ARCHITECTURE.md` §7), so a request arriving after a
deletion can be answered with nothing at all. Once A23's daily backups exist, such a
request can be answered only from a backup, and only while one carries the account.
*(counsel)* — whether a preservation demand can oblige Eva to hold a backup past its
rotation.

### 2.4 Processors

Eva's processors — Google Cloud (database, hosting, logs), Postmark (transactional email),
and, when they ship, the LLM vendor (A5), the food-database and photo-recognition vendors
(#25) — each hold what Eva sends them, under a data-processing agreement that binds them
to act only on Eva's instructions and to route any request they receive to Eva. Prompt
content sent to the LLM vendor is health data (LAUNCH §4.5). A processor served directly
with process it must obey is outside this policy's control; the DPA requires it to notify
Eva, and Eva then treats the request as its own under §4. *(counsel)* — the notification
and redirection duties each DPA actually imposes.

## 3. How a request must be served

1. **Valid legal process, served on the Eva entity.** A subpoena, court order or warrant
   that is valid where it was issued, names the Eva entity, and identifies the account it
   concerns. Nothing else is answered — not an email from an officer, not a letter on
   headed paper, not a phone call, not a request forwarded by a processor or a platform.
2. **Nothing on an informal request.** A request without process receives a copy of this
   policy and nothing else — including no confirmation that an account exists. A request
   from a private party (a partner, a relative, an employer, an insurer) receives the same
   answer; if they want data, they need process, and process is treated under §4.
3. **No voluntary disclosure, including on an "emergency" basis.** Eva does not hand
   over data because a requester describes the situation as urgent. US federal law
   *permits* a provider to disclose voluntarily in an emergency it believes in good faith
   involves danger of death or serious injury; it does not *require* it. *(counsel)* Eva
   chooses not to. The person who can act in an emergency is the user; the person best
   placed to reach her is not Eva.
4. **Non-US requests go through mutual legal assistance.** A foreign authority obtains
   data held by a US entity through a Mutual Legal Assistance Treaty request, letters
   rogatory, or an executive agreement under the CLOUD Act, each of which produces US
   legal process that §3.1 then covers. *(counsel)* Eva does not answer foreign process
   served directly.
5. **Valid US process cannot be refused.** A US entity that receives a valid subpoena,
   order or warrant must comply or challenge it; it cannot simply decline. *(counsel)*
   This policy is honest about that: what Eva controls is how narrowly it answers, whether
   it challenges, and whether the user knows. It does not promise to withhold what a
   court has validly ordered.
6. **Out-of-state and cross-jurisdiction inquiries.** Some states prohibit cooperating
   with out-of-state process concerning reproductive care that is legal in the state
   where it was provided (California AB 1242; Washington's shield law; others in LAUNCH
   §2.2). *(counsel)* Where such a law applies to Eva or to the process, Eva relies on
   it and does not answer. Which laws reach a company with no establishment in those
   states is a *(counsel)* question this policy does not settle.

## 4. What Eva does when one arrives

1. **Log it.** Date received, requesting authority or party, the kind of process, what it
   names, and the jurisdiction. This log is the source of the transparency report (§5)
   and holds no user data beyond the account identifier the process itself named.
2. **Review by the product owner.** Under A24 there is no counsel to route to; the
   product owner reviews the process against §3 and records the reasoning. The first
   request Eva ever receives is the moment to retain a lawyer for that request, whatever
   A24 says about the general case — the cost of one review is smaller than the cost of
   one wrong disclosure.
3. **Check validity before anything else.** Is it process at all (§3.1)? Is it served on
   the entity? Does it name an account Eva can actually identify — an email address, since
   Eva holds no name? Is it foreign process arriving directly (§3.4)? Is it barred by a
   shield law (§3.6)? A request that fails any of these is answered with this policy.
4. **Narrowest response.** Answer what the process names and nothing more. A request for
   "account records" does not receive calendar entries; a request for a date range does
   not receive the year. Overbroad process is challenged — a motion to quash or to narrow —
   before it is answered. *(counsel)* A preservation demand (a request to hold data
   pending process) is honoured for the period the law sets and no longer, and is itself
   counted in §5.
5. **Notify the user before disclosure.** Before answering, Eva tells the user what was
   requested, by whom, and what Eva intends to produce, at the address on the account,
   with enough time for her to seek to quash it herself. *(counsel)* The two exceptions:
   - a court order, a statutory non-disclosure order, or a national security letter
     forbids notification *(counsel)*; or
   - the account has been deleted and there is no address to reach.
6. **Notify after the bar lifts.** A non-disclosure order has a term. When it expires or
   is lifted, Eva notifies the user then, with the same detail. Eva asks the issuing court
   or authority to time-limit any order that has no term. *(counsel)*
7. **Produce in the least useful form the process permits** — a specific export, not
   database access; the named account, not the collection. Nobody outside Eva ever
   receives credentials, a backup, or a query interface.
8. **Record what was produced**, to whom, when, and whether and when the user was told.
   That record is what the transparency report is built from and what an audit reads.

## 5. The transparency report

Published at `/transparency`. It counts; it does not name.

- **What it counts:** requests received, by kind (law enforcement — US; law enforcement —
  non-US, including via MLAT; civil process; informal requests refused; preservation
  demands); how many were answered in full, in part, or refused; how many accounts each
  concerned; how many users were notified before disclosure, how many after a bar lifted,
  and how many could not be notified because an order still stands.
- **Cadence: twice a year**, in January and July, each covering the preceding six months.
  A report is published even when every count is zero. A missed update is a broken
  promise, so the cadence is deliberately the one a single product owner can keep.
- **Bands where the law requires them.** If a category may only be reported in a band
  (national security requests, for example), the report says so and uses the smallest
  band permitted. *(counsel)*
- **It starts empty.** The first entry states the date from which requests are counted —
  the day this policy was published — and that none had been received as of that date.
- **Warrant canary: none.** Eva does not publish a canary, because a statement whose
  removal is meant to signal something is a promise Eva may be legally unable to keep,
  and a promise Eva cannot keep is worse than none. *(counsel)* The report's counts are
  the only signal.

## 6. How to reach Eva

- **Service of process:** the Eva entity's registered address, published on
  `/transparency` once L1 is complete. Until then there is no entity to serve.
- **Questions about this policy:** the contact route on the website.
- **A user who has been contacted by someone claiming to hold her Eva data:** support,
  and this policy.

Eva does not accept service by email, and does not treat an email as process. *(counsel)*

## 7. What this policy changes in the product

Recorded here so the product changes are traceable to the decision, not to taste:

| Change | Where | Status |
|---|---|---|
| The footer sentence in Privacy & security | canvas `privacy` (#108); `docs/DESIGN.md` §9a | drawn; recorded in §9a by #91 |
| A "Requests for your data" row in Privacy & security, opening `/transparency` | canvas `privacy` (#108); PRD §Settings | drawn; a mobile issue when Settings ships |
| `/transparency` page with this policy and the report | `website/src/pages/transparency.astro` | #91 |
| A line in `/privacy` pointing here | `website/src/pages/privacy.astro` | #91 |
| Permanent deletion of the pregnancy timeline as its own action | PRD §Pregnancy loss 4 | **out of scope** — "offered separately, later"; its own issue |
| Storefront exclusions on account of this policy | A18 | none beyond China and Russia; revisit with counsel |
| Entity name and address for service | this document; `/transparency` | placeholders until L1 |

## Primary sources to read before relying on any *(counsel)* marker

Not consulted with counsel (A24). Statutes and agency text, not summaries, wherever a
marker above is confirmed or corrected.

- Stored Communications Act, 18 U.S.C. §2702 (voluntary disclosure — permitted, not
  required, in an emergency), §2703 (compelled disclosure and preservation), §2705(b)
  (delayed-notice and non-disclosure orders)
- National security letters, 18 U.S.C. §2709; reporting bands, 50 U.S.C. §1874
- Mutual legal assistance and foreign process: 28 U.S.C. §1782; the CLOUD Act (2018)
  and executive agreements under it
- California AB 1242 (2022) and the reproductive-health amendments in LAUNCH §2.2;
  Washington's 2023 shield law (HB 1469); the state list LAUNCH §2.2 asks *counsel* to
  confirm
- FTC Health Breach Notification Rule — an unauthorised disclosure is a breach; a wrong
  answer to a request is therefore a reportable event (LAUNCH §2.1)
- `docs/LAUNCH.md` Sources, for the state-law summaries this policy was written against
