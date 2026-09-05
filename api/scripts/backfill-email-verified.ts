/**
 * Sets Firebase's `emailVerified` on every account Eva already considers activated — a
 * one-off, run before Apple and Google sign-in are switched on (#7).
 *
 *   cd api && bun run backfill:email-verified --dry-run   # count, change nothing
 *   cd api && bun run backfill:email-verified             # do it
 *
 * **Why it has to happen before the providers are enabled.** Eva's `activatedAt` and
 * Firebase's `emailVerified` were never connected: activation is a Firestore field, and
 * nothing ever told Firebase. `proveAddress` closes that going forward, but only for
 * accounts that activate *after* it ships. Every account already activated stays
 * `emailVerified: false` for ever.
 *
 * That is not cosmetic. When Identity Toolkit merges a verified provider address onto an
 * account whose own address is unverified, it clears `passwordHash` and unlinks **every**
 * provider on it. So the first time an existing user taps the new "Sign in with Google"
 * button, their Eva password stops working — while `users/{uid}.authProviders` goes on
 * listing `password`, because `ensureUser` only ever adds to that array. Their next
 * password sign-in is a `401` with no explanation, and Profile still tells them they have
 * a password. Recoverable through forgot-password; unexplainable to the person it happens
 * to.
 *
 * **A script, not a route**, for the reasons `purge-events.ts` gives: the Admin SDK
 * bypasses `firestore.rules`, there is no admin role to authorize an HTTP caller with, and
 * authorization is IAM on the service account this runs as.
 *
 * Idempotent, and safe to re-run: an account already verified is left alone. It only ever
 * moves `emailVerified` from false to true, and only for accounts whose address Eva has
 * already seen proven — it never invents a claim Firebase did not already have grounds
 * for. Prints totals only: never a uid, never an address (GUARDRAILS 12).
 */

import { adminAuth } from '../src/firebase'
import { getUser, listAllUids } from '../src/users'

const USAGE = 'Usage: bun run backfill:email-verified [--dry-run]'

const parseArgs = (argv: string[]): { dryRun: boolean } => {
  let dryRun = false
  for (const arg of argv) {
    if (arg === '--dry-run') dryRun = true
    else {
      console.error(`Unrecognised argument: ${arg}\n${USAGE}`)
      process.exit(2)
    }
  }
  return { dryRun }
}

const main = async (): Promise<void> => {
  const { dryRun } = parseArgs(process.argv.slice(2))
  const uids = await listAllUids()

  let activated = 0
  let needed = 0
  let changed = 0
  let missing = 0

  for (const uid of uids) {
    // Eva's view first: a document that is not activated is not a claim we can make.
    const user = await getUser(uid)
    if (!user?.activated) continue
    activated += 1

    // Firebase's view second, because it is the thing being corrected. An Auth user that
    // is gone is a document awaiting its sweep, not an error.
    const account = await adminAuth.getUser(uid).catch(() => null)
    if (!account) {
      missing += 1
      continue
    }
    if (account.emailVerified) continue
    needed += 1
    if (dryRun) continue

    await adminAuth.updateUser(uid, { emailVerified: true })
    changed += 1
  }

  console.log(
    JSON.stringify({
      event: 'backfill_email_verified',
      dryRun,
      scanned: uids.length,
      activated,
      needed,
      changed,
      authUserMissing: missing,
    }),
  )
}

await main()
