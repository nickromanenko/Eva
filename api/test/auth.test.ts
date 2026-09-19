import { afterAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { verify } from 'hono/jwt'
import { config } from '../src/config'
import { issueToken } from '../src/email-tokens'
import { adminAuth, firestore } from '../src/firebase'
import {
  activateAccount,
  createLegacyAccount,
  createPreDateOfBirthAccount,
  createUnactivatedAccount,
} from './support/session'

/**
 * Integration tests against the REAL Firebase project (per spec §6).
 * Every account uses the e2e+<uuid>@e2e.evaapp.dev pattern and is deleted
 * (Auth user + Firestore doc) in afterAll, success or failure.
 */

// Sign-up now costs an Auth lookup and an activation round trip on top of the round
// trips it always made (#6), which put two cases past Bun's 5000ms default. 20s is not a
// measurement — it is a ceiling that still fails loudly on a genuine hang, the same one
// events.test.ts sets and for the same reason (#31).
setDefaultTimeout(20_000)

const BASE = process.env.EVA_API_URL ?? 'http://localhost:3003'
const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`
const password = 'correct-horse-8'
const createdUids: string[] = []
/** Every address this file signed up, so the token sweep below can find what the uid sweep
 *  cannot. Populated wherever an address is minted, not at the point of use. */
const createdEmails: string[] = [email]

/** A fresh address per case, for the ones that must not share the suite's account. */
const address = () => {
  const value = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`
  createdEmails.push(value)
  return value
}

/** Every `users/{uid}` holding this address — asked of Firestore, because "sign-up created
 *  nothing" is a claim about the database and not about a response body. */
const accountsForEmail = async (value: string): Promise<string[]> =>
  (await firestore.collection('users').where('email', '==', value).get()).docs.map((d) => d.id)

const api = (path: string, init?: RequestInit & { token?: string }) =>
  fetch(`${BASE}${path}`, {
    ...init,
    headers: {
      'content-type': 'application/json',
      ...(init?.token ? { authorization: `Bearer ${init.token}` } : {}),
    },
  })

interface UserBody {
  id: string
  email: string
  questionnaireCompleted: boolean
  activated: boolean
  /** Never carries `age` since #81 — asserted as raw JSON, not through this shape. */
  profile: Record<string, unknown> | null
}
interface UserResponse {
  user: UserBody
}
interface AuthResponse extends UserResponse {
  token: string
}
interface PendingResponse {
  pending: boolean
  email: string
}
interface ErrorResponse {
  error: { code: string; message: string }
}

/** Typed `res.json()` — the API contract is documented in docs/ARCHITECTURE.md §3. */
const json = <T>(res: Response): Promise<T> => res.json() as Promise<T>

/** A complete, valid questionnaire payload for one date of birth (#81). Every field is the
 *  current vocabulary, so a case that overrides one field is testing only that field. */
const profileBornOn = (dateOfBirth: string) => ({
  dateOfBirth,
  weightKg: 64,
  heightCm: 168,
  goals: ['Energy', 'Sleep'],
  conditions: ['noneOfThese'],
  medications: 'none',
  lifestyle: 'Active',
  sports: ['Yoga'],
})

afterAll(async () => {
  // **By address, and that half is not redundant.** This file does most of the suite's
  // sign-ups, and since #120 a sign-up issues its activation token *before* any account
  // exists — `uid: null`. The uid loop below cannot match those, so a clean full run was
  // leaving dozens of `authTokens/` rows behind, each holding an address. The TTL policy on
  // `expiresAt` reaps them within a day, so this is hygiene rather than accumulation, but
  // ARCHITECTURE §3 makes the address the sensitive artefact in that collection and a day
  // is not the promise.
  for (const value of createdEmails) {
    const byEmail = await firestore
      .collection('authTokens')
      .where('email', '==', value)
      .get()
      .catch(() => null)
    if (byEmail) {
      await Promise.all(byEmail.docs.map((d) => d.ref.delete().catch(() => {})))
    }
  }
  for (const uid of createdUids) {
    const byUid = await firestore
      .collection('authTokens')
      .where('uid', '==', uid)
      .get()
      .catch(() => null)
    if (byUid) await Promise.all(byUid.docs.map((d) => d.ref.delete().catch(() => {})))
    await adminAuth.deleteUser(uid).catch(() => {})
    await firestore
      .collection('users')
      .doc(uid)
      .delete()
      .catch(() => {})
  }
})

