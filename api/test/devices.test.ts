import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { adminAuth, firestore } from '../src/firebase'
import {
  cancelQueuedNotifications,
  dueNotifications,
  enqueueNotification,
} from '../src/notifications'
import { listDevices } from '../src/devices'
import { NO_SESSION } from '../src/users'
import { bootApi } from './support/boot-api'
import { signUpActivated } from './support/session'
import { testEmail } from './support/test-email'

/**
 * The device registry and notification queue (#79, A9): the two routes, the DELETE /me
 * sweep, and the pregnancy-loss stop against the job's queue. The APNs transport is
 * `apns.test.ts`; this file runs the Firestore half against the emulators and a booted API.
 */
setDefaultTimeout(20_000)

const PASSWORD = 'correct-horse-8'
const email = testEmail()

let token = ''
let uid = ''
let base = ''
let child: ReturnType<typeof Bun.spawn> | null = null

const api = (path: string, init?: RequestInit & { token?: string | null }) =>
  fetch(`${base}${path}`, {
    ...init,
    headers: {
      'content-type': 'application/json',
      ...(init?.token === null ? {} : { authorization: `Bearer ${init?.token ?? token}` }),
      ...(init?.headers ?? {}),
    },
  })

const device = () => ({
  token: `${'a'.repeat(64)}-${Math.floor(Math.random() * 1e9)}`,
  environment: 'production' as const,
  timeZone: 'Europe/London',
})

const deviceDocs = () => firestore.collection('users').doc(uid).collection('devices')
const notificationDocs = () => firestore.collection('users').doc(uid).collection('notifications')

beforeAll(async () => {
  const spawned = await bootApi({ range: [4100, 4199], label: 'devices.test.ts' })
  base = spawned.base
  child = spawned.child
  const account = await signUpActivated(base, email, PASSWORD)
  token = account.token
  uid = account.uid
}, 60_000)

afterAll(async () => {
  for (const sub of ['devices', 'notifications']) {
    const snapshot = await firestore
      .collection('users')
      .doc(uid)
      .collection(sub)
      .get()
      .catch(() => null)
    for (const doc of snapshot?.docs ?? []) await doc.ref.delete().catch(() => {})
  }
  if (uid)
    await firestore
      .collection('users')
      .doc(uid)
      .delete()
      .catch(() => {})
  if (uid) await adminAuth.deleteUser(uid).catch(() => {})
  child?.kill()
})

describe('the device registry', () => {
  test('register stores the row and list reads it back', async () => {
    const registration = device()
    const res = await api('/me/devices/dev-1', {
      method: 'PUT',
      body: JSON.stringify(registration),
    })
    expect(res.status).toBe(200)

    const stored = (await deviceDocs().doc('dev-1').get()).data()!
    expect(stored.token).toBe(registration.token)
    expect(stored.environment).toBe('production')
    expect(stored.timeZone).toBe('Europe/London')

    const devices = await listDevices(uid)
    expect(devices.map((d) => d.id)).toEqual(['dev-1'])
  })

  test('a second register with the same id replaces the token, not a second row', async () => {
    const second = device()
    const res = await api('/me/devices/dev-1', {
      method: 'PUT',
      body: JSON.stringify(second),
    })
    expect(res.status).toBe(200)

    const devices = await listDevices(uid)
    expect(devices).toHaveLength(1)
    expect(devices[0]!.token).toBe(second.token)
  })

  test('a nonsense environment and time zone are refused at the edge', async () => {
    const badEnvironment = await api('/me/devices/dev-2', {
      method: 'PUT',
      body: JSON.stringify({ token: 'x'.repeat(64), environment: 'staging', timeZone: 'UTC' }),
    })
    expect(badEnvironment.status).toBe(400)

    const badZone = await api('/me/devices/dev-2', {
      method: 'PUT',
      body: JSON.stringify({ token: 'x'.repeat(64), environment: 'production', timeZone: 'Not/AZone' }),
    })
    expect(badZone.status).toBe(400)
  })

  test('remove deletes the row, and a retried remove is still 200', async () => {
    expect((await api('/me/devices/dev-1', { method: 'DELETE' })).status).toBe(200)
    expect(await listDevices(uid)).toHaveLength(0)
    expect((await api('/me/devices/dev-1', { method: 'DELETE' })).status).toBe(200)
  })
})

describe('the pregnancy-loss stop and the queue', () => {
  test('cancelling removes every queued send from the job\'s select', async () => {
    const future = new Date(Date.now() + 60_000)
    await enqueueNotification(uid, NO_SESSION, { kind: 'today-card', dueAt: future })
    await enqueueNotification(uid, NO_SESSION, { kind: 'well-being', dueAt: future })

    expect((await dueNotifications(uid, future)).length).toBe(2)

    const cancelled = await cancelQueuedNotifications(uid, NO_SESSION)
    expect(cancelled).toBe(2)
    expect(await dueNotifications(uid, future)).toHaveLength(0)
  })
})

describe('account deletion sweeps both', () => {
  test('DELETE /me removes the device and notification subcollections', async () => {
    await api('/me/devices/dev-swept', {
      method: 'PUT',
      body: JSON.stringify(device()),
    })
    await enqueueNotification(uid, NO_SESSION, {
      kind: 'today-card',
      dueAt: new Date(Date.now() + 60_000),
    })

    const res = await api('/me', { method: 'DELETE' })
    expect(res.status).toBe(200)

    expect((await deviceDocs().get()).size).toBe(0)
    expect((await notificationDocs().get()).size).toBe(0)
  })
})
