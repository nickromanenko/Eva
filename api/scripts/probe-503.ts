/** Does repeatedly guessing a password tell a registered address from an unknown one by
 *  *status* rather than by timing? (#34) */
import { adminAuth, firestore } from '../src/firebase'
import { config } from '../src/config'

const BASE = process.env.EVA_API_URL!
const N = Number(process.env.N ?? 40)
const WRONG = 'definitely-wrong-9'

const email = `e2e+oracle-${crypto.randomUUID()}@e2e.evaapp.dev`
const unknown = `e2e+oracle-${crypto.randomUUID()}@e2e.evaapp.dev`
const { uid } = await adminAuth.createUser({ email, password: 'correct-horse-8', emailVerified: true })
await firestore.collection('users').doc(uid).set({
  email, authProviders: ['password'], questionnaireCompleted: false, profile: null,
  activatedAt: new Date(), createdAt: new Date(), updatedAt: new Date(),
})

const hit = async (addr: string) => {
  const r = await fetch(`${BASE}/auth/signin`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email: addr, password: WRONG }),
  })
  return r.status
}
const tally = (xs: number[]) => {
  const m = new Map<number, number>()
  for (const x of xs) m.set(x, (m.get(x) ?? 0) + 1)
  return [...m].map(([k, v]) => `${k}×${v}`).join(' ')
}

try {
  const reg: number[] = [], unk: number[] = []
  let firstNon401Registered = -1, firstNon401Unknown = -1
  for (let i = 0; i < N; i += 1) {
    const a = await hit(email);   reg.push(a); if (a !== 401 && firstNon401Registered < 0) firstNon401Registered = i + 1
    const b = await hit(unknown); unk.push(b); if (b !== 401 && firstNon401Unknown < 0) firstNon401Unknown = i + 1
  }
  console.log(`registered address : ${tally(reg)}   first non-401 at attempt ${firstNon401Registered}`)
  console.log(`unknown address    : ${tally(unk)}   first non-401 at attempt ${firstNon401Unknown}`)

  // What Identity Toolkit itself says at that point, unmapped.
  const raw = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${config.firebaseWebApiKey}`,
    { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email, password: WRONG, returnSecureToken: true }) })
  console.log('raw upstream for the registered address:', raw.status, await raw.text())
} finally {
  await adminAuth.deleteUser(uid).catch(() => {})
  await firestore.collection('users').doc(uid).delete().catch(() => {})
}
