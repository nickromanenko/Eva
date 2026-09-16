/**
 * The cycle maths' own rule-checker (C11, #176), imported so the boot refusal and the
 * refusal `analyzeCycles` raises on every evaluation cannot drift apart.
 *
 * It is the one edge in this file that points *up* the module diagram in `api/CLAUDE.md`,
 * and it costs nothing at runtime: `cycle.ts` is pure and its own two imports are `import
 * type`, erased at compile time, so loading it here loads no Firestore, no clock and no
 * credential. The alternative is two copies of a ten-clause safety check on constants that
 * decide whether a fertile window is drawn — see `cycleRulesProblem` for what each clause
 * prevents, and why a second copy of it is the failure rather than the safeguard.
 */
import { cycleRulesProblem, type CycleRules } from './cycle'

const required = (name: string): string => {
  const value = process.env[name]
  if (!value) throw new Error(`Missing required env var: ${name}`)
  return value
}

/** Optional tuning knob. Unset means the default; a malformed value fails at boot. */
const optionalCount = (name: string, fallback: number): number => {
  const raw = process.env[name]
  if (raw === undefined || raw === '') return fallback
  const value = Number(raw)
  if (!Number.isInteger(value) || value < 0) {
    throw new Error(`Invalid env var ${name}: expected a non-negative integer`)
  }
  return value
}

/**
 * Like `optionalCount`, but with a floor — for a knob where `0` is not a quieter setting
 * but a different, silently broken configuration. `RATE_LIMIT_TRUSTED_PROXY_HOPS=0` is the
 * case this exists for: every other `RATE_LIMIT_*` var documents `0` as "disable this
 * dimension", so `0` reads like a local-dev switch, while it would in fact strip per-IP
 * throttling from every route at once — including the ones where it is the only dimension.
 */
const optionalCountAtLeast = (name: string, fallback: number, min: number): number => {
  const value = optionalCount(name, fallback)
  if (value < min) {
    throw new Error(`Invalid env var ${name}: expected an integer of at least ${min}`)
  }
  return value
}

/** Unset or empty means "not provisioned yet" — `null`, not a throw. Used by the provider
 *  block below, where a boot that refuses to start because Apple's signing key has not been
 *  issued would take email/password sign-in down with it. */
const optionalString = (name: string): string | null => {
  const value = process.env[name]
  return value === undefined || value === '' ? null : value
}

/** Required, and one of a fixed set of words — the boot names the choices when it fails. */
const oneOf = <T extends string>(name: string, choices: readonly T[]): T => {
  const value = required(name)
  if (!(choices as readonly string[]).includes(value)) {
    throw new Error(`Invalid env var ${name}: expected one of ${choices.join(' | ')}`)
  }
  return value as T
}

/** Required, and an absolute URL. Returned without a trailing slash so links can append a path. */
const requiredUrl = (name: string): URL => {
  const value = required(name)
  try {
    return new URL(value)
  } catch {
    throw new Error(`Invalid env var ${name}: expected an absolute URL`)
  }
}

/**
 * How activation and reset links leave the server (issue #6). `log` writes the whole link
 * to stdout instead of sending anything — the local substitute for a mailbox, and a token
 * in a log line everywhere else. There is no default because a boot has to say which it
 * is, and `log` under `NODE_ENV=production` (which the Dockerfile sets) is refused outright.
 */
const emailTransport = oneOf('EMAIL_TRANSPORT', ['log', 'postmark'] as const)
if (emailTransport === 'log' && process.env.NODE_ENV === 'production') {
  throw new Error('EMAIL_TRANSPORT=log writes sign-in links to stdout; not allowed in production')
}

const publicWebUrl = requiredUrl('PUBLIC_WEB_URL')

/**
 * The three knobs behind the Today card's pattern rung, named once, each with its ceiling.
 *
 * `lowAtOrBelow` is a *rating*, not a count, so it is bounded at both ends: ratings are
 * whole numbers from 1 to 5 (`parseRating` in `index.ts`), and `5` would call every
 * answered rating low — a rule that matches anyone who logs at all three days running, and
 * reads from the card as a pattern in her data. The other two are day counts with no
 * ceiling worth asserting. `null` means "no upper bound".
 */
