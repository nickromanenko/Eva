import { createMiddleware } from 'hono/factory'
import { sign, verify } from 'hono/jwt'
import { config } from './config'

export interface TokenClaims {
  sub: string
  email: string
  iat: number
  exp: number
  [key: string]: unknown
}

export const mintToken = (uid: string, email: string): Promise<string> => {
  const now = Math.floor(Date.now() / 1000)
  return sign(
    { sub: uid, email, iat: now, exp: now + config.jwtTtlSeconds } satisfies TokenClaims,
    config.jwtSecret,
  )
}

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
