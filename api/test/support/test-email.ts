import { appendFileSync } from 'node:fs'

/**
 * A fresh throwaway address, `e2e+<uuid>@e2e.evaapp.dev` (or `e2e+<tag>-<uuid>@…`), written
 * down for the run's cleanup sweep (#341).
 *
 * `scripts/e2e.sh` runs this suite against the real project and then sweeps with
 * `scripts/e2e-cleanup.ts --only <ledger>`. An unscoped sweep deleted every e2e account in the
 * project — including the one a concurrent `scripts/verify-mobile.sh` was signed in to, whose
 * next request answered 401 and ended its session (#322). So the sweep may only touch the
 * addresses this run made, and this is where the API suite's are recorded: `EVA_E2E_LEDGER`
 * names the file, one address per line, the same shape the UI-test mailbox writes to
 * `EVA_MAILBOX_LEDGER`. Unset — `ci-api.sh`, `bun run verify`, a plain `bun test` — nothing is
 * written.
 *
 * Recorded **before** the address is returned, so before any account can exist: a test that
 * creates the account and then dies must still leave the address where the sweep will find
 * it. One `appendFileSync` per address, never a batch at exit, for the same reason.
 *
 * Every generated address in `api/test` comes from here; `test-email.test.ts` fails on an
 * inline one. Fixed literals (`e2e+registered-account@…`) are left out on purpose: they are
 * the same address in every run, so recording one would let this run's sweep delete another
 * run's account of that name. Their files delete them in `afterAll` and before reuse.
 */
export const testEmail = (tag?: string): string => {
  const email = `e2e+${tag ? `${tag}-` : ''}${crypto.randomUUID()}@e2e.evaapp.dev`
  const ledger = process.env.EVA_E2E_LEDGER
  if (ledger) appendFileSync(ledger, `${email}\n`)
  return email
}
