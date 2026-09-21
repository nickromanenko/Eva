import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from 'bun:test'
import { FieldValue } from 'firebase-admin/firestore'
import { firestore } from '../src/firebase'
import {
  CONTENT_IDS,
  SLOTS,
  UnreviewedContentError,
  applyContent,
  contentVersion,
  invalidateContentCache,
  parseItems,
  readContent,
  retireContent,
  reviewProblems,
  type Banner,
  type Nudge,
  type Review,
  type Template,
} from '../src/content'
import { BANNERS, NUDGES, REVIEW as SEED_REVIEW, TEMPLATES } from '../scripts/seed-content'
import { signUpActivated } from './support/session'

/**
 * The Dashboard content store (#97) — `content/`, `GET /content`, and the seed.
 *
 * Two halves. The store behaves like `refdata/` (#24) and is tested the way that is: the
 * `304` handshake, a content-derived version, ids that survive a relabel. The half that is
 * new is the **review requirement**: clinical copy that nobody signed must not be
 * servable, and the seed must not be talkable into it.
 *
 * The seed's own arrays are imported rather than re-typed. A test that restated the copy
 * would pass while the seed said something else, which is the one thing these cases exist
 * to prevent.
 */

/**
 * Live round trips to the API and Firestore on every case, and a sweep at the end. 20s is
 * the ceiling every network-touching suite sets (#31).
 */
setDefaultTimeout(20_000)

const BASE = process.env.EVA_API_URL ?? 'http://localhost:3003'
const PASSWORD = 'correct-horse-8'

/** The signature these tests write with. A real one lives in the seed, in a commit. */
const REVIEW: Review = {
  reviewedBy: 'content.test.ts',
  reviewedAt: '2026-09-16',
  source: 'docs/design/Eva App.dc.html — Dashboard rail',
}

const collection = () => firestore.collection('content')