describe('auth', () => {
  let token = ''
  let uid = ''

  test('signup creates nothing at all — no account, no document, no credential', async () => {
    const res = await api('/auth/signup', {
      method: 'POST',
      body: JSON.stringify({ email }),
    })
    expect(res.status).toBe(201)
    // No token — the address is not proven — and the address echoed back so the
    // "check your email" screen can name where the link went.
    expect(await json<PendingResponse>(res)).toEqual({ pending: true, email })

    // **The assertion this whole issue is about** (#120). Sign-up used to create a
    // Firebase Auth user with the caller's password here, which reserved the address
    // and put a working credential on it before anyone had proved it was theirs. An
    // attacker signed up as a victim, the victim clicked the confirmation mail they
    // never asked for, and the attacker's password opened an activated account holding
    // the victim's data. Nothing exists to inherit now.
    await expect(adminAuth.getUserByEmail(email)).rejects.toThrow()
    expect(await accountsForEmail(email)).toEqual([])
  })

  test('a password sent to signup is ignored, not honoured', async () => {
    // An older client still posts one. It must not become a credential — that is the
    // whole point — and it must not fail the request either, or every un-updated app
    // breaks at once.
    const other = address()
    const res = await api('/auth/signup', {
      method: 'POST',
      body: JSON.stringify({ email: other, password }),
    })
    expect(res.status).toBe(201)
    await expect(adminAuth.getUserByEmail(other)).rejects.toThrow()
  })

  test('signin is refused until the address is confirmed', async () => {
    // The gate still exists, but the normal flow can no longer reach it: a pending
    // sign-up has no account and no password, so there is nothing to sign in with.
    // What reaches it is an account somebody created *outside* sign-up — by calling
    // Identity Toolkit directly with the public web API key, which Eva cannot prevent
    // — or one predating #120. That is the shape this stands up.
    const stranded = address()
    const strandedUid = await createUnactivatedAccount(stranded, password)
    createdUids.push(strandedUid)

    const res = await api('/auth/signin', {
      method: 'POST',
      body: JSON.stringify({ email: stranded, password }),
    })
    expect(res.status).toBe(403)
    expect((await json<ErrorResponse>(res)).error.code).toBe('NOT_ACTIVATED')
  })

  test('an unconfirmed address with a wrong password is refused like any other', async () => {
    // Where the gate sits is the design (#6): the 403 above is only reachable once
    // Identity Toolkit has verified the password. Answering "not activated" first
    // would tell anyone holding an address that an Eva account stands behind it —
    // the question the 401 exists to refuse. So: same status, same bytes, for an
    // unconfirmed real account and an address that was never registered.
    const unconfirmed = await api('/auth/signin', {
      method: 'POST',
      body: JSON.stringify({ email, password: 'wrong-password-1' }),
    })
    const unknown = await api('/auth/signin', {
      method: 'POST',
      body: JSON.stringify({
        email: `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`,
        password: 'wrong-password-1',
      }),
    })
    expect(unconfirmed.status).toBe(401)
    expect(unknown.status).toBe(401)
    expect(await unconfirmed.text()).toBe(await unknown.text())
  })

  test('the activation link creates the account, sets the password, and confirms once', async () => {
    // The account comes into existence *here*, not at sign-up (#120): the link proves
    // the address and the form supplies the password, in the same request. So the uid
    // can only be read afterwards.
    await activateAccount(BASE, null, email, password)
    uid = (await adminAuth.getUserByEmail(email)).uid
    createdUids.push(uid)

    const doc = await firestore.collection('users').doc(uid).get()
    expect(doc.exists).toBe(true)
    expect(doc.data()!.email).toBe(email)
    expect(doc.data()!.authProviders).toEqual(['password'])
    expect(doc.data()!.questionnaireCompleted).toBe(false)
    // Proven at Firebase too, which the old activation never did: the caller proved the
    // address *and* chose the password, so there is no unproven credential left for
    // Firebase's merge-wipe to protect anyone from.
    expect((await adminAuth.getUser(uid)).emailVerified).toBe(true)

    const firstConfirmation = doc.data()!.activatedAt
    expect(firstConfirmation).not.toBeNull()

    // A second, *unspent* link against an account that is already activated is now a
    // dead link (#120), and that is the change rather than an accident. It used to
    // answer 200 idempotently, which was right while activation only stamped a flag.
    // The link sets the password now, so honouring a stale one against an activated
    // account would turn every activation email anybody ever saw into a password-reset
    // primitive.
    const token = await issueToken(uid, email, 'activation')
    const activate = (body: unknown) =>
      api('/auth/activate', { method: 'POST', body: JSON.stringify(body) })
    const second = await activate({ token, password })
    expect(second.status).toBe(400)
    expect((await json<ErrorResponse>(second)).error.code).toBe('INVALID_TOKEN')

    // Consumed anyway, so it cannot be replayed either.
    const replay = await activate({ token, password })
    expect(replay.status).toBe(400)
    expect((await json<ErrorResponse>(replay)).error.code).toBe('INVALID_TOKEN')

    // And the record of when the address was proven is the first confirmation.
    expect((await firestore.collection('users').doc(uid).get()).data()!.activatedAt).toEqual(
      firstConfirmation,
    )
  })

  test('duplicate signup is rejected with 409', async () => {
    const res = await api('/auth/signup', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    })
    expect(res.status).toBe(409)
    expect((await json<ErrorResponse>(res)).error.code).toBe('EMAIL_EXISTS')
  })

  test('signup validates the address, which is all it is given', async () => {
    const bad = await api('/auth/signup', {
      method: 'POST',
      body: JSON.stringify({ email: 'not-an-email' }),
    })
    expect(bad.status).toBe(400)
    // The password rule moved with the password: it is enforced at activation now, and
    // `activation password rule` below is where it is tested.
  })

  test('signin returns token for correct password, matches same user', async () => {
    const res = await api('/auth/signin', {
      method: 'POST',
      body: JSON.stringify({ email: email.toUpperCase(), password }), // case-insensitive email
    })
    expect(res.status).toBe(200)
    const body = await json<AuthResponse>(res)
    token = body.token
    expect(body.user.id).toBe(uid) // same uid → same users doc, no second record
    expect(body.user.activated).toBe(true)

    const claims = await verify(token, config.jwtSecret, 'HS256')
    expect(claims.sub).toBe(uid)
  })

  test('signin rejects wrong password with 401', async () => {
    const res = await api('/auth/signin', {
      method: 'POST',
      body: JSON.stringify({ email, password: 'wrong-password-1' }),
    })
    expect(res.status).toBe(401)
    expect((await json<ErrorResponse>(res)).error.code).toBe('INVALID_CREDENTIALS')
  })

  test('signin answers a wrong password and an unknown address identically', async () => {
    // The live half of the non-enumeration property (issue #21): this one guards the
    // upstream layer, and it is the weaker of the two. Identity Toolkit collapses both
    // cases into INVALID_LOGIN_CREDENTIALS today, so this stays green even if the route
    // interpolates the upstream reason into the message. test/signin-non-enumeration.test.ts
    // is the test that pins our half, with the upstream controlled.
    const wrongPassword = await api('/auth/signin', {
      method: 'POST',
      body: JSON.stringify({ email, password: 'wrong-password-1' }),
    })
    const unknownAddress = await api('/auth/signin', {
      method: 'POST',
      body: JSON.stringify({
        email: `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`,
        password,
      }),
    })
    expect(wrongPassword.status).toBe(unknownAddress.status)
    const wrong = await json<ErrorResponse>(wrongPassword)
    const unknown = await json<ErrorResponse>(unknownAddress)
    expect(wrong.error.code).toBe(unknown.error.code)
    expect(wrong.error.message).toBe(unknown.error.message)
  })

  test('GET /me requires and honors the JWT', async () => {
    expect((await api('/me')).status).toBe(401)
    const res = await api('/me', { token })
    expect(res.status).toBe(200)
    expect((await json<UserResponse>(res)).user.id).toBe(uid)
  })

  // The questionnaire is a health write, and this account has no consent on record — no
  // consent screen has run (#86). Grant it here the way the app would, through the route,
  // so the tests below exercise the questionnaire rather than the gate;
  // consent.test.ts is where the gate itself is tested.
  test('the collect consent is granted before the questionnaire writes', async () => {
    const res = await api('/me/consent/collect', {
      method: 'PUT',
      token,
      body: JSON.stringify({ granted: true, version: '2026-08-30' }),
    })
    expect(res.status).toBe(200)
  })

  test('questionnaire submission completes the profile', async () => {
    const res = await api('/me/questionnaire', {
      method: 'PUT',
      token,
      body: JSON.stringify(profileBornOn('1996-06-15')),
    })
    expect(res.status).toBe(200)
    expect((await json<UserResponse>(res)).user.questionnaireCompleted).toBe(true)

    const doc = await firestore.collection('users').doc(uid).get()
    expect(doc.data()!.questionnaireCompleted).toBe(true)
    // The date, not an age (#81). A stored age is wrong within a year and wrong
    // silently, and it is what the FIGO band — a gate on whether a fertile window is
    // drawn at all — is chosen from.
    expect(doc.data()!.profile.dateOfBirth).toBe('1996-06-15')
    expect('age' in doc.data()!.profile).toBe(false)

    // Returning user now routes as completed.
    const signin = await api('/auth/signin', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    })
    expect((await json<UserResponse>(signin)).user.questionnaireCompleted).toBe(true)
  })

  test('invalid questionnaire payload is rejected', async () => {
    const res = await api('/me/questionnaire', {
      method: 'PUT',
      token,
      body: JSON.stringify({ dateOfBirth: '1996-06-15' }),
    })
    expect(res.status).toBe(400)
  })

  /**
   * **Eva is 18+ (A12, decided on #81), enforced where the date is captured.**
   *
   * The boundary is pinned against the *caller's* day rather than the test's idea of one:
   * every case here sends `timeZone: "UTC"`, which takes `resolveClock`'s slack to zero and
   * makes the server's "today" exactly the UTC date this process can compute. Without that
   * the two could sit either side of midnight and the case would fail once a day, somewhere.
   */
  test('a date of birth under 18 is refused, and her birthday is the boundary', async () => {
    const todayUtc = new Date().toISOString().slice(0, 10)
    const [year, monthAndDay] = [Number(todayUtc.slice(0, 4)), todayUtc.slice(4)]
    const submit = (dateOfBirth: string) =>
      api('/me/questionnaire', {
        method: 'PUT',
        token,
        body: JSON.stringify({ ...profileBornOn(dateOfBirth), timeZone: 'UTC' }),
      })

    // Eighteen today: in, on the day itself and not the day after.
    expect((await submit(`${year - 18}${monthAndDay}`)).status).toBe(200)
    // Eighteen tomorrow: out. One day of difference either side of the same number.
    const eighteenTomorrow = new Date(Date.parse(`${todayUtc}T00:00:00.000Z`) + 86_400_000)
      .toISOString()
      .slice(0, 10)
    const refused = await submit(
      `${Number(eighteenTomorrow.slice(0, 4)) - 18}${eighteenTomorrow.slice(4)}`,
    )
    expect(refused.status).toBe(400)
    const body = await json<ErrorResponse>(refused)
    expect(body.error.code).toBe('VALIDATION')
    expect(body.error.message).toContain('18')
  })

  /**
   * **Which way the slack runs when the client does not say where it is.**
   *
   * The calendar routes give a logged date a day of tolerance in *both* directions so an
   * entry is never refused for the server's idea of today. The floor cannot take that
   * trade: a day of tolerance towards the caller admits somebody a day short of eighteen
   * every time a client forgets to send `timeZone`. So the age is measured against the
   * earliest day it could currently be anywhere, and the same date of birth that passes
   * with a zone is refused without one.
   *
   * This is the case that fails if the slack is dropped or reversed — the boundary case
   * above sends `timeZone: "UTC"`, which takes the slack to zero and cannot see it.
   */
  test('without a timeZone the floor is measured a day earlier, not a day later', async () => {
    const todayUtc = new Date().toISOString().slice(0, 10)
    const eighteenToday = `${Number(todayUtc.slice(0, 4)) - 18}${todayUtc.slice(4)}`
    const withZone = await api('/me/questionnaire', {
      method: 'PUT',
      token,
      body: JSON.stringify({ ...profileBornOn(eighteenToday), timeZone: 'UTC' }),
    })
    expect(withZone.status).toBe(200)

    const withoutZone = await api('/me/questionnaire', {
      method: 'PUT',
      token,
      body: JSON.stringify(profileBornOn(eighteenToday)),
    })
    expect(withoutZone.status).toBe(400)
    expect((await json<ErrorResponse>(withoutZone)).error.message).toContain('18')
  })

  test('a date of birth in the future is refused', async () => {
    const res = await api('/me/questionnaire', {
      method: 'PUT',
      token,
      body: JSON.stringify({ ...profileBornOn('2099-01-01'), timeZone: 'UTC' }),
    })
    expect(res.status).toBe(400)
    expect((await json<ErrorResponse>(res)).error.code).toBe('VALIDATION')
  })

  /** An un-updated client still sends `age`. Refused rather than ignored: accepting the
   *  rest would write a profile with no date of birth in it, which is the one field the
   *  18+ floor and the FIGO band are both read from. */
  test('an age key is refused outright', async () => {
    const res = await api('/me/questionnaire', {
      method: 'PUT',
      token,
      body: JSON.stringify({ ...profileBornOn('1996-06-15'), age: 28 }),
    })
    expect(res.status).toBe(400)
    expect((await json<ErrorResponse>(res)).error.code).toBe('VALIDATION')
  })

  /** The enumerations (A8). Codes, not labels — so the labels the app used to send are
   *  exactly what must not be accepted, or the vocabulary is decided by whoever typed
   *  first and changing a label becomes a data migration. */
  test('medications and conditions are validated against their enumerations', async () => {
    const submit = (over: Record<string, unknown>) =>
      api('/me/questionnaire', {
        method: 'PUT',
        token,
        body: JSON.stringify({ ...profileBornOn('1996-06-15'), ...over }),
      })

    expect((await submit({ medications: 'combinedPill' })).status).toBe(200)
    expect((await submit({ conditions: ['pcos', 'diabetes'] })).status).toBe(200)
    // The three #81 adds, each accepted by name so "extended" is asserted rather than
    // assumed.
    expect((await submit({ conditions: ['coeliacDisease', 'foodAllergies'] })).status).toBe(200)

    for (const over of [
      { medications: 'No' }, // the label the app used to send
      { medications: '' },
      { medications: ['none'] },
      { conditions: ['None of these'] },
      { conditions: ['pcos', 'not-a-condition'] },
      { conditions: 'pcos' },
    ]) {
      const res = await submit(over)
      expect(res.status).toBe(400)
      expect((await json<ErrorResponse>(res)).error.code).toBe('VALIDATION')
    }
  })

  /** And the refusal says which rule was broken without repeating what was sent: an error
   *  body is as readable as a log line, and a profile field is health data (GUARDRAILS 12). */
  test('a refusal names the field and not the value', async () => {
    const res = await api('/me/questionnaire', {
      method: 'PUT',
      token,
      body: JSON.stringify({
        ...profileBornOn('1996-06-15'),
        conditions: ['a-condition-nobody-should-see-echoed'],
      }),
    })
    const body = await json<ErrorResponse>(res)
    expect(body.error.message).toContain('conditions')
    expect(body.error.message).not.toContain('a-condition-nobody-should-see-echoed')
  })
})

