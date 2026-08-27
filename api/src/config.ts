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

export const config = {
  firebaseProjectId: required('FIREBASE_PROJECT_ID'),
  firebaseWebApiKey: required('FIREBASE_WEB_API_KEY'),
  jwtSecret: required('JWT_SECRET'),
  /** JWT lifetime: 30 days (v1 has no refresh tokens). */
  jwtTtlSeconds: 30 * 24 * 60 * 60,
  /**
   * Throttling for `/auth/*` (issue #5). Any limit set to `0` disables that dimension.
   * Per-IP is the loose backstop (carrier NAT puts many users behind one address);
   * per-address is the sharp one. Counters are per instance — see `rate-limit.ts`.
   */
  rateLimit: {
    windowSeconds: optionalCount('RATE_LIMIT_WINDOW_SECONDS', 15 * 60),
    signinPerIp: optionalCount('RATE_LIMIT_SIGNIN_PER_IP', 60),
    signinPerEmail: optionalCount('RATE_LIMIT_SIGNIN_PER_EMAIL', 10),
    signupPerIp: optionalCount('RATE_LIMIT_SIGNUP_PER_IP', 30),
    signupPerEmail: optionalCount('RATE_LIMIT_SIGNUP_PER_EMAIL', 5),
  },
}
