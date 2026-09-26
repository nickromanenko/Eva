import { Hono, type Context } from 'hono'
import { cors } from 'hono/cors'
import { createMiddleware } from 'hono/factory'
import { routePath } from 'hono/route'
import { mintToken, requireAuth, tokenVersionOf, type TokenClaims } from './auth'
import { config } from './config'
import { getContent } from './content'
import { exportFilename, openExport } from './data-export'
import { EmailError, sendActivationEmail, sendPasswordResetEmail } from './email'
import { TOKEN_LENGTH, consumeToken, deleteTokensForAccount, issueToken } from './email-tokens'
import {
  authRetryAfterSeconds,
  callerFromForwarded,
  consumeAuthAttempt,
  consumeDeleteAttempt,
  consumeExportAttempt,
  consumeProviderAttempt,
  consumeTokenAttempt,
  forgetEmail,
  type ProviderRoute,
  type TokenRoute,
  type AuthRoute,
} from './rate-limit'
import {
  IdentityToolkitError,
  PROVIDER_IDS,
  addressOfAuthAccount,
  deleteAuthAccount,
  federatedProvidersOf,
  findAuthUidByEmail,
  idTokenForUid,
  claimUnprovenAccount,
  createAccountWithPassword,
  markCredentialsProven,
  retractUnprovenIdentities,
  setPassword,
  signInWithIdp,
  signInWithPassword,
  signUpWithPassword,
  type IdpCredential,
} from './identity-toolkit'
import {
  FOCUS_AREA_CODES,
  FOCUS_AREA_PRD_ITEM,
  MAX_FOCUS_AREAS,
  MEALS_PER_DAY,
  NUTRITION_GOAL_CODES,
  SETUP_STEP_CODES,
  completedSetup,
  deleteNutritionProfile,
  getNutritionProfile,
  saveNutritionProfile,
  type FocusAreaCode,
  type MealPattern,
  type NutritionProfilePatch,
} from './nutrition-profile'
import {
  ImpossibleBodyMetricError,
  NutritionRulesUnsetError,
  planDailyTargets,
  type NutritionInput,
} from './nutrition'
import { ProviderError, exchangeGoogleAuthCode, revokeAppleToken } from './providers'
import { recordRoute, withRequestLog } from './request-log'
import { REQUEST_TIMEOUT_MS, withRequestTimeout } from './request-timeout'
import {
  deleteAllUserDevices,
  registerDevice,
  removeDevice,
  type DeviceEnvironment,
  type DeviceRegistration,
} from './devices'
import { cancelQueuedNotifications, deleteAllUserNotifications } from './notifications'
import {
  RETENTION_DAYS,
  createEvent,
  deleteAllUserEvents,
  exportEvents,
  listEvents,
  restoreEvent,
  softDeleteEvent,
  updateEvent,
  type AppointmentPayload,
  type BodySignalsPayload,
  type CyclePayload,
  type EventPatch,
  type EventPayload,
  type EventSource,
  type LoggableEventType,
  type NewEvent,
  type PositiveTestPayload,
  type SportPayload,
  type Symptom,
  type SymptomSeverity,
} from './events'
import { getRefData, getSymptomRules, type SymptomRules } from './refdata'
import {
  CycleRulesUnsetError,
  PatternRuleUnsetError,
  TemplateUnavailableError,
  ageYearsOn,
  cycleAnalysisFor,
  deleteAllUserToday,
  exportTodayCards,
  getToday,
  type CycleAnalysis,
  type EstimateWithheld,
} from './today'
import {
  ACTIVITY_BAND_CODES,
  AccountGoneError,
  CONDITION_CODES,
  CONSENT_KINDS,
  MEDICATION_CODES,
  SessionSupersededError,
  bumpTokenVersion,
  deleteUserDocument,
  dismissProfileNudge,
  ensureUser,
  getAccount,
  getUser,
  hasCollectConsent,
  isActivated,
  markActivated,
  markUserDeleted,
  readUser,
  saveConsent,
  saveQuestionnaire,
  servedUser,
  type Account,
  type ConditionCode,
  type ConsentKind,
  type Profile,
  type User,
  type UserRecord,
} from './users'

const app = new Hono()

const error = (code: string, message: string) => ({ error: { code, message } })

/** Everything a caller is ever told about a failure nobody planned for. One sentence, the
 *  same one every time, plus the `ref` the handler below generates. */
const INTERNAL_MESSAGE = 'Something went wrong on our end. Please try again.'

/** Identifier-shaped, or nothing. Bounds the one field whose text a library chooses. */
const ERROR_NAME = /^[A-Za-z][A-Za-z0-9_]{0,63}$/

const errorName = (err: unknown): string => {
  const name = err instanceof Error ? err.name : typeof err
  return ERROR_NAME.test(name) ? name : 'unknown'
}

/**
 * The floor under every route (issue #48). Nothing else changes: a handler that already
 * answers — every shaped 4xx, #32's Identity Toolkit mapping, #5's 429 — never throws, so
 * this is only reached when *nothing* handled the failure. A Firestore outage inside
 * `ensureUser` is the case that motivated it: before this it fell through to Hono's default
 * handler, which answers a bare `500` with no `{ error: { code, message } }` body at all.
 *
 * **What is not here is the point.** `err.message` reaches neither the body nor the log,
 * because nobody wrote it for either: #32 found that a failed `fetch`'s message names the
 * request URL and that URL carries the web API key, and a Firestore error's message can
 * name the document path, which is a uid. The same goes for `err.stack`, whose first line
 * *is* the message, and for `err.cause`, which is another error's message one hop away.
 * A library's choice of words is not a reviewed field, so it is treated as untrusted
 * (GUARDRAILS 1, 12).
 *
 * What the line carries instead, and why each field is safe to write down:
 * - `event` — a constant, so the count of these is alertable and greppable, next to
 *   `identity_toolkit_unavailable`. These two now separate an outage of Google's from an
 *   outage of anything else, and a bug of ours from either.
 * - `ref` — generated here from `crypto.randomUUID`, derived from nothing about the
 *   request. It is the one field also given to the caller (in `message`), so a user can
 *   quote it and an operator can find the single line it came from.
 * - `method` and `route` — `route` is the *registered* path (`/me/events/:id`), never
 *   `c.req.path`, which would carry the id, the query string, and — at
 *   `/me/body-signals/2026-08-27` — the date a user logged health data for, which
 *   GUARDRAILS 12 keeps out of logs as surely as the payload itself.
 * - `errorName` — a class name, chosen where the class is declared rather than formatted
 *   from runtime values, so `FirebaseError` vs `TypeError` distinguishes "the database is
 *   gone" from "we shipped a bug" with no data in it. Sanitized anyway, because a `name`
 *   *can* be assigned at runtime and this is the one field a library controls.
 *
 * The cost is real and worth stating: no stack, so this line locates a fault to a route
 * and a class, not to a line number. Reproducing from `route` + `errorName` is the trade
 * for a log that cannot leak. If that proves too thin, the answer is a reviewed field
 * (an error class of ours carrying a safe code), not the message.
 *
 * Hono routes only a thrown **`Error`** here — `#handleError` rethrows anything else at
 * the runtime, which answers its own unshaped 500. `wrapNonErrors` below closes that, so
 * every throw now arrives here. (`errorName`'s `typeof` branch was never reached even
 * before that, for the same reason: Hono only ever called this handler with an `Error`.
 * It stays as a floor, not because anything changed about it.)
 */
app.onError((err, c) => {
  // The one refusal that arrives here by design rather than by accident: `readBody` below
  // throws it, so that "a JSON body that is not an object" is answered once rather than by
  // a guard in each of fifteen handlers. It is a caller's mistake, not a fault of ours, so
  // it answers the ordinary edge-validation 400 and writes no line — an `unhandled_error`
  // per `null` body is the signal poisoning #119 is about.
  if (err instanceof BodyNotAnObjectError) {
    return c.json(error('VALIDATION', 'The request body must be a JSON object'), 400)
  }
  // The second (#286): a write that passed `requireAccount` and then found, inside its own
  // transaction, that `DELETE /me` had tombstoned the account. It is answered byte-for-byte
  // as the gate answers that account's token on its next request — the caller *is* such a
  // token, one step earlier — so no code is added and the client's sign-out path applies.
  // Not a fault either, so no line: every route that writes a subcollection can raise it,
  // which is why it is answered here once rather than in each handler.
  // Its twin (#294) is the same race against a password reset instead of a delete: the
  // write's own read found the session superseded after the gate let it through, and it is
  // answered exactly as the gate answers a superseded token — which is byte-for-byte the
  // dead-token answer above, so the client cannot tell the two apart and need not.
  if (err instanceof AccountGoneError || err instanceof SessionSupersededError) {
    return c.json(error('UNAUTHORIZED', 'Invalid or expired token'), 401)
  }
  // Short enough to read out over a support call, random enough to be unique among the
  // 500s anyone is looking through. It identifies a log line, never a user.
  const ref = crypto.randomUUID().slice(0, 8)
  console.error(
    JSON.stringify({
      event: 'unhandled_error',
      ref,
      method: c.req.method,
      route: routePath(c),
      errorName: errorName(err),
    }),
  )
  return c.json(error('INTERNAL', `${INTERNAL_MESSAGE} (ref: ${ref})`), 500)
})

/**
 * What a non-`Error` throw is called in the log line, derived from the value's *type* and
 * never from the value (#53).
 *
 * This is the whole care in this function. A thrown object could be anything — an
 * Identity Toolkit response body, a Firestore document, a request payload with a
 * symptom log in it — so nothing here stringifies it, indexes it, or reads a property
 * off it. `typeof` is the one question whose answer cannot contain data, and `null` is
 * split out because `typeof null` is `"object"` and would lose the only distinction that
 * is actually useful when reading these.
 *
 * The result is `NonError` + a capitalised type, which lands in the same `errorName`
 * field an `Error` fills with its class name and passes the same `ERROR_NAME` shape. So
 * `FirebaseError` and `NonErrorString` sit in one field, and a non-Error throw is
 * greppable as a class of fault rather than indistinguishable from a bug of ours.
 */
const nonErrorName = (value: unknown): string => {
  if (value === null) return 'NonErrorNull'
  const type = typeof value
  return `NonError${type.charAt(0).toUpperCase()}${type.slice(1)}`
}

/**
 * Every response is `cache-control: no-store` unless its handler said otherwise (#280).
 *
 * Almost everything this API answers is a session token, an account or health data, and a
 * response with no `Cache-Control` at all is one any client or intermediary may store
 * heuristically. The iOS app no longer does (#279), but the default belongs here, where it
 * is true of the next client too — a web page, a debugging proxy — without that client
 * having to know. It replaces the per-route `noStore` #6 put on the two link routes, which
 * this covers and which had the gap described below.
 *
 * Two rules, and both are the design:
 *
 * - **A handler's own `Cache-Control` stands** on the response it returned. `/content` and
 *   `/refdata` send `private, no-cache` beside an `ETag`, and their `304` handshake is what
 *   keeps the copy and the catalogues current offline; overwriting it would break that
 *   silently for anything that speaks HTTP caching. So the header is set only when absent.
 * - **A response `app.onError` built is always `no-store`**, whatever the handler had set
 *   before it threw — `c.error` is how that is known. A 500 is never worth keeping, and
 *   without this a throw after `/content` set its headers would answer a cacheable 500.
 *
 * **Registered before `wrapNonErrors`, so outside it** — only `recordRoute` (#263), which
 * does nothing after `next()`, sits above it. Set after `await next()`, a
 * throw passing through this block would skip the line; that is exactly how `noStore` let a
 * non-`Error` inside a link route answer without the header. Outside `wrapNonErrors` nothing
 * passes through as a throw: an `Error` is answered by `onError` at the level it was thrown,
 * and a non-`Error` is wrapped and answered at `wrapNonErrors`' level — both inside this —
 * and an unmatched path's `notFound` is answered inside Hono's chain as well. The one throw
 * that still escapes is `onError` itself throwing, which is Bun's unshaped 500 regardless.
 *
 * `c.res.headers`, not `c.header()`: after `next()` the response is built, and only the
 * built response's headers go out. Like `wrapNonErrors`, this holds no per-request state.
 */
const noStoreByDefault = createMiddleware(async (c, next) => {
  await next()
  if (c.error !== undefined || !c.res.headers.has('cache-control')) {
    c.res.headers.set('cache-control', 'no-store')
  }
})
// First of all: records the matched route *pattern* for the request-level log lines
// (`request-log.ts`, #263). It runs before anything can await, so `request_timeout` can
// always read it, and it writes nothing itself — the line is written at the server edge.
app.use('*', recordRoute)
app.use('*', noStoreByDefault)

/**
 * Every request, so that `app.onError` above is reached by **every** throw and not only
 * by the ones that happen to be `Error`s (#53).
 *
 * Hono's `#handleError` calls `onError` only for `err instanceof Error` and rethrows
 * anything else at the runtime, which answers its own unshaped 500 — no
 * `{ error: { code, message } }`, `content-type: text/plain`, and nothing in the log.
 * Nothing in the current stack throws a non-Error, so this is a guard against a future
 * dependency rather than a live bug; it is three lines, and the alternative is a response
 * shape that is true of every route except the one that surprises us.
 *
 * **Registered before every route and every other `app.use` but `recordRoute` and
 * `noStoreByDefault`**, which is what makes it wrap them: Hono runs handlers for a path in
 * registration order, so middleware added after a route does not run for it. That is also
 * why `webCors` sits above the two link routes rather than at the end of the file.
 * `noStoreByDefault` is registered before this deliberately — see above for why it has to
 * be outside — and `recordRoute` only records a pattern before calling `next()`.
 *
 * **It does not disturb #5's throttle**, and the reason is worth writing down because the
 * issue assumed otherwise: the throttle is not middleware. `throttleAuth`, `throttleToken`
 * and `throttleProvider` are plain calls at the top of each handler, inside the route this
 * wraps. Nothing about their order changes, and a 429 is a returned response rather than a
 * throw, so it never touches the `catch` below. Every shaped 4xx is likewise a *returned*
 * response, which this never inspects or replaces.
 *
 * A non-`Error` thrown inside `/auth/activate` or `/auth/password/reset` used to answer its
 * shaped 500 without `cache-control: no-store`, because the per-route `noStore` sat inside
 * this and set its header after `await next()`. `noStoreByDefault` replaced it from outside
 * (#280), which is what closed that.
 *
 * The wrapper carries **no `cause`**, deliberately. `cause` would retain the thrown value,
 * and the next person to improve this log line would find it there — which is exactly the
 * payload `nonErrorName` exists to keep out. The type is the whole of what is kept. Note
 * that nothing *tests* the absence: what a test can see is the log line's exact field set,
 * asserted in `unhandled-errors.test.ts`, which fails the moment a field is added.
 *
 * **Keep this block free of per-request state.** It is now the only code that runs on every
 * request, including unmatched paths, before any authentication — so a counter, a cache or
 * a log keyed by anything the caller controls would be an unauthenticated, unthrottled
 * surface reachable with `/x/<random>`. A `try`/`catch` and nothing else is what makes it
 * safe to sit there.
 */
const wrapNonErrors = createMiddleware(async (c, next) => {
  try {
    await next()
  } catch (err) {
    if (err instanceof Error) throw err
    const wrapped = new Error('Non-Error value thrown')
    wrapped.name = nonErrorName(err)
    throw wrapped
  }
})
app.use('*', wrapNonErrors)

/**
 * A path no route matched (#53). It is a *miss*, not a throw, so `app.onError` never sees
 * it and Hono answers its own plain-text `404 Not Found` — the one response left that does
 * not match the contract ARCHITECTURE §3 states and `APIClient` decodes.
 *
 * `NOT_FOUND` is the code the event routes already use for "the thing you named is not
 * here" (GUARDRAILS 11: adding is fine, repurposing is not — this is the same meaning one
 * level up, on the route instead of the row). The message says *route* so the two are
 * distinguishable by a human reading a support ticket, while a client switching on `code`
 * sees one thing.
 *
 * Nothing is logged: an unmatched path is a client that asked for something that does not
 * exist, not a fault of ours, and `c.req.path` is the one field that would make the line
 * useful — which is the field that carries ids and dates (GUARDRAILS 12).
 */
app.notFound((c) => c.json(error('NOT_FOUND', 'No such route'), 404))

/** Thrown by `readBody` and answered by `app.onError` as `400 VALIDATION` (#119). A class of
 *  ours so the handler can recognise it by `instanceof`, never by a message. */
class BodyNotAnObjectError extends Error {
  override name = 'BodyNotAnObjectError'
}

/**
 * The request's JSON body, for every route that reads one — **the** shared body parse (#119).
 *
 * Two answers that look alike and are not:
 *
 * - **No body, or not JSON at all** is `{}`, exactly what every route's
 *   `c.req.json().catch(() => ({}))` gave before. Each route's own validation then refuses
 *   the missing fields in its own words, and `DELETE /me` — whose body is optional — still
 *   deletes, which is the documented case for an old client or a declined Apple prompt.
 * - **Valid JSON that is not an object** — `null`, an array, a number, a string — throws
 *   `BodyNotAnObjectError`, which `app.onError` answers `400 VALIDATION` without a log line.
 *   `null` used to reach `body.provider` and throw a `TypeError`, which was a `500` and an
 *   `unhandled_error` line on the unauthenticated `/auth/idp`: a free way to fill the one
 *   signal meant to mean "we shipped a bug". An array or a number was merely *usually*
 *   refused, by whichever field check happened to come first — and not at all by
 *   `DELETE /me`, which read `[]` as "no Apple code" and deleted.
 *
 * Thrown rather than returned so the guard is here once and each handler's call stays one
 * line; `onError` is reached at the handler's own level of Hono's `compose`, so
 * `noStoreByDefault` and CORS still wrap the answer.
 */
const readBody = async (c: Context): Promise<Record<string, unknown>> => {
  let parsed: unknown
  try {
    parsed = await c.req.json()
  } catch {
    return {}
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new BodyNotAnObjectError()
  }
  return parsed as Record<string, unknown>
}

/**
 * `EMAIL_MAX_LENGTH` is RFC 5321's cap on a path. It is here rather than left to the
 * pattern because every accepted address becomes a key in the throttle's maps
 * (`rate-limit.ts`), which bound how many keys they hold but not how large each is — and
 * #6 added four more maps keyed the same way.
 */
const EMAIL_MAX_LENGTH = 254

/** A non-empty string no longer than `max`. The ceiling matters for every provider field
 *  (#7): they are opaque credentials we forward, so nothing about their *content* can be
 *  checked here, and an unbounded one is a body we would carry to a provider for free. */
const isBounded = (value: unknown, max: number): value is string =>
  typeof value === 'string' && value.length > 0 && value.length <= max

const normalizeEmail = (email: unknown): string | null => {
  if (typeof email !== 'string') return null
  const normalized = email.trim().toLowerCase()
  if (normalized.length > EMAIL_MAX_LENGTH) return null
  return /\S+@\S+\.\S+/.test(normalized) ? normalized : null
}

