import { describe, expect, test } from 'bun:test'

/**
 * The emulator switch (#67), and the one thing about it that is a security control rather
 * than a convenience.
 *
 * `FIREBASE_AUTH_EMULATOR_HOST` decides where every credential call goes, and those calls
 * carry every signup and signin password in their bodies. A deploy variable set by mistake —
 * or by anyone who can set one — would send them to a host of someone else's choosing,
 * and nothing about the running service would look wrong from the outside. `config.ts`
 * refuses to boot instead.
 *
 * Subprocesses, because `config.ts` reads the environment once at import and this process
 * has already imported it. The same reason, and the same shape, as the `EMAIL_TRANSPORT=log`
 * boot test in `email.test.ts`.
 */

/** Enough for `config.ts` to get past every other required variable. */
const BASE_ENV = {
  FIREBASE_PROJECT_ID: 'demo-eva-config-test',
  FIREBASE_WEB_API_KEY: 'not-a-real-key',
  JWT_SECRET: 'not-a-real-secret',
  EMAIL_TRANSPORT: 'log',
  POSTMARK_FROM: 'config-test@example.test',
  PUBLIC_WEB_URL: 'http://localhost:4321',
}

/**
 * `config.ts` has a second production refusal — `EMAIL_TRANSPORT=log` (#6) — and it is
 * checked earlier in the file. Left as `log`, every production case below would fail on
 * *that* guard and prove nothing about this one. Swapping the transport is what keeps
 * these tests about emulator hosts.
 */
const PROD_ENV = {
  NODE_ENV: 'production',
  EMAIL_TRANSPORT: 'postmark',
  POSTMARK_API_KEY: 'not-a-real-postmark-token',
}

const boot = async (env: Record<string, string>) => {
  const proc = Bun.spawn(['bun', 'run', 'src/config.ts'], {
    cwd: `${import.meta.dir}/..`,
    // A bare env, not `...process.env`: the developer running this may well have
    // NODE_ENV or an emulator host set, and inheriting either would decide the result.
    env: { PATH: process.env.PATH ?? '', ...BASE_ENV, ...env },
    stdout: 'pipe',
    stderr: 'pipe',
  })
  const [code, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()])
  return { code, stderr }
}

/** Both hosts, the pair CI actually runs with. */
const BOTH = {
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
  FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9099',
}

describe('the two hosts must be set together', () => {
  test('either one alone refuses the boot, in any environment', async () => {
    // The asymmetric case is the dangerous one and it is NOT about production:
    // with only the auth host set, `usingEmulators` stays false, so Firestore
    // keeps reading and writing the real project while every signup and signin
    // password goes over plain http to whatever host that variable names (the web API
    // key rides along in the query string, but it is public — GUARDRAILS 4a). `identity-toolkit.ts` drops
    // the failing fetch's error rather than logging its URL, so a redirect to
    // something that mimics Google's error shape produces no signal at all.
    for (const [name, value] of Object.entries(BOTH)) {
      const { code, stderr } = await boot({ NODE_ENV: 'test', [name]: value })
      expect(code).not.toBe(0)
      expect(stderr).toContain('must be set together')
    }
  }, 30_000)

  test('both together boot fine outside production, which is what CI depends on', async () => {
    const { code } = await boot({ NODE_ENV: 'test', ...BOTH })
    expect(code).toBe(0)
  }, 30_000)
})

describe('emulator hosts in production', () => {
  test('the pair is refused under NODE_ENV=production', async () => {
    // BOTH, not one: the symmetry check above runs first, so setting a single host
    // here would pass this test without ever reaching the guard it is named for.
    const { code, stderr } = await boot({ ...PROD_ENV, ...BOTH })
    expect(code).not.toBe(0)
    expect(stderr).toContain('refusing to run against emulators in production')
  }, 30_000)

  test('and under K_SERVICE, which Cloud Run sets and a deployer does not', async () => {
    // NODE_ENV arrives through `--set-env-vars` in deploy-api.yml — the same
    // channel someone would use to inject an emulator host. A guard resting on it
    // alone can be switched off by exactly whoever it is guarding against, so the
    // refusal also keys on a variable the platform owns.
    const { code, stderr } = await boot({
      NODE_ENV: 'development',
      K_SERVICE: 'eva-api',
      EMAIL_TRANSPORT: 'postmark',
      POSTMARK_API_KEY: 'not-a-real-postmark-token',
      ...BOTH,
    })
    expect(code).not.toBe(0)
    expect(stderr).toContain('refusing to run against emulators in production')
  }, 30_000)

  test('production with neither set boots, so the tests above are about the refusal', async () => {
    const { code } = await boot(PROD_ENV)
    expect(code).toBe(0)
  }, 30_000)
})

describe('where credential calls are sent', () => {
  test('the auth emulator host becomes the Identity Toolkit origin, and Google is the default', async () => {
    // Printed by a subprocess rather than imported, for the reason above. This is
    // the value `identity-toolkit.ts` builds every request URL from, so a typo
    // here is the difference between CI testing our code and CI testing nothing.
    const read = async (env: Record<string, string>) => {
      const proc = Bun.spawn(
        [
          'bun',
          '-e',
          "import('./src/config.ts').then(m => console.log(m.config.identityToolkitBaseUrl))",
        ],
        {
          cwd: `${import.meta.dir}/..`,
          env: { PATH: process.env.PATH ?? '', ...BASE_ENV, ...env },
          stdout: 'pipe',
          stderr: 'pipe',
        },
      )
      const [, stdout] = await Promise.all([proc.exited, new Response(proc.stdout).text()])
      return stdout.trim()
    }

    expect(await read({ NODE_ENV: 'test', ...BOTH })).toBe(
      'http://127.0.0.1:9099/identitytoolkit.googleapis.com',
    )
    expect(await read({})).toBe('https://identitytoolkit.googleapis.com')
  }, 30_000)
})