let token = ''
let uid = ''
const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`
/** Documents this file created, so the sweep leaves the project as it found it. */
const createdDocs: string[] = []

const api = (path: string, init?: RequestInit & { token?: string | null }) =>
  fetch(`${BASE}${path}`, {
    ...init,
    headers: {
      'content-type': 'application/json',
      ...(init?.token === null ? {} : { authorization: `Bearer ${init?.token ?? token}` }),
      ...(init?.headers ?? {}),
    },
  })

interface ContentBody {
  version: string
  templates: Template[]
  banners: Banner[]
  nudges: Nudge[]
}
const json = <T>(res: Response): Promise<T> => res.json() as Promise<T>

/** A scratch document id, so nothing here writes over the three the API serves. */
const scratch = () => {
  const id = `test-${crypto.randomUUID()}`
  createdDocs.push(id)
  return id
}

beforeAll(async () => {
  const session = await signUpActivated(BASE, email, PASSWORD)
  token = session.token
  uid = session.uid
}, 60_000)

afterAll(async () => {
  for (const id of createdDocs)
    await collection()
      .doc(id)
      .delete()
      .catch(() => {})
  if (uid) {
    await firestore
      .collection('users')
      .doc(uid)
      .delete()
      .catch(() => {})
    const { adminAuth } = await import('../src/firebase')
    await adminAuth.deleteUser(uid).catch(() => {})
  }
  const rows = await firestore.collection('authTokens').where('email', '==', email).get()
  for (const row of rows.docs) await row.ref.delete().catch(() => {})
})

describe('GET /content', () => {
  test('requires a bearer token', async () => {
    const res = await api('/content', { token: null })
    expect(res.status).toBe(401)
    expect((await json<{ error: { code: string } }>(res)).error.code).toBe('UNAUTHORIZED')
  })

  test('serves the three kinds', async () => {
    const body = await json<ContentBody>(await api('/content'))
    expect(Object.keys(body).sort()).toEqual(['banners', 'nudges', 'templates', 'version'])
    expect(body.version).toMatch(/^[0-9a-f]{16}$/)
  })

  test('and carries the ETag and revalidation headers a plain HTTP client uses', async () => {
    // The `?version=` query is how the app asks; `ETag` plus `no-cache` is how anything
    // else does, and it is the half no assertion here used to read.
    const res = await api('/content')
    const body = await json<ContentBody>(res)

    expect(res.headers.get('etag')).toBe(`"${body.version}"`)
    expect(res.headers.get('cache-control')).toBe('private, no-cache')
  })

  test('a client holding the current version gets 304 and no body', async () => {
    const { version } = await json<ContentBody>(await api('/content'))

    const res = await api(`/content?version=${version}`)

    expect(res.status).toBe(304)
    expect(await res.text()).toBe('')
  })

  test('a stale version gets the bundle back', async () => {
    const res = await api('/content?version=0000000000000000')
    expect(res.status).toBe(200)
  })

  test('If-None-Match works the same way, weak or strong', async () => {
    const { version } = await json<ContentBody>(await api('/content'))

    for (const header of [`"${version}"`, `W/"${version}"`]) {
      const res = await api('/content', { headers: { 'if-none-match': header } })
      expect(res.status).toBe(304)
    }
  })

  test('the two doors have a pinned precedence: query wins when it says something, header otherwise', async () => {
    // #147: both routes used to read `query ?? header`, and `??` only falls through on
    // null/undefined — so `?version=`, an empty value, short-circuited the header and a
    // client sending an empty parameter beside a valid validator got a full 200. Empty
    // means absent; the query wins only when non-empty.
    const { version } = await json<ContentBody>(await api('/content'))
    const header = { 'if-none-match': `"${version}"` }

    // Query non-empty and current: it wins (and a stale query would win the other way).
    expect((await api(`/content?version=${version}`, { headers: header })).status).toBe(304)
    expect((await api('/content?version=0000000000000000', { headers: header })).status).toBe(200)
    // Query absent: the header is read.
    expect((await api('/content', { headers: header })).status).toBe(304)
    // Query empty: the header is still read — the case that used to break.
    expect((await api('/content?version=', { headers: header })).status).toBe(304)
    // No validator at all: the body, whatever the query held.
    expect((await api('/content?version=')).status).toBe(200)
  })
})

describe('the version is a hash of the content', () => {
  test("changing one template's line2 changes it; rewriting the same words does not", async () => {
    const base = { templates: TEMPLATES, banners: BANNERS, nudges: NUDGES }
    const first = contentVersion(base)

    expect(contentVersion({ ...base, templates: [...TEMPLATES] })).toBe(first)

    const edited = TEMPLATES.map((t, i) =>
      i === 0 ? { ...t, line2: `${t.line2} And one more sentence.` } : t,
    )
    expect(contentVersion({ ...base, templates: edited })).not.toBe(first)
  })

  test('the field order a document happened to be written in does not move it', () => {
    // Firestore preserves insertion order, and a document edited in the console comes
    // back with its keys wherever the editor put them. Hashing that order would mean a
    // re-seed, or somebody re-typing a line, invalidating every device's cache for a
    // change nobody can read. `stable()` is what stops it, and nothing else asserts it.
    const one = { id: 'x', order: 0, status: 'active' as const, text: 'A', sub: 'B' }
    const other = { sub: 'B', text: 'A', status: 'active' as const, order: 0, id: 'x' }

    expect(contentVersion({ templates: [], banners: [], nudges: [other] as never })).toBe(
      contentVersion({ templates: [], banners: [], nudges: [one] as never }),
    )
  })

  test('re-signing the same copy is not a content change', async () => {
    // Review metadata is deliberately outside the hash: making a re-review push a new
    // bundle to every device would punish the thing the store exists to encourage.
    // Asserted through a document rather than by re-hashing the same argument, which
    // is a tautology — `contentVersion` takes only the items, so the signature has
    // nowhere to enter from and the property has to be read off what is stored.
    const id = scratch()
    const items = [{ id: 'one', order: 0, status: 'active' as const, title: 'A line' }]
    await applyContent(id as never, items, REVIEW)
    const before = contentVersion({
      templates: [],
      banners: [],
      nudges: (await readContent(id as never)) as Nudge[],
    })

    await applyContent(
      id as never,
      items,
      {
        reviewedBy: 'Somebody else',
        reviewedAt: '2026-12-01',
        source: 'a second look at the same words',
      },
      { rewrite: true },
    )

    const doc = (await collection().doc(id).get()).data()!
    expect(doc.reviewedBy).toBe('Somebody else')
    expect(
      contentVersion({
        templates: [],
        banners: [],
        nudges: (await readContent(id as never)) as Nudge[],
      }),
    ).toBe(before)
  })
})

describe('copy nobody signed is not servable', () => {
  test('the module refuses a write with no reviewer', async () => {
    const id = scratch()
    for (const incomplete of [
      { reviewedBy: '', reviewedAt: '2026-09-16', source: 'canvas' },
      { reviewedBy: 'Someone', reviewedAt: '', source: 'canvas' },
      { reviewedBy: 'Someone', reviewedAt: '2026-09-16', source: '' },
      { reviewedBy: '   ', reviewedAt: '2026-09-16', source: 'canvas' },
    ]) {
      await expect(applyContent(id as never, [], incomplete as Review)).rejects.toBeInstanceOf(
        UnreviewedContentError,
      )
    }

    // And nothing was written on the way to refusing.
    expect((await collection().doc(id).get()).exists).toBe(false)
  })

  /**
   * Skipped the day the copy is signed, and that is the point rather than a gap. The case
   * has to run the real script to prove the refusal is the script's exit status; once
   * `REVIEW` is filled in the same four spawns would seed whatever project the suite is
   * pointed at — `verify-api.sh` points it at the real one — and report the write as a
   * failed assertion. A test of a refusal has nothing to say once there is nothing to
   * refuse.
   */
  test.skipIf(reviewProblems(SEED_REVIEW).length === 0)(
    'the seed script refuses too, and no argument or env var gets past it',
    async () => {
      // Driven as a process, because the refusal is the script's exit status — not
      // something a caller could catch and ignore. The two escape hatches a hurried
      // operator would reach for are tried here, so adding either one fails this.
      const run = async (args: string[], env: Record<string, string>) => {
        const proc = Bun.spawn(['bun', 'run', 'scripts/seed-content.ts', ...args], {
          cwd: `${import.meta.dir}/..`,
          env: { ...process.env, ...env },
          stdout: 'pipe',
          stderr: 'pipe',
        })
        const [out, err, code] = await Promise.all([
          new Response(proc.stdout).text(),
          new Response(proc.stderr).text(),
          proc.exited,
        ])
        return { out, err, code }
      }

      for (const [args, env] of [
        [[], {}],
        [['--skip-review'], {}],
        [['--force'], {}],
        [[], { SKIP_REVIEW: '1' }],
      ] as [string[], Record<string, string>][]) {
        const { out, err, code } = await run(args, env)
        expect(code).toBe(1)
        expect(err).toContain('Refusing to seed')
        expect(out).not.toContain('seeded content/')
      }
    },
  )

  test('and a signature cannot be stamped over copy it never covered', async () => {
    // The merge is additive and the signature is on the document, so without this an
    // unsigned item added in the console would be written back under the next seeder's
    // name — the failure this collection exists to prevent, arriving through the
    // sanctioned path.
    const id = scratch()
    await collection()
      .doc(id)
      .set({
        items: [{ id: 'added-in-the-console', order: 0, status: 'active' }],
      })

    await expect(
      applyContent(id as never, [{ id: 'mine', order: 1, status: 'active' }], REVIEW),
    ).rejects.toBeInstanceOf(UnreviewedContentError)

    // And it wrote nothing on the way to refusing.
    const after = (await collection().doc(id).get()).data()!
    expect(after.items).toHaveLength(1)
    expect(after.reviewedBy).toBeUndefined()
  })

  test('a signature is stored beside the items, not inside them', async () => {
    const id = scratch()
    await applyContent(id as never, [{ id: 'x', order: 0, status: 'active' }], REVIEW)

    const doc = (await collection().doc(id).get()).data()!
    expect(doc.reviewedBy).toBe(REVIEW.reviewedBy)
    expect(doc.source).toBe(REVIEW.source)
    expect(doc.items).toHaveLength(1)
    expect(doc.items[0].reviewedBy).toBeUndefined()
  })

  test('reviewProblems names every missing field at once', () => {
    // So the seed can report all three rather than one write at a time.
    expect(reviewProblems({})).toEqual(['reviewedBy', 'reviewedAt', 'source'])
    expect(reviewProblems(REVIEW)).toEqual([])
  })
})

describe('the seed carries the canvas copy', () => {
  test('every CARDS key the canvas draws has a template', () => {
    // The canvas' 14 `CARDS` variants. Named here rather than counted, so adding a
    // template does not silently satisfy a missing one.
    const states = TEMPLATES.map((t) => t.state).sort()
    expect(states).toEqual(
      [
        'home_a',
        'home_b',
        'home_c',
        'home_d',
        'home_e',
        'home_edu',
        'home_f',
        'home_flag',
        'home_g',
        'home_h',
        'home_loss',
        'home_plan',
        'home_post',
        'home_preg',
      ].sort(),
    )
  })

  test('nine banner items, three per phase', () => {
    expect(BANNERS).toHaveLength(9)
    for (const phase of ['cycle', 'pregnancy', 'postpartum']) {
      expect(BANNERS.filter((b) => b.phase === phase)).toHaveLength(3)
    }
  })

  test("the four nudge rules carry the PRD's parameters and nothing else", () => {
    expect(NUDGES.map((n) => [n.id, n.withinDays])).toEqual([
      ['period_due', 2], // period within two days
      ['appointment_tomorrow', 1], // appointment tomorrow
      ['logging_gap', 3], // a three-day logging gap
      ['nutrition_setup', null], // a setup step never completed — no number
    ])
  })

  test('ids are permanent, so relabelling copy leaves them alone', async () => {
    // A device caches a rendered card pointing at a template id. Changing what a card
    // *says* must never change what it *is*.
    const id = scratch()
    const first = [{ id: 'phase_energy', order: 0, status: 'active' as const, title: 'One' }]
    await applyContent(id as never, first as never, REVIEW)

    const relabelled = [{ id: 'phase_energy', order: 0, status: 'active' as const, title: 'Two' }]
    await applyContent(id as never, relabelled as never, REVIEW, { rewrite: true })

    const items = (await collection().doc(id).get()).data()!.items
    expect(items).toHaveLength(1)
    expect(items[0].id).toBe('phase_energy')
    expect(items[0].title).toBe('Two')
  })

  test('a write keeps the row the read path was already serving, and its unknown fields', async () => {
    // Two agreements that have to hold between the write path and the read path, both
    // of them about a document somebody edited in the console.
    //
    // First: a duplicated id. `parseItems` serves the first row, so the merge has to
    // keep the first row too — last-wins would mean the read path hides a bad
    // duplicate until a legitimate re-seed promotes it and signs it.
    //
    // Second: a field this module does not model. The merge writes stored rows back as
    // they were, so a client release that lands a new field ahead of the server does
    // not lose it to the next unrelated write.
    const id = scratch()
    await collection()
      .doc(id)
      .set({
        items: [
          { id: 'twice', order: 0, status: 'active', text: 'First', imageUrl: 'a.png' },
          { id: 'twice', order: 1, status: 'active', text: 'Second' },
        ],
        ...REVIEW,
      })

    expect(((await readContent(id as never)) as Nudge[])[0]!.text).toBe('First')

    await applyContent(id as never, [{ id: 'new', order: 2, status: 'active' }], REVIEW)

    const rows = (await collection().doc(id).get()).data()!.items as Record<string, unknown>[]
    const survivor = rows.filter((row) => row.id === 'twice')
    expect(survivor).toHaveLength(1)
    expect(survivor[0]!.text).toBe('First')
    expect(survivor[0]!.imageUrl).toBe('a.png')
  })

  test("retiring one item leaves the others' unknown fields alone", async () => {
    // The same promise, from the other writer. Retirement is a status flip, not a
    // normalisation pass: it must not be the operation that quietly deletes a field
    // somebody added to the rows it did not touch.
    const id = scratch()
    await collection()
      .doc(id)
      .set({
        items: [
          { id: 'going', order: 0, status: 'active', imageUrl: 'a.png' },
          { id: 'staying', order: 1, status: 'active', imageUrl: 'b.png' },
        ],
        ...REVIEW,
      })

    expect(await retireContent(id as never, 'going')).toBe(true)

    const rows = (await collection().doc(id).get()).data()!.items as Record<string, unknown>[]
    expect(rows.find((row) => row.id === 'going')!.status).toBe('retired')
    expect(rows.find((row) => row.id === 'going')!.imageUrl).toBe('a.png')
    expect(rows.find((row) => row.id === 'staying')!.imageUrl).toBe('b.png')
  })

  test("without `rewrite` an existing item's words are left exactly alone", async () => {
    // The default, and the branch every other case here skips by passing `rewrite`.
    // A re-seed that is not asking to relabel must not relabel: the canonical use is
    // adding one new template to a document a person has since edited by hand.
    const id = scratch()
    await applyContent(
      id as never,
      [{ id: 'held', order: 0, status: 'active', text: 'As it was' } as never],
      REVIEW,
    )

    await applyContent(
      id as never,
      [
        { id: 'held', order: 0, status: 'active', text: 'Overwritten' } as never,
        { id: 'added', order: 1, status: 'active', text: 'New' } as never,
      ],
      REVIEW,
    )

    const items = (await readContent(id as never)) as Nudge[]
    expect(items.map((i) => i.id)).toEqual(['held', 'added'])
    expect(items[0]!.text).toBe('As it was')
    expect(items[1]!.text).toBe('New')
  })

  test('retiring says whether it did anything', async () => {
    // Both falsey answers, because the caller is a script deciding what to report.
    const id = scratch()
    await applyContent(id as never, [{ id: 'here', order: 0, status: 'active' }], REVIEW)

    expect(await retireContent(id as never, 'not-a-real-id')).toBe(false)
    expect(await retireContent(id as never, 'here')).toBe(true)
    expect(await retireContent(id as never, 'here')).toBe(false)
  })

  test('a re-seed does not un-retire what somebody retired', async () => {
    // `applyContent`'s rewrite branch keeps the stored `status` on purpose, and the
    // comment saying so had no test: dropping it leaves every other case green. The
    // seed ships every item as `active`, so without this a routine `bun run
    // seed:content` would quietly put a withdrawn card back in front of users.
    const id = scratch()
    await applyContent(id as never, [{ id: 'pulled', order: 0, status: 'active' }], REVIEW)
    expect(await retireContent(id as never, 'pulled')).toBe(true)

    await applyContent(id as never, [{ id: 'pulled', order: 0, status: 'active' }], REVIEW, {
      rewrite: true,
    })

    const items = (await readContent(id as never)) as { id: string; status: string }[]
    expect(items.find((i) => i.id === 'pulled')?.status).toBe('retired')
  })

  test('nothing is deleted, only retired — a cached card still resolves', async () => {
    const id = scratch()
    await applyContent(
      id as never,
      [
        { id: 'gone', order: 0, status: 'active' },
        { id: 'kept', order: 1, status: 'active' },
      ],
      REVIEW,
    )

    // Re-seeding without it must not remove it...
    await applyContent(id as never, [{ id: 'kept', order: 1, status: 'active' }], REVIEW, {
      rewrite: true,
    })
    expect(((await readContent(id as never)) as { id: string }[]).map((i) => i.id)).toEqual([
      'gone',
      'kept',
    ])

    // ...and retiring keeps it resolvable rather than dropping it.
    expect(await retireContent(id as never, 'gone')).toBe(true)
    const after = (await readContent(id as never)) as { id: string; status: string }[]
    expect(after.find((i) => i.id === 'gone')?.status).toBe('retired')
  })
})