/**
 * Whether `users/{uid}.email` still names the address the account's credential answers to —
 * the check every route that mints a session makes before minting one (#119).
 *
 * The document's copy is written once, when the document is created, and nothing rewrites
 * it; Firebase's copy can move under it (`accounts:update` with the public web API key, and
 * a Firebase merge that lands a stranger's credential on the account that held the address).
 * So a document whose address differs from the credential's is one that belongs to somebody
 * other than whoever is signing in, and the decision on #119 is to **refuse** rather than
 * hand them its profile and its events, or rewrite its address to theirs.
 *
 * Case and surrounding space are not a difference: Firebase stores addresses lower-cased,
 * and a document written before `normalizeEmail` existed may not be. An address absent on
 * either side *is* one — there is nothing to say the document is the caller's, and every
 * path that writes a document writes an address.
 */
const sameAddress = (stored: unknown, current: unknown): boolean =>
  typeof stored === 'string' &&
  typeof current === 'string' &&
  stored.trim().toLowerCase() === current.trim().toLowerCase()

/**
 * The password rule, stated exactly as the page that asks for a password states it —
 * `passwordRule` in website/src/pages/activate.astro. The user must never be told two
 * different rules, so this string is the rejection message verbatim, and test/auth.test.ts
 * reads the Astro page to pin the two together.
 *
 * **Not the iOS app.** Sign-up has no password field since #120 — the password is chosen on
 * the activation page, where the link has just proved the address — so the Swift file this
 * comment used to name no longer states a rule at all.
 *
 * Applied where a password is *set*: `/auth/activate` and `/auth/password/reset`, both
 * before the token is spent. Sign-in never applies it: accounts predating this rule keep
 * working.
 */
const PASSWORD_RULE = 'At least 8 characters, including one number.'

/**
 * `\p{N}`, not `\d`, so "a number" means the same thing here as it does in the client's
 * `Character.isNumber` (Unicode Nd/Nl/No). ASCII-only here would reject a password the
 * sign-up CTA accepted, while quoting the rule the user just satisfied.
 */
const isValidPassword = (password: string): boolean =>
  password.length >= 8 && password.length <= PASSWORD_MAX_LENGTH && /\p{N}/u.test(password)

/**
 * A ceiling, because Identity Platform has one of its own and enforces it late. Without
 * this, `/auth/password/reset` spends the token and *then* fails in `setPassword`, which
 * is a `500` and a dead link — precisely what checking the rule before the token is spent
 * exists to prevent. 128 is well past any password a person or a manager produces.
 *
 * Its own message: quoting the "at least 8 characters" rule at someone who typed 400
 * would be telling them a rule they had satisfied.
 */
const PASSWORD_MAX_LENGTH = 128
const PASSWORD_TOO_LONG = `Passwords are limited to ${PASSWORD_MAX_LENGTH} characters.`

/** The `WEAK_PASSWORD` message for a password that fails the rule: which end it failed. */
const passwordFailure = (password: string): string =>
  password.length > PASSWORD_MAX_LENGTH ? PASSWORD_TOO_LONG : PASSWORD_RULE

/**
 * The calling client's address, for the per-IP half of the auth throttle (issue #5).
 *
 * Counted from the **right** of `X-Forwarded-For`, never the left. Cloud Run appends the
 * address it actually accepted the connection from, and everything to the left of that is
 * whatever the caller chose to send — trusting the left would put the per-IP limit one
 * request header away from useless.
 *
 * **How far from the right is `config.rateLimit.trustedProxyHops`** (#37), not a constant.
 * `1` is a direct Cloud Run service, which is what `deploy-api.yml` deploys and what the
 * app's base URL points at — verified against the deployed service, which answers on its
 * `run.app` URL with no balancer in front. Add a Google external load balancer and there
 * are two trusted hops; leave this at `1` and the rightmost entry becomes the balancer's,
 * collapsing every caller into one bucket and turning a per-IP limit into a global one.
 *
 * That failure is silent — no header distinguishes the two shapes — so the knob does not
 * *detect* a topology change. What it does is make the assumption a value somewhere rather
 * than a sentence in a comment, so changing the topology has something to meet.
 *
 * `null` when the header is absent, or when it holds fewer entries than the configured
 * hops. Both skip the per-IP dimension rather than bucketing every caller together:
 * collapsing the world into one counter is an outage, the per-address limit still applies,
 * and a header shorter than expected is exactly the case where guessing which entry is the
 * client would be guessing. Cloud Run always sets the header, so in production the first
 * is unreachable; locally, and for in-process tests, it is the ordinary case.
 */
const clientIp = (c: Context): string | null =>
  callerFromForwarded(c.req.header('x-forwarded-for'), config.rateLimit.trustedProxyHops)

/**
 * Counts this attempt and, if it is over the limit, answers instead of serving it.
 * `null` means carry on.
 *
 * Called *after* validation and *before* the Identity Toolkit call, so a throttled request
 * costs neither us nor the bill anything, and so the answer cannot depend on what the
 * upstream would have said. The response is one constant for every caller: same status,
 * same code, same message, same `Retry-After`, with nothing derived from the address —
 * which is what keeps the sign-in non-enumeration property (§3) intact under throttling.
 */
const throttleAuth = (c: Context, route: AuthRoute, email: string) => {
  if (consumeAuthAttempt(route, clientIp(c), email)) return null
  return c.json(error('RATE_LIMITED', 'Too many attempts. Try again later.'), 429, {
    'retry-after': String(authRetryAfterSeconds(route)),
  })
}

/**
 * How long we tell a caller to wait when Identity Toolkit could not answer (issue #32).
 *
 * A constant, for the reason #5 gives for the throttle's own `Retry-After`: anything
 * computed — time left on a breaker, a backoff that grows per address — is a per-caller
 * value, and a per-caller value in a header is a channel that can differ between a
 * registered address and an unknown one. One number for everybody differs from nothing.
 *
 * Long enough that a client honouring it does not amplify an outage, short enough that a
 * blip is not a minute of dead app.
 */
const UPSTREAM_RETRY_AFTER_SECONDS = 30

/**
 * The upstream is down, or refusing to serve us. `503` + `Retry-After`, in the standard
 * error shape, saying only that this is temporary — nothing about what upstream said and
 * nothing about the address (issue #32).
 *
 * **This is also the operator's signal, and the only one.** A `503 SERVICE_UNAVAILABLE`
 * plus this log line means Identity Toolkit did not answer us; a bare `500` from these
 * routes now means a bug in our own code, because every Identity Toolkit failure is
 * mapped. Alert on the count of `identity_toolkit_unavailable` and the two are separable
 * without anything user-identifying being written down: the line carries the route and
 * the upstream HTTP status (`null` when the request never landed) and deliberately not
 * `err.reason`, not the address, not the password (GUARDRAILS 12).
 */
const serviceUnavailable = (c: Context) =>
  c.json(
    error(
      'SERVICE_UNAVAILABLE',
      "We can't reach the account service right now. Please try again in a moment.",
    ),
    503,
    { 'retry-after': String(UPSTREAM_RETRY_AFTER_SECONDS) },
  )

const upstreamUnavailable = (
  c: Context,
  route: AuthRoute | ProviderRoute,
  err: IdentityToolkitError,
) => {
  console.error(
    JSON.stringify({
      event: 'identity_toolkit_unavailable',
      route,
      upstreamStatus: err.upstreamStatus,
    }),
  )
  return serviceUnavailable(c)
}

/**
 * The account gate, and the second half of every authenticated route: `requireAuth`
 * proves the token was minted by us, this proves the account it names still exists.
 *
 * It exists because the Eva JWT is stateless, lives 30 days and has no revocation
 * (ARCHITECTURE §3), so a token minted before an account was deleted would otherwise keep
 * working for up to a month — and at `GET /me`, whose old `ensureUser` fallback treated
 * "no document" as "create one", it would have *recreated the account* from the claims it
 * carries. Deletion cannot mean deletion while that is true (#8).
 *
 * The user document is the revocation list, rather than a new one: every account has
 * exactly one, `users.ts` already owns it, and it stops answering the moment a delete
 * starts (`markUserDeleted`) — so nothing about a deleted account is kept in order to keep
 * refusing it. The cost, stated plainly, is one Firestore read on every authenticated
 * request; `GET /me` pays no more than before, since it needed that read anyway.
 *
 * It lives here rather than beside `requireAuth` because `auth.ts` must not reach
 * Firestore and `users.ts` is the only module that may (GUARDRAILS 10) — so the composing
 * of the two belongs at the route edge, which is what this file is.
 *
 * **It is also where a reset ends every other session (#76).** The account's
 * `tokenVersion` rides back on the very snapshot this gate already reads, so the check is
 * one integer comparison and not a second round trip — the design constraint the issue
 * set, and the reason the version lives on `users/{uid}` rather than in a revocation list
 * of its own. A stale token gets the byte-identical answer an expired one gets, so no
 * error code is added or repurposed and the client's existing sign-out handling (§5, #55)
 * applies to it unchanged.
 */
const requireAccount = createMiddleware<{
  Variables: { claims: TokenClaims; account: UserRecord }
}>(async (c, next) => {
  const claims = c.get('claims')
  const account = await getAccount(claims.sub)
  // 401, not 404: the caller's credential is the thing that is no longer good, and the
  // app signs out on it wherever it lands — `AppSession.authorized` routes every
  // authorized request through one handler, so this is not only caught at launch (#55).
  // Same code and message as any other dead token —
  // "your account was deleted" is not a distinction worth drawing for a caller who,
  // by definition, cannot be told anything about it. A superseded session is told the
  // same nothing, and for the stronger version of the same reason: whoever is holding it
  // may well be the person the reset was aimed at.
  if (!isCurrentSession(account, claims)) {
    return c.json(error('UNAUTHORIZED', 'Invalid or expired token'), 401)
  }
  c.set('account', account.user)
  await next()
})

/**
 * The question `requireAccount` asks, named so that `requireServedAccount` asks exactly the
 * same one rather than a copy of it.
 */
const isCurrentSession = (account: Account | null, claims: TokenClaims): account is Account =>
  // **Equality, not `<`.** "Minted at the current generation" is the property; a token
  // claiming a generation this account has never reached is not a session of ours
  // either, and reading it as good would make a rolled-back document hand every stale
  // token back its access.
  account !== null && tokenVersionOf(claims) === account.tokenVersion

/**
 * `requireAccount`, for the one route that serves the user it gates on (`GET /me`) — plus
 * Firebase Auth's answer to which federated identities she holds, read **beside** the
 * account read rather than after it (#117).
 *
 * `User.authProviders` takes `apple.com` / `google.com` from Auth now, so `/me` costs one
 * Admin SDK read on top of the Firestore read it always made — measured on #117 at about the
 * same cost as that read. Issued together, the route waits for the slower of the two
 * instead of their sum. The Auth read therefore happens before the session is known to be
 * current; nothing from it is answered unless the session is, and it only ever reads the
 * token's own uid. No Auth user is the same dead-token answer as no document.
 *
 * Only for a route that serves the gated user as it is. A route that serves the user its
 * own write returns reads Auth beside that write instead; every other route stays on
 * `requireAccount` and pays nothing.
 */
const requireServedAccount = createMiddleware<{
  Variables: { claims: TokenClaims; account: UserRecord; served: User }
}>(async (c, next) => {
  const claims = c.get('claims')
  const [account, federated] = await Promise.all([
    getAccount(claims.sub),
    federatedProvidersOf(claims.sub),
  ])
  if (!isCurrentSession(account, claims) || federated === null) {
    return c.json(error('UNAUTHORIZED', 'Invalid or expired token'), 401)
  }
  c.set('account', account.user)
  c.set('served', servedUser(account.user, federated))
  await next()
})

/**
 * The collection gate (A21, #86): nothing that writes health data runs without a collect
 * consent on record.
 *
 * It sits *after* `requireAccount` in the chain and reads the user that gate already
 * loaded, so the check is one field read and not a second Firestore round trip — the same
 * bargain `requireAccount`'s own comment describes. Both shapes of "no" answer the same
 * `403 CONSENT_REQUIRED`: an account that has never been asked (every pre-#86 account,
 * every new one until the screen is through) and one that withdrew (the freeze, which
 * stops collection without deleting anything). The client tells the two apart from
 * `GET /me`'s consent record, not from the error — the remedy is the same screen either
 * way, and the message says what is true of both.
 */
const requireCollectConsent = createMiddleware<{
  Variables: { claims: TokenClaims; account: UserRecord }
}>(async (c, next) => {
  if (!hasCollectConsent(c.get('account'))) {
    return c.json(
      error('CONSENT_REQUIRED', 'Eva stores nothing about your health until you consent to it'),
      403,
    )
  }
  await next()
})

app.get('/', (c) => c.text('Eva API'))
app.get('/health', (c) => c.json({ status: 'ok' }))

app.post('/auth/signup', async (c) => {
  const body = await readBody(c)
  const email = normalizeEmail(body.email)
  if (!email) return c.json(error('VALIDATION', 'A valid email is required'), 400)
  const throttled = throttleAuth(c, 'signup', email)
  if (throttled) return throttled

  // **No password, and no account** (#120). Sign-up used to create the Firebase Auth user
  // and its password here, before anyone had proved the address — which reserved the
  // address for whoever asked first and put a working credential on it. An attacker signed
  // up as a victim; the victim clicked the confirmation mail they never asked for; the
  // attacker's password then opened an activated account holding the victim's data.
  //
  // Both halves now happen at `/auth/activate`: the link proves the address and the form
  // supplies the password, in one request. So there is no moment at which a credential
  // exists on an address nobody has confirmed.
  //
  // What this route still does is refuse an address that already belongs to somebody.
  let existingUid: string | null
  try {
    existingUid = await findAuthUidByEmail(email)
  } catch (err) {
    // #32: an outage during the lookup is a shaped 503, not a bare 500 — the guarantee
    // signin and activate already carry, which this route's lookup alone lacked. A lookup
    // failure is never a verdict about the address, and `rejected` cannot occur here (the
    // edge has already normalised the address), so both kinds take the retryable answer.
    if (err instanceof IdentityToolkitError) return upstreamUnavailable(c, 'signup', err)
    throw err
  }
  if (existingUid) {
    const existing = await readUser(existingUid)
    // Activated means proven, and proven means taken. Answered plainly, as it always
    // has been (ARCHITECTURE §3): sign-up is the one route that deliberately says an
    // address is registered, because a sign-up form that silently did nothing would be
    // worse than the disclosure.
    if (existing.user?.activated) {
      return c.json(error('EMAIL_EXISTS', 'This email is already registered'), 409)
    }
    // An Auth user with no proven owner is not an obstacle. It is either an abandoned
    // sign-up or an address someone reserved by calling Identity Toolkit directly —
    // which the public web API key allows and Eva cannot prevent. Either way nobody has
    // proved it, so the link below is issued and whoever completes it takes the account.
  }

  await sendActivationLink(null, email)
  // The address comes back — the one the caller just sent — so the "check your email"
  // screen can name where the link went.
  return c.json({ pending: true, email }, 201)
})

app.post('/auth/signin', async (c) => {
  const body = await readBody(c)
  const email = normalizeEmail(body.email)
  const password = typeof body.password === 'string' ? body.password : ''
  if (!email || !password) {
    return c.json(error('VALIDATION', 'Email and password are required'), 400)
  }
  const throttled = throttleAuth(c, 'signin', email)
  if (throttled) return throttled

  // Everything below answers no sooner than `SIGNIN_FLOOR_MS` (#34), so the branch that
  // does less work cannot be told from the one that does more. Deliberately wrapping the
  // whole handler rather than only the two 401s: a branch added later would otherwise
  // have to remember to opt in, and the success path is slower than the floor anyway.
  //
  // The validation 400 and the throttled 429 above are outside it on purpose. Neither
  // depends on whether the address has an account, and padding a refused request would
  // hold a connection open for every attempt an attacker makes — paying to be throttled.
  return atLeast(SIGNIN_FLOOR_MS, async () => {
    try {
      const { localId } = await signInWithPassword(email, password)
      // A document whose address is not the one this password answers to is somebody
      // else's (#119, `sameAddress`): Identity Toolkit matched `email` against the Auth
      // account's *current* address, which can have moved since the document was written.
      // A **read** first, as `/auth/idp` does, because `ensureUser` writes — a refused
      // sign-in must leave the document exactly as it was. Same answer as a wrong
      // password, and inside the floor, so it says nothing more. One extra read on a
      // path whose success already sits well above the floor.
      const existing = await readUser(localId)
      if (existing.user && !sameAddress(existing.user.email, email)) {
        return c.json(error('INVALID_CREDENTIALS', 'Wrong email or password'), 401)
      }
      // Self-healing: also the attach point for future providers (same uid → same doc).
      // The account's token generation comes back with it (#76), off the snapshot
      // `ensureUser` already read, so this mints at the current one without asking.
      // Auth's half of `authProviders` (#117) rides beside it: the credentials are already
      // verified, so this reveals nothing, and the sign-in floor below hides its cost.
      const [account, federated] = await Promise.all([
        ensureUser(localId, email, 'password'),
        federatedProvidersOf(localId),
      ])
      // `null` means the account is being deleted. The credentials are real, and that is
      // exactly why this must not mint a token: signing in is the one path that could
      // otherwise walk an account back out of its own deletion. Answered as a failed
      // sign-in — the same answer a wrong password gets, which is also the honest one,
      // because the account those credentials named is gone.
      // No Auth user is the same fact seen from the other side.
      if (!account || !federated) {
        return c.json(error('INVALID_CREDENTIALS', 'Wrong email or password'), 401)
      }
      const user = account.user
      // The activation gate (#6), and *where* it sits is the design: after Identity
      // Toolkit has verified the password. Answering "not activated" for an unverified
      // password would tell anyone holding an address that an account exists behind it,
      // which is the question the 401 below refuses to answer. So the only caller who
      // can ever see this 403 already knows the password.
      // test/auth.test.ts pins the ordering, against the real upstream.
      if (!isActivated(user)) {
        return c.json(error('NOT_ACTIVATED', 'Confirm your email address first'), 403)
      }
      return c.json({
        token: await mintToken(localId, email, account.tokenVersion),
        user: servedUser(user, federated),
      })
    } catch (err) {
      if (err instanceof IdentityToolkitError) {
        if (err.kind === 'unavailable') return upstreamUnavailable(c, 'signin', err)
        // Everything else collapses into one answer — a wrong password, an address
        // that was never registered, an address upstream considers malformed. The
        // branch is chosen from `kind`, which is derived from the upstream *status*
        // and a fixed list of reasons, never from anything that varies with the
        // address: that is what keeps the non-enumeration property (ARCHITECTURE §3)
        // true of our layer and not merely of Google's. Signin has no 400 branch on
        // purpose — "that address is malformed" would answer the question the 401
        // refuses to. test/signin-non-enumeration.test.ts pins both halves.
        return c.json(error('INVALID_CREDENTIALS', 'Wrong email or password'), 401)
      }
      throw err
    }
  })
})

// ── Activation and password reset (#6) ─────────────────────────────────────────
// The API owns the tokens (issue, spend, expire — `email-tokens.ts`) and the delivery
// (`email.ts`); Firebase's own action emails would have put both outside the code this
// repo can test, and the link on a page we could barely brand. Links land on the website
// (`PUBLIC_WEB_URL/activate`, `/reset`), whose pages call the two routes below
// cross-origin — hence CORS on exactly those two, for exactly that origin, and nowhere
// else. `*` would let any page on the web spend a token it was handed.

