import { FieldValue } from 'firebase-admin/firestore'
import { issueToken } from '../../src/email-tokens'
import { adminAuth, firestore } from '../../src/firebase'

/**
 * How the live suites get a session now that sign-up does not hand one out (#6).
 *
 * The activation link never reaches a test — the server prints it (log transport) or
 * sends it (Postmark), and neither is readable from here — so the test process issues a
 * token of its own through the same `issueToken` the server uses, against the same
 * Firestore, and then spends it through the live `POST /auth/activate`. Every suite that
 * signs up therefore also exercises the activation route for real.
 *
 * Not a test file: Bun only picks up `*.test.ts`.
 */

const post = (base: string, path: string, body: unknown) =>
  fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })

/**
 * Spends a freshly issued activation token on the live server, setting the password.
 *
 * `uid` is `null` for the sign-up flow (#120): sign-up creates no account, so the token it
 * issues carries only the address and the route creates the account when the link is spent.
 * Pass a uid to activate an account that already exists — which is what a token minted
 * before #120 looks like, and what a directly-reserved address looks like.
 */
export const activateAccount = async (
  base: string,
  uid: string | null,
  email: string,
  password: string,
): Promise<void> => {
  const token = await issueToken(uid, email, 'activation')
  const res = await post(base, '/auth/activate', { token, password })
  if (res.status !== 200) throw new Error(`activate answered ${res.status}`)
}

/** Signs in and hands back the session token. */
export const signIn = async (base: string, email: string, password: string): Promise<string> => {
  const res = await post(base, '/auth/signin', { email, password })
  if (res.status !== 200) throw new Error(`signin answered ${res.status}`)
  return ((await res.json()) as { token: string }).token
}

/**
 * Sign-up → activation → sign-in → the collect consent, through the live routes.
 *
 * The account does not exist until the link is spent (#120): sign-up sends an address and
 * gets `201 { pending }`, and the password is chosen at activation. So the uid can only be
 * read from Auth *after* activating, not before.
 *
 * The last step is #86's, and it is here for the same reason activation is: a session
 * whose account has no collect consent cannot write health data, and nearly every caller
 * of this helper writes health data. The app grants it through the consent screen, which
 * no test process can draw, so the helper grants it the way it already spends the
 * activation link the app never sees. The version is the consent text's own — the
 * "Consent v1 · 2026-08-30" line the screen displays, matching the app's
 * `ConsentPolicy.version`. Pass `consent: false` for a suite that tests the refusal
 * itself (consent.test.ts).
 */
export const signUpActivated = async (
  base: string,
  email: string,
  password: string,
  opts: { consent?: boolean } = {},
): Promise<{ token: string; uid: string }> => {
  const res = await post(base, '/auth/signup', { email })
  if (res.status !== 201) throw new Error(`signup answered ${res.status}`)
  await activateAccount(base, null, email, password)
  const { uid } = await adminAuth.getUserByEmail(email)
  const token = await signIn(base, email, password)
  if (opts.consent ?? true) {
    const res = await fetch(`${base}/me/consent/collect`, {
      method: 'PUT',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({ granted: true, version: '2026-08-30' }),
    })
    if (res.status !== 200) throw new Error(`consent answered ${res.status}`)
  }
  return { token, uid }
}

/**
 * An account in the shape sign-up leaves behind: Auth user, `users/{uid}` document,
 * `activatedAt: null`. Written directly rather than through `POST /auth/signup` so a
 * suite can stand up as many as it needs without spending the shared per-IP sign-up
 * budget (#5) — and without sending an email for each.
 */
export const createUnactivatedAccount = async (
  email: string,
  password: string,
): Promise<string> => {
  const { uid } = await adminAuth.createUser({ email, password })
  await firestore
    .collection('users')
    .doc(uid)
    .set({
      email,
      authProviders: ['password'],
      questionnaireCompleted: false,
      profile: null,
      activatedAt: null,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    })
  return uid
}

/**
 * An account exactly as every one created before #6 looks: an Auth user and a
 * `users/{uid}` document with no `activatedAt` field at all. Written directly, because
 * nothing in `src/` can produce that shape any more — which is the point of having it.
 */
export const createLegacyAccount = async (email: string, password: string): Promise<string> => {
  const { uid } = await adminAuth.createUser({ email, password })
  await firestore
    .collection('users')
    .doc(uid)
    .set({
      email,
      authProviders: ['password'],
      questionnaireCompleted: false,
      profile: null,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    })
  return uid
}

/**
 * An activated account whose profile is the shape every one written before #81 has:
 * `profile.age`, no `dateOfBirth`, and `questionnaireCompleted: true`.
 *
 * Written directly, for `createLegacyAccount`'s reason — nothing in `src/` can produce that
 * shape any more, which is the point of having it. It is the fixture #81's migration answer
 * is asserted against: there is no date of birth derivable from an age, so nothing is
 * backfilled and nothing is deleted, and what has to be true is that the account still opens
 * and the questionnaire is asked again.
 */
export const createPreDateOfBirthAccount = async (
  email: string,
  password: string,
): Promise<string> => {
  const { uid } = await adminAuth.createUser({ email, password, emailVerified: true })
  await firestore
    .collection('users')
    .doc(uid)
    .set({
      email,
      authProviders: ['password'],
      questionnaireCompleted: true,
      profile: {
        age: 28,
        weightKg: 64,
        heightCm: 168,
        goals: ['Energy'],
        conditions: ['None of these'],
        medications: 'No',
        lifestyle: 'Active',
        sports: ['Yoga'],
      },
      activatedAt: FieldValue.serverTimestamp(),
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    })
  return uid
}
