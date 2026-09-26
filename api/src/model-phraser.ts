import type { Subject } from './dashboard-rules'
import { LLMUnavailableError, type LLM } from './llm'
import type { PhrasedText } from './today'

/**
 * D9 (#104) — the model phraser behind D3's deterministic `TemplatePhraser`. It does not
 * choose the card: it is handed the *filled* card (D3's text) and the subject D1 chose, and
 * it may only rewrite the words within the rules below. The subject is never its to change.
 *
 * Every rule is enforced **after** the model answers, and any failure — the vendor down, the
 * answer unparsable, an unexpected key, a forbidden word, a new number, an asserted phase —
 * falls back to the template text. The stored card records which one won, so a model's
 * rewrite is never mistaken for the reviewed copy, and a refusal is never a 500.
 *
 * The prompt it builds carries the filled card and the tone rules, never raw events, the
 * profile, sex events or the uid (GUARDRAILS 12 applies to the prompt as to logs). Rung 1
 * (`flag`) is deterministic and never reaches the model (D10).
 */

/** The only keys a model answer may set — the card's text lines. Anything else (`rung`,
 *  `templateId`, `state`, `actions`, `tone`) is an attempt to change the card, not phrase it,
 *  and is refused. */
const TEXT_KEYS = new Set(['title', 'line2', 'line3', 'kicker', 'meta'])

/**
 * The tone rules as rejections (PRD §Dashboard → Tone and framing), one named row each so a
 * test can pin each rule independently. A model answer matching any of them is refused.
 */
const FORBIDDEN: ReadonlyArray<{ name: string; pattern: RegExp }> = [
  { name: 'score', pattern: /\bscore\b/i },
  { name: 'streak', pattern: /\bstreak\b/i },
  { name: 'comparison', pattern: /\b(other users|most women|average woman|compared to)\b/i },
  { name: 'capability', pattern: /\b(you can |you will |you are able to|you are capable of)\b/i },
  { name: 'destiny', pattern: /\b(you will feel|you are going to|your day will|you should)\b/i },
]

/** An asserted phase, said as fact rather than as an estimate. Enforced only at `hedged`
 *  confidence — the one class where the PRD requires "likely"/"probably" rather than a
 *  statement. */
const ASSERTIVE_PHASE =
  /\b(you are ovulating|you are in your (luteal|follicular|fertile|menstrual) phase|you are fertile|your fertile window is)\b/i

const NUMBERS = /\d+(?:\.\d+)?/g

/** The card's own text, as one string — the only thing a number may echo. */
const filledText = (filled: PhrasedText): string =>
  [filled.title, filled.line2, filled.line3, filled.kicker, filled.meta]
    .filter((s): s is string => typeof s === 'string')
    .join(' ')

/** Every digit-run the filled card already carried. A model answer may not introduce one the
 *  input did not have. */
const carriedNumbers = (text: string): Set<string> => new Set(text.match(NUMBERS) ?? [])

/** The tone rules, as the prose the prompt carries — fixed, reviewed, never machine-argued. */
const TONE_RULES = [
  'The subject is fixed: never introduce a new topic, a number the card did not already carry,',
  'a score, a streak, or a comparison to other users.',
  'Never tell the reader what she can do today, or how she will feel.',
  'If a cycle phase is mentioned, keep it approximate ("likely", "may") — never state it as fact.',
  'Keep at most three lines: title, line2, line3.',
  'Answer with JSON only: {"title":"…","line2":"…","line3":"…"}.',
].join('\n')

/** Builds the prompt from the filled card and the tone rules, and nothing else. Exported so a
 *  test can assert the prompt carries no raw events, profile, sex events or uid. */
export const buildPrompt = (filled: PhrasedText): string =>
  [
    'Rewrite the lines of a wellness app daily card in plain, warm language.',
    TONE_RULES,
    `Card: ${JSON.stringify({
      title: filled.title,
      ...(filled.line2 !== undefined ? { line2: filled.line2 } : {}),
      ...(filled.line3 !== undefined ? { line3: filled.line3 } : {}),
      ...(filled.kicker !== undefined ? { kicker: filled.kicker } : {}),
      ...(filled.meta !== undefined ? { meta: filled.meta } : {}),
    })}`,
  ].join('\n\n')

/** The text lines a model answer may set, with `title` required and the rest optional. */
export interface ModelLines {
  title: string
  line2?: string
  line3?: string
  kicker?: string
  meta?: string
}

/** Parses the model's answer and applies the rules. Returns the rewritten text lines (only
 *  the keys it actually set), or `null` when the answer is refused. */
const enforce = (subject: Subject, filled: PhrasedText, raw: string): ModelLines | null => {
  let value: unknown
  try {
    value = JSON.parse(raw)
  } catch {
    return null
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return null

  const object = value as Record<string, unknown>
  const keys = Object.keys(object)
  if (keys.length === 0 || keys.some((key) => !TEXT_KEYS.has(key))) return null

  const title = object.title
  if (typeof title !== 'string' || title.trim() === '') return null

  const lines: ModelLines = { title: title.trim() }
  for (const key of ['line2', 'line3', 'kicker', 'meta'] as const) {
    const v = object[key]
    if (v === undefined) continue
    if (typeof v !== 'string') return null
    lines[key] = v.trim()
  }

  const prose = Object.values(lines).join(' ')

  if (subject.confidence === 'hedged' && ASSERTIVE_PHASE.test(prose)) return null
  for (const rule of FORBIDDEN) {
    if (rule.pattern.test(prose)) return null
  }

  const carried = carriedNumbers(filledText(filled))
  for (const number of prose.match(NUMBERS) ?? []) {
    if (!carried.has(number)) return null
  }

  return lines
}

/**
 * The model phraser: the deterministic fill stays the fallback, and the model's rewrite wins
 * only when every rule passes. `rewrite` returns which one produced the text, so the stored
 * card can say so.
 */
export class ModelPhraser {
  constructor(private readonly vendor: LLM) {}

  async rewrite(
    subject: Subject,
    filled: PhrasedText,
  ): Promise<{ text: PhrasedText; source: 'model' | 'template' }> {
    // Rung 1 is deterministic (D10): the escalation card is never rephrased.
    if (subject.rung === 'flag') return { text: filled, source: 'template' }

    let raw: string
    try {
      raw = await this.vendor.complete(buildPrompt(filled))
    } catch (err) {
      if (err instanceof LLMUnavailableError) return { text: filled, source: 'template' }
      throw err
    }

    const rewritten = enforce(subject, filled, raw)
    if (rewritten === null) return { text: filled, source: 'template' }

    return {
      text: {
        state: filled.state,
        ...(filled.tone !== undefined ? { tone: filled.tone } : {}),
        ...rewritten,
        actions: filled.actions,
      },
      source: 'model',
    }
  }
}
