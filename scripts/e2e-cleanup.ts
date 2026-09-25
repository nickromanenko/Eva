/**
 * Sweeps e2e test accounts (e2e+*@e2e.evaapp.dev) from the real Firebase project: the Auth
 * user, the `users/{uid}` document, **and everything beneath it**.
 *
 *   cd api && bun run ../scripts/e2e-cleanup.ts            # sweep
 *   cd api && bun run ../scripts/e2e-cleanup.ts --dry-run  # count, delete nothing
 *   cd api && bun run ../scripts/e2e-cleanup.ts --only <file>  # just the addresses listed
 *
 * ## `--only`, and why a UI run must not sweep everything (#322)
 *
 * Unscoped, this deletes every e2e account in the project — including the ones another run is
 * signed in to right now. Two `scripts/verify-mobile.sh` runs on two simulators is supported
 * (#162), and the first to finish used to take the other's accounts with it: the survivor's
 * next request answered `401 UNAUTHORIZED`, its app ended the session, and a test failed on
 * the welcome screen for no reason in its own code. So verify-mobile passes `--only` with
 * the list its mailbox wrote (one address per line), and only those accounts are swept. The
 * ghost pass below is skipped in that mode: a ghost has no address, so it cannot be shown to
 * belong to this run. An unreadable list fails the sweep rather than widening it.
 *
 * ## Why `recursiveDelete` and not `.delete()` (#62)
 *
 * Deleting a Firestore document does **not** delete its subcollections. The old sweep
 * removed `users/{uid}` and left `users/{uid}/events/` behind, and because the parent
 * document was gone the orphans matched no query the sweep ran — so nothing would ever
 * find them again.
 *
 * That was harmless while nothing wrote events: `scripts/e2e.sh` posts none. #159 made it
 * live — `CalendarUITests` is the first thing in the repo to `POST /me/events` against the
 * real project — and by the time it was noticed there were 42 orphaned event documents
 * across 17 users. Those are cycle entries and body signals: the most sensitive data Eva
 * holds, stranded where no code path could reach them.
 *
 * ## The ghost sweep, and why it is safe
 *
 * `listDocuments()` returns references for *missing* parents too — a path that holds a
 * subcollection but no document of its own. That is the only way to find the existing
 * orphans, since their `users/{uid}` document is already gone.
 *
 * A ghost under `users/` can only have been made by this script's old behaviour: the API
 * never leaves one. `DELETE /me` removes the whole `events` subcollection before the
 * document (ARCHITECTURE §7), and a live account always has its document. So a ghost is by
 * construction an artefact of the bug, not a real user — which is what makes deleting it
 * without being able to read an email defensible. Nothing here reads an event's contents;
 * the script counts documents and deletes paths (GUARDRAILS 12).
 *
 * ## Counts, never addresses or uids (#334)
 *
 * It used to print `removed <address> (<uid>)` for each account. The repo is public, so its
 * Actions step logs are too (#309), and verify-mobile.sh runs this sweep inside CI. #263 set
 * the rule that a raw address never leaves the runner; this was the last exception. So it
 * prints counts only — the same totals it always printed — and nothing that names an account
 * or a path under `users/`. A local operator who needs the names has the Auth console.
 */
import { readFileSync } from 'node:fs'
import { adminAuth, firestore } from '../api/src/firebase'

/** The addresses `--only` names, or `null` for the whole-project sweep. Read before anything
 *  is deleted, so a missing or unreadable list throws here and sweeps nothing. */
const onlyAt = process.argv.indexOf('--only')
const only: Set<string> | null =
  onlyAt === -1
    ? null
    : new Set(
        readFileSync(process.argv[onlyAt + 1] ?? '', 'utf8')
          .split('\n')
          .map((line) => line.trim().toLowerCase())
          .filter(Boolean),
      )

const isTestEmail = (email?: string) =>
  !!email && /^e2e\+.*@e2e\.evaapp\.dev$/.test(email) && (only === null || only.has(email))

const dryRun = process.argv.includes('--dry-run')
if (dryRun) console.log('DRY RUN — counting only, nothing is deleted\n')
if (only) console.log(`scoped to ${only.size} address(es) from ${process.argv[onlyAt + 1]}`)

/** Deletes a `users/{uid}` path and everything under it. `recursiveDelete` handles the
 *  subcollections `.delete()` silently leaves behind, which is the whole of #62. */
const sweepUserPath = async (uid: string): Promise<void> => {
  if (dryRun) return
  await firestore.recursiveDelete(firestore.collection('users').doc(uid))
}

let removed = 0
let orphanDocs = 0
let pageToken: string | undefined
do {
  const page = await adminAuth.listUsers(1000, pageToken)
  for (const user of page.users) {
    if (isTestEmail(user.email)) {
      if (!dryRun) await adminAuth.deleteUser(user.uid)
      await sweepUserPath(user.uid)
      removed += 1
    }
  }
  pageToken = page.pageToken
} while (pageToken)

// Orphaned Firestore docs (auth user already gone)
const orphans = await firestore
  .collection('users')
  .where('email', '>=', 'e2e+')
  .where('email', '<', 'e2e-')
  .get()
for (const doc of orphans.docs) {
  if (isTestEmail(doc.data().email)) {
    await sweepUserPath(doc.id)
    orphanDocs += 1
  }
}

// Ghost parents: a path under `users/` holding a subcollection but no document. The header
// explains why these can only be this script's own leavings. Counted separately from
// accounts, because they are not accounts — nobody can sign in to one.
let ghosts = 0
let ghostDocs = 0
for (const ref of only ? [] : await firestore.collection('users').listDocuments()) {
  if ((await ref.get()).exists) continue
  const subs = await ref.listCollections()
  if (subs.length === 0) continue

  let count = 0
  for (const sub of subs) count += (await sub.count().get()).data().count
  ghosts += 1
  ghostDocs += count
  await sweepUserPath(ref.id)
}

console.log(
  `cleanup ${dryRun ? 'dry run' : 'done'}, ${removed} account(s), ` +
    `${orphanDocs} orphaned user doc(s), ` +
    `${ghosts} ghost path(s) holding ${ghostDocs} document(s)`,
)
