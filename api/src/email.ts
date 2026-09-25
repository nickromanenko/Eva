import { config } from './config'

/**
 * Transactional email (issue #6): the activation link and the password-reset link, and
 * nothing else. The only reader of the Postmark server token (GUARDRAILS 4, by analogy
 * with `JWT_SECRET`).
 *
 * Postmark is called over its REST API with `fetch` rather than through its SDK: one POST
 * with three headers is not worth a dependency (GUARDRAILS 25), and a client library is
 * one more place a token or an address could be logged by code nobody here reviewed.
 *
 * Two messages, deliberately thin: no name, no health data, no personalisation — a link,
 * how long it lasts, and what to do if you did not ask for it. The recipient's address
 * is the only personal thing in the request, and it goes to Postmark and nowhere else:
 * no log line in this file carries an address, a link, or a token (GUARDRAILS 12).
 *
 * The `log` transport prints the whole link to stdout instead of sending. It is the local
 * substitute for a mailbox, and exactly the leak the rule above forbids anywhere else,
 * which is why `config.ts` refuses it under `NODE_ENV=production`.
 */

export type EmailKind = 'activation' | 'reset'

export type EmailTransport = 'log' | 'postmark'

export interface EmailOptions {
  transport: EmailTransport
  postmarkApiKey: string | null
  from: string
  publicWebUrl: string
}

export interface EmailSender {
  /** The sign-up confirmation: `${publicWebUrl}/activate#token=…`, valid 24 hours. */
  sendActivationEmail(to: string, rawToken: string): Promise<void>
  /** The password reset: `${publicWebUrl}/reset#token=…`, valid 60 minutes. */
  sendPasswordResetEmail(to: string, rawToken: string): Promise<void>
}

/**
 * Delivery failed. Carries the kind and the upstream HTTP status (`null` when the request
 * never landed) — the operator's two facts — and a constant message: never the address,
 * never the link, never Postmark's own text, which could quote either. The route decides
 * what a failure means to the caller; this only says that there was one.
 */
export class EmailError extends Error {
  constructor(
    readonly kind: EmailKind,
    readonly upstreamStatus: number | null,
  ) {
    super(`Email delivery failed: ${kind}`)
    this.name = 'EmailError'
  }
}

interface Message {
  kind: EmailKind
  to: string
  subject: string
  text: string
  html: string
}

/** The one call this module makes. Narrower than `typeof fetch` so a test can hand in a
 *  plain function and watch the request. */
export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>

/** Where a message leaves the process. `send` throws `EmailError` for any failure. */
type Transport = (message: Message, link: string) => Promise<void>

const POSTMARK_ENDPOINT = 'https://api.postmarkapp.com/email'

const activationMessage = (to: string, link: string): Message => ({
  kind: 'activation',
  to,
  subject: 'Confirm your email for Eva',
  text: [
    'Hi,',
    '',
    'Confirm your email address to finish setting up your Eva account:',
    '',
    link,
    '',
    'The link works for 24 hours.',
    '',
    "If you didn't create an Eva account, you can ignore this email.",
    '',
    '— Eva',
  ].join('\n'),
  html: [
    '<p>Hi,</p>',
    '<p>Confirm your email address to finish setting up your Eva account:</p>',
    `<p><a href="${link}">Confirm my email</a></p>`,
    '<p>The link works for 24 hours.</p>',
    "<p>If you didn't create an Eva account, you can ignore this email.</p>",
    '<p>— Eva</p>',
  ].join('\n'),
})

