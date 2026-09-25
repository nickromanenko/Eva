# Incident response and breach notification

What to do when Eva's data may have reached someone it should not have: an intrusion, or
an ordinary mistake that disclosed it. Why it exists: `docs/LAUNCH.md` gate L8 and §7.
The FTC Health Breach Notification Rule and GDPR each start a clock at *discovery*, and a
clock nobody has written down is one that runs out while people work out who to call.

**Status: draft with placeholders (#90).** Every `{{…}}` is a name, address or number that
does not exist yet. Most wait on gate L1 (the entity), L3 (the privacy programme,
counsel) and the Article 27 representatives. A placeholder still here at launch makes this
document false. §10 lists them all.

**It is not legal advice.** Every sentence that states what a law requires is marked
*counsel*, as in `docs/LAUNCH.md`. Under A24 no counsel is retained. Each marked sentence is
a reading of the primary source named beside it, and it needs a lawyer licensed in that
jurisdiction to confirm it before anyone relies on it. The marker flags an open question.
It does not cite advice anyone has received. Nothing in this document decides whether a
particular incident has to be notified. §4 names who decides that.

**Agents.** Several containment steps touch `JWT_SECRET`, Secret Manager or the deletion of
data. `docs/AUTONOMY.md` puts all of those on the Always-human list, and an incident does
not change that. An agent may gather evidence, draft commands and draft notices. A person
runs the commands and sends the notices. No notice goes out without the sign-off in §4.

---

## 1. Roles and contacts

### 1.1 Roles

A role is a hat, not a headcount. Before launch one person may hold several, and the
document still names the role so that it can be handed over.

| Role | Holds it | Decides / does |
|---|---|---|
| **Reporter** | whoever notices first | Writes down T0 (§4.1) and pages on-call. Starts the clock. |
| **On-call** | `{{ON_CALL_PRIMARY}}`, backup `{{ON_CALL_SECONDARY}}` | First response: confirms or dismisses the report, preserves evidence, runs containment. |
| **Incident lead** | `{{INCIDENT_LEAD}}` (default: Nick) | Declares the incident and its severity, owns the incident record and the timeline, and assigns every other role. Approves every containment step that is on the Always-human list. |
| **Privacy lead / DPO** | `{{DPO}}` | Assesses risk to the people affected, decides with counsel whether each regime is triggered, and owns the GDPR breach register (§4.4). *counsel*: whether Eva must formally appoint a DPO (GDPR Art. 37(1)(c) — large-scale processing of Art. 9 data). |
| **Counsel** | `{{COUNSEL}}` | Every legal threshold in §3–§4: is it a breach, is it notifiable, where, by when, and the final wording of every notice. |
| **Comms** | `{{COMMS}}` | Sends notices once they are approved: users, media, the support inbox, the website. |
| **Product owner** | Nick | Signs off before any external notice goes out. |

### 1.2 Contact list

There is one row for each party in LAUNCH §2.5, plus the regulators the clocks point at.
**"Their clock confirmed"** records whether we have checked, in that party's signed DPA,
how fast it must tell us about an incident on its side. That delay counts against our
72 hours, because the clock runs from the moment *we* become aware. Today every cell in
that column is *no*.

| Party | Why | Contact | Account / reference | Their clock confirmed |
|---|---|---|---|---|
| Counsel | every §3–§4 decision | `{{COUNSEL}}`, `{{COUNSEL_PHONE}}`, `{{COUNSEL_EMAIL}}` | — | n/a |
| EU Article 27 representative | GDPR point of contact for EU supervisory authorities | `{{EU_ART27_REP}}` | `{{EU_ART27_REF}}` | n/a; not appointed (L1) |
| UK Article 27 representative | UK GDPR point of contact for the ICO | `{{UK_ART27_REP}}` | `{{UK_ART27_REF}}` | n/a; not appointed (L1) |
| Google Cloud / Firebase | database, API hosting, logs, Auth, Hosting | Cloud Console support case; `{{GCP_SUPPORT_PLAN}}` | project `{{GCP_PROJECT_ID}}` | **no**. Read the Cloud Data Processing Addendum's incident-notification term |
| Postmark | transactional email (address + link) | `{{POSTMARK_CONTACT}}` | server `{{POSTMARK_SERVER}}` | **no**. No DPA is recorded yet |
| LLM vendor (A5) | receives health data in prompts (LAUNCH §4.5) | `{{LLM_VENDOR_CONTACT}}` | `{{LLM_VENDOR_ACCOUNT}}` | **no**. Vendor not chosen |
| Food-database vendor (#25 Q10) | receives food queries | `{{FOOD_DB_VENDOR_CONTACT}}` | — | **no**. Vendor not chosen |
| Photo-recognition vendor (#25 Q11) | receives meal photos | `{{PHOTO_VENDOR_CONTACT}}` | — | **no**. Vendor not chosen |
| Apple | Sign in with Apple key, App Store | Apple Developer account `{{APPLE_TEAM_ID}}` | key `{{APPLE_KEY_ID}}` | **no** |
| GitHub | source, CI, Workload Identity trust | `{{GITHUB_ORG_OWNER}}` | repo `Eva` | n/a (holds no user data) |
| FTC | Health Breach Notification Rule | the FTC's online breach-notice form, `{{FTC_FORM_URL}}` | — | — |
| EU supervisory authorities | GDPR Art. 33 | via `{{EU_ART27_REP}}`; which authorities: §3.2 | — | — |
| UK ICO | UK GDPR Art. 33 | ICO breach reporting, `{{ICO_URL}}` | Eva's ICO registration `{{ICO_REG}}` | — |
| State attorneys general | state breach and health-data laws | `{{STATE_AG_LIST}}` (counsel compiles it) | — | — |
| Eva's own addresses | where people report to us | security `{{SECURITY_CONTACT_EMAIL}}`, privacy `{{PRIVACY_CONTACT_EMAIL}}`, support `{{SUPPORT_EMAIL}}` | — | — |

Incident channel: `{{INCIDENT_CHANNEL}}`. Incident records and evidence live in
`{{EVIDENCE_STORE}}`, with access restricted to the roles above. **They never go in
GitHub.** A GitHub issue for follow-up work may describe the fault. It may not contain a
uid, an address, a payload or a log excerpt that has any of those in it (GUARDRAILS 12).

---

## 2. What counts as an incident

Report anything below. Deciding whether it is a *breach* in any legal sense comes later
and is §4's job. The reporter's only question is "might someone have seen or taken data
they should not have?"

Everything Eva stores about a user is health data (GUARDRAILS 12). An incident that
reaches `users/{uid}`, its `events/`, `today/` or `nutrition/` subcollections, or a
vendor's copy of any of them, is a health-data incident by default.

### 2.1 Disclosures: nothing was hacked

The FTC rule counts **unauthorised disclosure** as a breach, not only intrusion (LAUNCH
§2.1). *counsel*: 16 CFR §318.2, "breach of security", as amended in 2024. Under GDPR,
Art. 4(12) likewise covers accidental disclosure. In practice these are the likelier
incidents for Eva:

| Incident | How it could happen here |
|---|---|
| **An export reaches the wrong person** | `GET /me/export` (#58) serves the caller's own account. A fault that served another account's data, or an export the user shared that support then handled carelessly. |
| **A mail goes to the wrong address** | An activation or reset link sent to an address that is not the account's. A reset link is a live credential for 60 minutes (GUARDRAILS 12a). |
| **A vendor misconfiguration** | Postmark, or the LLM or other vendors once they ship, logging or retaining content beyond what the DPA allows, training on it, or exposing a dashboard. Prompts are health data (LAUNCH §4.5). |
| **Health data in a log** | A log line that breaks GUARDRAILS 12. Everyone with log access in the project can read Cloud Logging. `EMAIL_TRANSPORT=log` running in production is the same fault, because it logs the link and the address (`api/src/email.ts`). |
| **A loosened rules file** | `firestore.rules` or `storage.rules` deployed with anything other than `if false`. A client SDK could then read Firestore directly. `everyAllowIsDenied()` and `needs: test` exist to prevent this (GUARDRAILS 6a). |
| **A wrong answer to a request** | Data handed to a requester outside `docs/REQUESTS.md` §3. REQUESTS.md's sources name this as a reportable event. |
| **A cache or proxy stores a response** | A health or session response stored somewhere shared. #280 made `no-store` the default, so this now needs a regression. |
| **A backup restored or copied to the wrong place** | Once #89 schedules backups (A23). |
| **A laptop or credential lost** | A developer machine holding `api/.env` or `api/.secrets/` (both gitignored, and never committed; GUARDRAILS 1). |

### 2.2 Intrusions

| Incident | What it reaches |
|---|---|
| **`JWT_SECRET` leaked** | Anyone holding it can mint a token for any uid they know. Every account's data is reachable through the API. |
| **One user's JWT stolen** | That account, through the API, until the token expires (`jwtTtlSeconds`, 30 days) or its `tokenVersion` is bumped. |
| **Runtime service account or ADC credential compromised** | The whole Firestore database directly, since the Admin SDK bypasses rules. Also Auth, and whatever else the account's IAM roles reach. |
| **CI / Workload Identity abused** | Whatever the deploy identity can do, which includes deploying an API that reads everything. |
| **Firebase Auth account takeover at scale** | Credential stuffing past the per-instance throttle (ARCHITECTURE §7). Each account taken over is a disclosure. |
| **Apple or Google provider key leaked** | Sign-in impersonation is limited by Firebase's own verification. Mostly a revocation and reissue problem, not a data exposure. |
| **Postmark API key leaked** | Mail sent as Eva (phishing users), and Postmark's message history, which holds the addresses and links it sent. |

---

## 3. The two clocks

### 3.1 What starts them, and who starts them

Both clocks run from **discovery**, not from when the incident happened or when it was
confirmed.

- **FTC (HBNR):** *counsel*. A breach is treated as discovered on the first day it is
  known, *or reasonably should have been known*, to Eva. Knowledge held by any employee,
  officer or agent, other than the person committing the breach, counts as Eva's
  (16 CFR §318.3(b) / §318.4, as amended 2024).
- **GDPR / UK GDPR:** *counsel*. The 72 hours run from when Eva "becomes aware": a
  reasonable degree of certainty that a security incident has compromised personal data
  (Art. 33(1); EDPB Guidelines 9/2022). A short investigation to establish that is
  allowed. Sitting on a report is not.

**Who starts the clock:** the **reporter**, at the moment of the report, by writing T0 into
the incident record. The **incident lead** may later move T0 *earlier*, if evidence shows
Eva knew or should have known sooner. Nobody moves it later. If there is doubt, the
earlier time stands, and counsel decides whether a later "awareness" point is defensible.
The clock is not started when counsel is reached or when the incident lead agrees. A clock
that waited for them would lose hours before anyone was accountable for it.

### 3.2 The deadlines

Every row is *counsel*. The timings are the reading in LAUNCH §2.1 and §2.3 of the sources
at the end.

| Regime | To whom | Deadline from T0 | Threshold |
|---|---|---|---|
| **FTC Health Breach Notification Rule** (16 CFR Part 318) | each affected individual | without unreasonable delay, **no later than 60 calendar days** | any breach of unsecured PHR-identifiable health information |
| | the FTC | ≥ 500 people: at the same time as the individual notices, within the same 60 days. < 500: logged, and reported within 60 days of the end of the calendar year | |
| | prominent media | within 60 days | > 500 residents of one state or jurisdiction; see §5.3, state of residence |
| **GDPR** Art. 33 | the competent supervisory authority, or authorities | **72 hours** where feasible. Later only with the reasons for the delay | unless the breach is "unlikely to result in a risk", which is hard to argue for Art. 9 health data |
| **GDPR** Art. 34 | each affected data subject | without undue delay | "likely to result in a high risk". Art. 34(3) lists exceptions |
| **UK GDPR** Art. 33 / 34 | the ICO; data subjects | 72 hours; without undue delay | same tests |
| **US state breach and health-data laws** | residents; some AGs | **varies, and some are shorter than 60 days** | *counsel* compiles `{{STATE_AG_LIST}}`. The FTC's 60 days is a ceiling, not the plan |
| **Washington My Health My Data Act** (RCW 19.373) | — | — | *counsel*. Whether MHMDA or Washington's general breach statute (RCW 19.255) reaches Eva's data, which carries no name, and on what clock. MHMDA's access-control duty may be breached by the incident itself, whether or not a notice is due |

Open points that change the plan, all *counsel*:

- **Which EU authority.** Eva has no EU establishment, so the one-stop-shop lead-authority
  mechanism is believed not to apply. The EDPB (Guidelines 9/2022, as updated in 2023)
  reads that as notifying **every** supervisory authority in whose member state affected
  people live. The Article 27 representative is the contact point for authorities. It is
  not a substitute notifier unless the mandate says so. `{{EU_ART27_REP}}`'s mandate has to
  say what it does in the first 72 hours.
- **Whether HBNR reaches Eva at all.** LAUNCH §2.1 treats Eva as a vendor of personal
  health records. Counsel should confirm it once.
- **"Unsecured".** Firestore encrypts at rest with Google-managed keys. That is believed
  not to make data "secured" against an attacker who holds a credential that reads it
  decrypted.
- **Processors' clocks.** Google's and Postmark's DPAs set how fast *they* tell Eva. That
  delay is eaten from the 72 hours. §1.2 records that none is confirmed.

### 3.3 Working backwards

Put these in the incident record the moment T0 is written. With T0 = hour 0:

| When | What must be done | Owner |
|---|---|---|
| **H+1** | Incident declared or dismissed, severity set (§6), evidence preservation started (§7) | on-call → incident lead |
| **H+4** | Containment in place or explicitly deferred with a reason. Counsel and the DPO engaged | incident lead |
| **H+24** | First scope estimate (§5): which regimes might apply, and the worst-case population | DPO + incident lead |
| **H+48** | Notifiability decision per regime, with reasons recorded. Draft Art. 33 notice ready | DPO + counsel |
| **H+72** | **GDPR/UK GDPR authority notice sent**, phased if facts are still arriving (Art. 33(4)), or the non-notification reasoning recorded in the register | DPO; sign-off Nick |
| **D+7** | Scope final or bounded, individual notice drafted, state-law list complete | DPO + counsel |
| **D+30** | Target for individual and state notices. This leaves 30 days' margin inside HBNR for the shorter state clocks | comms; sign-off Nick |
| **D+60** | **HBNR hard stop** for individual notices and the FTC (≥ 500) | comms |
| **D+30 after close** | Post-incident review published (§9) | incident lead |

---

## 4. Who decides what

### 4.1 T0 and the incident record

The reporter opens a record in `{{EVIDENCE_STORE}}` using the §9.1 skeleton, writes T0 (UTC)
and what they saw, and pages on-call. A report that turns out to be nothing is closed with
a sentence. It is still recorded, because Art. 33(5) wants breaches documented and a
dismissed report is evidence that the process ran.

### 4.2 Declaring

On-call confirms or dismisses within the hour. The **incident lead** declares the incident
and its severity. Declaring does not decide notification.

### 4.3 Notifiability

For each regime in §3.2, the **DPO** proposes and **counsel** decides whether it is
triggered, recording the reasoning either way. **Nick signs off** before any external
notice. If counsel cannot be reached before H+72, the DPO's proposal stands and the
authority notice goes out phased. *counsel*: a late notice with reasons is believed to be
better than a missed one.

### 4.4 The register

Every incident, notified or not, goes in the GDPR breach register kept by the DPO in
`{{EVIDENCE_STORE}}`: facts, effects, remedial action, and the reasoning behind each
notification decision (Art. 33(5)). This also serves as the HBNR log for breaches of fewer
than 500 people.

---

## 5. Determining scope from what Eva records

This section is why GUARDRAILS 10 and 12 matter here. Logs carry no health data and no
uid. Every collection has one owner, and it is the only code that writes it. So the
question "what could this have touched?" has a finite answer. The same property is also
the limit: logs that say little about users cannot say *which* users were affected.

### 5.1 What exists to read

| Source | What it records | Retention | Notes |
|---|---|---|---|
| **Cloud Run request log** (Cloud Logging, `eva-api`) | per request: time, method, **actual path**, status, latency, caller IP, user agent | `_Default` bucket, 30 days unless changed. *Confirm* | Holds no bearer token and no body. The path *does* hold what `route` in app lines deliberately omits: an event id at `/me/events/{id}`, and a date at `/me/body-signals/{date}`. It carries no uid, so a request cannot be tied to an account from this log alone. |
| **API log lines** (stdout → Cloud Logging) | JSON lines with an `event`: `unhandled_error` (`ref`, `method`, registered `route`, `errorName`), `request_timeout`, `email_send_failed`, `export_aborted`, `apple_revocation_failed`, `provider_signin_refused`, `provider_endpoint_unavailable`, `identity_toolkit_unavailable`, `credentials_unproven_after_activation` / `_after_reset`, `dashboard_unavailable`, `predictions_unavailable` | as above | By design none of them carries a uid, address, token or payload (GUARDRAILS 12). A spike in `unhandled_error` on one route, or `export_aborted`, can date a fault. The lines cannot name who was affected. |
| **Cloud Audit Logs: Admin Activity** | IAM changes, Cloud Run deploys and traffic changes, Secret Manager version creation, Firestore rules and index changes | 400 days, always on | The first place to look for a compromised deploy identity or someone else's changes. |
| **Cloud Audit Logs: Data Access** | *if enabled*, reads of Firestore documents and access to secret versions | *Believed off by default. Not confirmed for this project* | **If it is off, a direct read of Firestore with a stolen service-account credential leaves no record of which documents were read.** Enabling it is a pre-launch decision (§10) with a cost: the audit log then holds document paths, which contain uids. |
| **Firestore document timestamps** | `users/{uid}`: `createdAt`, `updatedAt`, `activatedAt`, `deletedAt`, `tokenVersion`. `events/`: `createdAt`, `updatedAt`, `deletedAt`. `today/`: `generatedAt`, `storedAt`. `nutrition/`: `createdAt`, `updatedAt`. `authTokens/`: `createdAt`, `expiresAt`, `usedAt`, `email` | live data | These record **writes**, not reads. They can show tampering, such as entries edited or deleted in a window, or a `tokenVersion` that moved. They cannot show exfiltration. The export deliberately omits them (ARCHITECTURE §4), so read them with admin access, not through the API. |
| **Firebase Auth** | account creation, last sign-in time, linked providers | live | Last sign-in per uid can date suspicious sign-ins. *Confirm* whether Identity Platform audit logging is available on this project's plan. |
| **Firebase Hosting log** | requests to the website, including `/activate` and `/reset`, but the token is in the fragment and never sent | *confirm* | Mostly useful for a website-side incident. |
| **Postmark activity** | each message: recipient, time, status, content | Postmark's retention. *Confirm* | This is the log for "a mail went to the wrong address". It holds links, so treat it as credential-bearing. |
| **GitHub Actions logs and audit log** | who ran which workflow, and when | 90 days for run logs by default | For a CI or Workload Identity incident. |
| **Secret Manager** | secret versions and their creation times. Access is only visible with Data Access logs | — | A version that nobody on the team created is itself evidence. |

### 5.2 How to bound the population

Take the widest reach of the compromised thing, then narrow it only with evidence that
actually excludes people:

| Compromise | Worst-case population | Can it be narrowed? |
|---|---|---|
| `JWT_SECRET` | every account that existed while it was exposed | Only if the attacker's forged requests can be separated in the request log by IP or user agent. They still cannot be mapped to uids. Assume all. |
| One stolen JWT | that one account | Yes, by definition. The window is from theft until the `tokenVersion` bump or `exp`. |
| Service account / ADC | the whole database, including `authTokens/` addresses | Only with Data Access logs. Without them, assume all. |
| Rules loosened | whatever the loosened rule allowed, for as long as it was deployed | The Admin Activity log dates the deploy. Reads through a client SDK are only visible with Data Access logs. |
| Wrong-account export | the account whose data was served | Only if the fault is understood well enough to say *which* account was served. The request log gives the time and IP, not the uid. |
| Mis-sent mail | the recipient address in Postmark activity | Yes, from Postmark. |
| Vendor misconfiguration | whatever Eva sent that vendor in the window | From the vendor's own records, and the vendor's answer is the evidence. |

### 5.3 What Eva cannot determine

Say these plainly in every notice and every register entry. Do not paper over them:

- **Which documents were read** through the Admin SDK or a client SDK, unless Data Access
  audit logs were on.
- **Which account a request log line belongs to.** No uid is logged, by design.
- **A person's name.** None is stored (REQUESTS §2.2). Notices can only address people by
  email.
- **A person's state or country of residence.** No location is stored, ever (REQUESTS
  §2.2). So the HBNR media threshold ("> 500 residents of a state"), each state's law, and
  which EU authority to notify **cannot be counted from Eva's data.** *counsel*: whether
  to assume every state and authority, or to infer from something weaker such as the App
  Store storefront or the time zone sent with `?timeZone=`, which is not stored.
- **Anything about a deleted account.** `DELETE /me` removes it all immediately (#8), and
  no backup exists yet (#89). Such a person cannot be told, because Eva holds no address
  for them.
- **Anything older than log retention.** Once the request log has rolled over, an old
  window cannot be reconstructed.

---

## 6. Severity

Severity sets how fast people move. The notification clocks in §3 are independent of it:
a SEV3 disclosure can still be notifiable.

| Sev | Meaning | Examples | Response |
|---|---|---|---|
| **SEV1** | Health data of many accounts exposed or possibly exposed, or an attacker still inside | `JWT_SECRET` or service-account compromise; rules loosened in production; ongoing unexplained access | Page on-call and the incident lead immediately, at any hour. Contain before diagnosing. |
| **SEV2** | Exposure bounded to a known small set, or a credential leaked with no sign of use | One account's token; a mis-sent reset link; a vendor misconfiguration with limited reach; health data found in a log line | Same day. Contain, then scope. |
| **SEV3** | Possible exposure, unconfirmed or with no personal data | A suspicious report; a secret leaked in a dead branch; a Postmark bounce anomaly | Next working day, but T0 is still written at report time. |

---

## 7. Evidence preservation

Preserve before you contain *when you can*. When the attacker is still active, containment
comes first. Record what was lost by doing it.

Owner: **on-call**, directed by the incident lead.

1. **Freeze the logs.** Cloud Logging's `_Default` bucket rolls over (30 days unless
   changed). Route the relevant window to a bucket with a locked retention
   (`{{EVIDENCE_LOG_BUCKET}}`, a log sink or a copy), covering the Cloud Run request log,
   the API's stdout lines, and the Admin Activity and Data Access audit logs. Record the
   filter used.
2. **Do not delete Cloud Run revisions.** A compromised revision is evidence. Route
   traffic away from it (§8.2) instead of deleting it.
3. **Disable secret versions, do not destroy them.** Secret Manager's *disable* keeps the
   version and its metadata. *Destroy* does not.
4. **Snapshot what changed in Firestore, not the database.** Record the `updatedAt` /
   `deletedAt` / `tokenVersion` of the documents in scope. A full export copies every
   user's health data into a new place and is a decision in its own right (incident lead
   and DPO). If point-in-time recovery is enabled, note its window, because that is the
   deadline for reading an earlier state. *Confirm whether it is enabled.*
5. **Pull vendor records while they still exist.** Postmark message activity for the
   window. For any other vendor, a written request for their logs, as their DPA allows.
6. **GitHub.** Export the relevant Actions run logs and the organisation or repository
   audit log. If a secret was committed, record the commit, then rotate. Removing it from
   history does not make the secret safe (ARCHITECTURE §6a).
7. **Write down every action** in the incident record, with the UTC time, who took it and
   why. The timeline is itself evidence, and the Art. 33 notice is built from it.

---

## 8. Containment

Each step names what it does to users, because several steps sign everyone out or take
something offline. Everything touching `JWT_SECRET`, Secret Manager, the Firebase web API
key or user data is Always-human (AUTONOMY). The **incident lead** approves each step and
**on-call** runs it. The commands are sketches to check against the current `gcloud` before
running them, not copy-paste.

### 8.1 Sessions

| Step | What it does | Cost | Owner |
|---|---|---|---|
| **Rotate `JWT_SECRET`.** Add a new version of `eva-jwt-secret`, then deploy a new `eva-api` revision so every instance reads it (`deploy-api.yml` binds `:latest` at deploy), then disable the old version | **Every session dies.** `auth.ts` verifies with one secret, so every outstanding token fails and the app's `sessionExpired` path (ARCHITECTURE §3, #76) signs every user out | Everyone signs in again. Password, Apple and Google credentials are untouched | on-call; incident lead approves |
| **Bump one account's `tokenVersion`** | That account's outstanding tokens are refused byte-for-byte as expired (#76). Other accounts are untouched | Only that user signs in again | on-call. **Gap:** there is no admin route or script for this. It is a hand edit of `users/{uid}.tokenVersion` (+1) in the console, which `bumpTokenVersion` in `users.ts` otherwise does in a transaction. File an issue for a script |
| **Force a password reset** | A reset bumps `tokenVersion` and ends every other session (#76) | The user has to act | the user, via `/auth/password/forgot` |

### 8.2 The API

| Step | What it does | Cost | Owner |
|---|---|---|---|
| **Route traffic back to a known-good revision.** `gcloud run services update-traffic eva-api --to-revisions={{GOOD_REVISION}}=100` | Stops a bad deploy from serving without deleting it (§7 step 2) | Loses whatever the bad revision added | on-call |
| **Stop serving entirely.** Remove public invocation, or set ingress to internal | The API refuses everyone. The app cannot read or write | Total outage. Only for an active SEV1 with no narrower lever | incident lead |
| **Stop the deploy path.** Disable `Deploy API`, `Deploy Website` and `Deploy Rules` in GitHub Actions, and remove the Workload Identity binding for the repository | Nothing new reaches production | No fixes ship until it is restored | incident lead |

### 8.3 Credentials and keys

| Credential | Where | Rotate by | Cost |
|---|---|---|---|
| `JWT_SECRET` | Secret Manager `eva-jwt-secret` | §8.1 | everyone signed out |
| `POSTMARK_API_KEY` | Secret Manager `eva-postmark-key` | new server token in Postmark, new secret version, redeploy, revoke the old token | activation and reset mail fails until redeployed (`email_send_failed`) |
| `APPLE_SIGNIN_KEY` / `APPLE_KEY_ID` | Secret Manager `eva-apple-signin-key`; repo variable `APPLE_KEY_ID` | **revoke the key in the Apple Developer account**, create a new one, update both, redeploy | Sign in with Apple, and Apple revocation at `DELETE /me`, answer `503` until redeployed (`provider_endpoint_unavailable`) |
| Google OAuth client | repo variable `GOOGLE_IOS_CLIENT_ID`; Google Cloud console | new client, update, redeploy, **and ship an app build** if the client id is baked into the app | Google sign-in down in between |
| Firebase web API key | repo variable `GCP_FIREBASE_WEB_API_KEY` | restrict or regenerate in the Google Cloud console, update, redeploy | every Identity Toolkit call fails until redeployed |
| Runtime service account | IAM | remove its roles or disable it. Rotate any user-managed keys (there should be none; ADC) | API down until a replacement is bound |
| Workload Identity (CI) | IAM pool / provider | remove the binding | CI cannot deploy |
| Link tokens | `authTokens/` | delete the unexpired rows in scope. **This deletes data: incident lead approves** | outstanding activation and reset links stop working. Users request new ones |

### 8.4 Data access

- **Firestore and Storage rules are deny-all by design** (GUARDRAILS 5). First confirm
  the deployed rules still say so, by comparing the console with the repository and
  checking the Admin Activity log for a rules release. If they do not, redeploy the
  repository's rules through `Deploy Rules`, which runs `everyAllowIsDenied()` first
  (GUARDRAILS 6a).
- **A vendor.** Suspend the integration: remove the key from Secret Manager, which the
  owning module then treats as unconfigured, and redeploy. Then send the vendor a written
  instruction under its DPA to contain and report.
- **Health data found in a log.** Restrict access to the bucket, then delete the entries
  once §7 step 1 has preserved what counsel needs. Deletion is Always-human. Fix the line in a
  PR that cites GUARDRAILS 12.

### 8.5 Eradication and recovery

Once contained: find the root cause, fix it in a PR (the normal process applies,
including the security-engineer checker), verify, then undo the containment steps that
cost users something, one at a time and in the record. Do not restore a service to the
state that failed.

---

## 9. Notification skeletons

Structure only. **The legal text of every notice is counsel's** (#90 scope). Each skeleton
lists the content the regulation is believed to require (*counsel*) and uses placeholders
for the facts. Nothing is sent without the §4.3 sign-off. Notices follow DESIGN.md §8's
voice where they speak to users: plain, specific, not alarming, not minimising.

### 9.1 Incident record (internal)

```
Incident {{ID}}
T0 (UTC):            {{T0}}        — reported by {{REPORTER}}
Declared:            {{TIME}} by {{INCIDENT_LEAD}}, SEV{{N}}
Clocks:              GDPR H+72 = {{T0+72h}}   HBNR D+60 = {{T0+60d}}   states: {{…}}
What happened:       {{…}}
Data in scope:       {{collections / vendor / categories}}
Population:          {{worst case}} → {{bounded, with evidence}}
Cannot determine:    {{from §5.3}}
Timeline:            {{UTC — who — action — why}}
Decisions:           {{regime — notifiable? — reasoning — counsel — date}}
Notices sent:        {{to whom — when — by whom — copy stored at}}
```

### 9.2 Supervisory authority: GDPR / UK GDPR Art. 33(3)

```
Controller: {{ENTITY}}, {{ENTITY_ADDRESS}}; Art. 27 representative {{EU_ART27_REP}} / {{UK_ART27_REP}}
Contact point / DPO: {{DPO}}, {{PRIVACY_CONTACT_EMAIL}}
(a) Nature of the breach: {{…}}; categories of data subjects {{…}}, approximate number {{…}};
    categories of records {{health data: cycle, symptoms, …}}, approximate number {{…}}
(b) Contact point for more information: {{…}}
(c) Likely consequences: {{…}}
(d) Measures taken or proposed, including mitigation: {{…}}
Awareness: {{T0}}. If later than 72 hours, reasons: {{…}}
Phased: {{yes — further information to follow by {{DATE}} / no}}
```

### 9.3 Affected people: HBNR and GDPR Art. 34

Sent by email, since Eva holds no postal address or name. *counsel*: whether email meets
HBNR's method requirement for each person, and whether in-app notice is also needed.

```
Subject: {{…}}
What happened, and when: {{date of breach}}, discovered {{date of discovery}}
What information was involved: {{specific types}}
Who received it, if known: {{identity of the third party, if known}}
What we are doing: {{…}}
What you can do: {{concrete steps — e.g. sign in again, reset password, what to watch for}}
How to reach us: {{at least two of: toll-free number {{TOLL_FREE}}, {{PRIVACY_CONTACT_EMAIL}},
                   {{WEBSITE_URL}}, in-app}}
```

### 9.4 FTC (HBNR)

Filed on the FTC's own form (`{{FTC_FORM_URL}}`). The form defines the fields, so no
skeleton is kept here. The record in 9.1 holds everything it asks for.

### 9.5 Media (HBNR, > 500 in a state)

```
{{ENTITY}} statement, {{DATE}}: {{the same facts as 9.3, without anything identifying any person}}
Contact: {{COMMS}}, {{…}}
```

### 9.6 Eva to a controller, if Eva is ever a processor

Not applicable today, because Eva processes only for itself. Recorded so the question gets
asked if a B2B arrangement ever exists (Art. 33(2)).

---

## 10. After the incident

**Post-incident review**, owned by the incident lead and written within 30 days of
closing:

- the timeline from T0, and how long each clock phase in §3.3 actually took;
- the root cause, and why the guardrail or test that should have caught it did not;
- what §5 could and could not determine, and whether a gap there (such as Data Access
  logs) should close;
- follow-ups as GitHub issues. Each one carries no uid, address or payload (§1.2);
- changes to this document, in the same PR as the fix where one exists (CLAUDE.md:
  update docs in the PR that makes them stale).

The review is blameless about people and specific about mechanisms. It lives with the
incident record in `{{EVIDENCE_STORE}}`, and a redacted copy goes in `docs/reviews/`.

**Rehearsal.** A runbook that has never been run does not work (#90 Risks). Before launch,
run one tabletop exercise, a mis-sent reset link, from T0 to the H+72 decision, and record
it in `docs/reviews/`. Repeat it `{{REHEARSAL_CADENCE}}`.

### 10.1 What has to be true before launch

This document is only true at launch if every item here is closed. The items are gate L8,
with dependencies on L1 and L3.

| Item | Closes | Depends on |
|---|---|---|
| Every `{{…}}` in §1 filled in with a real person or address | §1 | L1 (entity), L3 (counsel), the Art. 27 representatives |
| Each vendor's incident-notification term read from its signed DPA, and §1.2's last column updated | §3.2 | LAUNCH §2.5 DPAs |
| Every *counsel* marker confirmed or corrected, including the state-law list | §3 | L3. Under A24 there is no counsel. **Breach notification across the US, EU and UK is where a sourced product-owner reading is least safe.** Whether to retain breach counsel anyway is a decision for Nick, and this document does not make it |
| Decide whether to enable Data Access audit logs for Firestore and Secret Manager, weighing the uids they would then hold | §5.3 | — |
| Confirm log retention, and create the locked evidence bucket | §5.1, §7 | infra |
| Confirm Firestore point-in-time recovery, and schedule backups (#89) | §7 step 4 | A23 |
| A script to bump one account's `tokenVersion` | §8.1 | issue to file |
| One tabletop exercise | §10 | — |

---

## Sources

Primary texts to read before relying on any *counsel* marker. None of them has been
reviewed by counsel (A24). LAUNCH's Sources list the secondary summaries that §2 of that
document was written against.

- FTC Health Breach Notification Rule, 16 CFR Part 318, as amended by the final rule
  published 30 May 2024 (89 FR 47028). §318.2 (definitions, "breach of security"),
  §318.3 (breach discovery and timing), §318.4–§318.6 (notice to individuals, the FTC and
  media, and their content)
- GDPR (Regulation (EU) 2016/679): Art. 4(12) (personal data breach), Art. 9 (health
  data), Art. 27 (representatives), Art. 33 (notification to the supervisory authority),
  Art. 34 (communication to the data subject), Art. 37 (DPO)
- EDPB, Guidelines 9/2022 on personal data breach notification under GDPR (v2.0, 2023),
  including the paragraph on controllers not established in the EU
- EDPB, Guidelines 01/2021 on examples regarding personal data breach notification
- UK GDPR and Data Protection Act 2018; ICO guidance on personal data breaches
- Washington My Health My Data Act, RCW 19.373; Washington data breach notification,
  RCW 19.255
- The state list counsel compiles for §3.2 (`{{STATE_AG_LIST}}`), starting from LAUNCH
  §2.2's table
- Google Cloud Data Processing Addendum (incident notification); Postmark's DPA; each
  later vendor's DPA
- In this repo: `docs/LAUNCH.md` §2 and §7, `docs/REQUESTS.md` §2, `docs/ARCHITECTURE.md`
  §3–§4 and §6–§7, `docs/GUARDRAILS.md` 5, 6a, 10, 12 and 12a, `docs/AUTONOMY.md`
  (Always human)
