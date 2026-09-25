import { describe, expect, test } from 'bun:test'

/**
 * `firebase.ts` turns off Google's metadata-server detection under the emulators (#333), and
 * only there.
 *
 * Against the emulators the Admin SDK holds no credential, so the first Firestore call asked
 * the GCE metadata server whether it could supply one and waited ~3s for that probe to time
 * out, with a `MetadataLookupWarning`, before carrying on without one. On Cloud Run the
 * metadata server *is* the credential, so the same setting in production would break every
 * Firestore and Auth call. Both halves are pinned here.
 *
 * Subprocesses, because `config.ts` reads the environment once at import (the reason
 * `config-emulators.test.ts` gives), and because the variable is process-wide. `--no-env-file`
 * because Bun would otherwise load `api/.env`, whose `GOOGLE_APPLICATION_CREDENTIALS` makes
 * google-auth-library read a key file and never probe, which is not what CI runs.
 */

/** Enough for `config.ts` to boot; the shape `config-emulators.test.ts` uses. */
const BASE_ENV = {
  FIREBASE_PROJECT_ID: 'demo-eva-metadata-test',
  FIREBASE_WEB_API_KEY: 'not-a-real-key',
  JWT_SECRET: 'not-a-real-secret',
  EMAIL_TRANSPORT: 'log',
  POSTMARK_FROM: 'metadata-test@example.test',
  PUBLIC_WEB_URL: 'http://localhost:4321',
}

const BOTH = {
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
  FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9099',
}

/** Imports `firebase.ts` in a bare environment and reports what it left the variable as. */
const detectionAfterImport = async (env: Record<string, string>) => {
  const proc = Bun.spawn(
    [
      'bun',
      '--no-env-file',
      '-e',
      "import('./src/firebase.ts').then(() => console.log(process.env.METADATA_SERVER_DETECTION ?? '<unset>'))",
    ],
    {
      cwd: `${import.meta.dir}/..`,
      env: { PATH: process.env.PATH ?? '', ...BASE_ENV, ...env },
      stdout: 'pipe',
      stderr: 'pipe',
    },
  )
  const [code, stdout, stderr] = await Promise.all([
    proc.exited,
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ])
  // A boot that failed would print nothing and read as "unset", passing the production
  // cases for the wrong reason.
  expect({ code, stderr: code === 0 ? '' : stderr }).toEqual({ code: 0, stderr: '' })
  return stdout.trim()
}

describe('metadata-server detection is off under the emulators, and only there', () => {
  test('emulator mode sets it to none', async () => {
    expect(await detectionAfterImport({ NODE_ENV: 'test', ...BOTH })).toBe('none')
  }, 30_000)

  test('the real-project mode leaves it unset', async () => {
    // The `bun run verify` configuration: no emulator hosts, real ADC.
    expect(await detectionAfterImport({ NODE_ENV: 'test' })).toBe('<unset>')
  }, 30_000)

  test('production leaves it unset, where the metadata server is the credential', async () => {
    // Cloud Run's shape: K_SERVICE from the platform, NODE_ENV from deploy-api.yml, and a
    // transport config.ts accepts in production.
    const prod = {
      NODE_ENV: 'production',
      K_SERVICE: 'eva-api',
      EMAIL_TRANSPORT: 'postmark',
      POSTMARK_API_KEY: 'not-a-real-postmark-token',
    }
    expect(await detectionAfterImport(prod)).toBe('<unset>')
  }, 30_000)

  test('an explicit value is kept, in emulator mode too', async () => {
    // So someone debugging the probe can turn it back on, and so the emulator case
    // below has a negative control.
    expect(
      await detectionAfterImport({
        NODE_ENV: 'test',
        ...BOTH,
        METADATA_SERVER_DETECTION: 'ping-only',
      }),
    ).toBe('ping-only')
  }, 30_000)
})

const onEmulators = Boolean(
  process.env.FIREBASE_AUTH_EMULATOR_HOST && process.env.FIRESTORE_EMULATOR_HOST,
)

/**
 * Runs one Firestore read through `firebase.ts` against the live emulator. It reports how
 * long the read took and whether a `MetadataLookupWarning` was emitted.
 *
 * `GCE_METADATA_HOST` points at an address in TEST-NET-1 (RFC 5737), which nothing answers,
 * so a probe that is made times out the way it does on a CI runner rather than being
 * refused quickly by whatever this machine happens to do with 169.254.169.254.
 * `GOOGLE_APPLICATION_CREDENTIALS` is dropped for the reason `--no-env-file` is passed.
 */
const firstRead = async (extra: Record<string, string> = {}) => {
  const env: Record<string, string> = {}
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined) env[k] = v
  delete env.GOOGLE_APPLICATION_CREDENTIALS
  delete env.METADATA_SERVER_DETECTION
  const script = `
    const warnings = []
    process.on('warning', (w) => warnings.push(w.name))
    const { firestore } = await import('./src/firebase.ts')
    const t = performance.now()
    await firestore.collection('metadata-probe-333').limit(1).get()
    console.log(JSON.stringify({ ms: Math.round(performance.now() - t), warnings }))
    process.exit(0)
  `
  const proc = Bun.spawn(['bun', '--no-env-file', '-e', script], {
    cwd: `${import.meta.dir}/..`,
    env: { ...env, GCE_METADATA_HOST: '192.0.2.1', ...extra },
    stdout: 'pipe',
    stderr: 'pipe',
  })
  const [code, stdout, stderr] = await Promise.all([
    proc.exited,
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ])
  expect({ code, stderr: code === 0 ? '' : stderr }).toEqual({ code: 0, stderr: '' })
  return JSON.parse(stdout.trim().split('\n').at(-1) ?? '{}') as { ms: number; warnings: string[] }
}

describe.skipIf(!onEmulators)('the first Firestore call under the emulators (#333)', () => {
  test('makes no metadata probe', async () => {
    const { ms, warnings } = await firstRead()
    expect(warnings).not.toContain('MetadataLookupWarning')
    // The probe's timeout is 3s; a cold emulator read is well under a second.
    expect(ms).toBeLessThan(2_000)
  }, 30_000)

  test('and the harness would have seen one: with detection forced back on, it waits', async () => {
    // Without this, the test above would also pass if the probe had moved somewhere
    // this read no longer reaches.
    const { ms, warnings } = await firstRead({ METADATA_SERVER_DETECTION: 'ping-only' })
    expect(warnings).toContain('MetadataLookupWarning')
    expect(ms).toBeGreaterThanOrEqual(2_500)
  }, 30_000)
})
