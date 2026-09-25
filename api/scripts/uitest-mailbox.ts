/**
 * The UI tests' stand-in for an inbox (#6).
 *
 * Sign-up no longer signs anyone in: the account waits behind an activation link that
 * arrives by email, and a simulator has no mailbox. This is the seam. It runs beside the
 * API that `scripts/verify-mobile.sh` starts, and answers one question — "activate the
 * account at this address" — by issuing an activation token against the same Firestore
 * and then spending it through the **live** `POST /auth/activate`. The route under test is
 * the real one; only the delivery is short-circuited, which is the one part of the flow a
 * simulator genuinely cannot do.
 *
 * It answers a second question the same way since #59 — "reset the password at this
 * address" — through the live `POST /auth/password/reset`; see `reset` below.
 *
 * And a third since #118 — "attach an Apple identity to this address" — which is not a
 * delivery short-circuit but the same kind of seam: Apple's sheet cannot run in a simulator
 * (`docs/PROVIDER-SIGNIN.md`), so this links a placeholder `apple.com` identity through the
 * Admin SDK instead; see `linkApple` below.
 *
 * It is not part of the API and never ships: nothing in `src/` imports it, it is started
 * by one verify script, and it binds to loopback only. Two more guards, because a service
 * that activates accounts is exactly the kind of thing that must not wander:
 *
 *   - it refuses to start under `NODE_ENV=production`;
 *   - it refuses any address outside the `e2e+…@e2e.evaapp.dev` sweep pattern
 *     (GUARDRAILS 16), so it cannot be pointed at a real account even by accident.
 *
 * Usage: `EVA_API_URL=http://localhost:3003 PORT=3103 bun run scripts/uitest-mailbox.ts`
 */

import { issueToken } from '../src/email-tokens'
import { adminAuth } from '../src/firebase'

/** What the UI suites sign in with afterwards. Kept in step with
 *  `EvaUITestCase.password`; a mismatch would pass activation and fail every sign-in. */
const DEFAULT_PASSWORD = 'uitest-pass-1'

if (process.env.NODE_ENV === 'production') {
  throw new Error('uitest-mailbox activates accounts; it must never run in production')
}

const apiUrl = (process.env.EVA_API_URL ?? 'http://localhost:3003').replace(/\/+$/, '')
const port = Number(process.env.PORT ?? 3103)

/** The pattern `scripts/e2e-cleanup.ts` sweeps. Anything else is somebody's real account. */
const E2E_ADDRESS = /^e2e\+[^@]+@e2e\.evaapp\.dev$/

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })

/**
 * Opens a password-reset link for `email` and spends it on the live
 * `POST /auth/password/reset`, setting the password it already has (#59).
 *
 * What the UI tests want from it is the side effect: a reset **ends every other session**
 * (#76), so the token the app is holding goes dead on the server while the app still
 * believes it — the one way a simulator can reach a real 401 on a route mid-session. The
 * account and its password are otherwise untouched, so the test can log straight back in.
 * Same delivery short-circuit, same address guard, as `/activate`.
 */
const reset = async (request: Request): Promise<Response> => {
  const body = (await request.json().catch(() => ({}))) as { email?: unknown }
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : ''
  if (!E2E_ADDRESS.test(email)) {
    return json({ error: 'only e2e+*@e2e.evaapp.dev addresses may be reset' }, 400)
  }
  // A reset token names the account, unlike an activation token — the forgot route looks
  // the uid up before issuing one, and so does this.
  const uid = await adminAuth
    .getUserByEmail(email)
    .then((user) => user.uid)
    .catch(() => null)
  if (!uid) return json({ error: 'no account holds that address' }, 404)

  const token = await issueToken(uid, email, 'reset')
  const answered = await fetch(`${apiUrl}/auth/password/reset`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token, password: DEFAULT_PASSWORD }),
  })
  if (!answered.ok) {
    const detail = await answered.text().catch(() => '')
    console.error(`[uitest-mailbox] reset ${answered.status} for ${email}: ${detail}`)
    return json({ error: `reset answered ${answered.status}` }, 502)
  }
  // The response carries a session token; it is not read, returned or logged.
  console.log(`[uitest-mailbox] reset ${email}`)
  return json({ reset: true })
}