const PATTERN_VARS = [
  ['lowSignalDays', 'DASHBOARD_PATTERN_LOW_SIGNAL_DAYS', null],
  ['lowAtOrBelow', 'DASHBOARD_PATTERN_LOW_AT_OR_BELOW', 4],
  ['severeSymptomDays', 'DASHBOARD_PATTERN_SEVERE_SYMPTOM_DAYS', null],
] as const

/**
 * Rung 2's thresholds (A32, #26), or `null`.
 *
 * **There is no default here, and the absence is the decision.** A32 settled the rule's
 * *form* — consecutive logged days at or below a level, or the same symptom severe on
 * consecutive days — and routed the numbers to #26, which has not answered. A plausible
 * default written here would be a clinical heuristic chosen by whoever typed it, running
 * live against real logs and indistinguishable from one a reviewer signed. So
 * `dashboard-rules.ts` refuses to evaluate that rung without them and this refuses to
 * invent them; `GET /me/today` answers `503` until they are configured.
 *
 * All three or none, like `providers.apple` and for the same reason: a half-configured
 * group is a rule that runs on numbers nobody chose. A partial group is a boot failure,
 * because unlike an unissued signing key it cannot be read as "not provisioned yet".
 */
const patternRule = (): { lowSignalDays: number; lowAtOrBelow: number; severeSymptomDays: number } | null => {
  const present = PATTERN_VARS.filter(([, name]) => optionalString(name) !== null)
  if (present.length === 0) return null
  if (present.length !== PATTERN_VARS.length) {
    const missing = PATTERN_VARS.filter(([, name]) => optionalString(name) === null).map(
      ([, name]) => name,
    )
    throw new Error(`Incomplete dashboard pattern rule: also set ${missing.join(', ')}`)
  }
  const values = PATTERN_VARS.map(([field, name, max]) => {
    const value = Number(required(name))
    // The same floor `dashboard-rules.ts` applies: a zero or a fraction is not a quieter
    // rule, it is one that never matches — which looks identical to one switched off.
    if (!Number.isInteger(value) || value < 1) {
      throw new Error(`Invalid env var ${name}: expected a positive integer`)
    }
    // And the ceiling `requirePatternRule` applies, half a day earlier. The rung refuses a
    // rule that always matches at selection time; this refuses it at boot, so an operator
    // who reads "the 1–5 rating" and writes 5 is told at startup rather than serving every
    // user a pattern card. Both are worth having — they fail at different moments and show
    // the operator different things.
    if (max !== null && value > max) {
      throw new Error(
        `Invalid env var ${name}: expected at most ${max} — ratings are whole numbers ` +
          `from 1 to 5, so ${max + 1} would call every answered rating low`,
      )
    }
    return [field, value] as const
  })
  return Object.fromEntries(values) as {
    lowSignalDays: number
    lowAtOrBelow: number
    severeSymptomDays: number
  }
}

/**
 * The cycle maths' constants (A25–A27, #176): the field on `CycleRules`, and the
 * environment variable it is read from.
 *
 * **The values are deliberately not here.** They are in `api/.env.example`, with the
 * decision each comes from, and a case in `cycle.test.ts` asserts the file still carries
 * them — a second copy written in this table would be a clinical constant nothing checks,
 * which is how one goes stale while looking authoritative. Sources: FIGO AUB System 1
 * (Munro MG et al., Int J Gynecol Obstet 2018;143:393–408) for the bands; Wilcox AJ, Dunson
 * D, Baird DD, BMJ 2000;321:1259 for the fixed luteal phase that ovulation and the fertile
 * window are derived from.
 */
