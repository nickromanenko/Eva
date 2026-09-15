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
  /** The one origin allowed to call the two routes the website's pages use (CORS). */
  publicWebOrigin: publicWebUrl.origin,
}
