import { afterEach, describe, expect, test } from 'bun:test'
import { buildPushPayload, createAPNS } from '../src/apns'
import { config } from '../src/config'

/**
 * The APNs transport (#79): the fixed payload and the send outcomes. The payload is pure;
 * the send path is driven against a stubbed `fetch`, with the key provisioned the way the
 * Apple client-secret test provisions its own — a real P-256 pair generated for the run,
 * nothing leaving the process.
 */

const pem = (der: ArrayBuffer): string => {
  const body = Buffer.from(der).toString('base64').replace(/(.{64})/g, '$1\n')
  return `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`
}

const original = { ...config.apns }

afterEach(() => {
  Object.assign(config.apns, original)
})

const provision = async (): Promise<void> => {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, [
    'sign',
  ])
  const der = await crypto.subtle.exportKey('pkcs8', pair.privateKey)
  Object.assign(config.apns, {
    key: pem(der),
    keyId: 'KEY123',
    teamId: 'TEAM123',
    topic: 'com.evaapp.ios',
  })
}

describe('buildPushPayload', () => {
  test('is the fixed preview and nothing else (ARCHITECTURE §9.3)', () => {
    const payload = JSON.parse(buildPushPayload('n1', 'today-card'))
    expect(payload).toEqual({
      aps: { alert: { title: 'Eva', body: 'Eva has an update' } },
      kind: 'today-card',
      notificationId: 'n1',
    })
  })

  test('never carries a symptom, a flow level, a date or a name', () => {
    // The payload is built from a kind and an id, so a health value can only appear if a
    // caller passed one as the kind — and the fixed preview means it still shows on the lock
    // screen as "Eva has an update". Assert the exact bytes, not the intent.
    const payload = buildPushPayload('n1', 'today-card')
    expect(payload).not.toContain('cramp')
    expect(payload).not.toContain('heavy')
    expect(payload).not.toContain('intercourse')
    expect(payload).not.toContain('2026-09')
  })
})

describe('createAPNS.send', () => {
  const responding = (status: number, body = '') => async () =>
    new Response(body, { status, headers: { 'content-type': 'application/json' } })

  test('unprovisioned is retryable, never a throw', async () => {
    Object.assign(config.apns, { key: null, keyId: null, teamId: null, topic: null })
    const outcome = await createAPNS(responding(200)).send(
      { token: 'tok', environment: 'production' },
      'n1',
      'today-card',
    )
    expect(outcome).toBe('retryable')
  })

  test('a 200 is sent', async () => {
    await provision()
    const outcome = await createAPNS(responding(200)).send(
      { token: 'tok', environment: 'production' },
      'n1',
      'today-card',
    )
    expect(outcome).toBe('sent')
  })

  test('a 410 is a dead token', async () => {
    await provision()
    const outcome = await createAPNS(responding(410)).send(
      { token: 'tok', environment: 'production' },
      'n1',
      'today-card',
    )
    expect(outcome).toBe('bad-token')
  })

  test('a BadDeviceToken reason is a dead token', async () => {
    await provision()
    const outcome = await createAPNS(responding(400, JSON.stringify({ reason: 'BadDeviceToken' }))).send(
      { token: 'tok', environment: 'production' },
      'n1',
      'today-card',
    )
    expect(outcome).toBe('bad-token')
  })

  test('a 5xx is retryable, leaving the row for the next tick', async () => {
    await provision()
    const outcome = await createAPNS(responding(500)).send(
      { token: 'tok', environment: 'production' },
      'n1',
      'today-card',
    )
    expect(outcome).toBe('retryable')
  })

  test('a network failure is retryable', async () => {
    await provision()
    const failing = async () => {
      throw new Error('connection refused')
    }
    const outcome = await createAPNS(failing).send(
      { token: 'tok', environment: 'production' },
      'n1',
      'today-card',
    )
    expect(outcome).toBe('retryable')
  })

  test('the request carries the fixed payload and the token-based auth', async () => {
    await provision()
    let captured: { url: string; authorization: string; body: string } | null = null
    const fetchImpl = async (url: string, init?: RequestInit) => {
      captured = {
        url,
        authorization: (init?.headers as Record<string, string>).authorization ?? '',
        body: (init?.body as string) ?? '',
      }
      return new Response('', { status: 200 })
    }
    await createAPNS(fetchImpl).send(
      { token: 'tok', environment: 'sandbox' },
      'n1',
      'today-card',
    )
    expect(captured!.url).toBe('https://api.sandbox.push.apple.com/3/device/tok')
    expect(captured!.authorization).toMatch(/^bearer eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/)
    expect(JSON.parse(captured!.body)).toEqual({
      aps: { alert: { title: 'Eva', body: 'Eva has an update' } },
      kind: 'today-card',
      notificationId: 'n1',
    })
  })
})
