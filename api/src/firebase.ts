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
const app =
  getApps()[0] ??
  initializeApp({
    ...(config.usingEmulators ? {} : { credential: applicationDefault() }),
    projectId: config.firebaseProjectId,
  })

export const firestore = getFirestore(app)
export const adminAuth = getAuth(app)