const CYCLE_VARS = [
  ['minCycleLengthDays', 'CYCLE_MIN_LENGTH_DAYS'],
  ['maxCycleLengthDays', 'CYCLE_MAX_LENGTH_DAYS'],
  ['historyCycles', 'CYCLE_HISTORY_CYCLES'],
  ['minCyclesForEstimate', 'CYCLE_MIN_CYCLES_FOR_ESTIMATE'],
  ['narrowBandMinCycles', 'CYCLE_NARROW_BAND_MIN_CYCLES'],
  ['lutealPhaseDays', 'CYCLE_LUTEAL_PHASE_DAYS'],
  ['fertileDaysBeforeOvulation', 'CYCLE_FERTILE_DAYS_BEFORE_OVULATION'],
  ['fertileDaysAfterOvulation', 'CYCLE_FERTILE_DAYS_AFTER_OVULATION'],
  ['peakDaysBeforeOvulation', 'CYCLE_PEAK_DAYS_BEFORE_OVULATION'],
] as const

const CYCLE_BAND_VARS = [
  ['youngMaxAge', 'CYCLE_IRREGULAR_YOUNG_MAX_AGE'],
  ['midMaxAge', 'CYCLE_IRREGULAR_MID_MAX_AGE'],
  ['youngVariationDays', 'CYCLE_IRREGULAR_YOUNG_VARIATION_DAYS'],
  ['midVariationDays', 'CYCLE_IRREGULAR_MID_VARIATION_DAYS'],
  ['olderVariationDays', 'CYCLE_IRREGULAR_OLDER_VARIATION_DAYS'],
] as const

/** The two tables above, as field → variable name. */
const cycleVar = Object.fromEntries(CYCLE_VARS.map(([field, name]) => [field, name])) as Record<
  (typeof CYCLE_VARS)[number][0],
  string
>
const bandVar = Object.fromEntries(
  CYCLE_BAND_VARS.map(([field, name]) => [field, name]),
) as Record<(typeof CYCLE_BAND_VARS)[number][0], string>

/** Which variable a `CycleRulesProblem` field name came from, so the boot failure names the
 *  thing an operator can actually edit rather than the field the maths calls it. */
const CYCLE_VAR_FOR_FIELD = new Map<string, string>([
  ...CYCLE_VARS.map(([field, name]) => [field as string, name] as const),
  ...CYCLE_BAND_VARS.map(([field, name]) => [`irregularity.${field}`, name] as const),
])

/**
 * The cycle maths' constants (A25–A27, #176), or `null`.
 *
 * **All fourteen or none, and a partial group is a boot failure** — the shape
 * `providers.apple` has in this file, and the one #98 gives rung 2's thresholds, for the
 * reason each has it: a half-configured group is arithmetic running on numbers nobody
 * chose. Unlike Apple's signing key, a missing one here cannot be read as "not provisioned
 * yet", so it is refused rather than tolerated.
 *
 * **Absent altogether means the capability is unconfigured**, and `cycle.ts` refuses to
 * answer — `analyzeCycles` throws `CycleRulesUnsetError` and `GET /me/today` answers 503,
 * exactly as it already does for rung 2's unset thresholds. There is deliberately no
 * default: the PRD's own sentence for this block is *"the code fails loudly if any is unset,
 * and none is hard-coded"*, and a copy of A25's values written here as a fallback would be
 * a clinical constant that no deployment records having chosen.
 *
 * Every range check lives in `cycleRulesProblem`, not here, so what the boot refuses and
 * what the maths refuses are the same set.
 */
