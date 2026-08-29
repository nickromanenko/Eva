/**
 * Hard-deletes events whose 30-day recovery window has passed — the job behind
 * "recoverable for 30 days" (PRD:472). Without it, soft-deleted health data is kept
 * forever, which is the opposite of what the promise implies.
 *
 *   cd api && bun run purge:events --dry-run       # count what would go, delete nothing
 *   cd api && bun run purge:events                 # delete it
 *   cd api && bun run purge:events --uid=<uid>     # one account only
 *
 * **A script, not a route**, for the same reasons as `seed-refdata.ts`: the Admin SDK
 * bypasses `firestore.rules`, so nothing needs loosening, and there is no admin role to
 * authorize a caller with — inventing one is a bigger decision than this. It also means
 * the most destructive operation in the API has no HTTP surface at all: there is no
 * endpoint a stolen or forged user bearer token could reach, and no shared secret to
 * leak, rotate or accidentally log. Authorization is IAM on the service account the job
 * runs as, which is Google's to check rather than ours.
 *
 * **In production** it runs as a Cloud Run *job* built from this same image, triggered
 * daily by Cloud Scheduler. Both must be created by a human (see
 * docs/ARCHITECTURE.md §4, "Retention"); nothing here creates or deploys anything, and
 * the deploy workflow does not either. Manually: `gcloud run jobs execute eva-purge-events`.
 *
 * Deleting on a timer is the thing to get right. The safety lives in
 * `purgeUserEvents` — bounded query, an in-code re-check of every document, and a
 * `lastUpdateTime` precondition on each delete — not here. This file only decides
 * *whose* events to sweep, and prints totals: never an ID, a date, or a payload
 * (GUARDRAILS 12).
 */

import { purgeUserEvents, retentionCutoff, RETENTION_DAYS } from '../src/events'
import { listAllUids } from '../src/users'

const USAGE = 'Usage: bun run purge:events [--dry-run] [--uid=<uid>]'

/** An unrecognised flag exits rather than being ignored: a typo'd `--dry-run` that
 *  silently deleted instead would be the worst possible failure of this script. */
const parseArgs = (argv: string[]) => {
  let dryRun = false
  let uid: string | null = null
  for (const arg of argv) {
    if (arg === '--dry-run') dryRun = true
    else if (arg.startsWith('--uid=')) uid = arg.slice('--uid='.length)
    else {
      console.error(`Unknown argument: ${arg}\n${USAGE}`)
      process.exit(2)
    }
  }
  return { dryRun, uid }
}

const main = async () => {
  const { dryRun, uid } = parseArgs(process.argv.slice(2))
  const cutoff = retentionCutoff()
  const uids = uid ? [uid] : await listAllUids()

  let purged = 0
  let skipped = 0
  for (const each of uids) {
    const result = await purgeUserEvents(each, { cutoff, dryRun })
    purged += result.purged
    skipped += result.skipped
  }

  const verb = dryRun ? 'would delete' : 'deleted'
  console.log(
    `${verb} ${purged} event(s) soft-deleted before ${cutoff.toDate().toISOString()} ` +
      `(${RETENTION_DAYS}-day window); skipped ${skipped}; ${uids.length} account(s) scanned`,
  )
}

if (import.meta.main) await main()