/**
 * Links a placeholder `apple.com` identity to the account at `email` (#118), so the UI tests
 * can look at what an Apple-connected account is shown — Profile's connected row and the
 * delete modal's revocation note — without Apple's sheet, which a simulator cannot run.
 *
 * Linked on the Auth user, not written to `users/{uid}`, because Auth is where the API reads
 * federated providers from (`federatedProvidersOf`, #117): the next `GET /me` serves
 * `apple.com` in `authProviders` exactly as it would for a real link. What is *not* real is
 * the identity itself — its `sub` is a random `e2e-uitest-…` value no Apple token will ever
 * carry — so nothing can sign in with it, and the test must not tap anything that would ask
 * Apple for one. The account is swept by `scripts/e2e-cleanup.ts` like every other.
 */
const linkApple = async (request: Request): Promise<Response> => {
  const body = (await request.json().catch(() => ({}))) as { email?: unknown }
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : ''
  if (!E2E_ADDRESS.test(email)) {
    return json({ error: 'only e2e+*@e2e.evaapp.dev addresses may be linked' }, 400)
  }
  const uid = await adminAuth
    .getUserByEmail(email)
    .then((user) => user.uid)
    .catch(() => null)
  if (!uid) return json({ error: 'no account holds that address' }, 404)

  try {
    await adminAuth.updateUser(uid, {
      providerToLink: { providerId: 'apple.com', uid: `e2e-uitest-${crypto.randomUUID()}` },
    })
  } catch (err) {
    console.error(`[uitest-mailbox] link-apple failed for ${email}: ${(err as Error).message}`)
    return json({ error: 'link-apple failed' }, 502)
  }
  console.log(`[uitest-mailbox] linked a placeholder Apple identity to ${email}`)
  return json({ linked: true })
}

const server = Bun.serve({
  hostname: '127.0.0.1',
  port,
  async fetch(request) {
    const url = new URL(request.url)
    if (url.pathname === '/health') return new Response('Eva UI-test mailbox')
    if (url.pathname === '/reset' && request.method === 'POST') return reset(request)
    if (url.pathname === '/link-apple' && request.method === 'POST') return linkApple(request)
    if (url.pathname !== '/activate' || request.method !== 'POST') {
      return json({ error: 'not found' }, 404)
    }

    const body = (await request.json().catch(() => ({}))) as { email?: unknown; password?: unknown }
    const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : ''
    if (!E2E_ADDRESS.test(email)) {
      return json({ error: 'only e2e+*@e2e.evaapp.dev addresses may be activated' }, 400)
    }

    // **No account to look up** (#120). Sign-up creates none — it sends an address and a
    // link — so the token carries the address alone and the route creates the account when
    // it is spent. Asking Firebase for a uid here would 404 on every fresh sign-up.
    const password = typeof body.password === 'string' ? body.password : DEFAULT_PASSWORD
    const token = await issueToken(null, email, 'activation')
    const activated = await fetch(`${apiUrl}/auth/activate`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      // The password travels with the token: activation is where the credential is set,
      // and the simulator cannot reach the web form that would normally supply it.
      body: JSON.stringify({ token, password }),
    })
    if (!activated.ok) {
      const detail = await activated.text().catch(() => '')
      console.error(`[uitest-mailbox] activate ${activated.status} for ${email}: ${detail}`)
      return json({ error: `activate answered ${activated.status}` }, 502)
    }
    // The length, never the value. GUARDRAILS 12 says never log a password and grants
    // `api/scripts/` no exemption; that this one is a fixture and that this process refuses
    // `NODE_ENV=production` are reasons it is not a leak today, not reasons to write a line
    // that gets copied. The length is what the debugging case actually needed — it tells an
    // empty or truncated password from a wrong one.
    console.log(`[uitest-mailbox] activated ${email} (password length ${password.length})`)
    return json({ activated: true })
  },
})

console.log(`UI-test mailbox on http://127.0.0.1:${server.port} → API ${apiUrl}`)
