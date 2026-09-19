import { createMiddleware } from 'hono/factory'
import { sign, verify } from 'hono/jwt'
import { config } from './config'

export interface TokenClaims {
  sub: string
  email: string
  /**
   * The account's token version when this session was minted (#76) — the whole of what
   * makes a password reset end every other session.
   *
   * **Optional, and that is the migration.** Every token minted before #76 carries no
   * `tv` at all, and every `users/{uid}` written before it carries no `tokenVersion`
   * field; `tokenVersionOf` and `users.ts` both read the absence as `0`, so those two
   * absences compare equal and nobody is signed out by the deploy itself. Declared
   * optional rather than defaulted so that stays a stated fact instead of an accident.
   */
  tv?: number
  iat: number
  exp: number
  [key: string]: unknown
}

/**
 * `tokenVersion` is a required argument rather than something this module looks up,
 * because `auth.ts` must not reach Firestore (GUARDRAILS 10, and the module map in
 * `api/CLAUDE.md`). Every caller already holds the value: a sign-in and a provider
 * sign-in get it back from `ensureUser`, and `/auth/password/reset` gets it back from the
 * bump it just performed. There is no call site that has to read anything to supply it.
 */
export const mintToken = (uid: string, email: string, tokenVersion: number): Promise<string> => {
  const now = Math.floor(Date.now() / 1000)
  return sign(
    {
      sub: uid,
      email,
      tv: tokenVersion,
      iat: now,
      exp: now + config.jwtTtlSeconds,
    } satisfies TokenClaims,
    config.jwtSecret,
  )
}

/**
 * The version a token was minted at, as a number (#76).
 *
 * Absent is `0`, matching what `users.ts` reads a document with no `tokenVersion` field
 * as — see `TokenClaims.tv`. The runtime type check is not redundant even though the
 * claim is typed: claims come off the wire through `verify` and a cast, so `tv` is
 * whatever the token actually carries. Anything that is not a number is a token this
 * code did not mint in a shape it recognises, and `0` is the safe reading — it matches
 * only an account that has never bumped, and any bump strands it.
 */
export const tokenVersionOf = (claims: TokenClaims): number =>
  typeof claims.tv === 'number' ? claims.tv : 0

/** Requires a valid `Authorization: Bearer <jwt>`; puts claims on the context. */
export const requireAuth = createMiddleware<{ Variables: { claims: TokenClaims } }>(
  async (c, next) => {
    const header = c.req.header('authorization') ?? ''
    const token = header.startsWith('Bearer ') ? header.slice(7) : null
    if (!token) {
      return c.json({ error: { code: 'UNAUTHORIZED', message: 'Missing bearer token' } }, 401)
    }
    try {
      const claims = (await verify(token, config.jwtSecret, 'HS256')) as TokenClaims
      c.set('claims', claims)
    } catch {
      return c.json({ error: { code: 'UNAUTHORIZED', message: 'Invalid or expired token' } }, 401)
    }
    await next()
  },
)