/**
 * **The migration (#81), which is a read and not a write.**
 *
 * Documents written before this carry `profile.age`, and there is no date of birth
 * derivable from an age — 28 is any of 366 days — so nothing is backfilled, nothing is
 * deleted, and no date is invented. A profile with no `dateOfBirth` is simply not a profile
 * under this schema: it is served as none, `questionnaireCompleted` follows it, and the app
 * asks the four questionnaire steps again.
 *
 * What these cases hold is the half that is easy to lose: **she is not locked out.** Her
 * account opens, her token works, and answering the questionnaire replaces the old map
 * outright — which is also the only thing that ever removes the stored `age`.
 */
describe('an account created before dateOfBirth', () => {
  let legacyUid = ''
  let legacyToken = ''
  const legacyEmail = address()

  test('its stored age never reaches the client, and the questionnaire is re-asked', async () => {
    legacyUid = await createPreDateOfBirthAccount(legacyEmail, password)
    createdUids.push(legacyUid)
    legacyToken = (
      await json<AuthResponse>(
        await api('/auth/signin', {
          method: 'POST',
          body: JSON.stringify({ email: legacyEmail, password }),
        }),
      )
    ).token
    // Signing in at all is half the assertion: a migration that locked her out would
    // fail here rather than below.
    expect(legacyToken.length).toBeGreaterThan(0)

    const res = await api('/me', { token: legacyToken })
    expect(res.status).toBe(200)
    const raw = await res.text()
    // Raw text, not a parse: the claim is that the string does not leave the API, and a
    // typed read of a field we just removed from the type would assert nothing.
    expect(raw).not.toContain('"age"')
    const { user } = JSON.parse(raw) as UserResponse
    expect(user.profile).toBe(null)
    expect(user.questionnaireCompleted).toBe(false)

    // And the document is untouched — this is a read-time answer, not a rewrite.
    const doc = await firestore.collection('users').doc(legacyUid).get()
    expect(doc.data()!.profile.age).toBe(28)
    expect(doc.data()!.questionnaireCompleted).toBe(true)
  })

  test('answering the questionnaire replaces the old map, age and all', async () => {
    // A pre-#86 account has no consent record, and answering the questionnaire is a
    // health write — grant it first, which is what the app's screen does for exactly
    // these accounts on their next launch.
    const granted = await api('/me/consent/collect', {
      method: 'PUT',
      token: legacyToken,
      body: JSON.stringify({ granted: true, version: '2026-08-30' }),
    })
    expect(granted.status).toBe(200)

    const res = await api('/me/questionnaire', {
      method: 'PUT',
      token: legacyToken,
      body: JSON.stringify(profileBornOn('1996-06-15')),
    })
    expect(res.status).toBe(200)
    expect((await json<UserResponse>(res)).user.questionnaireCompleted).toBe(true)

    const doc = await firestore.collection('users').doc(legacyUid).get()
    expect(doc.data()!.profile.dateOfBirth).toBe('1996-06-15')
    expect('age' in doc.data()!.profile).toBe(false)
  })

  /**
   * A document carrying **both** — a `dateOfBirth` and a stale `age` beside it.
   *
   * Nothing in `src/` writes that shape: `saveQuestionnaire` replaces the whole `profile`
   * map, so an answered questionnaire drops the legacy key outright. This is the floor
   * under a hand-edited or half-migrated document, held to the same standard as
   * `dayNumber`'s date round trip — the profile is valid under this schema and is served,
   * and the age still does not leave the API.
   *
   * It is here because the probe found it missing: removing the `delete` in `users.ts`
   * left the whole suite green, since a document with no `dateOfBirth` is answered `null`
   * before the drop can matter.
   */
  test('a half-migrated profile is served, and its stale age still is not', async () => {
    await firestore.collection('users').doc(legacyUid).update({ 'profile.age': 28 })

    const res = await api('/me', { token: legacyToken })
    const raw = await res.text()
    expect(raw).not.toContain('"age"')
    const { user } = JSON.parse(raw) as UserResponse
    expect(user.profile?.dateOfBirth).toBe('1996-06-15')
    expect(user.questionnaireCompleted).toBe(true)
    // …and it is still on the document, because this is a read and not a rewrite.
    expect((await firestore.collection('users').doc(legacyUid).get()).data()!.profile.age).toBe(28)
  })
})

