/**
 * Sweeps e2e test accounts (e2e+*@e2e.evaapp.dev) from the real Firebase
 * project: deletes both the Auth user and the users/{uid} Firestore doc.
 * Run from api/ so .env is loaded:  cd api && bun run ../scripts/e2e-cleanup.ts
 */
import { adminAuth, firestore } from '../api/src/firebase'

const isTestEmail = (email?: string) =>
  !!email && /^e2e\+.*@e2e\.evaapp\.dev$/.test(email)

let removed = 0
let pageToken: string | undefined
do {
  const page = await adminAuth.listUsers(1000, pageToken)
  for (const user of page.users) {
    if (isTestEmail(user.email)) {
      await adminAuth.deleteUser(user.uid)
      await firestore.collection('users').doc(user.uid).delete()
      removed += 1
      console.log(`removed ${user.email} (${user.uid})`)
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
    await doc.ref.delete()
    removed += 1
    console.log(`removed orphan doc ${doc.data().email}`)
  }
}

console.log(`cleanup done, ${removed} account(s) removed`)