const webCors = cors({
  origin: config.publicWebOrigin,
  allowMethods: ['POST', 'OPTIONS'],
  allowHeaders: ['Content-Type'],
})
app.use('/auth/activate', webCors)
app.use('/auth/password/reset', webCors)

// Both link routes change state and are reached with a one-time credential in the body, so
// nothing between here and the browser may keep a copy of either half. That is
// `noStoreByDefault`'s answer on every route (#280); these two set no `Cache-Control` of
// their own, and must not.

/**
 * The shape `email-tokens.ts` issues — `TOKEN_LENGTH` characters of base64url — and
 * nothing else gets as far as a lookup. Anything malformed is a dead link, answered like
 * one; a missing token altogether is a request the client built wrong.
 */
const TOKEN_SHAPE = new RegExp(`^[A-Za-z0-9_-]{${TOKEN_LENGTH}}$`)

/**
 * The floor both "send me a link" routes answer against, comfortably above what the
 * registered branch costs (an Auth lookup, a Firestore write and a POST to Postmark —
 * a few hundred milliseconds). See the note on the routes for why a floor and not a
 * detached send.
 */
const SEND_LINK_FLOOR_MS = 800

/**
 * The floor `/auth/signin` answers against (#34).
 *
 * #21 made the two failing branches byte-identical; they were never *time*-identical,
 * because Identity Toolkit refuses an address it has no record of without verifying a
 * password hash. Measured against the real project, 40 fresh addresses per branch:
 *
 *     registered, wrong password   p50 196.5ms   p95 277.3ms
 *     never registered             p50 166.9ms   p95 265.3ms
 *     difference                   mean 21.3ms, median 29.6ms, z = 3.01
 *
 * Real, and ~70 samples per branch to call it with 80% power. So it is equalised rather
 * than argued away. This number is above both failing branches and below what a *successful*
 * sign-in costs anyway — measured min 464.9ms, p50 866.2ms, because success additionally
 * reads and writes `users/{uid}` and mints a token — so the person this route exists for
 * pays nothing for it, and the person who mistyped their password waits an extra tenth of
 * a second on a request that was going to fail.
 *
 * A floor, not a constant delay: when Identity Toolkit is slower than this, nothing is
 * added and the residue is its own variance rather than the difference between the two
 * branches. Under enough load to push both branches past the floor the channel returns,
 * which is the honest limit of this approach and the reason the number has headroom.
 */
const SIGNIN_FLOOR_MS = 350

/** Runs `work` and does not return before `floor` milliseconds have passed, whichever
 *  takes longer. A failure inside `work` still waits, or the floor would only apply to
 *  the branch that succeeded — and a thrown error is a branch like any other. */
const atLeast = async <T>(floor: number, work: () => Promise<T>): Promise<T> => {
  const [outcome] = await Promise.all([
    // `Promise.resolve().then(work)`, not `work()`: a `work` that throws *synchronously*
    // would otherwise escape before the floor was armed, returning in no time at all —
    // the one input that defeats the whole helper. Unreachable from the three `async`
    // arrows that call it today, and the helper is generic now.
    Promise.resolve()
      .then(work)
      .then(
        (value) => ({ ok: true as const, value }),
        (err: unknown) => ({ ok: false as const, err }),
      ),
    new Promise((resolve) => setTimeout(resolve, floor)),
  ])
  if (!outcome.ok) throw outcome.err
  return outcome.value
}

/**
 * The per-IP throttle on the two routes a link lands on. They are unauthenticated, they
 * run a Firestore transaction per call, and they carry no address to count against — so
 * this is the only dimension there is. Guessing a token is infeasible at 256 bits; the
 * counter is here so the routes cannot be used as a free amplifier against Firestore.
 */
const throttleToken = (c: Context, route: TokenRoute) => {
  if (consumeTokenAttempt(route, clientIp(c))) return null
  return c.json(error('RATE_LIMITED', 'Too many attempts. Try again later.'), 429, {
    'retry-after': String(authRetryAfterSeconds('signin')),
  })
}

const parseToken = (value: unknown): string | null =>
  typeof value === 'string' && TOKEN_SHAPE.test(value) ? value : null

/**
 * A spent, unknown, or malformed token, and an expired one, are told apart — expiry is
 * the one the user can act on by asking for a new link. Neither says which account the
 * link named, and "used" is folded into "invalid" so the holder of a link cannot learn
 * whether someone else already clicked it.
 */
const tokenFailure = (c: Context, reason: 'invalid' | 'expired') =>
  reason === 'expired'
    ? c.json(error('TOKEN_EXPIRED', 'This link has expired. Request a new one.'), 400)
    : c.json(error('INVALID_TOKEN', 'This link is not valid. Request a new one.'), 400)

/**
 * Issues an activation token and sends the link. A delivery failure is deliberately not
 * the caller's failure: the account exists, the token is stored, and the gate screen has
 * a Resend — so `email.ts` has already written the one line an operator needs and the
 * typed error is swallowed here. Anything else (Firestore, on the token write) is a fault
 * of ours and still lands in `app.onError`.
 */
const sendActivationLink = async (uid: string | null, email: string): Promise<void> => {
  const token = await issueToken(uid, email, 'activation')
  try {
    await sendActivationEmail(email, token)
  } catch (err) {
    if (!(err instanceof EmailError)) throw err
  }
}

/** The reset counterpart: issuing also invalidates every earlier reset link. */
const sendResetLink = async (uid: string, email: string): Promise<void> => {
  const token = await issueToken(uid, email, 'reset')
  try {
    await sendPasswordResetEmail(email, token)
  } catch (err) {
    if (!(err instanceof EmailError)) throw err
  }
}

/**
 * Spends an activation token and stamps the account. Idempotent from the user's side: a
 * valid link on an account that is **already activated** is now a dead link, and that is a
 * deliberate change (#120). It used to answer `200` idempotently, on the grounds that the
 * thing the user did — prove the address — was done either way. That reasoning held while
 * activation only stamped a flag. It does not hold now that the link *sets the password*:
 * honouring a stale link against an activated account would make every unspent activation
 * email a password-reset primitive, usable by anyone who ever saw one. The token is consumed
 * either way, so it still cannot be replayed.
 */
const claimForActivation = async (uid: string, password: string): Promise<void> => {
  await setPassword(uid, password)
  await retractUnprovenIdentities(uid)
  // **And Eva's own sessions, not only Firebase's** (#76). `retractUnprovenIdentities`
  // revokes the account's refresh tokens; this is the same act on the session layer that
  // is actually in front of the user, and leaving the two disagreeing is how an
  // inconsistency of this kind gets written. Nothing to strand today — the route refuses
  // an already-activated account, and only an activated account can have a live session —
  // but that is true by the arrangement of three other routes rather than by anything
  // here. Deliberately *not* on the create path: there was no account to have sessions on.
  // The full rule, including what a provider unlink should do, is on `bumpTokenVersion`.
  await bumpTokenVersion(uid)
}

const activate = async (c: Context, raw: unknown, body: Record<string, unknown>) => {
  if (raw === undefined || raw === null || raw === '') {
    return c.json(error('VALIDATION', 'A token is required'), 400)
  }
  const token = parseToken(raw)
  if (!token) return tokenFailure(c, 'invalid')
  // Checked **before** the token is spent, exactly as the reset route does it: a weak
  // password costs the caller a retry, not their only link.
  const password = typeof body.password === 'string' ? body.password : ''
  if (!isValidPassword(password)) {
    return c.json(error('WEAK_PASSWORD', passwordFailure(password)), 400)
  }

  const result = await consumeToken(token, 'activation')
  if (!result.ok) return tokenFailure(c, result.reason)

  // **Here the address becomes proven and the credential comes into existence, in that
  // order, in one request** (#120). Sign-up created neither, which is the whole change:
  // there is no longer a window in which a working password sits on an address nobody has
  // confirmed.
  //
  // `result.uid` is null for a token sign-up issued. It is non-null only for a legacy
  // token minted before #120 against an account that already existed; those keep working
  // for their 24 hours rather than stranding whoever is mid-flow.
  const existingUid = result.uid ?? (await findAuthUidByEmail(result.email))

  // Resolve the account first, then run **one** set of guards over everything this
  // request did not itself create. An earlier version answered the race below inline,
  // with its own copy of the tail, and so skipped the two refusals the other branch
  // makes: two unspent links for one address — a sign-up plus a resend, opened on two
  // devices — let the second one overwrite the password the first had just set, on an
  // account that was by then activated. The dead-link rule has to hold on every path
  // that can reach an account somebody else already proved, not just the common one.
  let uid: string
  let created = false
  if (existingUid === null) {
    try {
      uid = await createAccountWithPassword(result.email, password)
      created = true
    } catch (err) {
      if (!(err instanceof IdentityToolkitError)) throw err
      // The address was taken between this caller's sign-up and their click — by
      // someone calling Identity Toolkit directly, which the public web API key
      // allows, or by a second link for the same address landing first. Whoever it
      // was cannot have *proved* the address, because proving it is this route, so
      // the holder of a valid link takes the account rather than being refused —
      // subject to the same guards as any other account that already existed.
      if (err.kind === 'email-exists') {
        const raced = await findAuthUidByEmail(result.email)
        if (!raced) throw err
        uid = raced
      } else if (err.kind === 'unavailable') {
        // #32: shaped, never a bare 500. `unavailable` is worth a retry and pages
        // an operator; `rejected` is something about the request our edge let
        // through.
        return upstreamUnavailable(c, 'signup', err)
      } else {
        return c.json(
          error('VALIDATION', "That email or password can't be used. Check them and try again."),
          400,
        )
      }
    }
  } else {
    uid = existingUid
  }

  if (!created) {
    const existing = await readUser(uid)
    // Gone or going: a delete landed between the email and the click. Answered as a
    // dead link rather than left to fall through — `setPassword` throws on a deleted
    // Auth user, which would page an operator with a 500 for what is just a stale link.
    if (existing.deleted) return tokenFailure(c, 'invalid')
    // Already proven by somebody. A valid link must not take an account away from an
    // owner who has one — that would be the takeover wearing a confirmation email.
    if (existing.user?.activated) return tokenFailure(c, 'invalid')
    await claimForActivation(uid, password)
  }

  // The account, not the token generation: this route answers `{ activated: true }` and
  // mints nothing, so there is no session here to stamp with one.
  const account = await ensureUser(uid, result.email, 'password')
  if (!account) return tokenFailure(c, 'invalid')
  if (!(await markActivated(uid))) return tokenFailure(c, 'invalid')
  // **Last, and the order is load-bearing.** `emailVerified` is what
  // `claimUnprovenAccount` reads to decide whether to apply its address test, and
  // `activatedAt` is what decides whether it runs the claim at all. Setting the first
  // before the second leaves a window — one dropped request wide — in which the claim is
  // armed and its address test is not, which is the one combination that claims
  // unconditionally. Setting it after inverts the failure: an activated account whose
  // merge-wipe is still armed, costing its owner a password on some later provider
  // sign-in and recoverable through reset. That is the direction to fail in.
  // **Not allowed to fail the request, now that it is last.** The account is activated and
  // the password is set by this point and the token is spent, so throwing here would show
  // the user an error for something that worked and page an operator for a link that did
  // its job — the same outcome the `deleted` guard above exists to avoid. A concurrent
  // `DELETE /me` is enough to cause it. What is lost by swallowing is Firebase's
  // `emailVerified`, which leaves the merge-wipe armed: a later provider sign-in may cost
  // this user their password, recoverable through reset. That is the direction to fail in,
  // and it is the same trade the ordering above is chosen for.
  try {
    await markCredentialsProven(uid, result.email)
  } catch {
    // No uid, no address, no reason string (GUARDRAILS 12) — this says only that an
    // account finished activation without its flag, which is what an operator needs.
    console.log(JSON.stringify({ event: 'credentials_unproven_after_activation' }))
  }
  return c.json({ activated: true })
}

// POST only, and the token is in the body. A `GET /auth/activate?token=…` would write
// the raw token into Cloud Run's request log — `httpRequest.requestUrl` carries the query
// string — which is the same secret `authTokens/` keeps by storing only a hash. The link
// in the email carries its token in the URL *fragment* for the same reason one layer out
// (`email.ts`), so the website's page has it and no server ever saw it.
app.post('/auth/activate', async (c) => {
  const throttled = throttleToken(c, 'activate')
  if (throttled) return throttled
  const body = await readBody(c)
  return activate(c, body.token, body)
})

/**
 * The two "send me a link" routes answer `200 { sent: true }` for every well-formed
 * address, registered or not, activated or not — for the reason `/auth/signin` answers a
 * wrong password and an unknown address identically (§3): whether an address has an Eva
 * account is not the caller's to learn. The throttle runs before the lookup, so a refused
 * request is refused the same way for both.
 *
 * The branches also have to answer in the same *time*, which they do not naturally: sending
 * costs a Firestore write and a POST to Postmark, not sending costs a lookup and nothing
 * else — hundreds of milliseconds against tens, readable from a single request. `atLeast`
 * holds both to a floor well above the slow branch, so the fast one cannot be told from it.
 * That is a floor, not a constant: a Postmark call slower than `SEND_LINK_FLOOR_MS` still
 * overruns it, and the residue is bounded by Postmark's own variance rather than by the
 * difference between doing the work and not. Answering before the send instead would be
 * exact, but Cloud Run throttles CPU after the response, so the email would go out whenever
 * the next request happened to arrive.
 *
 * **Which branch is the fast one differs between the two routes, and on `resend` it
 * inverted with #120.** On `forgot`, an address with no account is the fast one, as it
 * always was. On `resend` there is no account to look up until somebody activates, so the
 * fast branch is now the *activated* address — the one case that must not be mailed a fresh
 * link — and every other address does the send. So the residue above discriminates "this
 * address has an activated Eva account". That is deliberate to leave: it is the same fact
 * `POST /auth/signup` hands out flatly and for free as `409` against `201`, which §3 argues
 * for on its own terms. A tail-latency oracle, sampled at one request per address per
 * minute, buys nobody anything they cannot have in one request.
 */
app.post('/auth/activation/resend', async (c) => {
  const body = await readBody(c)
  const email = normalizeEmail(body.email)
  if (!email) return c.json(error('VALIDATION', 'A valid email is required'), 400)
  const throttled = throttleAuth(c, 'resend', email)
  if (throttled) return throttled

  await atLeast(SEND_LINK_FLOOR_MS, async () => {
    // A pending sign-up has no account to look up (#120), so this cannot ask Firebase
    // whether one exists the way it used to. What it asks instead is the only question
    // that should stop a link being sent: does the address already belong to somebody?
    //
    // Always addressed to `email`, the address the caller asked about, and never to
    // `users/{uid}.email`. Those are not the same fact: the lookup is `getUserByEmail`
    // against Firebase Auth, while the document's copy is written once at creation and
    // never rewritten, and an idToken holder can move their own Auth address with
    // `accounts:update` (the web API key is public). Sending to the stale copy mails a
    // live link for the victim's address to whoever moved it.
    const existingUid = await findAuthUidByEmail(email)
    if (existingUid) {
      const existing = await readUser(existingUid)
      // Proven, so taken. A resend must not hand a fresh link to an address whose
      // owner already has it — a valid activation link can claim an unproven account.
      if (existing.user?.activated) return
    }
    await sendActivationLink(null, email)
  })
  // `200 { sent: true }` for every well-formed address, registered or not (GUARDRAILS
  // 12b). That is unchanged, and is why the branch above returns silently rather than
  // answering differently.
  return c.json({ sent: true })
})

app.post('/auth/password/forgot', async (c) => {
  const body = await readBody(c)
  const email = normalizeEmail(body.email)
  if (!email) return c.json(error('VALIDATION', 'A valid email is required'), 400)
  const throttled = throttleAuth(c, 'forgot', email)
  if (throttled) return throttled

  await atLeast(SEND_LINK_FLOOR_MS, async () => {
    const uid = await findAuthUidByEmail(email)
    if (!uid) return
    // Activated or not: a reset proves control of the address as surely as the
    // activation link does, and the reset route stamps the account accordingly.
    const user = await getUser(uid)
    // `email`, not `user.email` — see the resend route above. This one is worse: the
    // reset route sets a password, stamps the account and calls `markCredentialsProven`,
    // so a link delivered to the wrong address hands over a password *and* an
    // `emailVerified` account at the victim's address, which disarms the merge-wipe that
    // would otherwise have evicted the attacker on the victim's next provider sign-in.
    if (user) await sendResetLink(uid, email)
  })
  return c.json({ sent: true })
})

/**
 * Spends a reset token, sets the password, and **mints a session**: the user has just
 * proven control of the address and chosen a password, which is more than a sign-in asks
 * for, and sending them back to the sign-in screen to type it again would be ceremony.
 * The password rule is checked *before* the token is spent, so a weak password costs the
 * user a retry, not the link.
 */
