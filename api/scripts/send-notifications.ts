/**
 * Sends every due notification to the devices it was queued for — the job behind §9's
 * "scheduled sends run as a server job". Built from the same image as the API, entrypoint
 * overridden (ARCHITECTURE §9.2, the same shape as the purge job §4).
 *
 *   cd api && bun run send-notifications --dry-run        # what would send, sends nothing
 *   cd api && bun run send-notifications                  # send due
 *   cd api && bun run send-notifications --uid=<uid>      # one account
 *
 * **A script, not a route**, for the same reasons as `purge-events.ts`: the Admin SDK
 * bypasses `firestore.rules`, and a send job has no caller to authorize. It runs as a Cloud
 * Run *job* on a Cloud Scheduler tick (a human creates both); nothing here deploys anything.
 *
 * At-most-once: `markSent` claims a row in a transaction, and a `410`/`BadDeviceToken`
 * removes the dead device so it is never fanned out to again. Prints totals only — never a
 * token, an id, or a payload (GUARDRAILS 12).
 */

import { apns } from '../src/apns'
import { listDevices, removeDevice } from '../src/devices'
import { dueNotifications, markSent } from '../src/notifications'
import { AccountGoneError, listAllUids, NO_SESSION } from '../src/users'

const USAGE = 'Usage: bun run send-notifications [--dry-run] [--uid=<uid>]'

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
  const uids = uid ? [uid] : await listAllUids()
  const now = new Date()

  let sent = 0
  let badTokens = 0
  let retryable = 0
  let skipped = 0

  for (const each of uids) {
    try {
      const due = await dueNotifications(each, now)
      if (due.length === 0) continue
      const devices = await listDevices(each)
      if (devices.length === 0) continue

      for (const notification of due) {
        for (const device of devices) {
          if (dryRun) {
            sent += 1
            continue
          }
          const outcome = await apns.send(device, notification.id, notification.kind)
          if (outcome === 'sent') {
            await markSent(each, notification.id)
            sent += 1
          } else if (outcome === 'bad-token') {
            await removeDevice(each, NO_SESSION, device.id)
            badTokens += 1
          } else {
            retryable += 1
          }
        }
      }
    } catch (err) {
      // A tombstoned account mid-delete is not a send job's concern; its devices are about
      // to go with it. Anything else in one account's processing must not stop the rest.
      if (err instanceof AccountGoneError) skipped += 1
      else throw err
    }
  }

  const verb = dryRun ? 'would send' : 'sent'
  console.log(
    `${verb} ${sent} notification(s); ${badTokens} dead device(s) removed; ` +
      `${retryable} left for the next tick; ${skipped} account(s) skipped`,
  )
}

if (import.meta.main) await main()
