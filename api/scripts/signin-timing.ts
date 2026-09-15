/**
 * #34 — is `/auth/signin`'s "wrong password" branch distinguishable from its "no such
 * address" branch by *timing*?
 *
 * #21 made the two byte-identical. Byte-identical is not time-identical: Identity Toolkit
 * may answer faster for an address it has no record of than for one where it has to verify
 * a password hash.
 *
 * ## Two things this design exists to avoid, both learned the hard way
 *
 * **Every address is used exactly once, on both sides.** A first attempt rotated across a
 * handful of registered accounts, against a fresh unknown address each time, produced a
 * clean-looking 25ms difference at z = 8.2 — and it was an artifact. Identity Toolkit
 * throttles *per identifier* after about six attempts (verified: a registered and an
 * unregistered address both start answering 503 at attempt 7), so reusing accounts on one
 * side measured throttled-versus-fresh, not registered-versus-unknown.
 *
 * **Samples are interleaved**, because network conditions drift over a minute and two
 * blocks measured back to back would attribute that drift to the branch.
 *
 * Run against a local API with the throttle disabled (`RATE_LIMIT_*=0`, the documented
 * escape hatch) — 60 sign-ins per 15 minutes is not a sample worth reading, and #5's own
 * cost is not what is being measured.
 */
import { adminAuth, firestore } from '../src/firebase'

const BASE = process.env.EVA_API_URL ?? 'http://localhost:3003'
const PASSWORD = 'correct-horse-8'
const WRONG = 'definitely-wrong-9'
const SAMPLES = Number(process.env.N_SAMPLES ?? 120)

const addr = () => `e2e+timing-${crypto.randomUUID()}@e2e.evaapp.dev`

const timed = async (email: string): Promise<[number, number]> => {
  const t0 = performance.now()
  const res = await fetch(`${BASE}/auth/signin`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email, password: WRONG }),
  })
  await res.text()
  return [performance.now() - t0, res.status]
}

const q = (xs: number[], p: number) => [...xs].sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor(p * xs.length))]!
const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length
const sd = (xs: number[]) => { const m = mean(xs); return Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / (xs.length - 1)) }

/** Mann–Whitney U, normal approximation with tie-corrected ranks. Distribution-free,
 *  because latency is right-skewed and a t-test on it overstates its own confidence. */
const mannWhitney = (a: number[], b: number[]) => {
  const all = [...a.map(v => [v, 0] as const), ...b.map(v => [v, 1] as const)].sort((x, y) => x[0] - y[0])
  const ranks = new Array<number>(all.length)
  let i = 0
  while (i < all.length) {
    let j = i
    while (j + 1 < all.length && all[j + 1]![0] === all[i]![0]) j += 1
    const r = (i + j + 2) / 2
    for (let k = i; k <= j; k += 1) ranks[k] = r
    i = j + 1
  }
  let rankSumA = 0
  all.forEach(([, g], idx) => { if (g === 0) rankSumA += ranks[idx]! })
  const na = a.length, nb = b.length
  const u = rankSumA - (na * (na + 1)) / 2
  return { z: (u - (na * nb) / 2) / Math.sqrt((na * nb * (na + nb + 1)) / 12), effect: (2 * u) / (na * nb) - 1 }
}

const uids: string[] = []
console.log(`creating ${SAMPLES} activated accounts, one per sample…`)
const registered: string[] = []
for (let i = 0; i < SAMPLES; i += 1) {
  const email = addr()
  const { uid } = await adminAuth.createUser({ email, password: PASSWORD, emailVerified: true })
  await firestore.collection('users').doc(uid).set({
    email, authProviders: ['password'], questionnaireCompleted: false, profile: null,
    activatedAt: new Date(), createdAt: new Date(), updatedAt: new Date(),
  })
  uids.push(uid); registered.push(email)
}

try {
  for (let i = 0; i < 5; i += 1) await timed(addr())   // warm the connection

  const wrongPassword: number[] = [], unknownAddress: number[] = []
  const statuses = new Set<number>()
  let dropped = 0
  for (let i = 0; i < SAMPLES; i += 1) {
    const order = i % 2 === 0 ? ['w', 'u'] : ['u', 'w']
    for (const which of order) {
      const [ms, st] = await timed(which === 'w' ? registered[i]! : addr())
      statuses.add(st)
      if (st !== 401) { dropped += 1; continue }
      ;(which === 'w' ? wrongPassword : unknownAddress).push(ms)
    }
  }

  const { z, effect } = mannWhitney(wrongPassword, unknownAddress)
  const row = (n: string, xs: number[]) =>
    `${n.padEnd(18)} n=${String(xs.length).padStart(3)}  mean=${mean(xs).toFixed(1)}ms  sd=${sd(xs).toFixed(1)}  p50=${q(xs, .5).toFixed(1)}  p90=${q(xs, .9).toFixed(1)}  min=${Math.min(...xs).toFixed(1)}`
  console.log('\n=== RESULT ===')
  console.log('statuses seen:', [...statuses].join(','), '· dropped (non-401):', dropped)
  console.log(row('wrong password', wrongPassword))
  console.log(row('unknown address', unknownAddress))
  console.log(`\nmedian difference: ${(q(wrongPassword, .5) - q(unknownAddress, .5)).toFixed(1)}ms`)
  console.log(`Mann-Whitney z = ${z.toFixed(2)}   (|z| > 1.96 is p < 0.05 two-sided)`)
  console.log(`rank-biserial  = ${effect.toFixed(3)}   (0 = indistinguishable, ±1 = fully separated)`)
} finally {
  console.log('\ncleaning up…')
  for (const uid of uids) {
    await adminAuth.deleteUser(uid).catch(() => {})
    await firestore.collection('users').doc(uid).delete().catch(() => {})
  }
  console.log('done')
}
