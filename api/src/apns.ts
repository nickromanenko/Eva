import { config } from './config'

/**
 * APNs, sent directly from the API (A9, #79). The transport only: token-based auth to
 * Apple, and the fixed payload. It owns no Firestore collection and reads no user data
 * beyond the token and environment it is handed — the one reader of `config.apns`
 * (GUARDRAILS 4), exactly as `providers.ts` is the one reader of the Apple signing key.
 *
 * **The payload is fixed** (ARCHITECTURE §9.3): title `Eva`, body `Eva has an update`, a
 * `kind`, and the notification id — never a symptom, a flow level, a date, an appointment
 * type, or a name (GUARDRAILS 12, extended to a push because it transits Apple and shows on
 * a lock screen). Nothing here logs the token, the payload or the id.
 */

/** APNs' two environments. The device row carries which one its token belongs to. */
export type APNSEnvironment = 'sandbox' | 'production'

const HOST: Record<APNSEnvironment, string> = {
  sandbox: 'https://api.sandbox.push.apple.com',
  production: 'https://api.push.apple.com',
}

/** Token-based auth: a short-lived ES256 JWT, `kid` in the header, `iss` = the team id.
 *  Apple caps the life; 55 minutes is inside it and long enough for a 5-minute job tick. */
const TOKEN_TTL_SECONDS = 55 * 60

/** What APNs answered, reduced to the three things the sender job acts on. */
export type PushOutcome = 'sent' | 'bad-token' | 'retryable'

/** A device as the transport needs it — the token and its environment, nothing else. */
export interface APNSDevice {
  token: string
  environment: APNSEnvironment
}

const base64url = (bytes: ArrayBuffer | Uint8Array): string =>
  Buffer.from(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes))
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '')

const utf8Base64url = (value: string): string => base64url(new TextEncoder().encode(value))

/** The DER bytes inside a PEM block, copied out of Node's shared pool (see providers.ts). */
const pemToDer = (pem: string): ArrayBuffer => {
  const pooled = Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''), 'base64')
  const der = new Uint8Array(pooled.length)
  der.set(pooled)
  return der.buffer
}

interface APNSCredentials {
  key: string
  keyId: string
  teamId: string
  topic: string | null
}

/** All three of key/keyId/teamId, or none: a token signed with two is one Apple rejects, and
 *  `topic` is genuinely optional (APNs derives it from the device token). */
const credentials = (): APNSCredentials | null => {
  const { key, keyId, teamId, topic } = config.apns
  if (!key || !keyId || !teamId) return null
  return { key, keyId, teamId, topic }
}

/** The provider-authentication token. Signed with WebCrypto, no JWT library (GUARDRAILS 25),
 *  the same way `providers.ts` signs Apple's client secret — `hono/jwt` cannot put `kid` in
 *  the header, which APNs requires. `JWT_SECRET` is not involved (GUARDRAILS 4). */
const providerToken = async (credentials: APNSCredentials): Promise<string> => {
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToDer(credentials.key),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  )
  const now = Math.floor(Date.now() / 1000)
  const header = utf8Base64url(JSON.stringify({ alg: 'ES256', kid: credentials.keyId }))
  const payload = utf8Base64url(JSON.stringify({ iss: credentials.teamId, iat: now }))
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    new TextEncoder().encode(`${header}.${payload}`),
  )
  return `${header}.${payload}.${base64url(signature)}`
}

/**
 * The fixed payload, as the string APNs receives. Exported pure so a test can pin the exact
 * bytes: the preview rule is a GUARDRAILS 12 property and it is checked on the payload, not
 * on intent.
 */
export const buildPushPayload = (notificationId: string, kind: string): string =>
  JSON.stringify({
    aps: { alert: { title: 'Eva', body: 'Eva has an update' } },
    kind,
    notificationId,
  })

type FetchLike = (input: string, init?: RequestInit) => Promise<Response>

export interface APNS {
  send(device: APNSDevice, notificationId: string, kind: string): Promise<PushOutcome>
}

export const createAPNS = (
  fetchImpl: FetchLike = (input, init) => fetch(input, init),
): APNS => {
  const creds = credentials()

  const send = async (device: APNSDevice, notificationId: string, kind: string): Promise<PushOutcome> => {
    if (creds === null) return 'retryable'
    let response: Response
    try {
      response = await fetchImpl(`${HOST[device.environment]}/3/device/${device.token}`, {
        method: 'POST',
        headers: {
          authorization: `bearer ${await providerToken(creds)}`,
          ...(creds.topic ? { 'apns-topic': creds.topic } : {}),
          'apns-push-type': 'alert',
          'content-type': 'application/json',
        },
        body: buildPushPayload(notificationId, kind),
      })
    } catch {
      return 'retryable'
    }
    if (response.status === 200) return 'sent'
    // A 410, or any body naming the token, means the token is gone — the device row is dead.
    if (response.status === 410) return 'bad-token'
    let reason: string | null = null
    try {
      reason = ((await response.json()) as { reason?: string }).reason ?? null
    } catch {
      reason = null
    }
    if (reason === 'BadDeviceToken' || reason === 'Unregistered' || reason === 'DeviceTokenNotForTopic') {
      return 'bad-token'
    }
    // 429 and 5xx, and anything else, leave the row for the next tick.
    return 'retryable'
  }

  return { send }
}

/** The live sender, built from `config`. */
export const apns = createAPNS()
