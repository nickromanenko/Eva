import { initializeApp, getApps, applicationDefault } from 'firebase-admin/app'
import { getFirestore } from 'firebase-admin/firestore'
import { getAuth } from 'firebase-admin/auth'
import { config } from './config'

// Uses Application Default Credentials: the Cloud Run runtime service account
// in production, `gcloud auth application-default login` locally.
const app =
  getApps()[0] ??
  initializeApp({
    credential: applicationDefault(),
    projectId: config.firebaseProjectId,
  })

export const firestore = getFirestore(app)
export const adminAuth = getAuth(app)
