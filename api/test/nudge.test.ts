import { describe, expect, test } from 'bun:test'
import type { Nudge } from '../src/content'
import { selectNudge, type NudgeInput } from '../src/dashboard-rules'

/**
 * The nudge slot's eligibility (D6, #101): the PRD's four rules, each driven by D2's own
 * parameter rather than a number re-decided here. Pure — no Firestore, no clock, runs
 * everywhere. The fifth (profile incomplete) is #19's and its dismissal rides the same
 * record, but its copy and rendering are #19's, so it is not selected here.
 */

const nudge = (over: Partial<Nudge>): Nudge => ({
  id: 'period_due',
  withinDays: 2,
  trigger: 'periodPredictedWithinDays',
  text: 'Your period is likely to start within two days.',
  action: 'View prediction',
  status: 'active',
  order: 0,
  ...over,
})

const input = (over: Partial<NudgeInput> = {}): NudgeInput => ({
  daysUntilPredictedPeriod: null,
  upcomingAppointments: [],
  daysSinceLastLog: null,
  nutritionSetUp: false,
  ...over,
})

const APPOINTMENT: Nudge = {
  id: 'appointment_tomorrow',
  withinDays: 1,
  trigger: 'appointmentTomorrow',
  text: 'You have an appointment tomorrow.',
  action: 'Review questions',
  status: 'active',
  order: 1,
}

const GAP: Nudge = {
  id: 'logging_gap',
  withinDays: 3,
  trigger: 'noBodySignalsForDays',
  text: "You haven't added any body signals recently.",
  action: 'Log signals',
  status: 'active',
  order: 2,
}

const SETUP: Nudge = {
  id: 'nutrition_setup',
  withinDays: null,
  trigger: 'nutritionSetupIncomplete',
  text: 'Complete your Nutrition setup.',
  action: 'Continue setup',
  status: 'active',
  order: 3,
}

describe('selectNudge', () => {
  test('a period predicted within the rule\'s days selects the period nudge', () => {
    const selected = selectNudge(
      input({ daysUntilPredictedPeriod: 2 }),
      [nudge({}), nudge(APPOINTMENT), nudge(GAP), nudge(SETUP)],
      new Set(),
    )
    expect(selected?.id).toBe('period_due')
  })

  test('a period further out than the rule does not', () => {
    const selected = selectNudge(input({ daysUntilPredictedPeriod: 3 }), [nudge({})], new Set())
    expect(selected).toBeNull()
  })

  test('no prediction is not a period nudge', () => {
    const selected = selectNudge(input(), [nudge({})], new Set())
    expect(selected).toBeNull()
  })

  test('an appointment tomorrow selects the appointment nudge', () => {
    const selected = selectNudge(
      input({ upcomingAppointments: [{ startAt: '2026-09-27T10:30:00', type: null, inDays: 1 }] }),
      [nudge(APPOINTMENT), nudge(GAP), nudge(SETUP)],
      new Set(),
    )
    expect(selected?.id).toBe('appointment_tomorrow')
  })

  test('an appointment today is not "tomorrow"', () => {
    const selected = selectNudge(
      input({ upcomingAppointments: [{ startAt: '2026-09-26T10:30:00', type: null, inDays: 0 }] }),
      [nudge(APPOINTMENT)],
      new Set(),
    )
    expect(selected).toBeNull()
  })

  test('a logging gap at or past the rule selects the gap nudge', () => {
    const selected = selectNudge(
      input({ daysSinceLastLog: 3 }),
      [nudge(GAP), nudge(SETUP)],
      new Set(),
    )
    expect(selected?.id).toBe('logging_gap')
  })

  test('a shorter gap does not', () => {
    const selected = selectNudge(input({ daysSinceLastLog: 2 }), [nudge(GAP)], new Set())
    expect(selected).toBeNull()
  })

  test('never having logged is not a gap', () => {
    const selected = selectNudge(input({ daysSinceLastLog: null }), [nudge(GAP)], new Set())
    expect(selected).toBeNull()
  })

  test('an unfinished Nutrition setup selects the setup nudge', () => {
    const selected = selectNudge(input({ nutritionSetUp: false }), [nudge(SETUP)], new Set())
    expect(selected?.id).toBe('nutrition_setup')
  })

  test('a finished setup does not', () => {
    const selected = selectNudge(input({ nutritionSetUp: true }), [nudge(SETUP)], new Set())
    expect(selected).toBeNull()
  })

  test('a dismissed id is never eligible again, whatever else is true', () => {
    const selected = selectNudge(
      input({ daysUntilPredictedPeriod: 1 }),
      [nudge({})],
      new Set(['period_due']),
    )
    expect(selected).toBeNull()
  })

  test('when several are eligible the store\'s order wins, not the input', () => {
    const selected = selectNudge(
      input({ daysUntilPredictedPeriod: 1, daysSinceLastLog: 5, nutritionSetUp: false }),
      [nudge(SETUP), nudge(GAP), nudge({})],
      new Set(),
    )
    expect(selected?.id).toBe('period_due')
  })

  test('a retired rule is never selected', () => {
    const selected = selectNudge(
      input({ daysSinceLastLog: 5 }),
      [nudge({ ...GAP, status: 'retired' })],
      new Set(),
    )
    expect(selected).toBeNull()
  })

  test('a rule with a trigger nothing recognises is inert', () => {
    const selected = selectNudge(
      input({ daysSinceLastLog: 5 }),
      [nudge({ id: 'mystery', trigger: 'doesNotExist', withinDays: null })],
      new Set(),
    )
    expect(selected).toBeNull()
  })
})
