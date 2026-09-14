# Launching Eva in the US and worldwide — what has to be true

**Decision A16 (2026-08-30):** launch in the United States and on every App Store storefront
Eva is not excluded from. English only; no localisation in v1. Supersedes A2 (EU + UK).

This document lists what must exist, be decided, or be changed before that launch is
possible. It is written from the product as specified in `Eva app _ PRD v1.md` after #69
and the decisions in `docs/reviews/2026-08-30-prd-and-design-review.md` §8: iOS only,
18+, paid subscription with a trial, everything in the PRD is v1.

**It is not legal advice.** Every item marked *counsel* is a statement of what the law
appears to require as of the sources at the end, and needs a lawyer licensed in the
relevant jurisdiction to confirm before it is relied on. Several sources are law-firm
summaries, not the statutes.

---

## 0. The gates, in one table

A gate is something launch cannot happen without. Everything else in this document is a
consequence of one of these.

| # | Gate | Owner | Status |
|---|---|---|---|
| L1 | A legal entity, an Apple Developer Program **organisation** account, and the Paid Apps agreement (tax + banking) signed | Nick | not started |
| L2 | Regulatory position written down: Eva is a *general wellness* product under FDA's January 2026 guidance and outside EU MDR / UK MHRA scope — with the product lines that keep it there (§1) | #26 clinician + *counsel* | #26 open; US scope not yet in it |
| L3 | Privacy programme for consumer health data: policy, consent flow, rights handling, breach procedure, vendor DPAs, data map (§2) | *counsel* + api/mobile | nothing exists; website privacy page is a placeholder |
| L4 | A law-enforcement / third-party request policy for reproductive-health data (§2.4) | Nick + *counsel* | policy written (A19, #91: `docs/REQUESTS.md`, `/transparency`); its *counsel* markers unconfirmed (A24); entity placeholders until L1 |
| L5 | App Store readiness: guideline conformance, age rating, privacy labels, subscription terms, storefront list, export compliance (§3) | mobile + Nick | partly (account deletion #8/#55 done; Sign in with Apple #7 open) |
| L6 | Product changes the markets force: English variant, locale units, country-aware emergency guidance and appointment types, food-database coverage, vendor processor locations (§4) | product + api + mobile | decisions listed in §6 |
| L7 | Content sign-off by clinicians credentialled for the primary market, and a claims register for everything the website and the app assert (§5) | #26 | not started |
| L8 | Operational: backups, incident response that can meet a 60-day (FTC) and 72-hour (GDPR) clock, support that works across time zones (§7) | infra | no backups, no runbook |

---

## 1. Regulatory: staying a wellness product

### 1.1 United States — FDA

FDA's *General Wellness: Policy for Low Risk Devices* guidance of 6 January 2026 (superseding
2019) says the agency does not intend to enforce device requirements on products that are
intended solely for wellness use and are non-invasive, pose no safety risk, are **not
intended for diagnosis, mitigation, prevention or treatment of disease**, do not substitute
for a cleared device, **do not guide clinical management**, and **do not output values that
mimic clinical values unless validated**. Menstrual and fertility tracking apps are explicitly
within the population the guidance addresses.

What that means for Eva, feature by feature — the PRD already draws most of these lines;
the point is that they are now *regulatory* lines, not tone preferences:

| Feature | Keeps Eva in wellness | Would take it out |
|---|---|---|
| Cycle predictions, fertile window | Shown as estimates with confidence; "not a contraceptive method" at the point of use (PRD §Phase 1) | Presenting the window as contraception or conception guidance with stated efficacy |
| Body signals, red-flag escalation | Deterministic "contact your provider" card (PRD §Calendar Other requirements 5); no model interpretation | Interpreting symptoms, grading severity, telling the user what a symptom means |
| Eva Chat | A5: no symptom interpretation | Any answer that reads as diagnosis or triage |
| Nutrition targets | General healthy-eating guidance for a healthy adult | Targets framed as treatment for a declared condition (diabetes, anaemia, PCOS) — PRD §Nutrition Other requirements 5 already forbids inferring; this extends to *treating* |
| Pregnancy mode | Dating and week counters as information; due date labelled "estimated" | Gestational-age outputs that mimic a clinical dating scan; anything that guides antenatal management |
| Nutrition score | A meal descriptor, per #25 Q1 | A number that mimics a clinical value |
| EPDS / mood screening (well-being coach, postpartum) | **This is the closest to the line.** A validated screening instrument with an escalation path is arguably clinical decision support | Scoring EPDS and acting on the score — *counsel* and #26 decide whether it ships |

Actions:
- **L2:** extend #26 to a US assessment under the 2026 guidance; the output is a one-page
  intended-use statement and the table above as a claims register, kept in the repo.
- Add to `docs/GUARDRAILS.md`: no feature may output a value that mimics a clinical
  measurement or guide clinical management; every prediction carries its confidence and
  its limits at the point of use. (Today §8 of DESIGN.md says this for copy; it needs to
  bind features.)
- App Store 1.4.1 asks medical-adjacent apps to *disclose data and methodology* behind
  accuracy claims — the "How this is calculated" sheet (Nutrition canvas) and the
  fixture-driven cycle maths (A11) are the mechanism; both must exist at submission.

### 1.2 EU and UK

Unchanged from A2: EU MDR and UK MHRA scope must be assessed by #26. The same product lines
apply. Nothing in A16 removes this — EU and UK users are still customers.

### 1.3 Elsewhere

No country-by-country device assessment for v1. The wellness position, if it holds in the
US and EU, is the position everywhere; storefronts where that is known not to hold are
excluded (§3.4).

---

## 2. Privacy law: consumer health data

Eva is not a HIPAA covered entity (it is not a provider, plan or clearinghouse). That does
**not** mean it is unregulated. The relevant regimes, in rough order of how much they change
the product:

### 2.1 United States — federal

- **FTC Act §5** — unfair or deceptive practices. The two enforcement actions that define
  this space are both period trackers: *Flo Health* (2021) and *Premom / Easy Healthcare*
  (2023), both for sharing health data with third parties (analytics, advertising SDKs)
  against their own privacy statements. The product implication is blunt: **no third-party
  SDK that sees health data, no advertising SDK at all**, and the privacy policy must be
  literally true.
- **Health Breach Notification Rule** (amended May 2024, in force since late July 2024) —
  explicitly covers health apps. "Breach" includes **unauthorised disclosure**, not only
  hacking; a data-sharing mistake is a breach. Notification to individuals *and* the FTC
  **within 60 days** of discovery (and to media for ≥500 people in a state).
- **COPPA** — not applicable at 18+ (A12), provided age is actually enforced (DOB gate).
- **CAN-SPAM** — for the transactional and any marketing email (#6).

### 2.2 United States — states

Twenty comprehensive state privacy laws are in force in 2026, and a growing set of
health-specific ones. The ones that change what Eva *builds*, not only what it writes:

| Law | What it requires of Eva | *counsel* |
|---|---|---|
| **Washington My Health My Data Act** (in force 31 Mar 2024) | A separate **consumer health data privacy policy**; **opt-in consent to collect** and a **separate, distinct consent to share** health data; a stand-alone authorisation for any sale; access / deletion / withdraw-consent rights with a 45-day clock; a ban on geofencing near health facilities. It applies to anyone whose data is collected *in* Washington, so it is effectively national for a consumer app. | applicability, private right of action |
| **Nevada SB 370** | Near-identical to Washington; need-to-know access controls. | |
| **Connecticut** (PA 23-56 + 2026 amendments) | Opt-in consent for consumer health data; applies to non-profits too. | |
| **California** CCPA/CPRA | Health data is *sensitive personal information*: purpose limitation, data minimisation, right to limit use, access, deletion, opt-out of sale/sharing; a "Do Not Sell or Share" mechanism even if Eva never does. AB 352 and related reproductive-health amendments restrict cooperation with out-of-state inquiries. | whether CMIA reaches Eva |
| Others (IL, NY, MA, NJ, NM, DE, DC, …) | Reproductive-health data laws with varying scope | list to confirm |

Practical consequence: build to the **strictest** (Washington) once, everywhere. That is one
consent screen with two separate opt-ins, one health-data privacy policy, one rights
mechanism, and no sharing at all outside processors under contract.

### 2.3 EU, UK and the rest of the world

- **GDPR / UK GDPR** — health data is Article 9 special-category data: **explicit consent** as
  the lawful basis, a DPIA (mandatory for large-scale health processing), records of
  processing, a **72-hour** breach clock to the supervisory authority, and — because Eva has
  no EU establishment — an **Article 27 representative** in the EU and another in the UK.
  Transfers to Google Cloud `us-central1` rely on the EU–US Data Privacy Framework plus SCCs;
  Google's certification covers it, the DPA must say so. Right of access and **portability**
  make #58 (export) a legal requirement, not a canvas nicety.
- **EU Accessibility Act** (applies from 28 June 2025) — covers e-commerce services offered
  to EU consumers, which a paid subscription app plausibly is. WCAG 2.1 AA is the practical
  bar; DESIGN.md §9a already works to it. *counsel* on applicability.
- **Brazil LGPD, Canada PIPEDA + Quebec Law 25, Australia Privacy Act, Japan APPI, South
  Korea PIPA, India DPDP Act, Switzerland nFADP** — all reachable with the GDPR baseline plus
  local notices; none is expected to change the product. Korea and Quebec have their own
  consent-form requirements worth a *counsel* check.
- **China (PIPL) and Russia** — data-localisation regimes that Eva's single-region
  architecture cannot meet. **Recommend excluding both storefronts in v1** (§3.4).

### 2.4 Reproductive-health data and third-party requests

This is the part that is specific to what Eva stores. Since *Dobbs* (2022), period, pregnancy
and pregnancy-loss data have been sought in criminal investigations in some US states, and
some states (California among them) now *prohibit* cooperation with out-of-state inquiries
about care that is legal locally. The design consequence is not a policy document alone;
it is what Eva can and cannot hand over:

1. **Data minimisation is the defence.** Store nothing Eva does not use. No IP retention
   beyond the rate limiter's window (`rate-limit.ts` already keys on it in memory only);
   no location ever; no analytics events that carry health data (GUARDRAILS 12 for logs
   needs an analytics twin).
2. **Deletion must be real and prompt.** It is (#8, immediate and complete). The 30-day
   soft-delete window for *entries* (#28) is a retention decision to re-state in the
   policy; #50's "not really recoverable" edge is a truth-in-copy issue.
3. **A written request policy** (L4): requests are accepted only through legal process
   served on the entity; non-US requests require MLAT; users are notified unless legally
   barred; a transparency report is published. This is the one the *Flo* and *Premom*
   settlements did not cover and the one users in the US now ask about first.
   **Written (A19, #91): `docs/REQUESTS.md`**, published at `/transparency`; the report
   is twice a year, January and July.
4. **Pregnancy-loss and positive-test events are the most sensitive records in the
   system.** PRD §Pregnancy loss already hides rather than deletes; the request policy
   decides whether Eva offers *permanent* deletion of the pregnancy timeline as its own
   action (the PRD says "offered separately, later").
5. **The privacy copy** must say exactly this. A10 already settled the encryption sentence;
   the request policy needs its own sentence in the app, not only on the website. It
   has one: the second sentence of the canvas `privacy` footer, recorded in
   `docs/DESIGN.md` §9a (#91).

### 2.5 What has to exist — the artefacts

| Artefact | Where | Depends on |
|---|---|---|
| Consumer-health-data privacy policy (WA-compliant) and general privacy policy | website `/privacy`, linked from sign-up | *counsel* |
| Terms of service incl. subscription terms, medical disclaimer, 18+ | website `/terms` | *counsel* |
| **Consent screen** in onboarding: two separate opt-ins (collect / share), withdrawable in Settings | canvas + mobile + `users/{uid}` (always-human schema gate) | L3 |
| Rights mechanism: access + export (#58), deletion (#8 ✓), withdraw consent, 45-day SLA | api + Settings | #58 |
| Breach-response runbook with the 60-day / 72-hour clocks and contact lists | `docs/` | L8 |
| Data map and DPIA | `docs/` | — |
| DPAs: Google Cloud, Postmark (#6), the LLM vendor (A5), the food-database vendor (#25 Q10), the photo-recognition vendor (#25 Q11), Apple | legal | vendor choices |
| EU and UK Article 27 representatives | legal | L1 |
| Law-enforcement request policy + transparency page — **exists** (#91): `docs/REQUESTS.md`, `/transparency` | website + `docs/` | L4; entity name and address for service wait on L1 |

---

## 3. App Store

The guidelines were last updated 8 June 2026; the numbers below are the ones that bind a
health app selling a subscription. Verify each against the current text at submission.

### 3.1 Guidelines that bind Eva

| Guideline | Requirement | State |
|---|---|---|
| **1.4.1 Physical harm / medical** | Medical-adjacent apps get extra scrutiny; disclose data and methodology behind accuracy claims; inaccurate data is a rejection | "How this is calculated" sheet, A11 fixture, "not a medical device" footer |
| **5.1.1(v)** | In-app account deletion | done (#8, #55) |
| **5.1.1(ix)** | Apps in highly regulated fields (health) should be submitted by the **legal entity**, not an individual | L1 |
| **5.1.3 Health and health research** | Health data may not be used for advertising or sold; no false or misleading health information; HealthKit rules (n/a, A15) | no ad SDKs ever |
| **4.8 Login services** | If the app offers Google sign-in, it must offer an equivalent privacy-preserving option — Sign in with Apple satisfies it | #7 |
| **3.1.1 / 3.1.2** | Subscriptions through IAP only; the paywall must show price, duration, auto-renewal, and link to terms and privacy; free-trial terms clear | A14 — paywall screen is undesigned |
| **2.1 / 2.3** | Complete, accurate metadata; demo account for review (a seeded test account, not a real user) | e2e account pattern exists |
| **5.1.2** | Data use and sharing must match the privacy labels | privacy nutrition labels |

### 3.2 App Store Connect items

- **Age rating**: the questionnaire will land on 17+ for "Medical/Treatment Information" and
  "Mature/Suggestive" (sex logging) — consistent with 18+ (A12); Apple has no 18 tier.
- **App privacy labels**: Health & Fitness, Contact Info, Identifiers, Purchases; all
  "linked to you"; none used for tracking. Must match §2 exactly.
- **Export compliance**: the app uses only Apple-provided TLS → exempt; set
  `ITSAppUsesNonExemptEncryption = NO` in `project.yml` so every build does not prompt.
- **Category**: Health & Fitness (not Medical).
- **Pricing**: one base price; Apple equalises across storefronts. Local taxes are Apple's.
- **Review notes**: what Eva is and is not (wellness, not medical), the demo account, how
  to reach Pregnancy mode without waiting nine months.

### 3.3 Localisation of the store listing

None (A16). One English listing is served on every storefront. Apple allows this.

### 3.4 Storefronts

175 available. Recommended v1 list: **all, except** China mainland (PIPL localisation),
Russia (data localisation), and any storefront Apple itself does not serve. Countries under
US sanctions are removed by Apple. Whether to also exclude jurisdictions where menstrual /
pregnancy data carries specific criminal-procedure risk is a **decision (A18)** — the
question is whether Eva can make the L4 policy hold there.

---

## 4. Product changes the markets force

These are changes to what is built, not to paperwork.

### 4.1 Which English (decision A17 — open)

The canvas is British English throughout: *anaemia, hot flushes, gynaecologist, GP, midwife,
programme, colour*. The US is the largest single market and iOS's default locale. Options:

- **US English everywhere** — largest market, Apple default; the canvas copy is re-read
  once. *Recommended.*
- **UK English everywhere** — no copy change; reads as foreign to most US users.
- **Two variants (en-US, en-GB)** — this *is* localisation, which A16 excludes.

Whichever is chosen, clinical role names should be **neutral** rather than translated:
"your provider", "your doctor" rather than *GP* / *OB-GYN*.

### 4.2 Units, dates, numbers

- Units default from the device locale (imperial for `en_US`), overridable in Settings (A2
  item 3 stands). Nutrition Step 4 already expects both systems.
- Dates and times use the locale formatter; the PRD's `12 August` examples become
  `August 12` in the US automatically if the code formats rather than hard-codes.
- Height/weight input in imperial needs feet+inches and pounds entry, not a unit toggle on
  a single field.

### 4.3 Country-aware content

| PRD requirement | v1 answer under A16 |
|---|---|
| Emergency guidance is region-aware (§Calendar Other requirements 7) | A per-country table of the emergency number and the wording for urgent maternity care, covering the top English-speaking storefronts (US, UK, IE, CA, AU, NZ) with a **neutral fallback** ("contact your maternity provider or local emergency services") everywhere else. Country comes from the device region, changeable in Settings. |
| Appointment timeline template per region (§Phase 2) | Exists **only** where content has been clinically reviewed for that country (US ACOG-style schedule; UK NHS schedule). Elsewhere: no template, the user enters her own. |
| Appointment types (refdata) | The catalogue is server-configurable (#24); the labels *GP* and *Midwife* are UK-shaped. Either neutral labels for all, or a per-country catalogue. **Decision** (part of A17). |
| Well-being / postpartum support resources (§Pregnancy loss 5) | Per-country list for the same top storefronts; neutral fallback elsewhere. |
| Clinician sign-off (§Calendar 8, §Nutrition 4) | Reviewers credentialled in the **primary** market (US: MD/DO and RD/RDN); content written to avoid jurisdiction-specific advice so one review serves all storefronts. |

### 4.4 Food database (#25 Q10, re-answered for A16)

The PRD requires a *licensed* database whose coverage matches the launch markets, and warns
that barcode fails otherwise. Worldwide coverage changes the answer:

- **Open Food Facts** — ~3M products, 200+ countries, the largest barcode set; strongest in
  France, Germany, UK, US. Free under the **ODbL** — attribution required, and any
  *database* derived from it must be shared alike. Eva's per-user meal logs are not a
  derived database; an enrichment queue that improves OFF records (PRD §Nutrition Edge
  cases 2) should feed back upstream. *counsel* on ODbL scope.
- **USDA FoodData Central** — US branded foods with GTIN/UPC, free, authoritative for the
  primary market.
- **Commercial fallback** (Nutritionix ≈ $1,850/mo, Edamam ≈ $299/mo, FatSecret on contract)
  for restaurant and US-branded items OFF misses.

Recommendation: OFF + USDA as the base, one commercial provider on a metered plan for
misses, and the PRD's "barcode not found → queue for enrichment" behaviour aimed at OFF.
Data-processor implications: none of these receive user data beyond a barcode or a query
string — but a query string is a food the user ate; the DPA still matters.

### 4.5 Vendors that receive health data (A5, #25)

The LLM (A5) receives cycle phase, symptoms, meals and goals; the photo-recognition vendor
receives meal photos. For every such vendor: a DPA, **no training on user data** (PRD
§Nutrition Other requirements 3 makes this a product promise), zero or minimal retention,
and a processing location Eva can name in the privacy policy. Prompt content is health data
under every regime in §2.

### 4.6 Consent and the first-run flow

The Washington rule (§2.2) and GDPR Article 9 both want explicit, separate, withdrawable
consent *before* collection. That is a screen the canvas does not have, between
activation and the first log, and a stored, timestamped consent record on `users/{uid}`
(always-human schema gate). It is the single largest undesigned screen this launch adds.

### 4.7 Website and marketing claims

- **Testimonials for an unlaunched product** ("Women who stopped guessing") are a §5 FTC
  problem and must go until they are real and substantiated.
- "Science-backed" and every specific health claim on the landing page needs a source in
  the claims register (L7). The FTC's health-claims substantiation standard is *competent
  and reliable scientific evidence*.
- `/privacy` and `/terms` are placeholders that the sign-up screen already links to.
- The website is static (Astro) and sets no cookies today — keep it that way and no cookie
  banner is needed in the EU.

### 4.8 Payments

Apple handles tax, currency and price display. Eva's obligations: the paywall content in
§3.1, a "Manage subscription" row that deep-links to Apple's management page (A14),
restore-purchases, and an entitlement check whose location is still open (review §8).
Nothing in v1 requires a payment processor of Eva's own.

---

## 5. Content and clinical sign-off for a worldwide English product

- One body of content, reviewed once, written so it is true in every market: describe
  physiology, not health-system pathways ("your provider may offer a scan around 20 weeks"
  rather than "your 20-week NHS anomaly scan").
- Reviewer credentials for the primary market (US) plus a UK reviewer for the NHS
  appointment template if it ships.
- The **claims register**: every sentence in the app or on the website that asserts a health
  fact, with its source and reviewer. This doubles as the 1.4.1 "methodology" disclosure and
  the FTC substantiation file.
- The Blog (§Blog) is the natural home for the sources; the register says which article
  backs which claim.

---

## 6. Decisions this document needs

| # | Decision | Recommendation |
|---|---|---|
| A17 | English variant and clinical-role wording | US English; neutral role names ("your provider") |
| A18 | Storefront exclusions beyond China and Russia | None in v1; rely on L4 and data minimisation, revisit with counsel |
| A19 | Law-enforcement / third-party request policy — legal process only, user notification, transparency report | **Decided 2026-08-30: all three** (review §8, third round). Written in `docs/REQUESTS.md`, published at `/transparency`, one sentence in the app (#91). Non-US requests via MLAT are part of "legal process only"; the report is twice a year. |
| A20 | Does the EPDS ship in v1, given §1.1? | Defer EPDS; ship the well-being check-in as a non-scored prompt until #26 rules |
| A21 | Consent model: one consent screen with two opt-ins (WA-strict) applied worldwide | Yes — one flow, strictest rule |
| A22 | Food database: OFF + USDA base, one metered commercial fallback | Yes, subject to ODbL check |
| A23 | Backups and retention: daily Firestore backups, retention period, and the entry soft-delete window as policy | Daily backups, 30-day retention, document both |

---

## 7. Operational readiness

- **Backups.** Nothing schedules a Firestore backup today. A daily backup schedule with a
  stated retention is a one-time infra act (always-human).
- **Incident response.** The breach clocks in §2 (60 days FTC, 72 hours GDPR to the
  authority) need a runbook, a contact list, and someone on call. Logs already carry no
  health data (GUARDRAILS 12), which makes the *scope* of a breach determinable.
- **Single region.** `us-central1` is fine for a v1 worldwide launch; latency to APAC is
  tolerable for a logging app. Firestore location is immutable — moving later is a
  migration, so say so in ARCHITECTURE.md §7.
- **Support.** Email-based, with a help centre; response-time promise stated in the terms.
  Time zones matter for the 45-day rights clock, not for support.
- **Status and uptime.** No NFRs exist (review P6); a subscription product needs a stated
  availability target and a status page before charging.
- **Email.** Postmark (#6) with SPF, DKIM and DMARC on the sending domain; the domain itself
  (`evatracker.com` in #6, `evaapp.dev` in the e2e tooling) is a decision.

---

## 8. What changes in the existing docs and issues

| Where | Change |
|---|---|
| PRD §Product frame → Markets and language | A16 supersedes A2 (done in #69 / PR #70) |
| PRD §Product frame → Open | Add: English variant (A17), storefront exclusions (A18), request policy (A19), consent model (A21). A19 is decided and written (#91); the PRD's Open list carries only the legal texts still unwritten |
| `docs/GUARDRAILS.md` | Add: no third-party SDK that can see health data; no advertising SDK; no analytics event carries health data; no feature outputs a value that mimics a clinical measurement |
| `docs/ARCHITECTURE.md` §7 | Add: single-region trade-off; no backups yet |
| #26 | Add the US assessment (FDA 2026 wellness guidance, EPDS question); add US-credentialled reviewers |
| #25 | Q10 re-answered: worldwide coverage → OFF + USDA + fallback (A22) |
| #58 | Export is a GDPR portability / CCPA access obligation, not only a canvas feature |
| #7 | Sign in with Apple is also App Store 4.8 compliance, since Google sign-in is offered |
| New issues | Consent screen + consent record on `users/{uid}`; country table for emergency guidance and support resources; imperial input controls; paywall + Manage-subscription; backups; breach runbook; request policy page; website claims clean-up; `ITSAppUsesNonExemptEncryption` |

---

## Sources

Consulted 2026-08-30. Law-firm summaries are secondary sources; statutes and agency pages are primary.

- FDA, *General Wellness: Policy for Low Risk Devices* (Jan 2026) — via [Faegre Drinker](https://www.faegredrinker.com/en/insights/publications/2026/1/key-updates-in-fdas-2026-general-wellness-and-clinical-decision-support-software-guidance), [Covington](https://www.cov.com/en/news-and-insights/insights/2026/01/fda-issues-revised-guidance-on-general-wellness-products), [Troutman Pepper](https://www.troutman.com/insights/fdas-2026-guidance-on-general-wellness-devices-policy-for-low-risk-devices/), [Arnold & Porter](https://www.arnoldporter.com/en/perspectives/advisories/2026/01/fda-cuts-red-tape-on-clinical-decision-support-software)
- FTC, [Health Breach Notification Rule — business guidance](https://www.ftc.gov/business-guidance/resources/complying-ftcs-health-breach-notification-rule-0) · [2024 amendments](https://www.ftc.gov/business-guidance/blog/2024/04/updated-ftc-health-breach-notification-rule-puts-new-provisions-place-protect-users-health-apps) · [Federal Register final rule](https://www.federalregister.gov/documents/2024/05/30/2024-10855/health-breach-notification-rule)
- Washington My Health My Data Act — [Goodwin](https://www.goodwinlaw.com/en/insights/publications/2024/03/alerts-technology-hltc-my-health-my-data-act-mhmda), [Stoel Rives FAQ](https://www.stoel.com/insights/publications/faq-washington-states-my-health-my-data-act), [Benesch](https://www.beneschlaw.com/insight/reminder-washingtons-my-health-my-data-act-now-in-effect/)
- State reproductive-health data laws — [Nixon Peabody](https://www.nixonpeabody.com/insights/alerts/2024/01/31/state-privacy-trends-in-reproductive-health), [Epstein Becker Green](https://www.ebglaw.com/insights/publications/usa-health-data-laws-state-privacy-laws-relating-to-reproductive-health-and-to-children), [ArentFox Schiff on California](https://www.afslaw.com/perspectives/health-care-counsel-blog/california-adopts-privacy-protections-digital-reproductive), [Troutman Pepper](https://www.troutman.com/insights/reproductive-health-data-privacy-laws-in-flux-compliance-in-an-ever-changing-landscape/), [MultiState 2026 effective dates](https://www.multistate.us/insider/2026/2/4/all-of-the-comprehensive-privacy-laws-that-take-effect-in-2026)
- Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) (updated 8 June 2026) · [5.1.1(v) account deletion thread](https://developer.apple.com/forums/thread/693997) · [National Law Review on health-app deletion](https://natlawreview.com/article/digital-health-apps-must-allow-users-to-delete-accounts-new-apple-app-store-rules)
- Food databases — [Nutrola comparison](https://nutrola.app/en/blog/open-nutrition-datasets-compared-usda-openfoodfacts-nutrola), [Spike API 2026 overview](https://www.spikeapi.com/blog/top-nutrition-apis-for-developers-2026), [USDA FoodData Central](https://fdc.nal.usda.gov/), [YMove barcode API notes](https://ymove.app/nutrition-api/barcode-api)
- Period-tracker privacy background — [PMC qualitative analysis](https://pmc.ncbi.nlm.nih.gov/articles/PMC11923453/), [Fordham ULR post-Dobbs](https://undergradlawreview.blog.fordham.edu/digital-privacy/period-tracking-apps-and-reproductive-privacy-in-the-post-dobbs-era/)
