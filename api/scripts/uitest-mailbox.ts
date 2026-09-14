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

const server = Bun.serve({
  hostname: '127.0.0.1',
  port,
  async fetch(request) {
    const url = new URL(request.url)
    if (url.pathname === '/health') return new Response('Eva UI-test mailbox')
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
