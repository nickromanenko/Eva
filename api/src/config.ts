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
  /** The one origin allowed to call the two routes the website's pages use (CORS). */
  publicWebOrigin: publicWebUrl.origin,
}
