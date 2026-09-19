import { config } from './config'

/**
 * The two places Eva talks to a provider *directly*, rather than through Firebase (#7).
 *
 * Sibling to `identity-toolkit.ts` rather than part of it, for the reason that file gives
 * for owning the Auth account alone: it is the only user of the Firebase **web API key**
 * (GUARDRAILS 4), and neither endpoint below uses it. What they use is a public OAuth
 * client id and Apple's signing key, which are a different credential with a different
 * blast radius, so they get a different owner.
 *
 * Only two things are here, and both are things Firebase cannot do for us:
 *
 * - **Google's PKCE code exchange.** The app is a *public* OAuth client with no secret, so
 *   it returns an authorization code and this exchanges it, with the code verifier, for an
 *   `id_token` we can spend at `signInWithIdp`. Doing it here rather than in the app keeps
 *   the GoogleSignIn SDK and its transitive packages out of the project (GUARDRAILS 25).
 * - **Apple's token revocation.** Apple requires that an app offering Sign in with Apple
 *   *and* in-app account deletion revoke the Apple token when the account goes, and App
 *   Review rejects on it. Firebase has no equivalent, so `DELETE /me` comes here.
 *
 * ## Nothing here is required to be configured
 *
 * Every credential is optional (`config.providers`). Unconfigured is answered as that one
 * capability being unavailable — never as a boot failure, and for revocation never as a
 * failed delete. See `RevocationOutcome`.
 *
 * ## Logs nothing
 *
 * An authorization code, a code verifier, an `id_token` and a client secret are all
 * credentials (GUARDRAILS 12), and the provider's own error strings are untrusted text of
 * the kind #32 kept out of `identity-toolkit.ts`. This file writes no line; it returns a
 * status and lets `index.ts` write the one line an operator gets.
 */

/**
 * Why a provider call failed, in our vocabulary — deliberately the same three words
 * `IdentityToolkitFailure` uses, so `index.ts` maps both boundaries with one rule
 * (ARCHITECTURE §3).
 *
 * - `unconfigured` — this provider's credentials are not set. Retrying cannot fix it and
 *   an operator has to; the caller is told only that it is temporarily unavailable.
 * - `rejected` — the provider refused the credential itself: an expired code, a mismatched
 *   verifier, a code minted for another client.
 * - `unavailable` — the provider could not answer: 5xx, a throttle, a network failure, a
 *   body that is not JSON.
 */
export type ProviderFailure = 'unconfigured' | 'rejected' | 'unavailable'

export class ProviderError extends Error {
  /**
   * `upstreamStatus` is the provider's HTTP status, `null` when nothing came back. It names
   * nobody and is the operator's signal. There is deliberately no field for the provider's
   * reason string: it does not reach a body, a header, or a log line.
   */
  constructor(
    readonly kind: ProviderFailure,
    readonly upstreamStatus: number | null = null,
  ) {
    super(`Provider: ${kind}`)
  }
}

/** The status decides before anything else, exactly as in `identity-toolkit.ts`: a 5xx or a
 *  429 is an outage whatever the body claims. */
const classify = (status: number): ProviderFailure =>
  status >= 500 || status === 429 ? 'unavailable' : 'rejected'

/**
 * One form-encoded POST to a provider's token endpoint. Form-encoded rather than JSON
 * because that is what OAuth 2.0 specifies and what both providers accept.
 *
 * The failing `fetch`'s own error is dropped rather than attached, for the reason
 * `identity-toolkit.ts` gives: its message carries the request URL, and these request
 * *bodies* carry credentials that a logged `cause` chain has a way of finding.
 */
const form = async (url: string, fields: Record<string, string>): Promise<unknown> => {
  let response: Response
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams(fields).toString(),
    })
  } catch {
    throw new ProviderError('unavailable')
  }

  let raw: string
  try {
    raw = await response.text()
  } catch {
    throw new ProviderError('unavailable', response.status)
  }

  // An empty body is success and carries nothing: that is exactly what Apple's revocation
  // endpoint answers with, so parsing unconditionally would read a completed revocation as
  // an outage. Anything non-empty that is not JSON is a proxy or an error page in front of
  // the provider, and is a verdict about nothing.
  let json: unknown = null
  if (raw !== '') {
    try {
      json = JSON.parse(raw)
    } catch {
      throw new ProviderError('unavailable', response.status)
    }
  }
  if (!response.ok) throw new ProviderError(classify(response.status), response.status)
  return json
}

