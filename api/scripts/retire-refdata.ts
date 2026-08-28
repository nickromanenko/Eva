/**
 * Retires codes in `refdata/` — the supported way to take an option out of the
 * pickers. Nothing is ever deleted (src/refdata.ts).
 *
 *   cd api && bun run retire:refdata
 *
 * A sibling of `seed:refdata` rather than a flag on it. Seeding is additive and safe
 * to re-run against any project by reflex; retirement is the one catalogue operation
 * that takes something away. Putting it behind the command everyone already runs
 * would make the destructive step the easiest thing in the file to trigger by
 * accident, and `applyCatalogue` refusing to drop codes is deliberately the reason
 * a re-seed can never do this on its own.
 *
 * The list below is a **record**, not a queue: every run re-applies all of it, and a
 * row that is already retired is a no-op. It stays here after it has run — it is where
 * a reader finds out *why* a code in seed-refdata.ts carries `status: 'retired'`, and
 * it is what api/test drives the retirement assertions off.
 *
 * This script is the migration, not the definition. A project seeded from the current
 * seed-refdata.ts is already in the retired state and this run reports "already
 * retired" for everything; what it exists for is a project seeded from an older
 * revision of that file, where the codes were written active and have to be moved.
 *
 * Only this process' cache is invalidated. Other instances pick the change up within
 * the 60s refdata TTL; nothing needs a deploy or a restart (PRD:483).
 */

import { readCatalogue, retireCode, type CatalogueId } from '../src/refdata'

interface Retirement {
  catalogue: CatalogueId
  code: string
  /** Why it went, in one line. */
  reason: string
}

const RETIREMENTS: Retirement[] = [
  {
    catalogue: 'symptoms',
    code: 'libido-changes',
    reason: '#24: superseded by `libido`, which carries the direction as values [low, high]',
  },
  {
    catalogue: 'symptoms',
    code: 'low-libido',
    reason: '#24: a direction of `libido-changes`, not a second concept; both fold into `libido`',
  },
]

/** `retireCode` answers `false` for both "already retired" and "never existed", and a
 *  report of what changed in a live catalogue has to tell those two apart. */
const apply = async ({ catalogue, code, reason }: Retirement): Promise<void> => {
  const before = (await readCatalogue(catalogue)).find((item) => item.code === code)
  if (!before) return console.log(`${catalogue}/${code}: absent — nothing to retire`)
  if (before.status === 'retired') return console.log(`${catalogue}/${code}: already retired`)

  await retireCode(catalogue, code)
  console.log(`${catalogue}/${code}: active → retired — ${reason}`)
}

const main = async () => {
  for (const retirement of RETIREMENTS) await apply(retirement)
}

// Importable for its list without retiring anything — api/test reads it.
if (import.meta.main) await main()

export { RETIREMENTS, type Retirement }