const cycleRules = (): CycleRules | null => {
  const names = [...CYCLE_VARS, ...CYCLE_BAND_VARS].map(([, name]) => name)
  const missing = names.filter((name) => optionalString(name) === null)
  if (missing.length === names.length) return null
  if (missing.length > 0) {
    throw new Error(`Incomplete cycle maths configuration: also set ${missing.join(', ')}`)
  }

  const whole = (name: string): number => {
    const value = Number(required(name))
    if (!Number.isInteger(value)) {
      throw new Error(`Invalid env var ${name}: expected a whole number of days`)
    }
    return value
  }

  // Written out field by field rather than assembled from the table, so the compiler
  // checks that every member of `CycleRules` is supplied: a field added there and
  // forgotten here is a build failure, not a variable nobody reads. The *names* still
  // come from the table, so what is checked for presence above and what is read below
  // cannot drift.
  const rules: CycleRules = {
    minCycleLengthDays: whole(cycleVar.minCycleLengthDays),
    maxCycleLengthDays: whole(cycleVar.maxCycleLengthDays),
    historyCycles: whole(cycleVar.historyCycles),
    minCyclesForEstimate: whole(cycleVar.minCyclesForEstimate),
    narrowBandMinCycles: whole(cycleVar.narrowBandMinCycles),
    lutealPhaseDays: whole(cycleVar.lutealPhaseDays),
    fertileDaysBeforeOvulation: whole(cycleVar.fertileDaysBeforeOvulation),
    fertileDaysAfterOvulation: whole(cycleVar.fertileDaysAfterOvulation),
    peakDaysBeforeOvulation: whole(cycleVar.peakDaysBeforeOvulation),
    irregularity: {
      youngMaxAge: whole(bandVar.youngMaxAge),
      midMaxAge: whole(bandVar.midMaxAge),
      youngVariationDays: whole(bandVar.youngVariationDays),
      midVariationDays: whole(bandVar.midVariationDays),
      olderVariationDays: whole(bandVar.olderVariationDays),
    },
  }

  const problem = cycleRulesProblem(rules)
  if (problem) {
    const name = CYCLE_VAR_FOR_FIELD.get(problem.field) ?? problem.field
    throw new Error(`Invalid env var ${name}: ${problem.message}`)
  }
  return rules
}

/**
 * The Firebase emulators, used by CI (#67) and by nothing in production.
 *
 * Both variables are Firebase's own, set by `firebase emulators:exec` — we read them
 * rather than invent our own so one command configures the Admin SDK and our REST calls
 * together, and so a stray value cannot point half the process at the emulator and half
 * at Google. `FIRESTORE_EMULATOR_HOST` is the switch because the Admin SDK is what a
 * missing credential breaks first (`firebase.ts`).
 *
 * The Auth emulator serves the Identity Toolkit REST API under the real API's path, so
 * only the origin changes. It ignores the API key entirely, which is why CI can pass a
 * placeholder and hold no secret at all.
 */
const authEmulatorHost = process.env.FIREBASE_AUTH_EMULATOR_HOST
const usingEmulators = Boolean(process.env.FIRESTORE_EMULATOR_HOST)

// Both or neither, in *every* environment. Setting only the auth host is the dangerous
// asymmetry: `usingEmulators` would stay false, so Firestore keeps reading and writing the
// real project while every signup and signin password — and the web API key, which rides
// in the query string (GUARDRAILS 1) — goes over plain http to whatever host that variable
// names. `identity-toolkit.ts` drops the failing fetch's error rather than logging its URL,
// so a redirect to something that mimics Google's error shape produces no signal at all.
if (usingEmulators !== Boolean(authEmulatorHost)) {
  throw new Error(
    'FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST must be set together or not at all',
  )
}

// And neither, ever, in production. `K_SERVICE` is set by Cloud Run itself and is not
// ours to pass, which is the point: `NODE_ENV` arrives through `--set-env-vars` in
// `deploy-api.yml`, the same channel an attacker would use to set an emulator host, so a
// guard resting on `NODE_ENV` alone can be turned off by whoever it is guarding against.
const inProduction = Boolean(process.env.K_SERVICE) || process.env.NODE_ENV === 'production'
for (const name of ['FIRESTORE_EMULATOR_HOST', 'FIREBASE_AUTH_EMULATOR_HOST']) {
  if (process.env[name] && inProduction) {
    throw new Error(`${name} is set; refusing to run against emulators in production`)
  }
}