// ── Google: the PKCE authorization-code exchange ───────────────────────────────

const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token'

export interface GoogleAuthCode {
  code: string
  codeVerifier: string
  /** The app's own redirect URI (the reversed client id scheme). Google checks it against
   *  the one the code was issued for, so it is echoed rather than trusted. */
  redirectUri: string
}

/**
 * Trades the app's authorization code for the `id_token` inside it. No client secret is
 * sent, because an iOS OAuth client has none — the `code_verifier` is what proves the
 * exchange is being made by whoever started the flow.
 *
 * Only the `id_token` is kept. The access and refresh tokens in the same response are
 * credentials for Google APIs Eva does not call, and the surest way not to leak one is not
 * to hold it.
 */
export const exchangeGoogleAuthCode = async ({
  code,
  codeVerifier,
  redirectUri,
}: GoogleAuthCode): Promise<string> => {
  const clientId = config.providers.googleIosClientId
  if (!clientId) throw new ProviderError('unconfigured')

  const json = (await form(GOOGLE_TOKEN_URL, {
    grant_type: 'authorization_code',
    code,
    code_verifier: codeVerifier,
    redirect_uri: redirectUri,
    client_id: clientId,
  })) as { id_token?: string } | null

  // A token response with no `id_token` means the client was not asked for `openid`, which
  // is a fault in the app's request rather than an outage: there is nothing to retry.
  if (!json?.id_token) throw new ProviderError('rejected')
  return json.id_token
}

// ── Apple: the client secret, and revocation ───────────────────────────────────

const APPLE_TOKEN_URL = 'https://appleid.apple.com/auth/token'
const APPLE_REVOKE_URL = 'https://appleid.apple.com/auth/revoke'
const APPLE_AUDIENCE = 'https://appleid.apple.com'

/** Apple's cap is six months; five minutes is all a single revocation needs, and a short
 *  life means a leaked secret is a leaked secret for five minutes. */
const APPLE_SECRET_TTL_SECONDS = 300

const base64url = (bytes: ArrayBuffer | Uint8Array): string =>
  Buffer.from(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes))
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '')

const utf8Base64url = (value: string): string => base64url(new TextEncoder().encode(value))

/** The DER bytes inside a PEM block, copied into an `ArrayBuffer` of their own — Node's
 *  `Buffer` is a view into a shared pool, which `importKey` will not take. */
const pemToDer = (pem: string): ArrayBuffer => {
  const pooled = Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''), 'base64')
  const der = new Uint8Array(pooled.length)
  der.set(pooled)
  return der.buffer
}

interface AppleCredentials {
  clientId: string
  teamId: string
  keyId: string
  signingKey: string
}

/** All four or none: a client secret signed with three of them is a secret Apple rejects,
 *  which would look like an outage instead of like the missing configuration it is. */
const appleCredentials = (): AppleCredentials | null => {
  const { clientId, teamId, keyId, signingKey } = config.providers.apple
  if (!clientId || !teamId || !keyId || !signingKey) return null
  return { clientId, teamId, keyId, signingKey }
}

/**
 * Apple's client secret: an ES256 JWT signed with the `.p8` key, `kid` in the header and
 * the client id as `sub` (`docs/PROVIDER-SIGNIN.md` §2–§3).
 *
 * That client id is the **App ID** — the bundle identifier — not the Services ID. Apple
 * issues an authorization code to whichever client asked for it, and a native
 * `ASAuthorization` request asks as the App ID; the Services ID identifies the *web* flow,
 * which Eva does not use. Exchanging a native code under the Services ID is refused, and
 * because revocation is deliberately non-fatal it would be refused **silently** — leaving
 * the App Review requirement this whole path exists to satisfy quietly unmet.
 *
 * Signed with WebCrypto rather than a JWT library — `hono/jwt` can sign ES256 but gives no
 * way to put `kid` in the header, which Apple requires, and a library for one 20-line
 * signature is a dependency for nothing (GUARDRAILS 25). ECDSA over P-256 with SHA-256
 * produces the raw `r‖s` pair that JWS defines as the ES256 signature, so there is no
 * encoding step to get wrong.
 *
 * `JWT_SECRET` is not involved and must never be: this signs for Apple, `auth.ts` signs for
 * us (GUARDRAILS 4).
 */