/**
 * The canvas' password rule, enforced at creation only (issue #20).
 *
 * The last test is the load-bearing one: the rule applies to signup, never to signin,
 * because accounts created before it exist and must keep working.
 */
describe('activation password rule', () => {
  /**
   * The rule moved with the password (#120). Sign-up takes no password, so the screen
   * that enforces it client-side moved too — from the sign-up step to the activation
   * page — and this reads the helper text from wherever it now lives, because a server
   * rule quoting text the user never saw is the failure this pins.
   */
  const clientHelperText = async (): Promise<string> => {
    // Read from the **website's** activation page, because that is where the password
    // is chosen now (#120). The point of this assertion has not changed: the server's
    // WEAK_PASSWORD message must be the text the user was actually shown, or it quotes
    // a rule they never saw. It moved because the field moved.
    const page = await Bun.file(`${import.meta.dir}/../../website/src/pages/activate.astro`).text()
    const match = page.match(/passwordRule = '([^']+)'/)
    if (!match) throw new Error('passwordRule not found in activate.astro')
    return match[1]!
  }

  /** A whole sign-up, then the link spent with `password`. The rule is checked before the
   *  token is consumed, so a rejected attempt leaves the link usable — asserted below. */
  const activateWith = async (password: string): Promise<Response> => {
    const target = address()
    await api('/auth/signup', { method: 'POST', body: JSON.stringify({ email: target }) })
    const token = await issueToken(null, target, 'activation')
    return api('/auth/activate', {
      method: 'POST',
      body: JSON.stringify({ token, password }),
    })
  }

  test('8 characters without a digit is rejected', async () => {
    const res = await activateWith('password')
    expect(res.status).toBe(400)
    expect((await json<ErrorResponse>(res)).error.code).toBe('WEAK_PASSWORD')
  })

  test('7 characters with a digit is rejected', async () => {
    const res = await activateWith('passwo1')
    expect(res.status).toBe(400)
    expect((await json<ErrorResponse>(res)).error.code).toBe('WEAK_PASSWORD')
  })

  test('8 characters with a digit is accepted', async () => {
    const target = address()
    await api('/auth/signup', { method: 'POST', body: JSON.stringify({ email: target }) })
    const token = await issueToken(null, target, 'activation')
    const res = await api('/auth/activate', {
      method: 'POST',
      body: JSON.stringify({ token, password: 'passwor1' }),
    })
    expect(res.status).toBe(200)
    createdUids.push((await adminAuth.getUserByEmail(target)).uid)
  })

  test('a non-ASCII digit counts as a number, as it does on the client', async () => {
    // Swift's Character.isNumber is Unicode-wide, so the CTA enables for this
    // password. An ASCII-only server check would reject it while quoting the rule
    // the user had just satisfied.
    const target = address()
    await api('/auth/signup', { method: 'POST', body: JSON.stringify({ email: target }) })
    const token = await issueToken(null, target, 'activation')
    const res = await api('/auth/activate', {
      method: 'POST',
      body: JSON.stringify({ token, password: 'passwor\u0663' }),
    })
    expect(res.status).toBe(200)
    createdUids.push((await adminAuth.getUserByEmail(target)).uid)
  })

  test("the rejection message is the screen's helper text", async () => {
    const res = await activateWith('password')
    expect((await json<ErrorResponse>(res)).error.message).toBe(await clientHelperText())
  })

  test('a rejected password does not spend the link', async () => {
    // The reason the rule is checked before `consumeToken`: a weak password should cost
    // the caller a retry, not the only link they have. Without this the user is left
    // with a dead link and an account that does not exist.
    const target = address()
    await api('/auth/signup', { method: 'POST', body: JSON.stringify({ email: target }) })
    const token = await issueToken(null, target, 'activation')

    const weak = await api('/auth/activate', {
      method: 'POST',
      body: JSON.stringify({ token, password: 'short' }),
    })
    expect(weak.status).toBe(400)

    const good = await api('/auth/activate', {
      method: 'POST',
      body: JSON.stringify({ token, password: 'passwor1' }),
    })
    expect(good.status).toBe(200)
    createdUids.push((await adminAuth.getUserByEmail(target)).uid)
  })

  test('signin still accepts a pre-rule password with no digit', async () => {
    // Created through the Admin SDK deliberately: signup itself now refuses this
    // password, so this is the only way to stand up an account that predates the
    // rule. Sign-in must not start rejecting the users who already hold one — and
    // the document is written in the pre-#6 shape, with no `activatedAt`, which is
    // what "predates" means for the activation gate too.
    const legacyEmail = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`
    const legacyPassword = 'horsestaple'
    const legacyUid = await createLegacyAccount(legacyEmail, legacyPassword)
    createdUids.push(legacyUid)

    const res = await api('/auth/signin', {
      method: 'POST',
      body: JSON.stringify({ email: legacyEmail, password: legacyPassword }),
    })
    expect(res.status).toBe(200)
    const body = await json<AuthResponse>(res)
    expect(body.user.id).toBe(legacyUid)
    // And the activation gate lets it through, which is the other half of what
    // "predates" means: a document with no `activatedAt` is an activated account, and
    // reading that field as falsy would sign out everyone who signed up before #6.
    expect(body.user.activated).toBe(true)
  })
})