describe('tone and framing, checkable on the seed', () => {
  /** Every user-facing string the seed ships. */
  const strings = [
    ...TEMPLATES.flatMap((t) => [t.kicker, t.title, t.line2, t.line3, t.meta, ...t.actions]),
    ...BANNERS.flatMap((b) => [b.title, b.meta]),
    ...NUDGES.flatMap((n) => [n.text, n.sub, n.action]),
  ].filter((s): s is string => typeof s === 'string')

  test("every string the seed ships is the canvas' string", async () => {
    // "Verbatim from the canvas" is the seed's central claim and nothing checked it:
    // the other cases here compare the seed to itself. This compares it to the file.
    // The canvas escapes its punctuation (`\u2019`, `\u2014`), so it is unescaped
    // first, and a string carrying a `{slot}` is checked fragment by fragment, because
    // the canvas holds a rendered example where the seed holds a placeholder.
    // `import.meta.dir`, not a `URL().pathname`: the canvas' filename has a space in
    // it, and a URL pathname percent-encodes it into a path that does not exist.
    const raw = await Bun.file(`${import.meta.dir}/../../docs/design/Eva App.dc.html`).text()
    const canvas = raw.replace(/\\u([0-9a-fA-F]{4})/g, (_, hex: string) =>
      String.fromCharCode(parseInt(hex, 16)),
    )

    const fragments = strings.flatMap((line) =>
      line
        .split(/\{\w+\}/)
        .map((fragment) => fragment.trim())
        .filter((fragment) => fragment.length > 3),
    )
    // The exact count, not a floor: a floor with slack in it lets a dozen strings be
    // deleted from the seed without a signal, which is the other way copy drifts.
    //
    // **94 → 93 in #177, and the one that went is arithmetic rather than copy.** That
    // change rewrote twelve strings across five cards and every one of them is slotless,
    // so each contributes exactly one fragment before and after. The exception is
    // `home_flag`'s kicker: `'Logged {loggedAt} today'` split either side of the slot
    // into `Logged` and `today`, and `'Logged {loggedAt}'` leaves only `Logged`. The
    // other half of this case — that every fragment is in the canvas — held at 93 of 93
    // through that change, which is the half that says the seed still transcribes the
    // drawing.
    expect(fragments).toHaveLength(93)
    for (const fragment of fragments) expect(canvas).toContain(fragment)
  })

  test('the app describes tendencies, never destiny', () => {
    // PRD §Dashboard. "you will" is the phrasing that turns a tendency into a promise.
    // The apostrophe is normalised first: the seed writes curly ones throughout
    // (`night’s`, `You’ve`, `haven’t`), so a straight-quote-only check would
    // miss `You’ll` — which is the spelling this copy would actually use.
    const flat = (line: string) => line.toLowerCase().replace(/[‘’ʼʹ＇`´]/g, "'")
    for (const line of strings) {
      expect(flat(line)).not.toContain('you will')
      expect(flat(line)).not.toContain("you'll")
    }
    // And the normalisation itself works, so this cannot quietly stop catching things.
    for (const quote of ['’', '‘', '＇', 'ʼ']) {
      expect(flat(`You${quote}ll feel better`)).toContain("you'll")
    }
  })

  test('every phase template has a hedged variant, and it is the only one at that rung', () => {
    // C11: a phase estimate without confirmed ovulation is approximate, and the wording
    // has to say so rather than asserting the phase as fact.
    const phase = TEMPLATES.filter((t) => t.rung === 'phase')
    expect(phase.length).toBeGreaterThan(0)
    for (const template of phase) expect(template.confidence).toBe('hedged')
  })

  test('no slot for a score, a streak or a comparison', () => {
    // "No comparison to other users, no scores for the person, no streaks." The slot
    // vocabulary is enumerated, so introducing one needs a code change and a review —
    // it cannot arrive by editing a Firestore document.
    const forbidden = ['score', 'streak', 'rank', 'percentile', 'average', 'compare', 'versus']
    for (const slot of SLOTS) {
      for (const word of forbidden) expect(slot.toLowerCase()).not.toContain(word)
    }
    // And every slot a template references exists in the vocabulary.
    for (const template of TEMPLATES) {
      for (const slot of template.slots) {
        expect(SLOTS as readonly string[]).toContain(slot)
      }
    }
  })

  test("every placeholder in a template's strings is a declared slot", () => {
    // A template that referenced `{streak}` would render it literally rather than being
    // refused, so the check is that the two lists agree.
    for (const template of TEMPLATES) {
      const used = [template.kicker, template.title, template.line2, template.line3, template.meta]
        .filter((s): s is string => typeof s === 'string')
        .flatMap((s) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]!))
      for (const placeholder of used) {
        expect(template.slots as readonly string[]).toContain(placeholder)
      }
    }
  })

  test('the red-flag card points at care and does not interpret', () => {
    const flag = TEMPLATES.find((t) => t.rung === 'flag')!
    expect(flag.line2).toContain('Eva cannot assess this')
    expect(flag.actions[0]).toBe('View contact options')
  })
})

describe('the collection the API reads', () => {
  test('it serves the three documents it names and ignores anything else', async () => {
    // A scratch document is in the collection throughout this file. It must not appear
    // in what `GET /content` returns.
    const id = scratch()
    await applyContent(id as never, [{ id: 'stray', order: 0, status: 'active' }], REVIEW)
    invalidateContentCache()

    const body = await json<ContentBody>(await api('/content'))

    expect(CONTENT_IDS).toEqual(['templates', 'banners', 'nudges'])
    const ids = [
      ...body.templates.map((t) => t.id),
      ...body.banners.map((b) => b.id),
      ...body.nudges.map((n) => n.id),
    ]
    expect(ids).not.toContain('stray')
  })

  test('a slot the vocabulary does not hold is dropped on the way out', () => {
    // The mechanism behind "no scores, no streaks, no comparison". A document can
    // reach this collection without passing `applyContent` — someone editing in the
    // Firebase console — so the parser is where it is enforced, and the document
    // below is one no writer in this repo would produce.
    const [template] = parseItems('templates', {
      items: [
        {
          id: 'invented',
          rung: 'phase',
          mode: 'cycle',
          state: 'home_x',
          confidence: 'plain',
          title: 'You are ahead of 80% of users',
          actions: [],
          slots: ['cycleDay', 'streakDays', 'percentile'],
          status: 'active',
          order: 0,
        },
      ],
    }) as Template[]

    expect(template!.slots).toEqual(['cycleDay'])
    // The card itself still comes through: the store serves what is there, it does
    // not sit in judgement of the words. The slot list is the one thing code decides.
    expect(template!.title).toBe('You are ahead of 80% of users')
  })

  test('the parser sorts by order, then by id', () => {
    // What the client draws top to bottom. Firestore returns array elements in stored
    // order, so without this the rail's order would be whoever wrote the document last.
    const items = parseItems('nudges', {
      items: [
        { id: 'c', order: 2, status: 'active' },
        { id: 'b', order: 1, status: 'active' },
        { id: 'a', order: 1, status: 'active' },
      ],
    }) as Nudge[]

    expect(items.map((n) => n.id)).toEqual(['a', 'b', 'c'])
  })

  test('a repeated id is served once, not twice', () => {
    // `applyContent` dedupes on the way in; a document edited in the console can still
    // hold the same id twice, and a card drawn twice is not something a client can
    // unpick from "ids are permanent and opaque".
    const items = parseItems('nudges', {
      items: [
        { id: 'same', order: 0, status: 'active', text: 'First' },
        { id: 'same', order: 1, status: 'active', text: 'Second' },
      ],
    }) as Nudge[]

    expect(items).toHaveLength(1)
    expect(items[0]!.text).toBe('First')
  })

  test('a template with no confidence is read as hedged, not as fact', () => {
    // The cautious default matters for exactly the documents this repo did not write:
    // an unlabelled phase template read as `plain` would let D1 state an estimate as
    // something observed.
    const [template] = parseItems('templates', {
      items: [{ id: 'unlabelled', order: 0, status: 'active', title: 'A phase card' }],
    }) as Template[]

    expect(template!.confidence).toBe('hedged')
  })

  test('the served version is the hash of what was served', async () => {
    // End to end, across the process boundary: the client's whole cache contract is
    // that it can recompute nothing and simply trust `version` to move exactly when the
    // words do. Written so it holds seeded or not — the real project is unseeded until
    // a clinician signs the copy, and this must not become a test of that.
    const body = await json<ContentBody>(await api('/content'))

    expect(body.version).toBe(
      contentVersion({
        templates: body.templates,
        banners: body.banners,
        nudges: body.nudges,
      }),
    )
  })

  test('an unseeded collection is an empty bundle, not an error', async () => {
    // The real project has no `content/` documents yet — the seed refuses until the copy
    // is signed. `GET /content` still has to answer, so the app can launch. Skipped
    // rather than inverted once someone seeds it: the claim is about the empty case.
    const body = await json<ContentBody>(await api('/content'))
    if (body.templates.length + body.banners.length + body.nudges.length > 0) return

    expect(body.version).toBe(contentVersion({ templates: [], banners: [], nudges: [] }))
    expect(body.templates).toEqual([])
  })
})

/**
 * The read path with something in it — **emulators only**.
 *
 * Every case above runs against three empty arrays, because the real project's `content/`
 * is unseeded and stays that way until a clinician signs the copy. That left the half of
 * the module that matters untested: the sort, the cache, "a retired item is still served",
 * and the `ETag` a client actually revalidates against. Seeding to get that coverage is
 * fine against an emulator, whose Firestore is a throwaway, and is not fine against the
 * real project, where it would put copy nobody reviewed in front of whoever is looking —
 * which is the thing this whole collection exists to prevent. CI runs `scripts/ci-api.sh`,
 * so these are enforced on every PR; a local `bun run verify` skips them and says so.
 *
 * The three documents it writes are the three the API serves. It deletes them afterwards.
 */
// Both hosts, not either: `config.ts` refuses to boot with only one set (#67), so this is
// belt and braces — but the thing it is bracing against is writing the three documents the
// API serves into the real project, so it is worth the second read.
const onEmulators = Boolean(
  process.env.FIREBASE_AUTH_EMULATOR_HOST && process.env.FIRESTORE_EMULATOR_HOST,
)

describe.skipIf(!onEmulators)('served from a seeded collection', () => {
  /** Retired in the seed itself, because the server caches for 60s and a test process
   *  cannot reach into it: retiring afterwards would not be visible over the route. */
  const RETIRED = 'post_sleep'

  let served: ContentBody
  let etag: string
  /** What `beforeAll` actually wrote. The teardown below follows this rather than
   *  `CONTENT_IDS`, so that it deletes the three documents the API serves only if this
   *  block is the thing that put them there. Iterating the constant instead would leave
   *  one framework semantic — that a skipped `describe` does not run its hooks — between
   *  a real-project `bun run verify` and deleting the live Dashboard copy. */
  const seeded: (typeof CONTENT_IDS)[number][] = []

  beforeAll(async () => {
    // Asserted rather than assumed. `describe.skipIf` already stops this block, but the
    // thing it stops is a write to the three documents the API serves — too large a
    // consequence to rest on one framework's hook semantics for a skipped describe.
    if (!onEmulators) return
    await applyContent('templates', TEMPLATES, REVIEW, { rewrite: true })
    seeded.push('templates')
    await applyContent(
      'banners',
      BANNERS.map((b) => (b.id === RETIRED ? { ...b, status: 'retired' as const } : b)),
      REVIEW,
      { rewrite: true },
    )
    seeded.push('banners')
    await applyContent('nudges', NUDGES, REVIEW, { rewrite: true })
    seeded.push('nudges')

    // The first request after seeding, and it must already have the copy: the empty
    // bundle is deliberately the one result `getContent` does not cache, so an instance
    // is serving real words within a request of the seed rather than a minute later.
    const res = await api('/content')
    // Asserted here rather than left to the cases below: a 401 or a 500 would otherwise
    // surface as five "undefined has no length" failures with nothing naming the cause.
    expect(res.status).toBe(200)
    served = await json<ContentBody>(res)
    const header = res.headers.get('etag')
    expect(header).toBeTruthy()
    etag = header!
  }, 60_000)

  afterAll(async () => {
    if (!onEmulators) return
    for (const id of seeded)
      await collection()
        .doc(id)
        .delete()
        .catch(() => {})
  })

  test("the seed's copy reaches the wire, all 27 items of it", () => {
    expect(served.templates).toHaveLength(TEMPLATES.length)
    expect(served.banners).toHaveLength(BANNERS.length)
    expect(served.nudges).toHaveLength(NUDGES.length)
    expect(served.templates.map((t) => t.id)).toEqual(TEMPLATES.map((t) => t.id))
    // Not just the ids: the words, which is the only reason the collection exists.
    expect(served.templates[0]!.title).toBe(TEMPLATES[0]!.title)
    expect(served.nudges.find((n) => n.id === 'period_due')!.text).toBe(
      NUDGES.find((n) => n.id === 'period_due')!.text,
    )
  })

  test('a retired item is still served, flagged rather than dropped', () => {
    // A card the device rendered yesterday still has to resolve. Retirement takes an
    // item out of what is *offered*, not out of what exists.
    const retired = served.banners.find((b) => b.id === RETIRED)
    expect(retired).toBeDefined()
    expect(retired!.status).toBe('retired')
    expect(served.banners.filter((b) => b.status === 'active')).toHaveLength(BANNERS.length - 1)
  })

  test('items arrive in the order the rail draws them', () => {
    for (const list of [served.templates, served.banners, served.nudges]) {
      const orders = list.map((item) => item.order)
      expect(orders).toEqual([...orders].sort((a, b) => a - b))
    }
  })

  test('the version and the ETag are the hash of the copy that came back', () => {
    expect(served.version).toBe(
      contentVersion({
        templates: served.templates,
        banners: served.banners,
        nudges: served.nudges,
      }),
    )
    expect(etag).toBe(`"${served.version}"`)
  })

  test('and a client holding it revalidates to a 304 with no body', async () => {
    const res = await api('/content', { headers: { 'if-none-match': etag } })

    expect(res.status).toBe(304)
    expect(await res.text()).toBe('')
    // A `?version=` carrying the same value answers identically — the two doors on the
    // same handshake, which nothing else compares.
    const byQuery = await api(`/content?version=${served.version}`)
    expect(byQuery.status).toBe(304)
  })

  test('re-seeding the identical words does not move the version', async () => {
    // The property the whole cache rests on: an idempotent re-seed must not invalidate
    // every device's copy. Read through `getContent`'s own cache-free path rather than
    // the route, which is holding a 60s snapshot by now.
    await applyContent('templates', TEMPLATES, REVIEW, { rewrite: true })
    await applyContent('nudges', NUDGES, REVIEW, { rewrite: true })

    // Re-read all three rather than reusing what the route returned: a write that
    // stamped something onto every row would otherwise be invisible in the two arrays
    // this case did not refresh.
    const [templates, banners, nudges] = await Promise.all([
      readContent('templates') as Promise<Template[]>,
      readContent('banners') as Promise<Banner[]>,
      readContent('nudges') as Promise<Nudge[]>,
    ])
    expect(contentVersion({ templates, banners, nudges })).toBe(served.version)
  })
})