app.post('/auth/password/reset', async (c) => {
  const throttled = throttleToken(c, 'reset')
  if (throttled) return throttled
  const body = await readBody(c)
  if (body.token === undefined || body.token === null || body.token === '') {
    return c.json(error('VALIDATION', 'A token is required'), 400)
  }
  const token = parseToken(body.token)
  if (!token) return tokenFailure(c, 'invalid')
  const password = typeof body.password === 'string' ? body.password : ''
  if (!isValidPassword(password)) {
    return c.json(error('WEAK_PASSWORD', passwordFailure(password)), 400)
  }

  const result = await consumeToken(token, 'reset')
  if (!result.ok) return tokenFailure(c, result.reason)
  // Non-null for every reset token by construction — `/auth/password/forgot` looks the
  // account up before issuing one, and only sign-up's activation tokens are issued
  // without a uid (#120). Narrowed rather than asserted, so a future issuer that forgets
  // that is a dead link instead of a crash.
  if (result.uid === null) return tokenFailure(c, 'invalid')
  const uid = result.uid
  // The token proves the mailbox it was sent to, not whichever address this uid happens
  // to hold now (#140). An idToken holder can move their Auth address out of band; letting
  // an older reset token continue would set a password and stamp that new address proven.
  // Compare before changing any credential. The issue originally expected this comparison
  // to reuse an Auth read, but this route had none: the authoritative lookup is one new round
  // trip, and doing it after updateUser(password) would discover the mismatch only after the
  // credential had already changed. There is no supported Eva address-change flow, so the
  // safe recovery from a mismatch is a fresh link for the current address.
  const currentAddress = await addressOfAuthAccount(uid)
  if (normalizeEmail(currentAddress.address) !== result.email) {
    return tokenFailure(c, 'invalid')
  }
  // Gone or going: the credentials must not be reset on an account mid-delete, and the
  // link is as dead as the account.
  const user = await getUser(uid)
  if (!user) return tokenFailure(c, 'invalid')
  // The link proved `result.email`, and the comparison above made that the Auth account's
  // address too — but the *document* can still name another one (#119). That is the
  // Firebase-merge case reached by its other door: the owner of an address whose Auth
  // account was repointed at it out of band asks for a reset, and would be handed a
  // session on the document — profile, events — of whoever repointed it. Refused before
  // anything is written, like every other dead link on this route.
  if (!sameAddress(user.email, result.email)) return tokenFailure(c, 'invalid')

  // **Every other session ends here** (#76), and this is the whole of the decision: the
  // reason a woman resets her password is usually that somebody else has it, so a reset
  // that leaves the other session live defeats its own purpose. Not an opt-in — a second
  // control is found by the people who need it least.
  //
  // **Before `setPassword`, deliberately.** The two can only fail in one order, so pick
  // the safe one: bump-then-fail signs everyone out and leaves the old password working,
  // which costs her a sign-in she can complete; set-then-fail changes the password and
  // leaves the attacker's session alive, which is the exact state this exists to prevent.
  // Annoying beats insecure.
  //
  // `null` is the account going away since the read two lines up — a dead link, the same
  // answer that read gives.
  const tokenVersion = await bumpTokenVersion(uid)
  if (tokenVersion === null) return tokenFailure(c, 'invalid')

  await setPassword(uid, password)
  // Same retraction as the activation route, and reachable by the same person: this is
  // the recovery an owner is sent to when someone else has reserved their address, so it
  // has to take that person's credentials away rather than merely reset the password.
  //
  // Keyed on the state read *above*, before anything was written, and run before the
  // stamp — see the activation route for why that order matters. Only when the account
  // was not already activated: someone who linked Apple deliberately from Profile and
  // then forgot their password must still have Apple afterwards.
  if (!user.activated) await retractUnprovenIdentities(uid)
  // Safe here because a reset proves address control *and* sets the password in the same
  // request, so the credentials are demonstrably the caller's. Activation now meets that
  // same condition (#120) and calls it too — it did not before, when sign-up set the
  // password and activation only proved the address, and the two could be different
  // people.
  //
  // Proof of control of the address, whichever link it came by. A delete landing since
  // the read above answers a dead link rather than a session for a tombstone.
  if (!(await markActivated(uid))) return tokenFailure(c, 'invalid')
  // **Last, and in the same order as the activation route** — the invariant `api/CLAUDE.md`
  // states, which this route used to be the one exception to (#127). `emailVerified` turns
  // off `claimUnprovenAccount`'s address test and `activatedAt` turns off the claim itself,
  // so any window carrying the first without the second is the one combination that claims
  // unconditionally.
  //
  // It was never exploitable here: `retractUnprovenIdentities` above has already unlinked
  // an attacker's `sub` and revoked their refresh tokens, so a fresh `signInWithIdp` with
  // their credential resolves elsewhere and the claim's read-back refuses anyway. The
  // reason to fix it is that two other places asserted the ordering was absolute while
  // this one contradicted them, which is how the window gets re-introduced somewhere it
  // *is* reachable.
  //
  // Unconditional rather than transition-only: a long-activated user who resets has just
  // proven the password whoever they are, and a wipe on their next provider sign-in would
  // be pure loss.
  //
  // **Not allowed to fail the request, now that it is last**, for the reason the activation
  // route gives at greater length: the password is set and the token is spent by this
  // point, and this route also mints a session. Throwing here would show the user an error
  // for a reset that worked and page an operator for a link that did its job. What is lost
  // by swallowing is Firebase's `emailVerified`, which leaves the merge-wipe armed — a
  // later provider sign-in may cost this user their password, recoverable through another
  // reset. That is the direction to fail in, and it is the same trade the ordering is
  // chosen for.
  try {
    // Writes the proved address together with the flag, closing the narrower race in which
    // `accounts:update` moves it after the comparison above but before this final stamp.
    await markCredentialsProven(uid, result.email)
  } catch {
    // No uid, no address, no reason string (GUARDRAILS 12).
    console.log(JSON.stringify({ event: 'credentials_unproven_after_reset' }))
  }
  // **The device that performed the reset keeps its session, and this line is how** (#76).
  // It is identified by being the one the new token is handed to — not by a heuristic, a
  // device id or a cookie, none of which this API has. The token minted here is the only
  // one carrying the generation the bump just created; every session outstanding before
  // it carries a lower one and is refused at the account gate on its next request. So she
  // stays signed in on the phone she is holding and is signed out everywhere else, which
  // is the outcome the issue asked for without needing to identify anything.
  // Read **after** the retraction above, never beside `getUser`: the federated half of
  // `authProviders` (#117) has to describe the account as this route leaves it, and on the
  // activation path the retraction has just unlinked every identity it held.
  const federated = await federatedProvidersOf(uid)
  if (!federated) return tokenFailure(c, 'invalid')
  return c.json({
    token: await mintToken(uid, user.email, tokenVersion),
    user: servedUser({ ...user, activated: true }, federated),
  })
})

// ── Sign in with Apple and Google (#7) ─────────────────────────────────────────
// The app never talks to Apple, Google or Firebase (ARCHITECTURE §2): it obtains a
// provider credential natively and sends *that* here, and this spends it through
// `identity-toolkit.ts` — the same seam the password path already goes through, and still
// the only place the web API key lives.
//
// **This code never matches on email. Firebase does, and that is the whole design.**
// `signInWithIdp` returns the uid Firebase keyed to the provider's `sub`; `ensureUser`
// lands on that document. Whether an address that already has a password account resolves
// to the *same* uid is the console setting `Authentication → Settings → User account
// linking`, set to "Link accounts that use the same email" (decided 2026-09-03). So a
// Google sign-in on an existing address logs into that account, which is what the PRD's
// edge case always asked for. Do not add a lookup here: the rule lives in one place, and a
// second copy is how the two come to disagree invisibly.
//
// Hide My Email is the case the setting cannot help — a relay address matches nothing, so
// those users get a new account regardless, and `POST /me/auth/providers` is their only
// route into an existing one.
//
// **`claimUnprovenAccount` below is what makes the linking safe, and is not optional.**
// Sign-up creates the Auth user before the address is confirmed, and the web API key is
// public, so anyone can pre-register an address and attach their own provider identity to
// it directly at Identity Toolkit. Deleting that call re-opens an account takeover; the
// full walk-through is on the function.
//
// Nothing here stores a display name, and nothing widens `users/{uid}`. Apple offers a name
// on first authorization and Eva shows a name nowhere, so collecting it would be personal
// data held for no purpose (#7's decision) — it is dropped where it arrives, which is
// `signInWithIdp`, which never asks for it.

/** A ceiling on the opaque credentials the app forwards. An Apple `identityToken` is a JWT
 *  of a few hundred bytes and an authorization code is shorter; 4096 is far above either
 *  and far below anything worth carrying to a provider on a caller's say-so. */
const PROVIDER_TOKEN_MAX_LENGTH = 4096
const REDIRECT_URI_MAX_LENGTH = 512

/** Apple's authorization code on `DELETE /me`. Same reasoning, smaller thing. */
const APPLE_AUTH_CODE_MAX_LENGTH = 2048

/**
 * What the client sends, per provider. Apple is native — the app already holds an
 * `identityToken` — and `rawNonce` is the nonce it hashed into its `ASAuthorization`
 * request, which is required rather than optional: without it Firebase has nothing to check
 * a replayed token against.
 *
 * Google is PKCE against a *public* iOS OAuth client, so what comes back from the dance is
 * an authorization code and there is no client secret anywhere in it — that is what keeps
 * the GoogleSignIn SDK out of the app (GUARDRAILS 25).
 */
type ProviderCredential =
  | { provider: 'apple'; identityToken: string; rawNonce: string }
  | { provider: 'google'; code: string; codeVerifier: string; redirectUri: string }

type CredentialCheck = { ok: true; value: ProviderCredential } | { ok: false; message: string }

/** Echoed to Google, which checks it against the client the code was issued for. Parsed
 *  only for shape — the app's is a custom scheme (`com.googleusercontent.apps.…:/…`), so
 *  this cannot demand https. */
const isRedirectUri = (value: unknown): value is string => {
  if (!isBounded(value, REDIRECT_URI_MAX_LENGTH)) return false
  try {
    new URL(value)
    return true
  } catch {
    return false
  }
}

/** Validation at the edge, for both provider routes (GUARDRAILS 13). Nothing below this
 *  line inspects the shape of a request again. */
const parseProviderCredential = (body: Record<string, unknown>): CredentialCheck => {
  if (body.provider === 'apple') {
    if (
      !isBounded(body.identityToken, PROVIDER_TOKEN_MAX_LENGTH) ||
      !isBounded(body.rawNonce, PROVIDER_TOKEN_MAX_LENGTH)
    ) {
      return { ok: false, message: 'identityToken and rawNonce are required' }
    }
    return {
      ok: true,
      value: {
        provider: 'apple',
        identityToken: body.identityToken,
        rawNonce: body.rawNonce,
      },
    }
  }
  if (body.provider === 'google') {
    if (
      !isBounded(body.code, PROVIDER_TOKEN_MAX_LENGTH) ||
      !isBounded(body.codeVerifier, PROVIDER_TOKEN_MAX_LENGTH) ||
      !isRedirectUri(body.redirectUri)
    ) {
      return {
        ok: false,
        message: 'code, codeVerifier and redirectUri are required',
      }
    }
    return {
      ok: true,
      value: {
        provider: 'google',
        code: body.code,
        codeVerifier: body.codeVerifier,
        redirectUri: body.redirectUri,
      },
    }
  }
  return { ok: false, message: "provider must be 'apple' or 'google'" }
}

/**
 * The OIDC token to spend at Firebase, whichever dance produced it. Apple's arrives with
 * the request; Google's has to be fetched from its token endpoint with the code verifier,
 * which is the one outbound call `providers.ts` exists for.
 *
 * `index.ts` does no `fetch` of its own here (ARCHITECTURE §3) — it decides which module
 * answers the question and nothing else.
 */
const providerIdToken = async (credential: ProviderCredential): Promise<IdpCredential> =>
  credential.provider === 'apple'
    ? {
        provider: 'apple',
        idToken: credential.identityToken,
        rawNonce: credential.rawNonce,
      }
    : { provider: 'google', idToken: await exchangeGoogleAuthCode(credential) }

/** Per IP and only per IP — `ProviderRoute` says why there is no per-address dimension.
 *  Counted after validation and before either upstream call, exactly as the password
 *  routes' throttle is, so a refused request costs nothing and can depend on nothing. */
const throttleProvider = (c: Context, route: ProviderRoute) => {
  if (consumeProviderAttempt(route, clientIp(c))) return null
  return c.json(error('RATE_LIMITED', 'Too many attempts. Try again later.'), 429, {
    'retry-after': String(authRetryAfterSeconds('signin')),
  })
}

/**
 * The one thing a caller is told about a provider credential that did not work: an expired
 * Apple token, a nonce that does not match, a code already spent, a code minted for another
 * client. All one answer, in our words, with nothing of the provider's own reason in it
 * (GUARDRAILS 12) — the caller's recovery is the same for every one of them, which is to
 * start the sign-in again.
 */
const PROVIDER_REJECTED = "That sign-in couldn't be completed. Please try again."

/**
 * The operator's half of a refused provider sign-in.
 *
 * `PROVIDER_REJECTED` is one message for five different refusals, on purpose — the caller's
 * recovery is identical for all of them and telling them apart would say whether an address
 * has an account (GUARDRAILS 12b). But nothing wrote a log line either, so *nobody* could
 * tell them apart, including us. The first real Apple sign-in on a device failed with that
 * message and there was no way to learn whether Firebase had refused the token, the claim
 * had refused the account, or the account was mid-delete.
 *
 * `stage` closes that, and carries nothing else: no address, no uid, no provider reason
 * string, no token. It says *which branch*, not *who*.
 */
const refuseProvider = (
  c: Context,
  route: ProviderRoute,
  stage: 'credential' | 'upstream' | 'deleted' | 'address' | 'claim' | 'deleted-race',
) => {
  console.error(JSON.stringify({ event: 'provider_signin_refused', route, stage }))
  return c.json(error('INVALID_CREDENTIALS', PROVIDER_REJECTED), 401)
}

/**
 * Maps both upstream boundaries — Firebase's and the provider's own — onto the contract,
 * by the rule ARCHITECTURE §3 already states for Identity Toolkit: **the status decides
 * before the reason does**, and the reason string reaches no body, header, or log line.
 *
 * `null` means this was not an upstream failure at all, and the caller rethrows so
 * `app.onError` answers it as the bug it is.
 */
const providerFailure = (c: Context, route: ProviderRoute, err: unknown) => {
  if (err instanceof IdentityToolkitError) {
    if (err.kind === 'unavailable') return upstreamUnavailable(c, route, err)
    // The `sub` is attached to a different Eva account. Answered plainly rather than
    // merged: merging two accounts on a credential is the account-takeover shape #7
    // rejected, and only the holder of a session for one account and a provider
    // credential for the other can ever see this.
    if (err.kind === 'provider-linked') {
      return c.json(
        error(
          'PROVIDER_ALREADY_LINKED',
          'That Apple or Google account is already connected to another Eva account.',
        ),
        409,
      )
    }
    return refuseProvider(c, route, 'credential')
  }
  if (err instanceof ProviderError) {
    if (err.kind === 'rejected') {
      return refuseProvider(c, route, 'upstream')
    }
    // The operator's signal, and separable from `identity_toolkit_unavailable` because
    // it is a different upstream with a different fix. `kind` distinguishes an outage
    // at Apple or Google (`unavailable`) from credentials this deploy was never given
    // (`unconfigured`) — the second is a page, not a retry. Both are constants of ours;
    // no code, no token, no address (GUARDRAILS 12).
    console.error(
      JSON.stringify({
        event: 'provider_endpoint_unavailable',
        route,
        kind: err.kind,
        upstreamStatus: err.upstreamStatus,
      }),
    )
    return serviceUnavailable(c)
  }
  return null
}

/**
 * Sign in — or sign up; with a provider they are the same request, which is the point.
 *
 * **The session comes back activated**, and that is a decision rather than an oversight
 * (#7). Google's address is verified and Apple's relay is Apple's own, so a provider
 * sign-in proves the address at least as well as the link we email does — and without this,
 * every Apple user would hit `403 NOT_ACTIVATED` from #6 and we would send a confirmation
 * link to a relay address to prove something Apple has already proved.
 */
app.post('/auth/idp', async (c) => {
  const body = await readBody(c)
  const parsed = parseProviderCredential(body)
  if (!parsed.ok) return c.json(error('VALIDATION', parsed.message), 400)
  const throttled = throttleProvider(c, 'idp')
  if (throttled) return throttled

  try {
    const { localId, email } = await signInWithIdp(await providerIdToken(parsed.value))
    // A **read**, deliberately, and before anything else. `ensureUser` writes, and nothing
    // may be written on the say-so of a credential this route is about to refuse. Found
    // as the refused provider left permanently in the stored `authProviders` of the
    // account it collided with, where Profile read it to decide whether to offer "Connect
    // Apple". Since #117 the served list takes Apple and Google from Auth, not from that
    // array — and what keeps a refused identity out of it is that a refusal mints nothing
    // and leaves the account unactivated, and every path that activates one
    // (`claimForActivation`, the reset, the claim below) strips federated identities
    // first. The order here still matters for the tombstone and the claim.
    const existing = await readUser(localId)
    // Mid-deletion, the same case `/auth/signin` refuses: the credential is real and
    // that is exactly why this must not mint a token, or a provider sign-in would walk
    // an account back out of its own deletion.
    if (existing.deleted) {
      return refuseProvider(c, 'idp', 'deleted')
    }
    // **The document must name the address the Auth account holds (#119)**, and it is
    // asked of Firebase, because `email` above is the provider token's own claim and not
    // the account's. That distinction is what makes this safe to enforce:
    //
    // - After a Firebase *merge* — "link accounts that use the same email" — the account
    //   holds the credential's address by construction; that equality is why Firebase
    //   merged. So a document naming another address is the case #119 describes: an
    //   account repointed at an unregistered victim, merged into on their first Google
    //   sign-in, whose profile and events are the repointer's. Refused, before the claim
    //   below can write anything, with the answer every refused credential gets.
    // - A `sub` already linked — Apple's relay on a password account, via
    //   `POST /me/auth/providers`, or an Apple ID whose address changed — keeps the
    //   account's own address, because Firebase neither merges nor rewrites it there. Its
    //   token claim differs from the document and always will, so comparing against the
    //   claim would lock out exactly the returning users the link route exists for.
    //
    // **With no document yet, the claim is the only witness, so it has to agree too.**
    // Otherwise the same attack runs in the other order: create an Auth account with
    // one's own Apple identity at Firebase directly, repoint its address at a victim, and
    // sign in here first — the document would be born naming the victim, activated, and
    // pass the comparison above on the victim's later merge. On a fresh provider account
    // Firebase copied the claim onto the account, so the two agree; a returning Apple
    // user whose token carries no address gets the account's address from
    // `signInWithIdp` itself, so they agree there too. Only an address moved out of band
    // separates them. Both checks run before the claim below, so a refusal writes nothing.
    const { address } = await addressOfAuthAccount(localId)
    if (!sameAddress(existing.user ? existing.user.email : email, address)) {
      return refuseProvider(c, 'idp', 'address')
    }
    // An unactivated account is one nobody has proven they own, and #6 creates it
    // before the address is confirmed — so every credential already on it was attached
    // by someone unverified. `claimUnprovenAccount` takes them all away, keeping only
    // the provider that just signed in, before the line below marks the account
    // activated on that person's behalf.
    //
    // The condition is `!user.activated` **alone**. An earlier version also required
    // `authProviders` to contain "password", which reads Eva's Firestore document rather
    // than Firebase's record of the account — and those diverge in exactly the case
    // that matters, because sign-up writes the Auth user before the document.
    // `claimUnprovenAccount` reads Firebase's `providerData`, the authoritative record.
    //
    // Fails **closed**: the throw is not a provider failure, so it falls through to
    // `app.onError` as a 500 and no token is minted. Continuing would hand out a
    // session for an account still carrying credentials we meant to take away.
    if (!existing.user?.activated) {
      const outcome = await claimUnprovenAccount(localId, PROVIDER_IDS[parsed.value.provider])
      // `refused` means the address on this account was reserved by someone who never
      // proved it, and this provider is not them. Answering as for any bad credential
      // is deliberate: it says nothing about whether the address is registered
      // (GUARDRAILS 12b), and returning here is what keeps `markActivated` below from
      // stamping the account on the attacker's behalf — which is the step that would
      // disarm the claim for the real owner's later sign-in.
      if (outcome === 'refused') {
        return refuseProvider(c, 'idp', 'claim')
      }
    }
    // Only now, once the credential has earned the account. The second tombstone check
    // is `ensureUser`'s own, and closes the window between the read above and this
    // write: a `DELETE /me` landing in between must still win.
    //
    // Auth's half of `authProviders` (#117) is read here too, after the claim and not
    // before it, so it describes the account the claim left — never an identity the claim
    // just stripped.
    const [account, federated] = await Promise.all([
      ensureUser(localId, address ?? email, PROVIDER_IDS[parsed.value.provider]),
      federatedProvidersOf(localId),
    ])
    if (!account || !federated) return refuseProvider(c, 'idp', 'deleted-race')
    // The claim above has already taken the account, so there is nothing left to
    // retract — and `proveAddress` must not run here: a provider sign-in would unlink
    // the very identity that just signed in.
    await markActivated(localId)
    // A provider sign-in mints at the account's current generation and bumps nothing:
    // signing in with Apple takes no credential away from anyone. `claimUnprovenAccount`
    // above is the one thing on this path that does, and it can only run on an
    // unactivated account — which, by the argument on `bumpTokenVersion`, has no
    // sessions to end.
    // The account's address, not the provider's claim: the two differ for a linked relay,
    // and a token that said one thing while `GET /me` said another is how #119 was found.
    return c.json({
      token: await mintToken(localId, account.user.email, account.tokenVersion),
      user: servedUser({ ...account.user, activated: true }, federated),
    })
  } catch (err) {
    const answer = providerFailure(c, 'idp', err)
    if (answer) return answer
    throw err
  }
})

