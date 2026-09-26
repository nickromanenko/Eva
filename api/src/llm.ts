import { config } from './config'

/**
 * The LLM vendor (A5, #267) — Google Gemini Flash, Google as data processor — reached over
 * HTTPS from this one module, exactly as Postmark is from `email.ts` (GUARDRAILS 32: a
 * contracted processor called over HTTPS from a single owning module). The key is read here
 * alone (GUARDRAILS 4); nothing else may reach for `config.llm`.
 *
 * What the prompt it is handed carries is `today.ts`'s contract, not this module's: it
 * passes the filled card's subject and inputs and the tone rules, never raw events, the
 * profile, sex events or the uid (GUARDRAILS 12 applies to the prompt as to logs). This
 * file logs nothing — not the prompt, not the response, not the key — and drops the cause
 * of a failed `fetch` for the reason `identity-toolkit.ts` gives: nobody wrote that message
 * for a log.
 */

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>

/** The vendor could not answer — unprovisioned, a timeout, a network failure, a non-200, or
 *  a body with no text. The model phraser's answer to this is the deterministic template
 *  fill, never a 500. Its own class so that fallback is explicit and greppable. */
export class LLMUnavailableError extends Error {
  constructor(readonly upstreamStatus: number | null) {
    super('the LLM vendor could not answer')
    this.name = 'LLMUnavailableError'
  }
}

/** The model phraser's stated budget: a phrasing call that has not answered in this long is
 *  slower than the template fill it is improving on, and the card is due. Tighter than the
 *  request's own timeout, so a hung vendor cannot hold `GET /me/today` open (#104). */
export const MODEL_BUDGET_MS = 2000

const endpoint = (model: string, key: string): string =>
  `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}`

export interface LLM {
  /** The rewritten text, or `LLMUnavailableError`. The prompt is the caller's; this never
   *  inspects or logs it. */
  complete(prompt: string): Promise<string>
}

export const createLLM = (
  apiKey: string | null,
  model: string,
  fetchImpl: FetchLike = (input, init) => fetch(input, init),
  budgetMs: number = MODEL_BUDGET_MS,
): LLM => ({
  async complete(prompt: string): Promise<string> {
    if (apiKey === null) throw new LLMUnavailableError(null)
    let response: Response
    try {
      response = await fetchImpl(endpoint(model, apiKey), {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          contents: [{ parts: [{ text: prompt }] }],
          generationConfig: { maxOutputTokens: 256, temperature: 0 },
        }),
        signal: AbortSignal.timeout(budgetMs),
      })
    } catch {
      throw new LLMUnavailableError(null)
    }
    if (!response.ok) throw new LLMUnavailableError(response.status)
    const body = (await response.json()) as {
      candidates?: { content?: { parts?: { text?: string }[] } }[]
    }
    const text = body.candidates
      ?.find((c) => c?.content?.parts !== undefined)
      ?.content?.parts?.find((p) => typeof p?.text === 'string')?.text?.trim()
    if (!text) throw new LLMUnavailableError(response.status)
    return text
  },
})

/** The one live client, built from `config` — exported so the model phraser reads no env of
 *  its own, and so a test can stand up a stubbed vendor instead. */
export const llm = createLLM(config.llm.apiKey, config.llm.model)