const resetMessage = (to: string, link: string): Message => ({
  kind: 'reset',
  to,
  subject: 'Reset your Eva password',
  text: [
    'Hi,',
    '',
    'Someone asked to reset the password for the Eva account with this email address.',
    'To choose a new password, open this link:',
    '',
    link,
    '',
    'The link works for 60 minutes.',
    '',
    "If you didn't ask for this, ignore this email — your password stays as it is.",
    '',
    '— Eva',
  ].join('\n'),
  html: [
    '<p>Hi,</p>',
    '<p>Someone asked to reset the password for the Eva account with this email address.',
    ' To choose a new password, open this link:</p>',
    `<p><a href="${link}">Choose a new password</a></p>`,
    '<p>The link works for 60 minutes.</p>',
    "<p>If you didn't ask for this, ignore this email — your password stays as it is.</p>",
    '<p>— Eva</p>',
  ].join('\n'),
})

/**
 * The one line an operator gets when a message did not go out. `kind` says which flow is
 * affected and `upstreamStatus` whether Postmark answered; alert on the event name. No
 * address — the person it failed for is not the operator's business, and a resend from
 * the gate is theirs to press.
 */
const failed = (kind: EmailKind, upstreamStatus: number | null): EmailError => {
  console.error(JSON.stringify({ event: 'email_send_failed', kind, upstreamStatus }))
  return new EmailError(kind, upstreamStatus)
}

/** Postmark, over REST. The token travels in a header, so a failing `fetch`'s message
 *  would not carry it — but the error is dropped rather than attached all the same, for
 *  the reason `identity-toolkit.ts` gives: nobody wrote that message for a log. */
const postmark =
  (apiKey: string, from: string, fetchImpl: FetchLike): Transport =>
  async (message) => {
    let response: Response
    try {
      response = await fetchImpl(POSTMARK_ENDPOINT, {
        method: 'POST',
        headers: {
          accept: 'application/json',
          'content-type': 'application/json',
          'x-postmark-server-token': apiKey,
        },
        body: JSON.stringify({
          From: from,
          To: message.to,
          Subject: message.subject,
          TextBody: message.text,
          HtmlBody: message.html,
          MessageStream: 'outbound',
        }),
      })
    } catch {
      throw failed(message.kind, null)
    }
    if (!response.ok) throw failed(message.kind, response.status)
  }

/** Dev only: the link goes to stdout, prefixed so it is greppable and unmistakable. */
const log: Transport = async (message, link) => {
  console.log(`[email:log] ${message.kind} to=${message.to} link=${link}`)
}

/**
 * Built once from `config` below; exposed so a test can stand up a Postmark sender with a
 * stubbed `fetch` and watch what leaves and what gets logged.
 */
export const createEmailSender = (
  options: EmailOptions,
  fetchImpl: FetchLike = (input, init) => fetch(input, init),
): EmailSender => {
  let transport: Transport
  if (options.transport === 'postmark') {
    if (!options.postmarkApiKey) throw new Error('postmark transport needs an API key')
    transport = postmark(options.postmarkApiKey, options.from, fetchImpl)
  } else {
    transport = log
  }

  /**
   * The token rides in the URL **fragment**, never the query string. A fragment is not
   * sent to any server, so it appears in no access log: not Firebase Hosting's for the
   * page, not Cloud Run's for the API call behind it, and not in a `Referer`. A query
   * string would have put a live credential — for a reset link, one good for an hour —
   * into two sets of retained, broadly readable logs, which is the same secret the
   * hash-only storage in `email-tokens.ts` exists to keep. `readTokenAndScrubUrl` in
   * `website/src/scripts/auth-api.js` is the other half.
   */
  const link = (path: string, rawToken: string): string =>
    `${options.publicWebUrl}${path}#token=${encodeURIComponent(rawToken)}`

  return {
    sendActivationEmail: (to, rawToken) => {
      const url = link('/activate', rawToken)
      return transport(activationMessage(to, url), url)
    },
    sendPasswordResetEmail: (to, rawToken) => {
      const url = link('/reset', rawToken)
      return transport(resetMessage(to, url), url)
    },
  }
}

const sender = createEmailSender(config.email)

export const sendActivationEmail = sender.sendActivationEmail
export const sendPasswordResetEmail = sender.sendPasswordResetEmail