/**
 * Attaches a provider to **the account the bearer token names** — the deliberate link #7
 * put in place of automatic email matching, and the only way an existing email/password
 * account ever gains an Apple or Google credential.
 *
 * How, and why this way: the Admin SDK mints a custom token for the signed-in uid,
 * `identity-toolkit.ts` exchanges it for a Firebase ID token, and `signInWithIdp` links
 * against that. Every step stays inside seams that already exist and adds no dependency.
 * The one-call alternative — `adminAuth.updateUser(uid, { providerToLink })` — takes a
 * `sub` we would have had to verify ourselves, which means owning Apple's and Google's JWKS
 * and the nonce check; letting Firebase remain the only validator of a provider token is
 * the same choice ARCHITECTURE §2 makes for passwords.
 */
app.post('/me/auth/providers', requireAuth, requireAccount, async (c) => {
  const body = await readBody(c)
  const parsed = parseProviderCredential(body)
  if (!parsed.ok) return c.json(error('VALIDATION', parsed.message), 400)
  const throttled = throttleProvider(c, 'link')
  if (throttled) return throttled

  const account = c.get('account')
  try {
    // The provider credential is resolved first, so a code that was never going to work
    // fails before we mint a Firebase session for the account it would have joined.
    const credential = await providerIdToken(parsed.value)
    const { localId } = await signInWithIdp(credential, await idTokenForUid(account.id))
    // Linking that landed on another account would mean Firebase merged rather than
    // linked — the console setting in step 0 of docs/PROVIDER-SIGNIN.md. There is no
    // safe answer to give a caller for that, so it is raised as the fault it is and
    // `app.onError` answers 500 with a `ref`.
    if (localId !== account.id) {
      throw new Error('signInWithIdp resolved a different account')
    }
    // No bump: linking adds a credential and removes none, so the caller's other
    // devices have no reason to be signed out (see `bumpTokenVersion` for the rule,
    // and for what an unlink route would owe instead).
    // The answer's `authProviders` takes the new identity from Auth, which the link above
    // has just written (#117) — so it is read after that, beside the document write.
    const [linked, federated] = await Promise.all([
      ensureUser(account.id, account.email, PROVIDER_IDS[parsed.value.provider]),
      federatedProvidersOf(account.id),
    ])
    // A delete landed between the account gate and here.
    if (!linked || !federated) {
      return c.json(error('UNAUTHORIZED', 'Invalid or expired token'), 401)
    }
    return c.json({ user: servedUser(linked.user, federated) })
  } catch (err) {
    const answer = providerFailure(c, 'link', err)
    if (answer) return answer
    throw err
  }
})

/**
 * Apple's revocation step on account deletion (#7). Never throws and never fails the
 * delete: revocation not happening is a compliance problem, revocation stopping a deletion
 * is a data problem, and the second is worse. One log line, of the same no-PII shape as
 * every other upstream failure — a stage and a status, no code, no uid, no address.
 */
const revokeApple = async (authorizationCode: string): Promise<void> => {
  const outcome = await revokeAppleToken(authorizationCode).catch(() => null)
  if (outcome?.ok) return
  console.error(
    JSON.stringify({
      event: 'apple_revocation_failed',
      stage: outcome?.stage ?? 'threw',
      upstreamStatus: outcome?.upstreamStatus ?? null,
    }),
  )
}

app.get('/me', requireAuth, requireServedAccount, (c) => c.json({ user: c.get('served') }))

/**
 * Her data, as one JSON file the app saves (#58; GDPR Art. 15 and 20, CCPA access —
 * LAUNCH.md §2.3). Decided on the issue: JSON, delivered as an in-app download — no email,
 * no link, so the export exists nowhere but in this response and on her device.
 *
 * `{ format, version, exportedAt, account, nutritionProfile, events, today }`: `account` is
 * exactly what `GET /me` answers — the same gate, `requireServedAccount`, so the same assembled
 * `authProviders` (#117) — `nutritionProfile` exactly what `GET /me/nutrition/profile` answers,
 * or `null` before setup is started (#221), `events` is every stored entry in `GET /me/events`' shape **including
 * soft-deleted ones** (their `deletedAt` is what marks them), `today` every stored card in
 * `GET /me/today`'s shape. ARCHITECTURE §4 "Data export" lists what is deliberately left out
 * — credentials, the session generation, cache bookkeeping — and why.
 *
 * **Streamed, because an account is unbounded.** Twenty thousand entries read with one
 * `.get()` would be the whole history in memory at once; the owning modules hand pages over
 * instead, and `data-export.ts` writes each one out before the next is read. That moves the
 * failure mode, and the route is shaped around it: the account was read by the gate and the
 * first page of each collection is read before the headers go, so a Firestore that is down
 * at the start is an ordinary `500 INTERNAL`; a failure on a later page cuts the body short,
 * and a short body is never valid JSON because the closing brackets are written last.
 *
 * Throttled per account and per IP (`consumeExportAttempt`) — the one authenticated read
 * that is, because it is the only one whose cost grows with the account. Not behind
 * `requireCollectConsent`: reading her own data is not collecting it, and the freeze a
 * withdrawal starts says stored data leaves by export or by `DELETE /me`.
 *
 * Nothing about it is logged except, on a mid-stream failure, the error's class name — not
 * the uid, not a count, not a date (GUARDRAILS 12).
 */
app.get('/me/export', requireAuth, requireServedAccount, async (c) => {
  const uid = c.get('claims').sub
  if (!consumeExportAttempt(clientIp(c), uid)) {
    return c.json(error('RATE_LIMITED', 'Too many attempts. Try again later.'), 429, {
      'retry-after': String(config.rateLimit.windowSeconds),
    })
  }

  const exportedAt = new Date().toISOString()
  const pageSize = config.dataExport.pageSize
  // Read whole, here, before a header exists — a failure is an ordinary 500, like the account's.
  const nutritionProfile = await getNutritionProfile(uid)
  const body = await openExport({
    exportedAt,
    // The served `User`, never the gate's `UserRecord` (#117): `authProviders` assembled
    // from Auth and the stored password fact, and no `passwordChosen` key in her file.
    account: c.get('served'),
    nutritionProfile,
    events: exportEvents(uid, pageSize),
    today: exportTodayCards(uid, pageSize),
    onAbort: (err) => {
      console.error(
        JSON.stringify({ event: 'export_aborted', route: '/me/export', errorName: errorName(err) }),
      )
    },
  })
  return new Response(body, {
    status: 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'content-disposition': `attachment; filename="${exportFilename(exportedAt)}"`,
      // Her whole history: nothing between here and the device keeps a copy.
      'cache-control': 'no-store',
    },
  })
})

/**
 * Account deletion is **immediate and complete** (#8): no grace period, no delayed purge,
 * nothing recoverable — including entries inside their own 30-day event window, because a
 * recovery window inside an account that no longer exists is a promise to nobody.
 *
 * The order is the design, and it is chosen so that every partial failure is safe *and*
 * resumable rather than fast:
 *
 *   1. while the account is still live, delete its uid-linked tokens and, only for a
 *      proven address, the pre-account tokens whose uid is null (#139);
 *   2. mark the user document deleted — one write, and from that instant the account is
 *      inert: every gated route 401s and sign-in refuses to revive it;
 *   3. delete the Firebase Auth user — the credentials stop opening anything and the
 *      address is free to sign up again;
 *   4. delete every event, soft-deleted ones included, every stored Today card, and the
 *      nutrition profile;
 *   5. delete the user document, which is the tombstone step 2 wrote.
 *
 * Address-keyed link cleanup goes before the tombstone so a new holder cannot race into
 * its sweep; health data goes after the mark and before the document is removed. The
 * invariant that ordering buys is: **a missing user document implies a missing Auth user**, so there is no
 * state in which health data outlives its owner unmarked, and none in which somebody can
 * sign in to an account whose document has already gone (which is what would let
 * `ensureUser` create a fresh one). The cost is the milder failure mode — an interrupted
 * delete can leave an Auth user with no data behind it — and that resolves itself: the
 * account is already unusable, and a retry finishes the job.
 *
 * Every step is idempotent, so this route is too: deleting twice is a `200`, not an error.
 * It is also the one authenticated route deliberately *not* behind `requireAccount` — the
 * gate would reject the very token a client needs to retry with. What that token can still
 * do here is re-delete an account that is already gone, which is nothing.
 *
 * **The session check is not part of that exception (#76).** "A password reset invalidates
 * every session" has to be true of the route that destroys the account, or it is a
 * sentence rather than a property — a superseded session locked out of every read while
 * still able to delete everything is worse than no revocation at all. So the generation is
 * checked here by hand, and only *while there is still a document to check it against*:
 * the retry the exception exists for happens after the tombstone is stamped, where
 * `getAccount` answers `null` and this falls straight through, exactly as before.
 */
app.delete('/me', requireAuth, async (c) => {
  // Bounds the weaker, address-keyed half of token cleanup. Two deletes can overlap; a
  // delayed request must not erase a link issued after the faster one released the address.
  const tokenDeletionCutoff = new Date()
  const claims = c.get('claims')
  const { sub } = claims
  // One read, on a route that already makes a dozen round trips — not the per-request
  // cost `requireAccount` is careful about. `null` is "no account, or one already being
  // deleted", which is the retry case and proceeds.
  const live = await getAccount(sub)
  if (live && tokenVersionOf(claims) !== live.tokenVersion) {
    return c.json(error('UNAUTHORIZED', 'Invalid or expired token'), 401)
  }
  // An **optional** fresh Apple authorization code (#7), obtained by the app re-prompting
  // for authorization just before it calls this. Optional because deletion cannot depend
  // on it: an old client, a user who declines the prompt, or a request built by anything
  // else must still delete the account. Absent, this route is exactly what it was.
  //
  // A code and not a stored refresh token, deliberately: keeping Apple's refresh token
  // would put a long-lived third-party credential in a health app's user document and
  // would widen `users/{uid}`, which #7 does not do. See `providers.ts` for the cost.
  const body = await readBody(c)
  // Absent and malformed are **not** the same answer, though one expression used to give
  // them one. Absent is the documented case above and deletes without revoking. Present
  // but over-long or not a string is a client bug, and folding it into "absent" meant the
  // account was deleted with Apple's entitlement quietly unmet — no error, no log line,
  // and nothing the caller could see. Every other field on this API is refused at the
  // edge; this one now is too.
  const rawAppleCode = body.appleAuthorizationCode
  const supplied = rawAppleCode !== undefined && rawAppleCode !== null
  if (supplied && !isBounded(rawAppleCode, APPLE_AUTH_CODE_MAX_LENGTH)) {
    return c.json(
      error('VALIDATION', 'appleAuthorizationCode must be a short, non-empty string'),
      400,
    )
  }
  const appleAuthorizationCode = supplied ? (rawAppleCode as string) : null
  // Per account, after validation and before the first write or upstream call (#119) — the
  // same place every other throttle sits. Without it one token replays this route for the
  // thirty days it lives: a POST to Apple, a tombstone write, a sweep and a log line each
  // time. The budget is several deletes and their retries, so the idempotence the retry
  // depends on is untouched inside it; `consumeDeleteAttempt` says why there is no per-IP
  // dimension. The Apple code is still not bound to *this* account's Apple identity: that
  // would mean verifying the `id_token` Apple returns, which is JWKS work `providers.ts`
  // deliberately does not own, and ARCHITECTURE §3 records what leaving it costs.
  if (!consumeDeleteAttempt(sub)) {
    return c.json(error('RATE_LIMITED', 'Too many attempts. Try again later.'), 429, {
      'retry-after': String(authRetryAfterSeconds('signin')),
    })
  }

  // Read **from Firebase Auth**, and before `deleteAuthAccount` below removes it, for the
  // token sweep — which since #120 cannot find an activation token by uid, because there
  // was no uid when it was issued. Not from `users/{uid}.email`: that copy is written once
  // at creation and can be left pointing at an address the account no longer holds (#121),
  // and as a *delete* key a stale address wipes somebody else's live links.
  const { address, proven } = await addressOfAuthAccount(sub)
  // Sweep while Auth still reserves the address *and* the live activated document makes
  // sign-up refuse it. After the tombstone, sign-up can treat this Auth account as an
  // unactivated reservation and issue a new uid-null token; after Auth deletion the address
  // is free outright. Either ordering would let this delete erase the next holder's link.
  // The uid half remains unconditional. A moved, unproven address is skipped: stranding
  // this account's own pre-account token until TTL is safer than deleting another person's.
  // The request-start cutoff also makes overlapping deletes safe: neither can touch a link
  // issued to the address's next holder after deletion began.
  await deleteTokensForAccount(sub, live !== null && proven ? address : null, tokenDeletionCutoff)
  await markUserDeleted(sub)
  // After the tombstone, so the account is already inert whatever Apple answers, and
  // before the Auth user goes, so the ordering below is untouched. Revocation is Apple's
  // requirement of any app offering Sign in with Apple *and* in-app deletion, and App
  // Review rejects on its absence.
  if (appleAuthorizationCode) await revokeApple(appleAuthorizationCode)
  await deleteAuthAccount(sub)
  await deleteAllUserEvents(sub)
  // With the events, not after the document: a stored card is her own logged data written
  // out as prose, so leaving it would make `today/` the one readable summary of an account
  // that no longer exists. Before `deleteUserDocument` for the same reason the events are —
  // a subcollection outlives its parent document in Firestore.
  await deleteAllUserToday(sub)
  // Her nutrition setup answers (#221) — a goal and a target weight are health facts, and the
  // subcollection outlives the document if it is left for later.
  await deleteNutritionProfile(sub)
  // The device registry and the notification queue (#79, A9) — a device token is an
  // identifier for a user, and a queued notification is intent about her, so both go with
  // the account rather than outliving it. Subcollections outlive the document, so before it.
  await deleteAllUserDevices(sub)
  await deleteAllUserNotifications(sub)
  await deleteUserDocument(sub)
  // The address's own throttle counters go with it (#56). In-memory and per-instance, so
  // this is a small courtesy rather than a guarantee — but being refused a fresh sign-up
  // by the attempts of the account you just deleted is confusing in a flow people reach
  // at an emotional moment, and it protects nothing: there is no account behind that
  // address any more. Per-address only; the per-IP backstop is deliberately left alone,
  // or deleting an account would be a way to clear one's own budget.
  //
  // **Only a `proven` address**, and this is the half that is not obvious. This call clears
  // state keyed by an address, and that budget is shared with whoever else is using it. An
  // idToken holder can point their own Auth account at any address no Firebase user holds
  // (`accounts:update`, public web API key), delete, and walk away with that address's
  // sign-up and resend counters reset — the per-address cap on unsolicited activation mail,
  // reset for the price of one account lifecycle. `accounts:update` clears `emailVerified`
  // whenever the address moves, so `proven` is what tells the two apart, and skipping is
  // the harmless direction: the counters expire on their own.
  //
  // **Defence in depth, not the thing holding the door.** Measured against the real
  // project: `accounts:update` refuses to repoint an account at an address nobody has
  // verified — `400 OPERATION_NOT_ALLOWED : Please verify the new email before changing
  // email` — so the move this guards against is not reachable as the project is configured
  // today, whatever `identity-toolkit.ts`'s comment says. That is a console setting rather
  // than a property of this code, which is why `account-deletion.test.ts` asserts the
  // refusal: turn it off and `bun run verify` goes red instead of this going quiet.
  // **Not CI** — CI runs the emulators, which allow the move, so that half of the test
  // asserts the permissive behaviour and can never fail for this reason.
  //
  // If the setting changes, `/auth/password/reset` no longer re-opens this path: #140 binds
  // proof to the address carried by the link and refuses a uid whose Auth address moved.
  //
  // Last, after everything that can fail. A throw above leaves the counters standing,
  // which is the harmless direction there too.
  if (proven) forgetEmail(address)
  // No count, no email, no id — a delete is exactly where a log line is tempting
  // (GUARDRAILS 12). Anything that throws above lands in `app.onError` as a 500 with a
  // `ref`, and the account is already inert by then.
  return c.json({ deleted: true })
})

/**
 * Records or withdraws one consent kind (A21, #86). `kind` is `collect` or `share`;
 * `granted: true` records the consent with the `version` of the text the client showed,
 * `granted: false` withdraws — the freeze, not a delete: the record keeps its version and
 * its `at`, and gains `withdrawnAt`. Withdrawal takes no version, because the text being
 * withdrawn from is the one already recorded.
 *
 * `share` is accepted and stored although it governs nothing today (its scope is on
 * #86): the vendor list the screen names is what a future share decision hangs from, and
 * a consent the API refused to record would make the screen's second toggle a lie.
 */
app.put('/me/consent/:kind', requireAuth, requireAccount, async (c) => {
  const kind = c.req.param('kind')
  if (!isOneOf(kind, CONSENT_KINDS)) {
    return c.json(error('NOT_FOUND', 'No such consent kind'), 404)
  }
  const body = await readBody(c)
  if (typeof body.granted !== 'boolean') {
    return c.json(error('VALIDATION', 'granted must be a boolean'), 400)
  }
  let version = ''
  if (body.granted) {
    // The version names the text she actually saw. The server keeps no table to check it
    // against — re-prompting works by the recorded version differing from the next one —
    // but a consent with no version could never be told from any other, so there is no
    // such record.
    version = typeof body.version === 'string' ? body.version.trim() : ''
    if (version.length === 0 || version.length > 64) {
      return c.json(error('VALIDATION', 'version is required when granting consent'), 400)
    }
  }
  // Auth's half of `authProviders` (#117), read beside the write rather than after it.
  const [user, federated] = await Promise.all([
    saveConsent(c.get('claims').sub, kind, body.granted, version),
    federatedProvidersOf(c.get('claims').sub),
  ])
  if (!user || !federated) return c.json(error('UNAUTHORIZED', 'User not found'), 401)
  return c.json({ user: servedUser(user, federated) })
})

app.put('/me/questionnaire', requireAuth, requireAccount, requireCollectConsent, async (c) => {
  const body = await readBody(c)
  // The caller's own day, the way every calendar route resolves it, because the 18+ floor
  // is measured against it: UTC-12..UTC+14 means the server's date is a different day from
  // hers for several hours out of every twenty-four, and a birthday is exactly the kind of
  // boundary that falls in them. `timeZone` is optional here as it is there.
  const clock = resolveClock(body.timeZone)
  if (!clock.ok) return c.json(error(clock.code, clock.message), 400)
  const profile = parseProfile(body, clock.value)
  if (!profile.ok) return c.json(error(profile.code, profile.message), 400)

  // Auth's half of `authProviders` (#117), read beside the write rather than after it.
  const [user, federated] = await Promise.all([
    saveQuestionnaire(c.get('claims').sub, profile.value),
    federatedProvidersOf(c.get('claims').sub),
  ])
  if (!user || !federated) return c.json(error('UNAUTHORIZED', 'User not found'), 401)
  return c.json({ user: servedUser(user, federated) })
})

