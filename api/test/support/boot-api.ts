/**
 * Boots an Eva API process on a free port and waits until *that* child answers.
 *
 * `today.test.ts` and `events.test.ts` each carried a private copy of this, and the copies
 * disagreed on two things (#199):
 *
 * - the free-port draw has to *ask* whether anything answers and refuse when the range is
 *   exhausted, rather than adopt whatever happens to answer `Eva API`; and
 * - the wait has to stop when the child dies *either* way — an exit code (a bind failure,
 *   `EADDRINUSE`) **or** a signal (`exitCode` is `null` for a signal-killed child) — so a
 *   killed child cannot leave the helper polling, and then adopting, whatever holds its port.
 *
 * Not a test file: Bun only picks up `*.test.ts`.
 */

/** Ports any boot has drawn in this run, so one is never handed to two processes. A server
 *  stays up for the whole run (its file's `beforeAll`), so "already drawn" and "already free
 *  again" are different things and the first is the one that matters. */
const claimed = new Set<number>()

/** Whether anything at all answers HTTP at `url` — not whether it is an Eva API. */
const answers = (url: string): Promise<boolean> =>
  fetch(`${url}/`)
    .then(() => true)
    .catch(() => false)

export interface BootOptions {
  /** Layered over this process's environment; `PORT` is added on top. */
  env?: Record<string, string>
  /** The port range to draw from, inclusive. */
  range: [number, number]
  /** A port window to exclude by value — the suite server's `EVA_API_PORT..+10`. */
  exclude?: { from: number; to: number }
  /** Names the refusal, so a red run says which helper could not boot. */
  label?: string
  /** Poll iterations before giving up (250ms each). */
  tries?: number
}

export interface BootedApi {
  base: string
  child: ReturnType<typeof Bun.spawn>
}

/** Draws a port in `range` that nothing is answering and that has not already been drawn,
 *  or throws naming the range rather than returning one that answers. */
export const drawPort = async (
  range: [number, number],
  exclude?: { from: number; to: number },
  label = 'bootApi',
): Promise<number> => {
  const [lo, hi] = range
  for (let attempt = 0; attempt < 100; attempt++) {
    const port = lo + Math.floor(Math.random() * (hi - lo + 1))
    if (claimed.has(port)) continue
    if (exclude && port >= exclude.from && port <= exclude.to) continue
    if (await answers(`http://localhost:${port}`)) continue
    claimed.add(port)
    return port
  }
  throw new Error(`${label}: no free port in ${lo}-${hi}`)
}

/** Waits until `child` answers `Eva API` at `base`, stopping — and throwing — the moment the
 *  child dies by exit code **or** signal. Polling on would mean waiting for, or adopting,
 *  whatever else answers there. */
export const waitForApi = async (
  child: ReturnType<typeof Bun.spawn>,
  base: string,
  tries = 60,
  label = 'bootApi',
): Promise<void> => {
  let up = false
  for (let i = 0; i < tries && !up; i++) {
    // A child that has already exited could not have bound, and could not be the thing
    // answering. `signalCode` is the half the older idiom missed: a signal-killed child
    // has `exitCode === null`, so it kept polling on.
    if (child.exitCode !== null || child.signalCode !== null) break
    up = await fetch(`${base}/`)
      .then((r) => r.text())
      .then((t) => t === 'Eva API')
      .catch(() => false)
    if (!up) await Bun.sleep(250)
  }
  if (!up) {
    const state = child.signalCode
      ? `killed by signal ${child.signalCode}`
      : `exited ${child.exitCode ?? 'without a code'}`
    throw new Error(
      `${label}: no Eva API answering at ${base} — the child ${state} (the port may be held by another process)`,
    )
  }
}

/** Boots an Eva API with `env` layered over this process's environment and waits for it.
 *  `config.ts` is read once at import, so a case that needs a different configuration needs
 *  a different *process* — there is no seam short of that. */
export const bootApi = async (options: BootOptions): Promise<BootedApi> => {
  const { env = {}, range, exclude, label = 'bootApi', tries = 60 } = options
  const port = await drawPort(range, exclude, label)
  const child = Bun.spawn(['bun', 'run', 'src/index.ts'], {
    cwd: new URL('../..', import.meta.url).pathname,
    env: { ...process.env, PORT: String(port), ...env },
    // Discarded, not piped: nothing reads a booted child's stdout, and since #263 the server
    // writes one line per request there. An undrained pipe fills at the OS buffer and can
    // stall the child's writes — a hang that would read as the API's, not the harness's.
    stdout: 'ignore',
    stderr: 'pipe',
  })
  const base = `http://localhost:${port}`
  await waitForApi(child, base, tries, label)
  return { base, child }
}
