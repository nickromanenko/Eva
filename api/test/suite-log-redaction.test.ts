import { afterAll, describe, expect, test } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

/**
 * `redact_suite_log` (scripts/lib/api-server.sh, #263) — the scrub between the mobile
 * suite's API and mailbox logs and the CI artifact they are uploaded as.
 *
 * The artifact outlives the runner, and under `EMAIL_TRANSPORT=log` the API prints every
 * activation and reset link with the address it went to, so GUARDRAILS 12 is enforced by
 * this shell function and nothing else. Each input below is a line in the format the code
 * actually writes (`email.ts`'s log transport, `uitest-mailbox.ts`, the request-level JSON
 * lines), and each is asserted against its **exact** redacted output — so dropping any one
 * `sed` expression fails a case here, not merely weakens one.
 *
 * Runs the real script through `bash`; no Firestore, no network, no config.
 */

const SCRIPT = join(import.meta.dir, '..', '..', 'scripts', 'lib', 'api-server.sh')
const dir = mkdtempSync(join(tmpdir(), 'eva-redact-'))
afterAll(() => rmSync(dir, { recursive: true, force: true }))

/** 43 base64url chars — the shape `email-tokens.ts` hands out. */
const TOKEN = 'Jjqhq-zitjpUEQANCCd9hAwKEUDn8yUdSx1ApiDIFaM'
const HASH = '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'
const JWT = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1aWQtMSIsInYiOjB9.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
const EMULATOR_ID_TOKEN = 'eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJlbWFpbCI6ImUyZSJ9.'

let n = 0
const redact = (input: string): { out: string | null; code: number } => {
  n += 1
  const src = join(dir, `in-${n}.log`)
  const dest = join(dir, 'out', `out-${n}.log`)
  writeFileSync(src, input)
  const proc = Bun.spawnSync(['bash', '-c', `source "$0"; redact_suite_log "$1" "$2"`, SCRIPT, src, dest])
  return { out: existsSync(dest) ? readFileSync(dest, 'utf8') : null, code: proc.exitCode }
}

/** [input line, exact expected output line] */
const CASES: Array<[string, string, string]> = [
  [
    'activation link',
    `[email:log] activation to=e2e+ui-1727@e2e.evaapp.dev link=http://localhost:4321/activate#token=${TOKEN}`,
    '[email:log] activation to=[redacted-address] link=[redacted-link]',
  ],
  [
    'reset link',
    `[email:log] reset to=e2e+reset-9@e2e.evaapp.dev link=http://localhost:4321/reset#token=${TOKEN}`,
    '[email:log] reset to=[redacted-address] link=[redacted-link]',
  ],
  [
    'a fragment without link= in front of it',
    `opened http://localhost:4321/reset#token=${TOKEN}`,
    'opened http://localhost:4321/reset#[redacted-token]',
  ],
  [
    'mailbox activated',
    '[uitest-mailbox] activated e2e+ui-1727@e2e.evaapp.dev (password length 13)',
    '[uitest-mailbox] activated [redacted-address] (password length 13)',
  ],
  [
    'mailbox activate failure',
    '[uitest-mailbox] activate 400 for e2e+x@e2e.evaapp.dev: {"error":{"code":"INVALID_TOKEN","message":"bad"}}',
    '[uitest-mailbox] activate 400 for [redacted-address]: {"error":{"code":"INVALID_TOKEN","message":"bad"}}',
  ],
  [
    'a percent-encoded address',
    'GET http://127.0.0.1:9099/lookup?email=e2e%2Bui-3%40e2e.evaapp.dev failed',
    'GET http://127.0.0.1:9099/lookup?email=[redacted-address] failed',
  ],
  [
    'an upper-case address',
    'to=E2E+Upper@E2E.EvaApp.DEV',
    'to=[redacted-address]',
  ],
  ['a signed JWT', `Authorization: Bearer ${JWT}`, 'Authorization: Bearer [redacted-jwt]'],
  [
    "the Auth emulator's unsigned ID token",
    `idToken=${EMULATOR_ID_TOKEN} end`,
    'idToken=[redacted-jwt] end',
  ],
  [
    'an authTokens/ document path (sha256 hex)',
    `NOT_FOUND: authTokens/${HASH}`,
    'NOT_FOUND: authTokens/[redacted-token]',
  ],
  ['a bare raw token', `token ${TOKEN} spent`, 'token [redacted-token] spent'],
]

/** Lines that must pass through byte-identical: what the artifact is for. */
const KEPT = [
  '{"event":"request","method":"POST","route":"/auth/signup","status":202,"ms":143}',
  '{"event":"request","method":"PUT","route":"/me/body-signals/:date","status":401,"ms":0}',
  '{"event":"request","method":"GET","route":null,"status":404,"ms":1}',
  '{"event":"request_timeout","method":"POST","route":"/auth/signup"}',
  '{"event":"unhandled_error","ref":"a1b2c3d4","method":"GET","route":"/me/events/:id","errorName":"FirebaseAppError"}',
  'Started development server: http://localhost:3303',
  'UI-test mailbox on http://127.0.0.1:3320 → API http://localhost:3303',
  '    at /Users/runner/work/Eva/Eva/api/src/index.ts:123:45',
]

describe('redact_suite_log', () => {
  for (const [name, input, expected] of CASES) {
    test(`scrubs ${name}`, () => {
      const { out, code } = redact(`${input}\n`)
      expect(code).toBe(0)
      expect(out).toBe(`${expected}\n`)
    })
  }

  test('keeps the request-level and diagnostic lines byte-identical', () => {
    const input = `${KEPT.join('\n')}\n`
    expect(redact(input).out).toBe(input)
  })

  test('nothing forbidden survives a whole mixed log', () => {
    const input = [...CASES.map(([, line]) => line), ...KEPT].join('\n') + '\n'
    const { out } = redact(input)
    expect(out).not.toBeNull()
    expect(out).not.toContain('@')
    expect(out).not.toContain('%40')
    expect(out).not.toContain('#token=')
    expect(out).not.toMatch(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\./)
    expect(out).not.toMatch(/[A-Za-z0-9_-]{43,}/)
    for (const line of KEPT) expect(out).toContain(line)
  })

  test('a missing source writes nothing and does not fail', () => {
    const dest = join(dir, 'out', 'never.log')
    const proc = Bun.spawnSync([
      'bash', '-c', `source "$0"; redact_suite_log "$1" "$2"`, SCRIPT, join(dir, 'absent.log'), dest,
    ])
    expect(proc.exitCode).toBe(0)
    expect(existsSync(dest)).toBe(false)
  })

  test('an empty source path writes nothing and does not fail', () => {
    const dest = join(dir, 'out', 'never-empty.log')
    const proc = Bun.spawnSync(['bash', '-c', `source "$0"; redact_suite_log "" "$1"`, SCRIPT, dest])
    expect(proc.exitCode).toBe(0)
    expect(existsSync(dest)).toBe(false)
  })
})