/**
 * The Nutrition coach's setup answers (S1 of #25, #221), read back so setup can resume where
 * she left it (PRD Edge case 1). `404 NOT_FOUND` until she has started — "not started" is
 * the absence of the thing named, which is what that code already means on the event routes.
 * Served with `complete`, which is `false` for anything short of a finished setup; nothing
 * may be calculated or shown from a profile that says so (PRD line 677).
 */
app.get('/me/nutrition/profile', requireAuth, requireAccount, async (c) => {
  const nutritionProfile = await getNutritionProfile(c.get('claims').sub)
  if (!nutritionProfile) return c.json(error('NOT_FOUND', 'No nutrition profile yet'), 404)
  return c.json({ nutritionProfile })
})

/**
 * The day's targets for a finished setup (S2 of #25, #222 — the first route to serve one).
 *
 * PRD line 677: "Nothing is calculated, displayed or suggested from partial data." So a
 * profile that is not complete answers `400 VALIDATION` rather than a plan, and the summary
 * the app draws is gated on `complete` exactly as the route is. The plan is `planDailyTargets`'
 * own answer — the target and the macros, or `{ kind: 'refused' }` with the lowest weight the
 * guards will accept — so the guard cards and the plan summary render one shape rather than
 * two. A `503` while the `NUTRITION_*` constants are unconfigured (#222's refusal, mapped
 * here before anything can throw it), and `400` for a profile missing the body metrics the
 * maths needs (an unanswered activity band).
 */
app.get('/me/nutrition/plan', requireAuth, requireAccount, async (c) => {
  const uid = c.get('claims').sub
  try {
    const [nutritionProfile, user] = await Promise.all([getNutritionProfile(uid), getUser(uid)])
    if (!nutritionProfile?.complete) {
      return c.json(error('VALIDATION', 'Complete your Nutrition setup first'), 400)
    }
    const profile = user?.profile
    if (!profile || profile.lifestyle === null) {
      return c.json(error('VALIDATION', 'Your body metrics are not complete'), 400)
    }
    const setup = completedSetup(nutritionProfile)!
    const body = {
      weightKg: profile.weightKg,
      heightCm: profile.heightCm,
      ageYears: ageYearsOn(profile.dateOfBirth, new Date().toISOString().slice(0, 10)),
      activityBand: profile.lifestyle,
      focusAreas: setup.focusAreas.map((code) => FOCUS_AREA_PRD_ITEM[code]),
    }
    // Built as the two union arms, so the goal's weight target is present exactly when the
    // goal has one — `completedSetup` already paired them, and the literal comparison
    // narrows rather than re-tests (PRD line 745: goals 4 and 5 have none).
    const input: NutritionInput =
      setup.goal === 'lose' || setup.goal === 'gain' || setup.goal === 'buildMuscle'
        ? { ...body, goal: setup.goal, targetWeightKg: setup.targetWeightKg }
        : { ...body, goal: setup.goal }
    return c.json({ plan: planDailyTargets(input, config.nutrition) })
  } catch (err) {
    if (err instanceof NutritionRulesUnsetError) return nutritionUnavailable(c)
    if (err instanceof ImpossibleBodyMetricError) {
      return c.json(error('VALIDATION', 'Your body metrics are out of range'), 400)
    }
    throw err
  }
})

/**
 * Saves one step's worth of setup answers (#221). A key that is absent is left as it was, so
 * each screen sends only its own answers — and a client that does not mention `hideNumbers`
 * can never turn the numbers back on (#212). Behind the collect consent (#86): a goal and a
 * target weight are health data, exactly as the questionnaire is.
 *
 * Shape is refused here; the two rules that depend on what is already stored — `done` with
 * an answer missing, a target weight for a goal that has none — are the module's, and both
 * answer `400 VALIDATION` naming the field. No message repeats a value (GUARDRAILS 12).
 */
app.patch(
  '/me/nutrition/profile',
  requireAuth,
  requireAccount,
  requireCollectConsent,
  async (c) => {
    const patch = parseNutritionProfilePatch(await readBody(c))
    if (!patch.ok) return c.json(error(patch.code, patch.message), 400)
    const saved = await saveNutritionProfile(
      c.get('claims').sub,
      tokenVersionOf(c.get('claims')),
      patch.value,
    )
    if (!saved.ok) {
      const message =
        saved.rule === 'required'
          ? `${saved.field} is required before setup is done`
          : `${saved.field} is only asked for a weight-change goal`
      return c.json(error('VALIDATION', message), 400)
    }
    return c.json({ nutritionProfile: saved.profile })
  },
)

/**
 * Registers or replaces a device's push token (#79, A9). The device id is a UUID the app
 * mints once per install, so a token rotation is a replace rather than a second row;
 * `environment` says which APNs environment the token belongs to, and `timeZone` is the
 * device's own IANA zone, stored so the sender job resolves a wall-clock reminder in it.
 */
app.put('/me/devices/:deviceId', requireAuth, requireAccount, async (c) => {
  const deviceId = c.req.param('deviceId')
  if (!deviceId) return c.json(error('VALIDATION', 'A device id is required'), 400)
  const parsed = parseDeviceRegistration(await readBody(c))
  if (!parsed.ok) return c.json(error(parsed.code, parsed.message), 400)
  await registerDevice(
    c.get('claims').sub,
    tokenVersionOf(c.get('claims')),
    deviceId,
    parsed.value,
  )
  return c.json({ registered: true })
})

/**
 * Removes one device — the app's half of sign-out, so a signed-out install stops receiving.
 * A row already gone is a no-op, so a retried sign-out never answers 404.
 */
app.delete('/me/devices/:deviceId', requireAuth, requireAccount, async (c) => {
  const deviceId = c.req.param('deviceId')
  if (!deviceId) return c.json(error('VALIDATION', 'A device id is required'), 400)
  await removeDevice(c.get('claims').sub, tokenVersionOf(c.get('claims')), deviceId)
  return c.json({ removed: true })
})

/**
 * A device-registration body, validated at the edge. `environment` is a closed set; the
 * token is an opaque string (its format is APNs' to change, not ours to parse); the time
 * zone is checked the way `resolveClock` checks one, so a nonsense zone is refused rather
 * than stored and later misresolving a reminder.
 */
const parseDeviceRegistration = (body: Record<string, unknown>): Parsed<DeviceRegistration> => {
  if (typeof body.token !== 'string' || body.token.length === 0 || body.token.length > 4096) {
    return bad('token must be a non-empty string')
  }
  if (body.environment !== 'sandbox' && body.environment !== 'production') {
    return bad('environment must be "sandbox" or "production"')
  }
  if (typeof body.timeZone !== 'string') return bad('timeZone must be an IANA time zone name')
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: body.timeZone }).format(new Date())
  } catch {
    return bad('timeZone must be an IANA time zone name')
  }
  return good({
    token: body.token,
    environment: body.environment as DeviceEnvironment,
    timeZone: body.timeZone,
  })
}

/** The keys a nutrition-profile PATCH may carry — the setup answers and nothing else. */
const NUTRITION_PROFILE_KEYS: readonly string[] = [
  'goal',
  'focusAreas',
  'mealPattern',
  'targetWeightKg',
  'hideNumbers',
  'step',
]

const MEAL_PATTERN_KEYS: readonly string[] = ['mealsPerDay', 'snacks', 'mealTimes']

/** `HH:mm`, a wall clock: the time she usually eats, never an instant. */
const WALL_CLOCK = /^([01]\d|2[0-3]):[0-5]\d$/

/**
 * A nutrition-profile PATCH body, validated (#221).
 *
 * **An unknown key is refused, not dropped.** The field list is exactly the setup answers
 * (#221), and a key that is stored because nobody refused it is how a field nobody decided
 * gets added — a disordered-eating flag being the one #212 names. The message does not name
 * the key: it is caller-controlled text.
 *
 * **A fourth focus area is refused, never truncated** (PRD line 726, canvas `s2`), and the
 * refusal writes nothing, so the stored list is what it was.
 */
const parseNutritionProfilePatch = (
  body: Record<string, unknown>,
): Parsed<NutritionProfilePatch> => {
  for (const key of Object.keys(body)) {
    if (!NUTRITION_PROFILE_KEYS.includes(key)) {
      return bad('nutrition profile has no such field')
    }
  }
  const patch: NutritionProfilePatch = {}

  if ('goal' in body) {
    if (body.goal !== null && !isOneOf(body.goal, NUTRITION_GOAL_CODES)) {
      return bad(`goal must be one of: ${NUTRITION_GOAL_CODES.join(', ')}`)
    }
    patch.goal = body.goal
  }

  if ('focusAreas' in body) {
    const areas = body.focusAreas
    if (!Array.isArray(areas)) return bad('focusAreas must be a list')
    if (areas.length > MAX_FOCUS_AREAS) {
      return bad(`focusAreas allows at most ${MAX_FOCUS_AREAS}`)
    }
    const codes: FocusAreaCode[] = []
    for (const area of areas) {
      if (!isOneOf(area, FOCUS_AREA_CODES)) {
        return bad(`focusAreas must be a list of: ${FOCUS_AREA_CODES.join(', ')}`)
      }
      if (codes.includes(area)) return bad('focusAreas must not repeat an area')
      codes.push(area)
    }
    patch.focusAreas = codes
  }

  if ('mealPattern' in body) {
    const pattern = body.mealPattern
    if (pattern === null) {
      patch.mealPattern = null
    } else {
      if (typeof pattern !== 'object' || Array.isArray(pattern)) {
        return bad('mealPattern must be an object')
      }
      const fields = pattern as Record<string, unknown>
      if (Object.keys(fields).some((key) => !MEAL_PATTERN_KEYS.includes(key))) {
        return bad('mealPattern has no such field')
      }
      const { mealsPerDay, snacks, mealTimes = null } = fields
      if (
        typeof mealsPerDay !== 'number' ||
        !(MEALS_PER_DAY as readonly number[]).includes(mealsPerDay)
      ) {
        return bad(`mealPattern.mealsPerDay must be one of: ${MEALS_PER_DAY.join(', ')}`)
      }
      if (typeof snacks !== 'boolean') return bad('mealPattern.snacks must be a boolean')
      if (
        mealTimes !== null &&
        (!Array.isArray(mealTimes) ||
          mealTimes.length !== mealsPerDay ||
          !mealTimes.every((t) => typeof t === 'string' && WALL_CLOCK.test(t)))
      ) {
        return bad('mealPattern.mealTimes must be one HH:mm time per meal')
      }
      patch.mealPattern = {
        mealsPerDay: mealsPerDay as MealPattern['mealsPerDay'],
        snacks,
        mealTimes: mealTimes as string[] | null,
      }
    }
  }

  if ('targetWeightKg' in body) {
    const target = body.targetWeightKg
    // The Sign Up profile's own accepted range, which is also the engine's (`nutrition.ts`).
    // Whether a target is *safe* — A29's BMI floor and 15% cap — is the engine's answer and
    // S3's to show; a refusal here would be a second, different rule.
    if (
      target !== null &&
      !(typeof target === 'number' && Number.isFinite(target) && target >= 30 && target <= 200)
    ) {
      return bad('targetWeightKg must be 30–200')
    }
    patch.targetWeightKg = target
  }

  if ('hideNumbers' in body) {
    // No `null`: an answered preference cannot be un-answered back into "show the numbers by
    // default". Turning it off is `false`, which is her own act.
    if (typeof body.hideNumbers !== 'boolean') return bad('hideNumbers must be a boolean')
    patch.hideNumbers = body.hideNumbers
  }

  if ('step' in body) {
    if (!isOneOf(body.step, SETUP_STEP_CODES)) {
      return bad(`step must be one of: ${SETUP_STEP_CODES.join(', ')}`)
    }
    patch.step = body.step
  }

  return good(patch)
}

/**
 * Dismisses the "complete your profile" nudge (#19).
 *
 * Idempotent and side-effect-free beyond the flag: dismissing takes "no" for an answer and
 * never blocks anything, and the flag is server-side so the dismissal survives reinstall.
 * No body is read — there is nothing to validate.
 */
app.post('/me/profile-nudge/dismiss', requireAuth, requireAccount, async (c) => {
  // Auth's half of `authProviders` (#117), read beside the write rather than after it.
  const [user, federated] = await Promise.all([
    dismissProfileNudge(c.get('claims').sub),
    federatedProvidersOf(c.get('claims').sub),
  ])
  if (!user || !federated) return c.json(error('UNAUTHORIZED', 'User not found'), 401)
  return c.json({ user: servedUser(user, federated) })
})

/**
 * Eva's account floor, in years (A12, decided on #81).
 *
 * Enforced here, where the date of birth is captured, and **enforced here even after #19
 * moves the rest of the questionnaire into Profile** — it is the one question that cannot
 * move with the others, because it gates the account rather than the personalisation.
 *
 * `cycle.ts` declares the same number as the floor `bandForAge` refuses under. It cannot be
 * one constant: that module imports only types, which is what keeps it pure and testable
 * against fixtures, and a runtime import from here would be a cycle as well as a boundary
 * violation. `the account floor is one number` in `cycle.test.ts` reads both files and pins
 * them equal instead, so the two cannot drift silently.
 */
const MIN_ACCOUNT_AGE_YEARS = 18

/** Membership in one of `users.ts`' profile enumerations, narrowing to the code union. */
const isOneOf = <T extends string>(value: unknown, codes: readonly T[]): value is T =>
  typeof value === 'string' && (codes as readonly string[]).includes(value)

/**
 * The questionnaire payload, validated (#81).
 *
 * **`dateOfBirth`, never `age`.** A stored age is wrong within a year of being written and
 * wrong silently, and the thing it feeds — the FIGO irregularity band — decides whether a
 * fertile window is drawn at all. An `age` key is refused outright rather than ignored: a
 * client still sending one is a client that has not been updated, and accepting the rest of
 * its payload would write a profile with no date of birth in it.
 *
 * **No message repeats what was sent.** Every refusal below names the field and the rule,
 * never the value — a date of birth, a condition and a medication are all profile contents,
 * and an error body is as readable as a log line (GUARDRAILS 12).
 */
const parseProfile = (body: Record<string, unknown>, clock: Clock): Parsed<Profile> => {
  const isStringArray = (v: unknown): v is string[] =>
    Array.isArray(v) && v.every((x) => typeof x === 'string')
  const inRange = (v: unknown, min: number, max: number): v is number =>
    typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max

  const { dateOfBirth, weightKg, heightCm, goals, conditions, medications, lifestyle, sports } =
    body

  if ('age' in body) {
    return bad('age is no longer accepted; send dateOfBirth instead')
  }
  if (!isCalendarDate(dateOfBirth)) {
    return bad('dateOfBirth must be a YYYY-MM-DD calendar date')
  }
  // Slack in the strict direction, and only when the caller did not name its zone. A day
  // of tolerance is what the calendar routes give a *logged date* so an entry is never
  // refused for the server's idea of today; extending the same courtesy here would admit
  // somebody a day short of 18 whenever a client forgets to say where it is. So the age is
  // measured against the earliest day it could currently be anywhere — she is 18 in every
  // zone, or she waits a day. A client that sends `timeZone` gets the exact boundary.
  const asOf = shiftDays(clock.today, -clock.slackDays)
  if (dateOfBirth > asOf) {
    return bad('dateOfBirth cannot be in the future')
  }
  if (ageYearsOn(dateOfBirth, asOf) < MIN_ACCOUNT_AGE_YEARS) {
    return bad(`You must be ${MIN_ACCOUNT_AGE_YEARS} or over to use Eva`)
  }

  if (!inRange(weightKg, 30, 200)) return bad('weightKg must be 30–200')
  if (!inRange(heightCm, 120, 220)) return bad('heightCm must be 120–220')
  if (!isStringArray(goals)) return bad('goals must be a list of strings')
  if (!isStringArray(sports)) return bad('sports must be a list of strings')

  // The enumerated fields (A8). Codes, not labels — `users.ts` says why — so an
  // unrecognised value is a client sending a vocabulary this version does not have, which
  // is a 400 and not something to store and puzzle over later.
  if (!isOneOf(medications, MEDICATION_CODES)) {
    return bad(`medications must be one of: ${MEDICATION_CODES.join(', ')}`)
  }
  // The activity band (#221): the one answer here that arithmetic reads, so a label that
  // matched no band would become a plausible calorie target rather than an error.
  // **Unanswered is an answer the profile can hold** — `null` or absent, stored as `null` —
  // because the read side already serves an unrecognised legacy label that way ("absent
  // means setup asks"), and every profile editor re-sends the whole profile: refusing it here
  // would lock such an account out of saving her goals until she picked a band. `""` is not
  // unanswered, it is a client sending a vocabulary this version does not have.
  const band = lifestyle ?? null
  if (band !== null && !isOneOf(band, ACTIVITY_BAND_CODES)) {
    return bad(`lifestyle must be one of: ${ACTIVITY_BAND_CODES.join(', ')}, or null`)
  }
  if (!isStringArray(conditions)) return bad('conditions must be a list of strings')
  const conditionCodes: ConditionCode[] = []
  for (const value of conditions) {
    if (!isOneOf(value, CONDITION_CODES)) {
      return bad(`conditions must be a list of: ${CONDITION_CODES.join(', ')}`)
    }
    conditionCodes.push(value)
  }

  return good({
    dateOfBirth,
    weightKg,
    heightCm,
    goals,
    conditions: conditionCodes,
    medications,
    lifestyle: band,
    sports,
  })
}

// ── Reference data ─────────────────────────────────────────────────────────────
// The option lists the client draws (PRD:483 — new options ship without an app
// release). `version` is a hash of the content, so it changes exactly when a
// catalogue does. The client stores it beside its copy and sends it back; an
// unchanged catalogue answers 304 with no body, and the client keeps what it has.
// `If-None-Match` does the same thing for anything that speaks HTTP caching.