const appleClientSecret = async (credentials: AppleCredentials): Promise<string> => {
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToDer(credentials.signingKey),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  )
  const now = Math.floor(Date.now() / 1000)
  const header = utf8Base64url(JSON.stringify({ alg: 'ES256', kid: credentials.keyId, typ: 'JWT' }))
  const payload = utf8Base64url(
    JSON.stringify({
      iss: credentials.teamId,
      iat: now,
      exp: now + APPLE_SECRET_TTL_SECONDS,
      aud: APPLE_AUDIENCE,
      sub: credentials.clientId,
    }),
  )
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    new TextEncoder().encode(`${header}.${payload}`),
  )
  return `${header}.${payload}.${base64url(signature)}`
}

/**
 * What `DELETE /me` learns about a revocation attempt. Never an exception, because a
 * deletion that failed on this step would be a deletion that did not happen — and the
 * user's data still going is more important than Apple's token going (#7).
 *
 * `stage` says how far it got, with no credential and nothing about the user in it:
 * `unconfigured` (Apple's keys are not provisioned), `client-secret` (the `.p8` we hold
 * would not sign — a configuration fault of ours, and the one stage no retry and no client
 * change can fix), `token` (the code would not exchange — usually one already spent, or
 * older than its five minutes), `revoke` (Apple refused the revocation itself).
 */
export interface RevocationOutcome {
  ok: boolean
  stage: 'revoked' | 'unconfigured' | 'client-secret' | 'token' | 'revoke'
  upstreamStatus: number | null
}

/**
 * Revokes the user's Apple tokens, given a **fresh** authorization code the app obtained by
 * re-prompting for authorization at delete time.
 *
 * *Why a code and not a stored refresh token*, stated because it is the decision here: Apple
 * hands out a refresh token that would have to be kept for as long as the account lives.
 * That is a long-lived third-party credential sitting in a health app's user document, and
 * a field on `users/{uid}` that this issue is otherwise careful not to add. A code the
 * client fetches at the moment of deletion is worth about five minutes and is gone by the
 * time the response is written.
 *
 * The cost, stated: an account deleted without one is deleted without revocation. Nothing
 * remains that could revoke it later, and the entitlement is satisfied only when the client
 * sends the code.
 */
export const revokeAppleToken = async (authorizationCode: string): Promise<RevocationOutcome> => {
  const credentials = appleCredentials()
  if (!credentials) return { ok: false, stage: 'unconfigured', upstreamStatus: null }

  // Outside the `try` below, deliberately. Building the client secret is our own work, not
  // an exchange with Apple: it fails when the `.p8` in Secret Manager is malformed — PKCS#1
  // where PKCS#8 was expected, or a newline that did not survive the env var. Inside, that
  // would be reported as `token`, which reads as "the code was already spent" and points
  // the operator at the client instead of at the configuration.
  let clientSecret: string
  try {
    clientSecret = await appleClientSecret(credentials)
  } catch {
    // The `DOMException` is dropped rather than attached: WebCrypto puts nothing useful in
    // it, and the key material is what it was handed (GUARDRAILS 1).
    return { ok: false, stage: 'client-secret', upstreamStatus: null }
  }

  let refreshToken: string
  let tokenTypeHint: 'refresh_token' | 'access_token'
  try {
    const json = (await form(APPLE_TOKEN_URL, {
      grant_type: 'authorization_code',
      code: authorizationCode,
      client_id: credentials.clientId,
      client_secret: clientSecret,
    })) as { refresh_token?: string; access_token?: string } | null
    // Revoking the refresh token revokes everything derived from it. The access token is
    // the fallback for a response that carries no refresh token at all — and the hint has
    // to travel with it: Apple takes `token_type_hint` at its word, so calling an access
    // token a refresh token gets the revocation refused. Silently, because revocation is
    // deliberately non-fatal, which is the whole failure mode this path is careful about.
    const token = json?.refresh_token ?? json?.access_token
    if (!token) return { ok: false, stage: 'token', upstreamStatus: null }
    refreshToken = token
    tokenTypeHint = json?.refresh_token ? 'refresh_token' : 'access_token'
  } catch (err) {
    const status = err instanceof ProviderError ? err.upstreamStatus : null
    return { ok: false, stage: 'token', upstreamStatus: status }
  }

  try {
    await form(APPLE_REVOKE_URL, {
      token: refreshToken,
      token_type_hint: tokenTypeHint,
      client_id: credentials.clientId,
      client_secret: clientSecret,
    })
  } catch (err) {
    const status = err instanceof ProviderError ? err.upstreamStatus : null
    return { ok: false, stage: 'revoke', upstreamStatus: status }
  }
  return { ok: true, stage: 'revoked', upstreamStatus: null }
}
