import { FieldValue } from 'firebase-admin/firestore'
import { firestore } from './firebase'

export interface Profile {
  age: number
  weightKg: number
  heightCm: number
  goals: string[]
  conditions: string[]
  medications: string
  lifestyle: string
  sports: string[]
}

export interface User {
  id: string
  email: string
  questionnaireCompleted: boolean
  profile: Profile | null
}

const users = () => firestore.collection('users')

const toUser = (id: string, data: FirebaseFirestore.DocumentData): User => ({
  id,
  email: data.email,
  questionnaireCompleted: data.questionnaireCompleted ?? false,
  profile: data.profile ?? null,
})

/** Creates the user doc if missing; returns the (existing or new) user.
 *  Doc ID = Firebase Auth uid, so future providers matched to the same
 *  Auth account (by email) always land on the same document. */
export const ensureUser = async (uid: string, email: string, provider: string): Promise<User> => {
  const ref = users().doc(uid)
  const snapshot = await ref.get()
  if (snapshot.exists) {
    await ref.update({
      authProviders: FieldValue.arrayUnion(provider),
      updatedAt: FieldValue.serverTimestamp(),
    })
    return toUser(uid, snapshot.data()!)
  }
  await ref.set({
    email,
    authProviders: [provider],
    questionnaireCompleted: false,
    profile: null,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  })
  return { id: uid, email, questionnaireCompleted: false, profile: null }
}

export const getUser = async (uid: string): Promise<User | null> => {
  const snapshot = await users().doc(uid).get()
  return snapshot.exists ? toUser(uid, snapshot.data()!) : null
}

export const saveQuestionnaire = async (uid: string, profile: Profile): Promise<User | null> => {
  const ref = users().doc(uid)
  const snapshot = await ref.get()
  if (!snapshot.exists) return null
  await ref.update({
    profile,
    questionnaireCompleted: true,
    updatedAt: FieldValue.serverTimestamp(),
  })
  return toUser(uid, { ...snapshot.data()!, profile, questionnaireCompleted: true })
}
