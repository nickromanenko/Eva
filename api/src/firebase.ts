import { initializeApp, getApps, applicationDefault } from 'firebase-admin/app'
import { getFirestore } from 'firebase-admin/firestore'
import { getAuth } from 'firebase-admin/auth'
import { config } from './config'

// Uses Application Default Credentials: the Cloud Run runtime service account
// in production, `gcloud auth application-default login` locally.
//
// Against the emulators (#67) there is no credential to find, and `applicationDefault()`
// throws when it cannot find one — so CI could not even construct the app. The emulators
// authenticate nobody, so the credential is genuinely not needed rather than merely
// unavailable. `FIRESTORE_EMULATOR_HOST` is the Firebase-standard signal and is set by
// `firebase emulators:exec`, so nothing in this repo has to remember to set it.
//
// Having no credential still costs ~3s on the first Firestore call off Google Cloud (#333):
// google-gax builds its stub via `getUniverseDomain()` → `getClient()`, which finds no ADC,
// asks `gcp-metadata` whether it is on GCE, and waits for the metadata server's probe to
// time out (with a `MetadataLookupWarning`) before falling back to the default universe.
// `none` gives that same answer at once — `gcp-metadata` reads the variable on every
// probe, so setting it here is early enough. Emulators only, never in production: Cloud
// Run's credential *is* the metadata server, and this would switch it off. An explicit
// value from the environment is left alone.
if (config.usingEmulators) process.env.METADATA_SERVER_DETECTION ??= 'none'

const app =
  getApps()[0] ??
  initializeApp({
    ...(config.usingEmulators ? {} : { credential: applicationDefault() }),
    projectId: config.firebaseProjectId,
  })

export const firestore = getFirestore(app)
export const adminAuth = getAuth(app)
