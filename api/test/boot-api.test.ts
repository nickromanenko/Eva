import { describe, expect, test } from 'bun:test'
import { drawPort, waitForApi } from './support/boot-api'

/**
 * The two properties `boot-api.ts` exists to hold (#199), proved directly rather than
 * inferred from the suites that use the helper:
 *
 * - a port a stranger answers is **refused** (the free-port draw throws), so a case cannot
 *   run against a process it never started; and
 * - a **signal-killed** child ends the wait — `exitCode` is `null` for one, so an idiom that
 *   checked only the exit code would keep polling and then adopt whatever held the port.
 *
 * Neither case boots a real API, so this file runs in every environment.
 */

describe('bootApi', () => {
    test('refuses a port a stranger answers, rather than adopting it', async () => {
        // A decoy that answers "Eva API" on its own port, and a range that can only draw that
        // port: the draw must refuse with a message naming itself, not hand the decoy's URL
        // back as if it had booted it.
        const decoy = Bun.serve({ port: 0, fetch: () => new Response('Eva API') })
        try {
            const port = decoy.port
            if (port === undefined) throw new Error('decoy did not bind a port')
            await expect(drawPort([port, port], undefined, 'bootApi')).rejects.toThrow(
                /bootApi: no free port/,
            )
        } finally {
            decoy.stop(true)
        }
    })

    test('a signal-killed child ends the wait, not adopted', async () => {
        const child = Bun.spawn(['sleep', '30'])
        // SIGTERM: the child exits with `signalCode` set and `exitCode` null — exactly the
        // shape the older idiom did not break on.
        child.kill()
        await child.exited
        await expect(
            waitForApi(child, 'http://localhost:59999', 2, 'bootApi'),
        ).rejects.toThrow(/killed by signal/)
    })
})
