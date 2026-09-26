import { describe, expect, test } from 'bun:test'
import type { Subject } from '../src/dashboard-rules'
import { LLMUnavailableError, type LLM } from '../src/llm'
import { ModelPhraser, buildPrompt } from '../src/model-phraser'
import type { PhrasedText } from '../src/today'

/**
 * D9 (#104): the model phraser. Pure — the vendor is stubbed, so these run in every
 * environment with no network. Each rejection rule has its own named case, because the
 * stub suite is necessary, not sufficient: it proves the *enforcement*, while a real model's
 * behaviour still needs the review the issue names. Say so rather than hide it.
 */

const subject = (over: Partial<Subject> = {}): Subject => ({
  rung: 'phase',
  templateId: 'phase_energy',
  slots: {},
  confidence: 'hedged',
  ...over,
})

const filled = (over: Partial<PhrasedText> = {}): PhrasedText => ({
  state: 'home_d',
  tone: 'base',
  kicker: 'Cycle day 15',
  title: 'Many women notice higher energy around now',
  line2: 'day 15',
  actions: ['View cycle details'],
  ...over,
})

const answering = (raw: string | (() => string)): LLM => ({
  complete: async () => (typeof raw === 'function' ? raw() : raw),
})

const json = (object: unknown): string => JSON.stringify(object)

describe('buildPrompt', () => {
  test('carries the filled card and the tone rules, and nothing else', () => {
    const prompt = buildPrompt(filled())
    // The filled card's own words are there …
    expect(prompt).toContain('Many women notice higher energy around now')
    expect(prompt).toContain('day 15')
    // … and the tone rules …
    expect(prompt).toContain('never state it as fact')
    // … and none of what a raw event, the profile, sex events or a uid would carry.
    // `buildPrompt` is handed only the filled card, so the test plants a marker that would
    // be present on any of those and asserts it is absent.
    expect(prompt).not.toContain('e2e+profile-marker@e2e.evaapp.dev')
    expect(prompt).not.toContain('some-uid')
    expect(prompt).not.toContain('intercourse')
  })
})

describe('ModelPhraser', () => {
  test('a valid rewrite wins, and keeps the card structure from the fill', async () => {
    const vendor = answering(
      json({ title: 'Some women notice more energy around now', line2: 'take it easy today' }),
    )
    const result = await new ModelPhraser(vendor).rewrite(subject(), filled())

    expect(result.source).toBe('model')
    expect(result.text.title).toBe('Some women notice more energy around now')
    expect(result.text.line2).toBe('take it easy today')
    // The model rewrites the lines, never the structure: state, tone and actions are the
    // deterministic fill's, and a line the model dropped is gone.
    expect(result.text.state).toBe('home_d')
    expect(result.text.tone).toBe('base')
    expect(result.text.actions).toEqual(['View cycle details'])
    expect(result.text.kicker).toBeUndefined()
  })

  test('the vendor being down falls back to the template text', async () => {
    const vendor: LLM = { complete: async () => Promise.reject(new LLMUnavailableError(null)) }
    const result = await new ModelPhraser(vendor).rewrite(subject(), filled())

    expect(result.source).toBe('template')
    expect(result.text).toEqual(filled())
  })

  test('rung 1 (flag) never reaches the model', async () => {
    let called = false
    const vendor: LLM = { complete: async () => ((called = true), '{}') }
    const result = await new ModelPhraser(vendor).rewrite(
      subject({ rung: 'flag', templateId: 'red_flag' as never, confidence: 'plain' }),
      filled(),
    )

    expect(called).toBe(false)
    expect(result.source).toBe('template')
  })

  test('an answer that tries to set rung or templateId is refused', async () => {
    const vendor = answering(json({ rung: 'flag', title: 'tampered' }))
    const result = await new ModelPhraser(vendor).rewrite(subject(), filled())
    expect(result.source).toBe('template')
  })

  test('an answer that is not JSON is refused', async () => {
    const result = await new ModelPhraser(answering('not json')).rewrite(subject(), filled())
    expect(result.source).toBe('template')
  })

  test('an answer with no title is refused', async () => {
    const result = await new ModelPhraser(answering(json({ line2: 'hi' }))).rewrite(
      subject(),
      filled(),
    )
    expect(result.source).toBe('template')
  })

  test('a hedged subject is not rewritten into an asserted phase', async () => {
    const result = await new ModelPhraser(answering(json({ title: 'You are ovulating today' }))).rewrite(
      subject({ confidence: 'hedged' }),
      filled(),
    )
    expect(result.source).toBe('template')
  })

  test('the same asserted phase passes at plain confidence', async () => {
    const result = await new ModelPhraser(answering(json({ title: 'You are ovulating today' }))).rewrite(
      subject({ confidence: 'plain' }),
      filled(),
    )
    expect(result.source).toBe('model')
  })

  test('a new number the card did not carry is refused', async () => {
    const result = await new ModelPhraser(answering(json({ title: 'Your cycle is day 20' }))).rewrite(
      subject(),
      filled(),
    )
    expect(result.source).toBe('template')
  })

  test('a number the card already carried is allowed', async () => {
    const result = await new ModelPhraser(answering(json({ title: 'Cycle day 15 already' }))).rewrite(
      subject(),
      filled(),
    )
    expect(result.source).toBe('model')
  })

  // One named case per tone rule, so a rule that is dropped fails alone rather than as a
  // vague "the model said something".
  test('score vocabulary is refused', async () => {
    const result = await new ModelPhraser(answering(json({ title: 'Your score is high' }))).rewrite(
      subject(),
      filled(),
    )
    expect(result.source).toBe('template')
  })

  test('streak vocabulary is refused', async () => {
    const result = await new ModelPhraser(
      answering(json({ title: 'You are on a 3-day streak' })),
    ).rewrite(subject(), filled())
    expect(result.source).toBe('template')
  })

  test('comparison to other users is refused', async () => {
    const result = await new ModelPhraser(
      answering(json({ title: 'More than most women, you are set' })),
    ).rewrite(subject(), filled())
    expect(result.source).toBe('template')
  })

  test('a sentence about what she can do today is refused', async () => {
    const result = await new ModelPhraser(
      answering(json({ title: 'You can do your hardest work today' })),
    ).rewrite(subject(), filled())
    expect(result.source).toBe('template')
  })

  test('a sentence about how she will feel is refused', async () => {
    const result = await new ModelPhraser(
      answering(json({ title: 'You will feel energetic' })),
    ).rewrite(subject(), filled())
    expect(result.source).toBe('template')
  })
})
