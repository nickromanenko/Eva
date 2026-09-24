import type { EvaEvent } from './events'
import type { TodayDocument } from './today'
import type { User } from './users'

/**
 * The body of `GET /me/export` (#58): everything Eva holds about one account, as one JSON
 * document written out a page at a time.
 *
 * A pure leaf, like `request-timeout.ts`: no Firestore, no clock, no `fetch`, no log line.
 * The route reads the account, hands in the two owning modules' page generators
 * (`exportEvents`, `exportTodayCards`) and the instant it stamps, and this turns them into
 * bytes. Its three imports are `import type`, so it reaches nothing at runtime.
 *
 * **What a truncated body looks like is the design.** Once the headers are out, a read that
 * fails can no longer become a `{ error }` response. So:
 *
 * - `openExport` reads the **first page of both collections before it returns**, and the
 *   account was read by the gate before that. A Firestore that is down at the start is
 *   therefore an ordinary throw at the route — `app.onError`'s `500 INTERNAL` in the usual
 *   shape — and never a `200` with half a body. Only a failure on a *later* page reaches the
 *   stream.
 * - The document's closing `]}` is written last and only after every page has been read, so
 *   a body cut short anywhere is never valid JSON. A client that parses the download cannot
 *   mistake a partial export for a complete one; there is no "complete" flag to forget to
 *   check, because the brackets are the flag.
 * - A failure errors the stream (Bun then abandons the response) with a constant error of
 *   ours, never the one Firestore threw: the runtime prints a stream's error, and a Firestore
 *   message can carry a document path, which is a uid (ARCHITECTURE §3, #48). The real error
 *   goes to `onAbort`, where the route decides what may be logged — its class name, nothing
 *   else.
 */

export const EXPORT_FORMAT = 'eva-export'

/** Bumped when a field's meaning changes or a field is removed; adding one is not a bump,
 *  because a reader that ignores unknown keys still reads the old document correctly. */
export const EXPORT_VERSION = 1

/** `eva-export-YYYY-MM-DD.json`, the UTC date of the stamp — the same instant the body's
 *  `exportedAt` carries, so the file and its contents can never name different days. */
export const exportFilename = (exportedAt: string): string =>
  `eva-export-${exportedAt.slice(0, 10)}.json`

export interface ExportSource {
  /** ISO-8601, system time. Stamped once by the route. */
  exportedAt: string
  /** Exactly what `GET /me` answers with — `User` already leaves the session generation,
   *  the activation and deletion instants and the audit stamps behind (`users.ts`). */
  account: User
  /** Every event, soft-deleted included, a page at a time (`exportEvents`). */
  events: AsyncGenerator<EvaEvent[], void, undefined>
  /** Every stored Today card, a page at a time (`exportTodayCards`). */
  today: AsyncGenerator<TodayDocument[], void, undefined>
  /** Told about a failure after the headers were sent — the stream's only caller-visible
   *  trace of it. Never handed anything that reached the body. */
  onAbort: (err: unknown) => void
}

/** The error the stream is failed with. Constant, so the runtime has nothing of ours or
 *  Firestore's to print. */
export class ExportAbortedError extends Error {
  constructor() {
    super('export aborted')
    this.name = 'ExportAbortedError'
  }
}

type Page<T> = IteratorResult<T[], void>

/** `, `-joined elements of one page, with the separator a previous page needs. */
const joinPage = <T>(items: readonly T[], afterAnother: boolean): string =>
  (afterAnother ? ',' : '') + items.map((item) => JSON.stringify(item)).join(',')

async function* arrayBody<T>(
  first: Page<T>,
  rest: AsyncGenerator<T[], void, undefined>,
): AsyncGenerator<string, void, undefined> {
  let written = false
  const emit = (items: readonly T[]): string | null => {
    if (items.length === 0) return null
    const chunk = joinPage(items, written)
    written = true
    return chunk
  }
  if (first.done) return
  const head = emit(first.value)
  if (head !== null) yield head
  for await (const page of rest) {
    const chunk = emit(page)
    if (chunk !== null) yield chunk
  }
}

/**
 * Reads the first page of each collection, then returns a stream that writes the whole
 * document and reads each later page only when the consumer asks for more (`pull`), so one
 * page is in memory at a time however large the account is.
 *
 * Throws — before any byte exists — if either first read fails. Key order is fixed:
 * `format`, `version`, `exportedAt`, `account`, `events`, `today`.
 */
export const openExport = async (source: ExportSource): Promise<ReadableStream<Uint8Array>> => {
  const { exportedAt, account, events, today, onAbort } = source
  let firstEvents: Page<EvaEvent>
  let firstToday: Page<TodayDocument>
  try {
    firstEvents = await events.next()
    firstToday = await today.next()
  } catch (err) {
    // Release whichever generator is still open; the caller answers the throw.
    await Promise.allSettled([events.return(), today.return()])
    throw err
  }

  const head = JSON.stringify({
    format: EXPORT_FORMAT,
    version: EXPORT_VERSION,
    exportedAt,
    account,
  })
  async function* chunks(): AsyncGenerator<string, void, undefined> {
    yield `${head.slice(0, -1)},"events":[`
    yield* arrayBody(firstEvents, events)
    yield '],"today":['
    yield* arrayBody(firstToday, today)
    yield ']}'
  }

  const encoder = new TextEncoder()
  const body = chunks()
  return new ReadableStream<Uint8Array>({
    pull: async (controller) => {
      try {
        const next = await body.next()
        if (next.done) controller.close()
        else controller.enqueue(encoder.encode(next.value))
      } catch (err) {
        onAbort(err)
        controller.error(new ExportAbortedError())
      }
    },
    // The client went away: stop reading. `return()` unwinds `chunks`, whose `for await`
    // returns the page generator it was suspended in.
    cancel: async () => {
      await body.return()
    },
  })
}
