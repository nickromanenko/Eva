import { adminAuth } from './firebase'
import { config } from './config'

/**
 * Owner of the Firebase Auth account itself — created, verified and destroyed here and
 * nowhere else.
 *
 * Two transports, for one reason: the Admin SDK cannot verify a password, so creating
 * and checking credentials goes through the Identity Toolkit REST API with the web API
 * key (GUARDRAILS 4, and the only place that key is read), while deleting an account has
 * no REST equivalent we hold a credential for and goes through the Admin SDK. Splitting
 * that across two modules would leave the Auth user with two owners, which is exactly
 * what GUARDRAILS 10 is about for Firestore collections.
 */

/**
 * Why a call failed, in *our* vocabulary rather than Google's (issue #32).
 *
 * The route has to answer differently for "this request will never work" and "ask again
 * in a minute", but it must not read `reason` to decide — a value derived from the
 * upstream answer is one refactor away from being interpolated into a message, which is
 * the enumeration leak #21 closed. So the mapping from Google's strings happens here,
 * where the upstream protocol already lives, and `index.ts` only ever sees these three.
 *
 * - `email-exists` — the address is taken. Signup says so deliberately (ARCHITECTURE §3).
 * - `rejected` — upstream refused the request itself. Our edge validation should have
 *   caught it; that it did not is a client mistake or a gap in our rule, never an outage.
 * - `unavailable` — upstream could not answer: 5xx, a throttle, a network failure, a
 *   response that is not JSON, or a project configuration that refuses the operation.
 *   Retrying is reasonable for all but the last, which retrying cannot fix but which an
 *   operator must be paged about rather than shown to the user as a bad email.
 */
export type IdentityToolkitFailure = 'email-exists' | 'rejected' | 'unavailable'

/**
 * Reasons Google returns with a 4xx that are nonetheless "not now", not "not ever":
 * the first two are load-shedding, the last two mean the project is misconfigured (the
 * password provider disabled, or sign-up locked to admins). None of them says anything
 * about the address that was submitted, which is what makes them safe to distinguish.
 */
const UNAVAILABLE_REASONS = new Set([
  'TOO_MANY_ATTEMPTS_TRY_LATER',
  'QUOTA_EXCEEDED',
  'OPERATION_NOT_ALLOWED',
  'ADMIN_ONLY_OPERATION',
])

/**
 * The status decides first, and only then the reason: a 5xx or a 429 is an outage whatever
 * the body claims, so a garbled or absent reason under one can never be read as a verdict
 * about the caller's address. A `null` status means the caller knows better than the reason
 * does and is expected to pass `kind` explicitly.
 */
const classify = (reason: string, upstreamStatus: number | null): IdentityToolkitFailure => {
  if (upstreamStatus !== null && (upstreamStatus >= 500 || upstreamStatus === 429)) {
    return 'unavailable'
  }
  if (reason === 'EMAIL_EXISTS') return 'email-exists'
  return UNAVAILABLE_REASONS.has(reason) ? 'unavailable' : 'rejected'
}

export class IdentityToolkitError extends Error {
  /**
   * `reason` is Google's own string and is for *nothing but* this class. It must never
   * reach a response body, a header, or a log line (GUARDRAILS 12) — route code branches
   * on `kind`. `upstreamStatus` is the HTTP status Google answered with, `null` when there
   * was no answer at all; it names no user and is the operator's signal.
   *
   * `kind` is derived rather than required so that every construction — including the
   * mocks in `test/` — classifies by the same rule the live call does. Pass it explicitly
   * only for a failure that has no upstream status to be judged by.
   */
  constructor(
    readonly reason: string,
    readonly upstreamStatus: number | null = null,
    readonly kind: IdentityToolkitFailure = classify(reason, upstreamStatus),
  ) {
    super(`Identity Toolkit: ${reason}`)
  }
}

interface TokenResponse {
  localId: string
  email: string
}

const call = async (endpoint: string, body: Record<string, unknown>): Promise<TokenResponse> => {
  let response: Response
  try {
    response = await fetch(
      `${config.identityToolkitBaseUrl}/v1/accounts:${endpoint}?key=${config.firebaseWebApiKey}`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ ...body, returnSecureToken: true }),
      },
    )
  } catch {
    // The underlying error is dropped rather than attached as a `cause`: fetch puts the
    // request URL in its message, and that URL carries the web API key (GUARDRAILS 1).
    // A DNS failure, a refused connection, or a timeout are all the same fact here.
    throw new IdentityToolkitError('NETWORK_FAILURE', null, 'unavailable')
  }

  let json: {
    localId?: string
    email?: string
    error?: { message?: string }
  }
  try {
    json = (await response.json()) as typeof json
  } catch {
    // Not JSON means the answer did not come from Identity Toolkit at all — a proxy or
    // load balancer error page in front of it. Treat it as an outage, not as a verdict.
    throw new IdentityToolkitError('MALFORMED_RESPONSE', response.status, 'unavailable')
  }

  if (!response.ok) {
    // Google returns codes like EMAIL_EXISTS, INVALID_LOGIN_CREDENTIALS,
    // WEAK_PASSWORD : Password should be at least 6 characters
    const reason = json.error?.message?.split(' ')[0] ?? 'UNKNOWN'
    throw new IdentityToolkitError(reason, response.status)
  }
  return { localId: json.localId!, email: json.email! }
}

export const signUpWithPassword = (email: string, password: string) =>
  call('signUp', { email, password })

export const signInWithPassword = (email: string, password: string) =>
  call('signInWithPassword', { email, password })

/** Firebase Admin's code for "no such user". */
const USER_NOT_FOUND = 'auth/user-not-found'

/**
 * Deletes the Firebase Auth user — step two of account deletion (#8), after the account
 * has been marked deleted in Firestore and before any of its data is swept. From here on
 * the address is free to sign up again and the old credentials open nothing.
 *
 * Idempotent: an already-deleted user is the state this is asking for, so it is success,
 * not a failure to report. That is what lets a `DELETE /me` retried after a partial
 * failure walk the same steps and finish rather than erroring on the first one that is
 * already done.
 *
 * Deliberately never told *which* address it removed, and it logs nothing: a uid is
 * enough to do the work, and an email in a log line is the thing GUARDRAILS 12 forbids.
 */
export const deleteAuthAccount = async (uid: string): Promise<void> => {
  try {
    await adminAuth.deleteUser(uid)
  } catch (err) {
    if ((err as { code?: string }).code !== USER_NOT_FOUND) throw err
  }
}

/**
 * The uid behind an address, or `null` when no Auth user holds it — the lookup behind
 * the two "send me a link" routes (#6). Those routes answer `200 { sent: true }` either
 * way, so the `null` never reaches a caller; it only decides whether there is anyone to
 * write to. Here rather than in `users.ts` because the Auth account, not the document, is
 * what a password reset acts on — and because `users/` is keyed by uid, never by email
 * (GUARDRAILS 9). Logs nothing.
 */
export const findAuthUidByEmail = async (email: string): Promise<string | null> => {
  try {
    return (await adminAuth.getUserByEmail(email)).uid
  } catch (err) {
    if ((err as { code?: string }).code === USER_NOT_FOUND) return null
    throw err
  }
}

/**
 * Sets a new password on the Auth account — the last step of a reset (#6), after the
 * token has been spent. The Admin SDK can set a password even though it cannot verify one,
 * so this is the one credential operation that needs no web API key. Never logs, and is
 * never told the old password; the new one passes through and is gone.
 */
export const setPassword = async (uid: string, password: string): Promise<void> => {
  await adminAuth.updateUser(uid, { password })
}
