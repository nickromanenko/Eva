const required = (name: string): string => {
  const value = process.env[name]
  if (!value) throw new Error(`Missing required env var: ${name}`)
  return value
}

export const config = {
  firebaseProjectId: required('FIREBASE_PROJECT_ID'),
  firebaseWebApiKey: required('FIREBASE_WEB_API_KEY'),
  jwtSecret: required('JWT_SECRET'),
  /** JWT lifetime: 30 days (v1 has no refresh tokens). */
  jwtTtlSeconds: 30 * 24 * 60 * 60,
}