/** Strips the weak-validator prefix and quotes: `W/"abc"` and `"abc"` are both abc. */
const etagValue = (header: string | undefined): string | undefined =>
  header?.trim().replace(/^W\//, '').replace(/^"|"$/g, '')

/**
 * The version the client already holds: the `version` query when it says anything, the
 * `If-None-Match` header otherwise (#147).
 *
 * Both cache routes used to read this as `query ?? header`, and `??` only falls through
 * on `null`/`undefined` — so `?version=`, an empty value, short-circuited the header and
 * a client that sent an empty parameter beside a valid validator got a full `200` instead
 * of a `304`. Empty means absent: the query wins when non-empty, the header is the
 * fallback, and the precedence is pinned by test on both routes.
 */
const knownVersion = (c: Context): string | undefined => {
  const query = c.req.query('version')
  if (query !== undefined && query !== '') return query
  return etagValue(c.req.header('if-none-match'))
}

/**
 * The Dashboard's words (#97). Same handshake as `/refdata` and for the same reasons: the
 * device caches the bundle against a content-derived `version`, revalidates on every
 * launch, and gets a `304` with no body when nothing changed — which is what makes the
 * copy available offline (A3).
 *
 * It serves what the collection holds, review metadata included in neither the body nor
 * the version: who signed the copy is an operational fact, not something a device needs,
 * and putting it in the hash would push a new bundle to everyone each time someone
 * re-reviewed the same words.
 */
app.get('/content', requireAuth, requireAccount, async (c) => {
  const content = await getContent()
  c.header('ETag', `"${content.version}"`)
  c.header('Cache-Control', 'private, no-cache')
  const known = knownVersion(c)
  if (known === content.version) return c.body(null, 304)
  return c.json(content)
})

app.get('/refdata', requireAuth, requireAccount, async (c) => {
  const refdata = await getRefData()
  c.header('ETag', `"${refdata.version}"`)
  // Reference data changes rarely but must not go stale silently: revalidate always,
  // and the revalidation is a 304 with an empty body.
  c.header('Cache-Control', 'private, no-cache')
  const known = knownVersion(c)
  if (known === refdata.version) return c.body(null, 304)
  return c.json(refdata)
})

// ── Calendar events ────────────────────────────────────────────────────────────
// Everything below validates at the edge and delegates to events.ts, which is the
// only module allowed to touch users/{uid}/events (GUARDRAILS rule 10).
//
// Times on the wire are the user's wall clock, never an instant: `localDate` is
// what the device says the day is, and the server never derives it from its own
// clock. `timeZone` (optional, IANA) is used only to work out what "today" is for
// the caller — it is not stored. Without it the server falls back to UTC and allows
// a day of slack in both directions, because UTC-12..UTC+14 means someone's real
// today is always within one day of the server's.

type Parsed<T> = { ok: true; value: T } | { ok: false; code: string; message: string }

const good = <T>(value: T): Parsed<T> => ({ ok: true, value })
const bad = (message: string, code = 'VALIDATION'): Parsed<never> => ({
  ok: false,
  code,
  message,
})

const CALENDAR_DATE = /^\d{4}-\d{2}-\d{2}$/
const LOCAL_DATETIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/
const NOTE_LIMIT = 280
const APPOINTMENT_NOTE_LIMIT = 10_000
const MAX_RANGE_DAYS = 400

/** `YYYY-MM-DD` that is also a real day — 2026-02-30 parses but is not one. */
const isCalendarDate = (value: unknown): value is string => {
  if (typeof value !== 'string' || !CALENDAR_DATE.test(value)) return false
  const parsed = new Date(`${value}T00:00:00.000Z`)
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value
}

const shiftDays = (date: string, days: number): string =>
  new Date(Date.parse(`${date}T00:00:00.000Z`) + days * 86_400_000).toISOString().slice(0, 10)

/** Twelve months back. 29 Feb lands on 1 Mar in a non-leap year, which is fine
 *  for a cap — it is a day either way. */
const minusTwelveMonths = (date: string): string => {
  const [year, month, day] = date.split('-').map(Number)
  return new Date(Date.UTC(year! - 1, month! - 1, day!)).toISOString().slice(0, 10)
}

interface Clock {
  /** The caller's current local date. */
  today: string
  /** The caller's current local time, `HH:mm:ss`. */
  timeOfDay: string
  /** Days of tolerance around `today` when the caller did not name its zone. */
  slackDays: number
}

const resolveClock = (timeZone: unknown): Parsed<Clock> => {
  if (timeZone !== undefined && typeof timeZone !== 'string') {
    return bad('timeZone must be an IANA time zone name')
  }
  const zone = timeZone ?? 'UTC'
  let parts: Intl.DateTimeFormatPart[]
  try {
    parts = new Intl.DateTimeFormat('en-US', {
      timeZone: zone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23',
    }).formatToParts(new Date())
  } catch {
    return bad(`Unknown time zone: ${zone}`)
  }
  const part = (name: string) => parts.find((p) => p.type === name)!.value
  return good({
    today: `${part('year')}-${part('month')}-${part('day')}`,
    timeOfDay: `${part('hour')}:${part('minute')}:${part('second')}`,
    slackDays: timeZone === undefined ? 1 : 0,
  })
}

/** Future dates are for appointments only — you cannot observe something that has
 *  not happened. Everything is capped at 12 months of backdating (PRD edge case 1). */
const checkDatePolicy = (
  type: LoggableEventType,
  localDate: string,
  clock: Clock,
): Parsed<true> => {
  if (type !== 'appointment') {
    const latest = shiftDays(clock.today, clock.slackDays)
    if (localDate > latest) {
      return bad('Only appointments can be logged on a future date', 'FUTURE_DATE_NOT_ALLOWED')
    }
  }
  const earliest = shiftDays(minusTwelveMonths(clock.today), -clock.slackDays)
  if (localDate < earliest) {
    return bad('Entries can only be backdated 12 months', 'BACKDATE_LIMIT_EXCEEDED')
  }
  return good(true)
}

/** Now for today, 12:00 otherwise. The date half always matches `localDate`: the
 *  day sheet orders entries by this, so it is a time *on that day*, not an instant. */
const defaultLoggedAt = (localDate: string, clock: Clock): string =>
  localDate === clock.today ? `${localDate}T${clock.timeOfDay}` : `${localDate}T12:00:00`

const parseLoggedAt = (value: unknown, localDate: string, clock: Clock): Parsed<string> => {
  if (value === undefined || value === null) return good(defaultLoggedAt(localDate, clock))
  if (typeof value !== 'string' || !LOCAL_DATETIME.test(value)) {
    return bad('loggedAt must be a local YYYY-MM-DDTHH:mm:ss')
  }
  const normalized = value.length === 16 ? `${value}:00` : value
  if (!normalized.startsWith(`${localDate}T`)) {
    return bad("loggedAt must fall on the entry's localDate")
  }
  return good(normalized)
}

const parseNote = (value: unknown, type: LoggableEventType): Parsed<string | null> => {
  if (value === undefined || value === null) return good(null)
  if (typeof value !== 'string') return bad('note must be text')
  const limit = type === 'appointment' ? APPOINTMENT_NOTE_LIMIT : NOTE_LIMIT
  const note = value.trim()
  if (note.length > limit) return bad(`note must be ${limit} characters or fewer`)
  return good(note.length > 0 ? note : null)
}

const parseSource = (value: unknown): Parsed<EventSource> => {
  if (value === undefined || value === null) return good('user')
  if (value !== 'user' && value !== 'eva') return bad('source must be user or eva')
  return good(value)
}

const parseIdempotencyKey = (value: unknown): Parsed<string | null> => {
  if (value === undefined || value === null) return good(null)
  if (typeof value !== 'string' || value.length < 1 || value.length > 128) {
    return bad('idempotencyKey must be 1–128 characters')
  }
  return good(value)
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value)

const parseCyclePayload = (body: Record<string, unknown>): Parsed<CyclePayload> => {
  const hasSpotting = body.spotting !== undefined && body.spotting !== null
  const hasFlow = body.flow !== undefined && body.flow !== null
  const hasPeriodEnd = body.periodEnd !== undefined && body.periodEnd !== null
  // Spotting is a marker, not a flow level: a spotting day does not start a period.
  if (hasSpotting && hasFlow) {
    return bad('A cycle entry is either spotting or a flow level, not both')
  }
  // The explicit period end rides on the last day *with* flow (#75), so both refusals
  // below are one rule seen from two sides: the mark cannot say a period ended on a day
  // that records no bleeding. They overlap deliberately — a spotting body reaches the
  // second one too, since it has no flow — and each is kept because the message is what
  // tells the caller which rule it broke. For the same reason the second is narrower
  // than the catch-all at the bottom: a client sending `periodEnd` with nothing to
  // attach it to has a different bug from one sending an empty payload.
  if (hasPeriodEnd) {
    if (body.periodEnd !== true) return bad('periodEnd must be true when present')
    if (hasSpotting) return bad('periodEnd cannot sit on a spotting day: spotting is not flow')
    if (!hasFlow) return bad('periodEnd needs a flow level on the same entry')
  }
  if (hasSpotting) {
    return body.spotting === true
      ? good({ spotting: true })
      : bad('spotting must be true when present')
  }
  if (hasFlow) {
    if (body.flow !== 'light' && body.flow !== 'medium' && body.flow !== 'heavy') {
      return bad('flow must be light, medium or heavy')
    }
    // The key is absent when unmarked rather than `false` or `undefined`: Firestore
    // rejects undefined, and PATCH replaces `payload` whole, so clearing the mark is
    // sending the day's payload without it.
    return good(hasPeriodEnd ? { flow: body.flow, periodEnd: true } : { flow: body.flow })
  }
  return bad('A cycle entry needs either spotting or a flow level')
}

/** A positive test records one thing — this day — and carries nothing else (#80).
 *
 *  Absent, `null` and `{}` are the same request and all three are accepted: the entry is
 *  the fact, so a client has no field to send. **Any other key is refused rather than
 *  dropped**, and that refusal does two jobs no other payload parser has to do.
 *
 *  It stops `{"negative": true}` being posted to a type named `positiveTest` and stored,
 *  silently, as a positive — a payload parser that ignored unknown keys would accept that
 *  body with a 201 and record the opposite of what the caller meant.
 *
 *  And it is the only door a clinical number could come through. An empty payload with no
 *  validator is the obvious place for a client to start attaching a beta-hCG reading or a
 *  test's own score; GUARDRAILS 35 keeps values a clinic would report out of Eva, and a
 *  field that is refused at the edge cannot become one that is merely unused at rest. */
const parsePositiveTestPayload = (payload: unknown): Parsed<PositiveTestPayload> => {
  if (payload === undefined || payload === null) return good({})
  if (!isRecord(payload)) return bad('payload must be an object')
  if (Object.keys(payload).length > 0) {
    return bad('A positive test marks the day and carries nothing else')
  }
  return good({})
}

const parseRating = (value: unknown, name: string): Parsed<number | undefined> => {
  if (value === undefined || value === null) return good(undefined)
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 1 || value > 5) {
    return bad(`${name} must be a whole number from 1 to 5`)
  }
  return good(value)
}

/** Codes are checked against the catalogue `refdata.ts` serves, so the client and the
 *  validator agree on one vocabulary (PRD:484). `rules` is null when the catalogue is
 *  unavailable — codes then stay opaque, as they were before #24, because refusing a
 *  health entry over missing reference data is the worse failure.
 *
 *  A *retired* code is accepted: an offline queue may hold an entry logged while the
 *  chip was still offered, and the user must still be able to edit it. Only a code the
 *  catalogue has never carried is rejected. */
const parseSymptoms = (value: unknown, rules: SymptomRules | null): Parsed<Symptom[]> => {
  if (value === undefined || value === null) return good([])
  if (!Array.isArray(value)) return bad('symptoms must be a list')
  if (value.length > 40) return bad('symptoms must hold 40 entries or fewer')
  const symptoms: Symptom[] = []
  for (const entry of value) {
    if (!isRecord(entry)) return bad('each symptom must be an object')
    const { severity } = entry
    if (typeof entry.code !== 'string' || entry.code.trim().length < 1 || entry.code.length > 64) {
      return bad('each symptom needs a code of 1–64 characters')
    }
    const code = entry.code.trim()
    if (rules && !rules.has(code)) {
      // Its own code so a stale client can refetch /refdata instead of guessing.
      return bad(`Unknown symptom code: ${code}`, 'UNKNOWN_SYMPTOM_CODE')
    }
    if (
      severity !== undefined &&
      severity !== null &&
      severity !== 'normal' &&
      severity !== 'severe'
    ) {
      return bad('symptom severity must be normal or severe')
    }
    const parsedValue = parseSymptomValue(entry.value, code, rules)
    if (!parsedValue.ok) return parsedValue
    if (symptoms.some((s) => s.code === code)) {
      return bad(`symptom ${code} is listed twice`)
    }
    symptoms.push({
      code,
      severity: (severity as SymptomSeverity) ?? 'normal',
      // Absent, never undefined: Firestore rejects an undefined field.
      ...(parsedValue.value !== undefined ? { value: parsedValue.value } : {}),
    })
  }
  return good(symptoms)
}

/** The chip's own picker (discharge: dry/sticky/creamy/watery/egg-white). Optional
 *  even where the catalogue offers one — a chip logged without a choice is still a
 *  logged chip — but a value the catalogue does not offer is a client bug. */
const parseSymptomValue = (
  value: unknown,
  code: string,
  rules: SymptomRules | null,
): Parsed<string | undefined> => {
  if (value === undefined || value === null) return good(undefined)
  if (typeof value !== 'string' || value.trim().length < 1 || value.length > 64) {
    return bad('symptom value must be 1–64 characters')
  }
  const trimmed = value.trim()
  if (!rules) return good(trimmed)
  const allowed = rules.valuesFor(code)
  if (!allowed) return bad(`symptom ${code} does not take a value`)
  if (!allowed.includes(trimmed)) {
    return bad(`symptom ${code} value must be one of ${allowed.join(', ')}`)
  }
  return good(trimmed)
}

const parseBodySignalsPayload = (
  body: Record<string, unknown>,
  rules: SymptomRules | null,
): Parsed<BodySignalsPayload> => {
  const energy = parseRating(body.energy, 'energy')
  if (!energy.ok) return energy
  const mood = parseRating(body.mood, 'mood')
  if (!mood.ok) return mood
  const sleep = parseRating(body.sleep, 'sleep')
  if (!sleep.ok) return sleep
  const symptoms = parseSymptoms(body.symptoms, rules)
  if (!symptoms.ok) return symptoms
  // Absent ratings stay absent — nothing is preselected, and 3 is not "unanswered".
  return good({
    ...(energy.value !== undefined ? { energy: energy.value } : {}),
    ...(mood.value !== undefined ? { mood: mood.value } : {}),
    ...(sleep.value !== undefined ? { sleep: sleep.value } : {}),
    symptoms: symptoms.value,
  })
}

const parseSportPayload = (body: Record<string, unknown>): Parsed<SportPayload> => {
  const { activity, durationMin, intensity } = body
  if (typeof activity !== 'string' || activity.trim().length < 1 || activity.length > 64) {
    return bad('activity must be 1–64 characters')
  }
  if (
    typeof durationMin !== 'number' ||
    !Number.isInteger(durationMin) ||
    durationMin < 5 ||
    durationMin > 300
  ) {
    return bad('durationMin must be a whole number of minutes from 5 to 300')
  }
  if (intensity !== 'light' && intensity !== 'medium' && intensity !== 'hard') {
    return bad('intensity must be light, medium or hard')
  }
  return good({ activity: activity.trim(), durationMin, intensity })
}

const parseAppointmentPayload = (
  body: Record<string, unknown>,
  localDate: string,
): Parsed<AppointmentPayload> => {
  const { startAt, type, questions, reminderMinutesBefore } = body
  if (typeof startAt !== 'string' || !LOCAL_DATETIME.test(startAt)) {
    return bad('startAt must be a local YYYY-MM-DDTHH:mm:ss')
  }
  const normalizedStart = startAt.length === 16 ? `${startAt}:00` : startAt
  if (!normalizedStart.startsWith(`${localDate}T`)) {
    return bad("startAt must fall on the appointment's localDate")
  }
  if (type !== undefined && type !== null && (typeof type !== 'string' || type.length > 64)) {
    return bad('type must be 64 characters or fewer')
  }
  const list: string[] = []
  if (questions !== undefined && questions !== null) {
    if (!Array.isArray(questions)) return bad('questions must be a list')
    if (questions.length > 50) return bad('questions must hold 50 entries or fewer')
    for (const question of questions) {
      if (typeof question !== 'string' || question.trim().length < 1 || question.length > 500) {
        return bad('each question must be 1–500 characters')
      }
      list.push(question.trim())
    }
  }
  // Omitted means the PRD's default of one day before; explicit null means none.
  let reminder: number | null = 1440
  if (reminderMinutesBefore === null) reminder = null
  else if (reminderMinutesBefore !== undefined) {
    if (
      typeof reminderMinutesBefore !== 'number' ||
      !Number.isInteger(reminderMinutesBefore) ||
      reminderMinutesBefore < 0 ||
      reminderMinutesBefore > 40_320
    ) {
      return bad('reminderMinutesBefore must be a whole number of minutes from 0 to 40320')
    }
    reminder = reminderMinutesBefore
  }
  return good({
    startAt: normalizedStart,
    type: typeof type === 'string' && type.trim().length > 0 ? type.trim() : null,
    questions: list,
    reminderMinutesBefore: reminder,
  })
}

/** `rules` is fetched once per request at the route edge and threaded down, so
 *  validation stays here and `refdata.ts` stays the only reader of its collection. */
const parsePayload = (
  type: LoggableEventType,
  payload: unknown,
  localDate: string,
  rules: SymptomRules | null,
): Parsed<EventPayload> => {
  // The one type whose `payload` may be absent, so its check runs before the guard
  // below rather than as an arm of the switch: it has no field to send, and requiring
  // `payload: {}` would be a key that exists only to be empty.
  if (type === 'positiveTest') return parsePositiveTestPayload(payload)
  if (!isRecord(payload)) return bad('payload must be an object')
  switch (type) {
    case 'cycle':
      return parseCyclePayload(payload)
    case 'bodySignals':
      return parseBodySignalsPayload(payload, rules)
    case 'sport':
      return parseSportPayload(payload)
    case 'appointment':
      return parseAppointmentPayload(payload, localDate)
  }
}

const parseEventType = (value: unknown): Parsed<LoggableEventType> => {
  if (value === 'sex') {
    // Reserved in the model; ships in C10 with its privacy switch.
    return bad('The sex event type is not available yet')
  }
  if (
    value !== 'cycle' &&
    value !== 'bodySignals' &&
    value !== 'sport' &&
    value !== 'appointment' &&
    value !== 'positiveTest'
  ) {
    return bad('type must be cycle, bodySignals, sport, appointment or positiveTest')
  }
  return good(value)
}

const parseNewEvent = (
  body: Record<string, unknown>,
  rules: SymptomRules | null,
): Parsed<NewEvent> => {
  const type = parseEventType(body.type)
  if (!type.ok) return type
  if (!isCalendarDate(body.localDate)) return bad('localDate must be YYYY-MM-DD')
  const localDate = body.localDate

  const clock = resolveClock(body.timeZone)
  if (!clock.ok) return clock
  const policy = checkDatePolicy(type.value, localDate, clock.value)
  if (!policy.ok) return policy

  const loggedAt = parseLoggedAt(body.loggedAt, localDate, clock.value)
  if (!loggedAt.ok) return loggedAt
  const note = parseNote(body.note, type.value)
  if (!note.ok) return note
  const source = parseSource(body.source)
  if (!source.ok) return source
  const idempotencyKey = parseIdempotencyKey(body.idempotencyKey)
  if (!idempotencyKey.ok) return idempotencyKey
  const payload = parsePayload(type.value, body.payload, localDate, rules)
  if (!payload.ok) return payload

  return good({
    type: type.value,
    localDate,
    loggedAt: loggedAt.value,
    note: note.value,
    source: source.value,
    idempotencyKey: idempotencyKey.value,
    payload: payload.value,
  } as NewEvent)
}

/**
 * An inclusive `localDate` range off the query string, validated and capped.
 *
 * Lifted out of `GET /me/events` unchanged — same checks, same order, same `VALIDATION`
 * code and same messages — when the calendar gained a second range read (#205). One
 * implementation rather than two that agree today: the cap is the only thing bounding how
 * much a single request can ask the server to enumerate, and a copy of it is a copy that
 * can be raised on one route and not the other.
 */
