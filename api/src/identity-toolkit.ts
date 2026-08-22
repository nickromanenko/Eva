import { config } from './config'

/**
 * Thin client for Firebase's Identity Toolkit REST API — the only way to
 * create/verify email+password credentials server-side (the Admin SDK cannot
 * verify passwords).
 */

export class IdentityToolkitError extends Error {
  constructor(readonly reason: string) {
    super(`Identity Toolkit: ${reason}`)
  }
}

interface TokenResponse {
  localId: string
  email: string
}

const call = async (endpoint: string, body: Record<string, unknown>): Promise<TokenResponse> => {
  const response = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:${endpoint}?key=${config.firebaseWebApiKey}`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ...body, returnSecureToken: true }),
    },
  )
  const json = (await response.json()) as {
    localId?: string
    email?: string
    error?: { message?: string }
  }
  if (!response.ok) {
    // Google returns codes like EMAIL_EXISTS, INVALID_LOGIN_CREDENTIALS,
    // WEAK_PASSWORD : Password should be at least 6 characters
    throw new IdentityToolkitError(json.error?.message?.split(' ')[0] ?? 'UNKNOWN')
  }
  return { localId: json.localId!, email: json.email! }
}

export const signUpWithPassword = (email: string, password: string) =>
  call('signUp', { email, password })

export const signInWithPassword = (email: string, password: string) =>
  call('signInWithPassword', { email, password })