export const config = {
  usingEmulators,
  /** Where `identity-toolkit.ts` sends credential calls. Google, unless CI redirected it. */
  identityToolkitBaseUrl: authEmulatorHost
    ? `http://${authEmulatorHost}/identitytoolkit.googleapis.com`
    : 'https://identitytoolkit.googleapis.com',
  firebaseProjectId: required('FIREBASE_PROJECT_ID'),
  firebaseWebApiKey: required('FIREBASE_WEB_API_KEY'),
  jwtSecret: required('JWT_SECRET'),
  /** JWT lifetime: 30 days (v1 has no refresh tokens). */
  jwtTtlSeconds: 30 * 24 * 60 * 60,
  /**
   * Throttling for `/auth/*` (issue #5). Any *limit* set to `0` disables that dimension;
   * the two knobs that are not limits are different — `RATE_LIMIT_BACKOFF_BASE_SECONDS=0`
   * disables the whole per-address dimension, and `RATE_LIMIT_TRUSTED_PROXY_HOPS` will not
   * accept `0` at all. Both say so below.
   * Per-IP is the loose backstop (carrier NAT puts many users behind one address);
   * per-address is the sharp one. Counters are per instance — see `rate-limit.ts`.
   */
  rateLimit: {
    windowSeconds: optionalCount('RATE_LIMIT_WINDOW_SECONDS', 15 * 60),
    signinPerIp: optionalCount('RATE_LIMIT_SIGNIN_PER_IP', 60),
    signinPerEmail: optionalCount('RATE_LIMIT_SIGNIN_PER_EMAIL', 10),
    signupPerIp: optionalCount('RATE_LIMIT_SIGNUP_PER_IP', 30),
    signupPerEmail: optionalCount('RATE_LIMIT_SIGNUP_PER_EMAIL', 5),
    /**
     * The first block a sign-in or sign-up address earns after exhausting its free
     * attempts (#37). Each block after it doubles, capped at `windowSeconds`, and the
     * whole record decays after `windowSeconds` of quiet.
     *
     * At the cap a block is the same length as the window it replaced, but it is not the
     * same trade: holding an address out costs an attacker fewer requests than before, and
     * what the change buys is on the guessing side, not the lockout side. `rate-limit.ts`
     * and ARCHITECTURE §3 carry the measured numbers.
     *
     * `0` disables the **whole per-address dimension** for sign-in and sign-up — not just
     * the escalation. That is the only defence against a distributed attack on one
     * account, so it is a local-development setting.
     */
    backoffBaseSeconds: optionalCount('RATE_LIMIT_BACKOFF_BASE_SECONDS', 30),
    /**
     * How many rightmost `X-Forwarded-For` entries were appended by infrastructure we
     * trust, and therefore how far from the right the caller's own address sits (#37).
     *
     * `1` is a **direct Cloud Run service**, which is what `deploy-api.yml` deploys and
     * what `https://eva-api-…-uc.a.run.app` is: Cloud Run appends the address it accepted
     * the connection from, and everything left of it is whatever the caller chose to send.
     * Put a Google external load balancer in front and there are two trusted hops, so this
     * becomes `2` — and if it is *not* changed, every caller collapses into one bucket and
     * the per-IP limit silently becomes global.
     *
     * A knob rather than a constant because that failure is invisible: nothing in a header
     * distinguishes "the rightmost entry is Cloud Run" from "the rightmost entry is a
     * balancer". What this buys is that the assumption is written down somewhere a
     * topology change has to meet, instead of in a comment.
     *
     * Raising it is half a change: `deploy-api.yml` deploys with `--allow-unauthenticated`
     * and no `--ingress`, so the `run.app` URL stays reachable. Set this to `2` without
     * also passing `--ingress=internal-and-cloud-load-balancing` and a request sent
     * straight to `run.app` carries a one-entry header, resolves to `null`, and skips the
     * per-IP dimension entirely — the same outage as leaving it at `1`, reached from the
     * other side.
     *
     * Minimum `1`: there is no topology with zero trusted hops, and `0` would not disable
     * "this dimension" the way the other knobs do — it would disable per-IP throttling on
     * every route, `/auth/idp` and `/auth/activate` included, where it is the only one.
     */
    trustedProxyHops: optionalCountAtLeast('RATE_LIMIT_TRUSTED_PROXY_HOPS', 1, 1),
    /**
     * The two "send me a link" routes (#6): one per address per this many seconds — the
     * canvas' once-per-60s Resend — and a per-IP backstop over the ordinary window. Both
     * knobs serve `/auth/activation/resend` and `/auth/password/forgot`, on separate
     * counters.
     */
    resendPerEmailSeconds: optionalCount('RATE_LIMIT_RESEND_PER_EMAIL_SECONDS', 60),
    resendPerIp: optionalCount('RATE_LIMIT_RESEND_PER_IP', 30),
    /**
     * `/auth/activate` and `/auth/password/reset` (#6), per IP over the ordinary window.
     * Loose: one person opening a link, failing, and asking for another is normal, and
     * these routes cannot be guessed at. It is a ceiling on Firestore work, not a
     * defence against a credential attack.
     */
    tokenPerIp: optionalCount('RATE_LIMIT_TOKEN_PER_IP', 60),
    /**
     * `/auth/idp` and `/me/auth/providers` (#7), per IP over the ordinary window. Per IP is
     * the only dimension there is: a provider credential carries no address we are willing
     * to count against before the provider has vouched for it, and counting against one we
     * had not verified would be a lockout primitive anyone could aim.
     */
    idpPerIp: optionalCount('RATE_LIMIT_IDP_PER_IP', 60),
  },
  /** Transactional email (issue #6). Read only in `email.ts`. */
  email: {
    transport: emailTransport,
    /** The Postmark server token. `null` under `log`, which sends nothing and needs none. */
    postmarkApiKey: emailTransport === 'postmark' ? required('POSTMARK_API_KEY') : null,
    from: required('POSTMARK_FROM'),
    /** Where the links point: `${publicWebUrl}/activate?token=…`, `/reset?token=…`. */
    publicWebUrl: publicWebUrl.href.replace(/\/+$/, ''),
  },
  /**
   * Sign in with Apple and Google (#7). Every value here is **optional**, because none of
   * it is provisioned yet (`docs/PROVIDER-SIGNIN.md` is the errand) and an API that will
   * not boot without an Apple signing key is an API that cannot serve email/password
   * sign-in either. Unconfigured is therefore a *capability* that is unavailable, answered
   * `503` per provider, not a boot failure — see `providers.ts` and `index.ts`.
   *
   * Read only in `providers.ts`. Apple sign-*in* needs none of it: the app hands us an
   * `identityToken` and Firebase holds the Apple credentials (console step 5). Only Google's
   * PKCE code exchange and Apple's token *revocation* talk to a provider directly.
   */
  providers: {
    /**
     * The public iOS OAuth client (`docs/PROVIDER-SIGNIN.md` §4). Not a secret and not in
     * Secret Manager: an iOS client has no secret, which is exactly what lets the app run
     * PKCE itself instead of pulling in the GoogleSignIn SDK (GUARDRAILS 25).
     */
    googleIosClientId: optionalString('GOOGLE_IOS_CLIENT_ID'),
    /**
     * Apple's revocation credentials, and only revocation uses them. All four or none:
     * a half-configured group would sign a client secret Apple rejects, so `providers.ts`
     * treats a partial group as unconfigured rather than as an outage to retry.
     *
     * `signingKey` is the `.p8` contents (`-----BEGIN PRIVATE KEY-----…`), from Secret
     * Manager. Env vars flatten newlines, so a literal `\n` is restored here — the only
     * place that transformation happens.
     */
    apple: {
      // The App ID (bundle identifier), NOT the Services ID — see providers.ts.
      clientId: optionalString('APPLE_CLIENT_ID'),
      teamId: optionalString('APPLE_TEAM_ID'),
      keyId: optionalString('APPLE_KEY_ID'),
      signingKey: optionalString('APPLE_SIGNIN_KEY')?.replace(/\\n/g, '\n') ?? null,
    },
  },
  /**
   * The Today card's rules layer (#96/#98). Read only in `today.ts`, which hands it to
   * `dashboard-rules.ts` — the ladder takes its configuration as an argument and reads no
   * environment of its own.
   */
  dashboard: {
    /** `null` until #26 answers A32. See `patternRule` above for why there is no default. */
    pattern: patternRule(),
  },
  /**
   * The cycle maths' constants (C11, #176). Read only in `today.ts`, which hands them to
   * `cycle.ts` — the maths takes its configuration as an argument and reads no environment
   * of its own, so every gate can be exercised against fixtures.
   *
   * `null` until the group is set, and the maths refuses rather than estimating; see
   * `cycleRules` above for why there is no default.
   */
  cycle: cycleRules(),
  /** The one origin allowed to call the two routes the website's pages use (CORS). */
  publicWebOrigin: publicWebUrl.origin,
}