const parseDateRange = (from: unknown, to: unknown): Parsed<{ from: string; to: string }> => {
  if (!isCalendarDate(from) || !isCalendarDate(to)) {
    return bad('from and to must be YYYY-MM-DD')
  }
  if (from > to) return bad('from must not be after to')
  if (
    Date.parse(`${to}T00:00:00.000Z`) - Date.parse(`${from}T00:00:00.000Z`) >
    MAX_RANGE_DAYS * 86_400_000
  ) {
    return bad(`Range must be ${MAX_RANGE_DAYS} days or fewer`)
  }
  return good({ from, to })
}

app.get('/me/events', requireAuth, requireAccount, async (c) => {
  const range = parseDateRange(c.req.query('from'), c.req.query('to'))
  if (!range.ok) return c.json(error(range.code, range.message), 400)
  return c.json({
    events: await listEvents(c.get('claims').sub, range.value.from, range.value.to),
  })
})

app.post('/me/events', requireAuth, requireAccount, requireCollectConsent, async (c) => {
  const body = await readBody(c)
  const parsed = parseNewEvent(body, await getSymptomRules())
  if (!parsed.ok) return c.json(error(parsed.code, parsed.message), 400)
  return c.json(
    {
      event: await createEvent(c.get('claims').sub, tokenVersionOf(c.get('claims')), parsed.value),
    },
    201,
  )
})

app.patch('/me/events/:id', requireAuth, requireAccount, requireCollectConsent, async (c) => {
  const body = await readBody(c)
  // `type` and `localDate` are always required: with both, every payload and
  // timestamp rule can be checked here instead of after a read in the module.
  const type = parseEventType(body.type)
  if (!type.ok) return c.json(error(type.code, type.message), 400)
  if (!isCalendarDate(body.localDate)) {
    return c.json(error('VALIDATION', 'localDate must be YYYY-MM-DD'), 400)
  }
  const localDate = body.localDate
  const clock = resolveClock(body.timeZone)
  if (!clock.ok) return c.json(error(clock.code, clock.message), 400)
  const policy = checkDatePolicy(type.value, localDate, clock.value)
  if (!policy.ok) return c.json(error(policy.code, policy.message), 400)

  const patch: EventPatch = { type: type.value, localDate }
  if (body.note !== undefined) {
    const note = parseNote(body.note, type.value)
    if (!note.ok) return c.json(error(note.code, note.message), 400)
    patch.note = note.value
  }
  if (body.payload !== undefined) {
    const payload = parsePayload(type.value, body.payload, localDate, await getSymptomRules())
    if (!payload.ok) return c.json(error(payload.code, payload.message), 400)
    patch.payload = payload.value
  }
  if (body.loggedAt !== undefined) {
    const loggedAt = parseLoggedAt(body.loggedAt, localDate, clock.value)
    if (!loggedAt.ok) return c.json(error(loggedAt.code, loggedAt.message), 400)
    patch.loggedAt = loggedAt.value
  }

  const result = await updateEvent(
    c.get('claims').sub,
    tokenVersionOf(c.get('claims')),
    c.req.param('id'),
    patch,
  )
  if (result.ok) return c.json({ event: result.event })
  if (result.reason === 'not-found') return c.json(error('NOT_FOUND', 'No such event'), 404)
  if (result.reason === 'type-mismatch') {
    return c.json(error('VALIDATION', 'type does not match the stored event'), 400)
  }
  return c.json(
    error('VALIDATION', 'This entry is one per day — delete it and log the other day instead'),
    400,
  )
})

app.delete('/me/events/:id', requireAuth, requireAccount, async (c) => {
  const deleted = await softDeleteEvent(
    c.get('claims').sub,
    tokenVersionOf(c.get('claims')),
    c.req.param('id'),
  )
  if (!deleted) return c.json(error('NOT_FOUND', 'No such event'), 404)
  return c.json({ deleted: true })
})

/** Undo for the delete toast. Nothing to validate — the id is the whole request, and
 *  what may be restored is a question about stored state, which the module answers. */
app.post(
  '/me/events/:id/restore',
  requireAuth,
  requireAccount,
  requireCollectConsent,
  async (c) => {
    const result = await restoreEvent(
      c.get('claims').sub,
      tokenVersionOf(c.get('claims')),
      c.req.param('id'),
    )
    if (result.ok) return c.json({ event: result.event })
    if (result.reason === 'day-taken') {
      // 409, not 404: the entry is not missing, the day is occupied. Restoring would
      // have to overwrite a newer entry, so the client is told rather than obeyed.
      return c.json(
        error('DAY_ALREADY_LOGGED', "That day already has an entry, so this one can't be restored"),
        409,
      )
    }
    if (result.reason === 'expired') {
      return c.json(
        error('NOT_FOUND', `That entry is past its ${RETENTION_DAYS}-day recovery window`),
        404,
      )
    }
    return c.json(error('NOT_FOUND', 'No such event'), 404)
  },
)

/** Upsert-by-day: one body signals entry per user per day, always replaced whole.
 *  The ratings sit at the top level here — the route already says what this is. */
app.put('/me/body-signals/:date', requireAuth, requireAccount, requireCollectConsent, async (c) => {
  const body = await readBody(c)
  const localDate = c.req.param('date')
  if (!isCalendarDate(localDate)) {
    return c.json(error('VALIDATION', 'date must be YYYY-MM-DD'), 400)
  }

  const clock = resolveClock(body.timeZone)
  if (!clock.ok) return c.json(error(clock.code, clock.message), 400)
  const policy = checkDatePolicy('bodySignals', localDate, clock.value)
  if (!policy.ok) return c.json(error(policy.code, policy.message), 400)

  const payload = parseBodySignalsPayload(body, await getSymptomRules())
  if (!payload.ok) return c.json(error(payload.code, payload.message), 400)
  const loggedAt = parseLoggedAt(body.loggedAt, localDate, clock.value)
  if (!loggedAt.ok) return c.json(error(loggedAt.code, loggedAt.message), 400)
  const note = parseNote(body.note, 'bodySignals')
  if (!note.ok) return c.json(error(note.code, note.message), 400)
  const source = parseSource(body.source)
  if (!source.ok) return c.json(error(source.code, source.message), 400)
  const idempotencyKey = parseIdempotencyKey(body.idempotencyKey)
  if (!idempotencyKey.ok) return c.json(error(idempotencyKey.code, idempotencyKey.message), 400)

  const event = await createEvent(c.get('claims').sub, tokenVersionOf(c.get('claims')), {
    type: 'bodySignals',
    localDate,
    loggedAt: loggedAt.value,
    note: note.value,
    source: source.value,
    idempotencyKey: idempotencyKey.value,
    payload: payload.value,
  })
  return c.json({ event })
})

// ── Cycle predictions ──────────────────────────────────────────────────────────
// The calendar's overlay (C12a of #11, #205). Validates at the edge and delegates to
// today.ts, which is the seam the cycle maths is read through (ARCHITECTURE §3) — no
// Firestore here, and not one number of the maths either.

/** What the calendar draws over one range, and nothing else it does not draw.
 *
 *  Three lists of dates rather than three spans: a withheld prediction is then an empty
 *  overlay by construction, instead of three nulls a client has to remember to check. Every
 *  date in them was computed by `cycle.ts`. */
interface CyclePredictionsBody {
  /** The range asked for, echoed so a cached month knows what it holds. */
  from: string
  to: string
  /** The predicted next first flow day, when it falls inside the range.
   *
   *  At most one day, because `cycle.ts` produces a next-period *start* and deliberately
   *  no period length ("never an end date, a period length or a cycle length"). Painting
   *  four more cells would mean inventing one here, which is the thing #205 forbids. */
  predictedPeriod: string[]
  /** Ovulation − `fertileDaysBeforeOvulation` through + `fertileDaysAfterOvulation`,
   *  clipped to the range. Never a contraceptive method — the screen that draws it says
   *  so (GUARDRAILS 35). */
  fertileWindow: string[]
  /** Peak fertility, a subset of `fertileWindow`. */
  peak: string[]
  /**
   * A27's band: `wide` below `narrowBandMinCycles` counted cycles, `narrow` at or above
   * it, `null` when there is no prediction at all.
   *
   * **C11's own vocabulary, passed through.** A second set of words here is how a wide
   * band gets drawn as a certainty — the client picks its band off this, and a prediction
   * from four cycles must not look like one from ten (PRD §Phase 1 rule 5).
   */
  confidence: 'wide' | 'narrow' | null
  /**
   * Why there is nothing to draw, or `null` when there is.
   *
   * **In the response rather than inferred from empty lists**, because the two states are
   * different and only one of them is about her data: `withheld` set means a gate closed
   * (she has logged no flow, she has too few counted cycles, her cycles vary more than her
   * FIGO band allows, or one interval in the window fell outside the countable range),
   * while `withheld: null` with empty lists means the prediction simply falls outside the
   * range asked for. A client that guessed from emptiness would explain the second as the
   * first.
   *
   * **The last two are not interchangeable and the client must not collapse them** (#190).
   * `irregular-cycles` is a statement about her cycles; `uncountable-cycle` is a statement
   * about one of her logs, and it was being answered as the first for six cycles after a
   * single missed period start. A fourth value is additive here and is a **breaking decode**
   * on a client that models this as a closed enum — `EvaPredictionWithheld` in
   * `mobile/Eva/Calendar/EvaCyclePrediction.swift` is one, and fails the whole response
   * rather than the one field. Nothing serves it yet (`CYCLE_*` is unset in every
   * environment, #191), which is the window in which the iOS case has to land.
   */
  withheld: EstimateWithheld | null
}

/**
 * The days from `span.from` through `span.to` that the caller also asked about.
 *
 * Enumeration, not arithmetic: both ends were computed by `cycle.ts` from the configured
 * constants and nothing here derives a date of its own — it lists the days between two it
 * was handed and drops the ones outside the range. `YYYY-MM-DD` orders lexicographically,
 * which is what makes the clipping a string comparison; the loop is bounded by the range,
 * which `parseDateRange` has already capped.
 */
const daysWithin = (
  span: { from: string; to: string },
  range: { from: string; to: string },
): string[] => {
  const start = span.from > range.from ? span.from : range.from
  const end = span.to < range.to ? span.to : range.to
  const days: string[] = []
  for (let day = start; day <= end; day = shiftDays(day, 1)) days.push(day)
  return days
}

/**
 * C11's answer as the canvas draws it.
 *
 * A projection and nothing more. Every gate was decided in `analyzeCycles` — `prediction`
 * is `null` exactly when one of them closed, and `withheld` then says which — so there is
 * no threshold here that could disagree with the one the Today card speaks from. The
 * irregular-cycles gate reaches the wire through this single branch, which is why
 * `[28, 60, 28, 60, 28, 60]` cannot produce a fertile window by any path through this route.
 */
const toPredictionsBody = (
  analysis: CycleAnalysis,
  range: { from: string; to: string },
): CyclePredictionsBody => {
  const prediction = analysis.prediction
  if (prediction === null) {
    return {
      ...range,
      predictedPeriod: [],
      fertileWindow: [],
      peak: [],
      confidence: null,
      withheld: analysis.withheld,
    }
  }
  const window = prediction.fertileWindow
  const start = prediction.nextPeriodStart
  return {
    ...range,
    predictedPeriod: daysWithin({ from: start, to: start }, range),
    fertileWindow: daysWithin(window, range),
    peak: daysWithin({ from: window.peakFrom, to: window.peakTo }, range),
    confidence: prediction.confidence,
    withheld: null,
  }
}

/**
 * The prediction cannot be produced right now — a refusal, not a bug.
 *
 * One cause today, and it is the state of every environment: the cycle maths' constants are
 * unconfigured (A25–A27, #176, #191). `SERVICE_UNAVAILABLE` rather than a new code, because
 * the client contract grows by addition only (GUARDRAILS 11) and this is what that code
 * already means here — a capability that is not available, not a request that was wrong.
 * 503 rather than the 500 `app.onError` hands back anything a route drops, which is the same
 * mapping `GET /me/today` makes for the same throw (#181).
 *
 * The log line carries the kind of refusal and nothing else. Not the range, not a withheld
 * reason, not a date: which gate closed over whose calendar is derived from her logs, so
 * `irregular-cycles` against a named request is a health fact in a log line (GUARDRAILS 12).
 */
const predictionsUnavailable = (c: Context, reason: string) => {
  console.warn(JSON.stringify({ event: 'predictions_unavailable', reason }))
  return c.json(
    error(
      'SERVICE_UNAVAILABLE',
      "Cycle predictions aren't available right now. Please try again later.",
    ),
    503,
  )
}

/**
 * The cycle overlay for a date range (#205, slice C12a of #11).
 *
 * **By range, because that is how the calendar already asks.** `CalendarModel` fetches
 * events with `from`/`to` and caches by month, and a month grid spans up to three of them;
 * a per-day prediction would give one screen two fetch models. So the range is validated
 * and capped exactly as `GET /me/events` is, through the same `parseDateRange`.
 *
 * `timeZone` decides which local day the maths is anchored on — optional, with the same UTC
 * fallback events and the Today card use. The *range* is what to draw; `today` is what the
 * prediction is measured from, and they are different questions.
 *
 * **Derived on read, never cached** (PRD §Predictions 5): nothing is stored under this
 * route, so an edited flow entry moves the answer on the very next request.
 */
app.get('/me/cycle/predictions', requireAuth, requireAccount, async (c) => {
  const range = parseDateRange(c.req.query('from'), c.req.query('to'))
  if (!range.ok) return c.json(error(range.code, range.message), 400)
  const clock = resolveClock(c.req.query('timeZone'))
  if (!clock.ok) return c.json(error(clock.code, clock.message), 400)

  try {
    // Only the caller's local *date* is needed: `cycle.ts` reads no clock, and the
    // stored `localDate`s are calendar labels rather than instants — so unlike the Today
    // card, nothing here has to turn a wall clock back into one.
    const analysis = await cycleAnalysisFor(c.get('claims').sub, clock.value.today)
    return c.json(toPredictionsBody(analysis, range.value))
  } catch (err) {
    if (err instanceof CycleRulesUnsetError) {
      return predictionsUnavailable(c, 'cycle-rules-unset')
    }
    // `InvalidCycleDateError` is deliberately not mapped. Every `localDate` the maths
    // reads was written through `isCalendarDate` above, and `today` comes from
    // `resolveClock`, so nothing reachable through the API can raise it — and an arm
    // nothing can reach is one nothing can test. `today.ts` removed `InvalidTimeError`
    // from the sibling route for exactly this reason. Anything else is a bug, and
    // `app.onError` answers it as one.
    throw err
  }
})

// ── Dashboard ──────────────────────────────────────────────────────────────────
// Validates at the edge and delegates to today.ts, the only module allowed to touch
// users/{uid}/today (GUARDRAILS rule 10).

/**
 * The Today card cannot be produced right now — and that is a refusal, not a bug.
 *
 * Three causes, all of them "something this card depends on has not been supplied": rung 2's
 * thresholds are unconfigured (#26 has not answered A32), the cycle maths' constants are
 * unconfigured (A25–A27, #176), or the content store holds no template for the chosen
 * subject at its confidence (nobody has seeded `content/`, which is the state of every
 * environment today — #97 refuses to seed without a reviewer). Answering past any of them
 * would mean a card that looks live and is not.
 *
 * `SERVICE_UNAVAILABLE` rather than a new code: the client contract grows by addition only
 * (GUARDRAILS 11), and this is exactly what that code already means everywhere else here —
 * a capability that is not available, not a request that was wrong.
 *
 * The log line is the operator's signal and carries the *kind* of refusal and nothing else.
 * Not the template id: which card a user was about to be shown is derived from her logs, so
 * `late_period` in a log line is a health fact about a named request (GUARDRAILS 12).
 */
const dashboardUnavailable = (c: Context, reason: string) => {
  console.warn(JSON.stringify({ event: 'dashboard_unavailable', reason }))
  return c.json(
    error(
      'SERVICE_UNAVAILABLE',
      "Your Today card isn't available right now. Please try again later.",
    ),
    503,
  )
}

/** The Nutrition targets engine's refusal (#222): the `NUTRITION_*` group is unset, so there
 *  is no target to serve. The same shape as `dashboardUnavailable`, its own event so an
 *  operator can tell the two apart. */
const nutritionUnavailable = (c: Context) => {
  console.warn(JSON.stringify({ event: 'nutrition_unavailable' }))
  return c.json(
    error(
      'SERVICE_UNAVAILABLE',
      "Your nutrition plan isn't available right now. Please try again later.",
    ),
    503,
  )
}

/**
 * The day's card (#98, slice D3 of #10).
 *
 * `timeZone` decides which local day this is, exactly as it does for a calendar entry:
 * optional, and without it the server falls back to UTC. The card is generated once for
 * that date and returned unchanged on every later open — `today.ts` regenerates only when
 * her own data has moved, never because the page was refreshed.
 */
app.get('/me/today', requireAuth, requireAccount, async (c) => {
  const timeZone = c.req.query('timeZone')
  const clock = resolveClock(timeZone)
  if (!clock.ok) return c.json(error(clock.code, clock.message), 400)

  try {
    const today = await getToday(c.get('claims').sub, tokenVersionOf(c.get('claims')), {
      date: clock.value.today,
      timeZone: timeZone ?? 'UTC',
    })
    return c.json(today)
  } catch (err) {
    if (err instanceof PatternRuleUnsetError) return dashboardUnavailable(c, 'pattern-rule-unset')
    if (err instanceof TemplateUnavailableError) {
      return dashboardUnavailable(c, 'template-unavailable')
    }
    // C11's, and reachable since #179 handed `today.ts`'s estimate to `analyzeCycles`.
    // It was mapped one issue before it could be thrown (#181), because the day it
    // became reachable is the day a deployment without the `CYCLE_*` group starts
    // answering 500 instead of 503 — and that group is unset in every environment today
    // (`deploy-api.yml` does not set it; #176 says why that is deliberate).
    if (err instanceof CycleRulesUnsetError) return dashboardUnavailable(c, 'cycle-rules-unset')
    // D1's `InvalidTimeError` had a third branch here and it was dead code: `date` comes
    // from `resolveClock`, `now` from `new Date()`, and `today.ts` drops a stored wall
    // clock it cannot parse rather than passing it down. Nothing could reach it, so
    // nothing could test it. Re-open one of those three and it belongs back here.
    // Anything else is a bug, and `app.onError` answers it as one.
    throw err
  }
})

export default {
  // Cloud Run injects PORT (8080); default to 3003 for local dev
  port: Number(process.env.PORT ?? 3003),
  // Outermost, so `ms` covers the timeout wrapper too and every request that answers writes
  // one `request` line; a hung one writes `request_timeout` first (#263, #225).
  fetch: withRequestLog(withRequestTimeout(app.fetch)),
  // Bun's `idleTimeout` is in *seconds* (max 255); `REQUEST_TIMEOUT_MS` is in milliseconds
  // for the timer above. Both are the same 10s, deliberately not raised (#225).
  idleTimeout: REQUEST_TIMEOUT_MS / 1000,
}
