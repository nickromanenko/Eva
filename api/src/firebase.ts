import { initializeApp, getApps, applicationDefault } from 'firebase-admin/app'
import { initializeFirestore } from 'firebase-admin/firestore'
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

/**
 * **HTTP/1.1 REST, not gRPC, because gRPC does not survive on Bun** (#225).
 *
 * The Firestore client defaults to gRPC, and under Bun that channel dies: after a few
 * dozen round trips every subsequent Firestore call hangs and never returns. The process
 * stays up and keeps serving — `GET /` answered in 0.6ms while every Firestore-touching
 * route hung past 30s — so nothing sheds the instance and a liveness probe on `/` cannot
 * see it. Recovering means restarting the process.
 *
 * Isolated to the runtime rather than guessed at. Same machine, same credentials, same
 * network, a loop of Firestore writes and reads with no HTTP server in it at all:
 *
 *   | bun 1.3.10 | gRPC (default) | wedged at iteration 28 |
 *   | node 26.7  | gRPC (default) | 60 iterations, clean   |
 *   | bun 1.3.10 | REST           | 60 iterations, clean   |
 *
 * Through the API the same shape held, and deterministically: wedged at iteration 14 of a
 * write-plus-read loop, twice, in 54s — then 120 iterations clean on REST.
 *
 * This is a production setting and not a test-harness one. `api/Dockerfile` runs
 * `oven/bun:1.3-slim`, so Cloud Run runs the identical stack and would wedge the same way;
 * it surfaced here as UI-test flakiness only because that is what exercises the API
 * hardest. `preferRest` is safe to spend: it costs the real-time listeners and streaming
 * reads that this codebase does not use, and the SDK still falls back to gRPC for
 * operations that need it. Latency was indistinguishable in both arms above.
 *
 * Revisit when Bun's HTTP/2 client is fixed — this is a workaround for a runtime bug, not
 * a preference about transports.
 */
export const firestore = initializeFirestore(app, { preferRest: true })
export const adminAuth = getAuth(app)
