import { afterAll, afterEach, describe, expect, test } from 'bun:test'
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { testEmail } from './support/test-email'

/**
 * `testEmail()` is how `scripts/e2e.sh` scopes its cleanup sweep to its own accounts (#341):
 * each address lands in `EVA_E2E_LEDGER`, and the sweep deletes that list and nothing else.
 * Pure — no Firebase, no server — so it runs in every gate.
 */

const scratch = mkdtempSync(join(tmpdir(), 'eva-test-email-'))
const saved = process.env.EVA_E2E_LEDGER

afterEach(() => {
  if (saved === undefined) delete process.env.EVA_E2E_LEDGER
  else process.env.EVA_E2E_LEDGER = saved
})
afterAll(() => rmSync(scratch, { recursive: true, force: true }))

describe('testEmail', () => {
  test('is a fresh address in the pattern the sweep matches', () => {
    const [a, b] = [testEmail(), testEmail('moved')]
    expect(a).toMatch(/^e2e\+[0-9a-f-]{36}@e2e\.evaapp\.dev$/)
    expect(b).toMatch(/^e2e\+moved-[0-9a-f-]{36}@e2e\.evaapp\.dev$/)
    expect(testEmail()).not.toBe(a)
  })

  // Written as the address is handed out — before the caller can create an account with it.
  test('with EVA_E2E_LEDGER set, every address is on the ledger by the time it is returned', () => {
    const ledger = join(scratch, 'ledger')
    process.env.EVA_E2E_LEDGER = ledger
    const first = testEmail()
    expect(readFileSync(ledger, 'utf8')).toBe(`${first}\n`)
    const second = testEmail('tagged')
    expect(readFileSync(ledger, 'utf8')).toBe(`${first}\n${second}\n`)
  })

  test('with EVA_E2E_LEDGER unset, nothing is written', () => {
    delete process.env.EVA_E2E_LEDGER
    const before = readdirSync(scratch).length
    testEmail()
    expect(readdirSync(scratch).length).toBe(before)
    expect(existsSync(join(scratch, 'undefined'))).toBe(false)
  })

  // The ledger only covers addresses that came from here. A test that builds its own
  // e2e+<uuid> address in a template literal creates an account the scoped sweep cannot see —
  // harmless per run, but it silently undoes #341 one file at a time.
  test('no test file generates an e2e address inline', () => {
    const inline = /e2e\+[a-z0-9-]*\$\{crypto\.randomUUID\(\)\}/
    const offenders = readdirSync(import.meta.dir)
      .filter((name) => name.endsWith('.test.ts'))
      .filter((name) => inline.test(readFileSync(join(import.meta.dir, name), 'utf8')))
    expect(offenders).toEqual([])
  })
})
