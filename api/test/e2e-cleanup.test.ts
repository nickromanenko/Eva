import { afterAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { adminAuth, firestore } from '../src/firebase'

// Each case spawns `bun run scripts/e2e-cleanup.ts` against a cold emulator — 0.2 s usually,
// 3.4 s seen — so Bun's 5 s default flaked (#322 review). api/CLAUDE.md's #31 rule.
setDefaultTimeout(20_000)

/**
 * `scripts/verify-mobile.sh` sweeps only the accounts **its own** run created (#322).
 *
 * The sweep used to delete every `e2e+…@e2e.evaapp.dev` account in the project. Two UI runs
 * on two simulators is a supported setup (#162), and the first to finish deleted the account
 * the other was still signed in to: its next request answered `401 UNAUTHORIZED`, the app
 * ended the session, and `DeleteAccountUITests` failed at "Export data instead" on the
 * welcome screen. So the mailbox — the only way a UI test gets an account — writes down each
 * address it activates, and the sweep is handed that list.
 *
 * Emulators only. What this proves is that an account the list does not name survives, and
 * the way it fails is by deleting it — against the real project, that is somebody else's
 * run's account, which is the bug.
 */
const onEmulators = Boolean(
  process.env.FIREBASE_AUTH_EMULATOR_HOST && process.env.FIRESTORE_EMULATOR_HOST,
)

const apiDir = resolve(import.meta.dir, '..')
const scratch = mkdtempSync(join(tmpdir(), 'eva-e2e-cleanup-test-'))
const created: string[] = []

const freshEmail = () => `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`

/** An account the way the API leaves one: an Auth user and its `users/{uid}` document. */
const account = async (email: string): Promise<string> => {
  const { uid } = await adminAuth.createUser({ email, password: 'cleanup-test-1' })
  created.push(uid)
  await firestore.collection('users').doc(uid).set({ email })
  return uid
}

const exists = async (uid: string) => {
  const auth = await adminAuth
    .getUser(uid)
    .then(() => true)
    .catch(() => false)
  const doc = (await firestore.collection('users').doc(uid).get()).exists
  return { auth, doc }
}

afterAll(async () => {
  for (const uid of created) {
    await adminAuth.deleteUser(uid).catch(() => {})
    await firestore.recursiveDelete(firestore.collection('users').doc(uid)).catch(() => {})
  }
  rmSync(scratch, { recursive: true, force: true })
})

describe.skipIf(!onEmulators)('the sweep a UI run ends with (#322)', () => {
  test('removes the accounts on its list and leaves another run’s alone', async () => {
    const mine = freshEmail()
    const theirs = freshEmail()
    const mineUid = await account(mine)
    const theirsUid = await account(theirs)

    const ledger = join(scratch, 'ledger')
    writeFileSync(ledger, `${mine}\n`)
    const sweep = Bun.spawnSync(['bun', 'run', '../scripts/e2e-cleanup.ts', '--only', ledger], {
      cwd: apiDir,
      env: process.env,
    })
    expect(sweep.exitCode, sweep.stderr.toString()).toBe(0)

    expect(await exists(mineUid)).toEqual({ auth: false, doc: false })
    expect(await exists(theirsUid)).toEqual({ auth: true, doc: true })
  })

  test('refuses a list it cannot read rather than sweeping everything', async () => {
    const bystander = await account(freshEmail())

    const sweep = Bun.spawnSync(
      ['bun', 'run', '../scripts/e2e-cleanup.ts', '--only', join(scratch, 'never-written')],
      { cwd: apiDir, env: process.env },
    )
    expect(sweep.exitCode).not.toBe(0)
    expect(await exists(bystander)).toEqual({ auth: true, doc: true })
  })

  test('the mailbox writes an address down before it activates it', async () => {
    const ledger = join(scratch, 'mailbox-ledger')
    writeFileSync(ledger, '')
    const email = freshEmail()

    // Nothing listens on port 1, so activation itself fails — which is the point: the
    // address must be on the list even when the request that creates the account does not
    // come back, or a run that dies there leaves an account no sweep will name.
    const mailbox = Bun.spawn(['bun', 'run', 'scripts/uitest-mailbox.ts'], {
      cwd: apiDir,
      env: {
        ...process.env,
        PORT: '0',
        EVA_API_URL: 'http://127.0.0.1:1',
        EVA_MAILBOX_LEDGER: ledger,
      },
      stdout: 'pipe',
      stderr: 'pipe',
    })
    try {
      const reader = mailbox.stdout.getReader()
      let out = ''
      let port: string | undefined
      while (!port) {
        const { value, done } = await reader.read()
        if (done) throw new Error(`mailbox exited before listening: ${out}`)
        out += new TextDecoder().decode(value)
        port = out.match(/on http:\/\/127\.0\.0\.1:(\d+)/)?.[1]
      }
      await fetch(`http://127.0.0.1:${port}/activate`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ email }),
      })
      expect(readFileSync(ledger, 'utf8').split('\n')).toContain(email)
    } finally {
      mailbox.kill()
    }
  })
})
