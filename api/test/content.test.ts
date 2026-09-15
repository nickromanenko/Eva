import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { FieldValue } from "firebase-admin/firestore";
import { firestore } from "../src/firebase";
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
} from "../src/content";
import { BANNERS, NUDGES, TEMPLATES } from "../scripts/seed-content";
import { signUpActivated } from "./support/session";

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
setDefaultTimeout(20_000);

const BASE = process.env.EVA_API_URL ?? "http://localhost:3003";
const PASSWORD = "correct-horse-8";

/** The signature these tests write with. A real one lives in the seed, in a commit. */
const REVIEW: Review = {
    reviewedBy: "content.test.ts",
    reviewedAt: "2026-09-16",
    source: "docs/design/Eva App.dc.html — Dashboard rail",
};

const collection = () => firestore.collection("content");

let token = "";
let uid = "";
const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
/** Documents this file created, so the sweep leaves the project as it found it. */
const createdDocs: string[] = [];

const api = (path: string, init?: RequestInit & { token?: string | null }) =>
    fetch(`${BASE}${path}`, {
        ...init,
        headers: {
            "content-type": "application/json",
            ...(init?.token === null ? {} : { authorization: `Bearer ${init?.token ?? token}` }),
            ...(init?.headers ?? {}),
        },
    });

interface ContentBody {
    version: string;
    templates: Template[];
    banners: Banner[];
    nudges: Nudge[];
}
const json = <T>(res: Response): Promise<T> => res.json() as Promise<T>;

/** A scratch document id, so nothing here writes over the three the API serves. */
const scratch = () => {
    const id = `test-${crypto.randomUUID()}`;
    createdDocs.push(id);
    return id;
};

beforeAll(async () => {
    const session = await signUpActivated(BASE, email, PASSWORD);
    token = session.token;
    uid = session.uid;
}, 60_000);

afterAll(async () => {
    for (const id of createdDocs) await collection().doc(id).delete().catch(() => {});
    if (uid) {
        await firestore.collection("users").doc(uid).delete().catch(() => {});
        const { adminAuth } = await import("../src/firebase");
        await adminAuth.deleteUser(uid).catch(() => {});
    }
    const rows = await firestore.collection("authTokens").where("email", "==", email).get();
    for (const row of rows.docs) await row.ref.delete().catch(() => {});
});

describe("GET /content", () => {
    test("requires a bearer token", async () => {
        const res = await api("/content", { token: null });
        expect(res.status).toBe(401);
    });

    test("serves the three kinds", async () => {
        const body = await json<ContentBody>(await api("/content"));
        expect(Object.keys(body).sort()).toEqual(["banners", "nudges", "templates", "version"]);
        expect(body.version).toMatch(/^[0-9a-f]{16}$/);
    });

    test("a client holding the current version gets 304 and no body", async () => {
        const { version } = await json<ContentBody>(await api("/content"));

        const res = await api(`/content?version=${version}`);

        expect(res.status).toBe(304);
        expect(await res.text()).toBe("");
    });

    test("a stale version gets the bundle back", async () => {
        const res = await api("/content?version=0000000000000000");
        expect(res.status).toBe(200);
    });

    test("If-None-Match works the same way, weak or strong", async () => {
        const { version } = await json<ContentBody>(await api("/content"));

        for (const header of [`"${version}"`, `W/"${version}"`]) {
            const res = await api("/content", { headers: { "if-none-match": header } });
            expect(res.status).toBe(304);
        }
    });
});

describe("the version is a hash of the content", () => {
    test("changing one template's line2 changes it; rewriting the same words does not", async () => {
        const base = { templates: TEMPLATES, banners: BANNERS, nudges: NUDGES };
        const first = contentVersion(base);

        expect(contentVersion({ ...base, templates: [...TEMPLATES] })).toBe(first);

        const edited = TEMPLATES.map((t, i) =>
            i === 0 ? { ...t, line2: `${t.line2} And one more sentence.` } : t,
        );
        expect(contentVersion({ ...base, templates: edited })).not.toBe(first);
    });

    test("re-signing the same copy is not a content change", () => {
        // Review metadata is deliberately outside the hash: making a re-review push a new
        // bundle to every device would punish the thing the store exists to encourage.
        const base = { templates: TEMPLATES, banners: BANNERS, nudges: NUDGES };
        const before = contentVersion(base);

        // `contentVersion` takes only the items, so this is structural — the signature has
        // nowhere to enter the hash from.
        expect(contentVersion({ ...base })).toBe(before);
    });
});

describe("copy nobody signed is not servable", () => {
    test("the module refuses a write with no reviewer", async () => {
        const id = scratch();
        for (const incomplete of [
            { reviewedBy: "", reviewedAt: "2026-09-16", source: "canvas" },
            { reviewedBy: "Someone", reviewedAt: "", source: "canvas" },
            { reviewedBy: "Someone", reviewedAt: "2026-09-16", source: "" },
            { reviewedBy: "   ", reviewedAt: "2026-09-16", source: "canvas" },
        ]) {
            await expect(
                applyContent(id as never, [], incomplete as Review),
            ).rejects.toBeInstanceOf(UnreviewedContentError);
        }

        // And nothing was written on the way to refusing.
        expect((await collection().doc(id).get()).exists).toBe(false);
    });

    test("the seed script refuses too, and no argument or env var gets past it", async () => {
        // Driven as a process, because the refusal is the script's exit status — not
        // something a caller could catch and ignore. The two escape hatches a hurried
        // operator would reach for are tried here, so adding either one fails this.
        const run = async (args: string[], env: Record<string, string>) => {
            const proc = Bun.spawn(["bun", "run", "scripts/seed-content.ts", ...args], {
                cwd: new URL("..", import.meta.url).pathname,
                env: { ...process.env, ...env },
                stdout: "pipe",
                stderr: "pipe",
            });
            const [out, err, code] = await Promise.all([
                new Response(proc.stdout).text(),
                new Response(proc.stderr).text(),
                proc.exited,
            ]);
            return { out, err, code };
        };

        for (const [args, env] of [
            [[], {}],
            [["--skip-review"], {}],
            [["--force"], {}],
            [[], { SKIP_REVIEW: "1" }],
        ] as [string[], Record<string, string>][]) {
            const { out, err, code } = await run(args, env);
            expect(code).toBe(1);
            expect(err).toContain("Refusing to seed");
            expect(out).not.toContain("seeded content/");
        }
    });

    test("a signature is stored beside the items, not inside them", async () => {
        const id = scratch();
        await applyContent(id as never, [{ id: "x", order: 0, status: "active" }], REVIEW);

        const doc = (await collection().doc(id).get()).data()!;
        expect(doc.reviewedBy).toBe(REVIEW.reviewedBy);
        expect(doc.source).toBe(REVIEW.source);
        expect(doc.items).toHaveLength(1);
        expect(doc.items[0].reviewedBy).toBeUndefined();
    });

    test("reviewProblems names every missing field at once", () => {
        // So the seed can report all three rather than one write at a time.
        expect(reviewProblems({})).toEqual(["reviewedBy", "reviewedAt", "source"]);
        expect(reviewProblems(REVIEW)).toEqual([]);
    });
});

describe("the seed carries the canvas copy", () => {
    test("every CARDS key the canvas draws has a template", () => {
        // The canvas' 14 `CARDS` variants. Named here rather than counted, so adding a
        // template does not silently satisfy a missing one.
        const states = TEMPLATES.map((t) => t.state).sort();
        expect(states).toEqual(
            [
                "home_a", "home_b", "home_c", "home_d", "home_e", "home_edu", "home_f",
                "home_flag", "home_g", "home_h", "home_loss", "home_plan", "home_post",
                "home_preg",
            ].sort(),
        );
    });

    test("nine banner items, three per phase", () => {
        expect(BANNERS).toHaveLength(9);
        for (const phase of ["cycle", "pregnancy", "postpartum"]) {
            expect(BANNERS.filter((b) => b.phase === phase)).toHaveLength(3);
        }
    });

    test("the four nudge rules carry the PRD's parameters and nothing else", () => {
        expect(NUDGES.map((n) => [n.id, n.withinDays])).toEqual([
            ["period_due", 2],          // period within two days
            ["appointment_tomorrow", 1], // appointment tomorrow
            ["logging_gap", 3],          // a three-day logging gap
            ["nutrition_setup", null],   // a setup step never completed — no number
        ]);
    });

    test("ids are permanent, so relabelling copy leaves them alone", async () => {
        // A device caches a rendered card pointing at a template id. Changing what a card
        // *says* must never change what it *is*.
        const id = scratch();
        const first = [{ id: "phase_energy", order: 0, status: "active" as const, title: "One" }];
        await applyContent(id as never, first as never, REVIEW);

        const relabelled = [{ id: "phase_energy", order: 0, status: "active" as const, title: "Two" }];
        await applyContent(id as never, relabelled as never, REVIEW, { rewrite: true });

        const items = (await collection().doc(id).get()).data()!.items;
        expect(items).toHaveLength(1);
        expect(items[0].id).toBe("phase_energy");
        expect(items[0].title).toBe("Two");
    });

    test("nothing is deleted, only retired — a cached card still resolves", async () => {
        const id = scratch();
        await applyContent(
            id as never,
            [{ id: "gone", order: 0, status: "active" }, { id: "kept", order: 1, status: "active" }],
            REVIEW,
        );

        // Re-seeding without it must not remove it...
        await applyContent(id as never, [{ id: "kept", order: 1, status: "active" }], REVIEW, {
            rewrite: true,
        });
        expect(((await readContent(id as never)) as { id: string }[]).map((i) => i.id)).toEqual([
            "gone",
            "kept",
        ]);

        // ...and retiring keeps it resolvable rather than dropping it.
        expect(await retireContent(id as never, "gone")).toBe(true);
        const after = (await readContent(id as never)) as { id: string; status: string }[];
        expect(after.find((i) => i.id === "gone")?.status).toBe("retired");
    });
});

describe("tone and framing, checkable on the seed", () => {
    /** Every user-facing string the seed ships. */
    const strings = [
        ...TEMPLATES.flatMap((t) => [t.kicker, t.title, t.line2, t.line3, t.meta, ...t.actions]),
        ...BANNERS.flatMap((b) => [b.title, b.meta]),
        ...NUDGES.flatMap((n) => [n.text, n.sub, n.action]),
    ].filter((s): s is string => typeof s === "string");

    test("the app describes tendencies, never destiny", () => {
        // PRD §Dashboard. "you will" is the phrasing that turns a tendency into a promise.
        for (const line of strings) {
            expect(line.toLowerCase()).not.toContain("you will");
            expect(line.toLowerCase()).not.toContain("you'll");
        }
    });

    test("every phase template has a hedged variant, and it is the only one at that rung", () => {
        // C11: a phase estimate without confirmed ovulation is approximate, and the wording
        // has to say so rather than asserting the phase as fact.
        const phase = TEMPLATES.filter((t) => t.rung === "phase");
        expect(phase.length).toBeGreaterThan(0);
        for (const template of phase) expect(template.confidence).toBe("hedged");
    });

    test("no slot for a score, a streak or a comparison", () => {
        // "No comparison to other users, no scores for the person, no streaks." The slot
        // vocabulary is enumerated, so introducing one needs a code change and a review —
        // it cannot arrive by editing a Firestore document.
        const forbidden = ["score", "streak", "rank", "percentile", "average", "compare", "versus"];
        for (const slot of SLOTS) {
            for (const word of forbidden) expect(slot.toLowerCase()).not.toContain(word);
        }
        // And every slot a template references exists in the vocabulary.
        for (const template of TEMPLATES) {
            for (const slot of template.slots) {
                expect(SLOTS as readonly string[]).toContain(slot);
            }
        }
    });

    test("every placeholder in a template's strings is a declared slot", () => {
        // A template that referenced `{streak}` would render it literally rather than being
        // refused, so the check is that the two lists agree.
        for (const template of TEMPLATES) {
            const used = [template.kicker, template.title, template.line2, template.line3, template.meta]
                .filter((s): s is string => typeof s === "string")
                .flatMap((s) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]!));
            for (const placeholder of used) {
                expect(template.slots as readonly string[]).toContain(placeholder);
            }
        }
    });

    test("the red-flag card points at care and does not interpret", () => {
        const flag = TEMPLATES.find((t) => t.rung === "flag")!;
        expect(flag.line2).toContain("Eva cannot assess this");
        expect(flag.actions[0]).toBe("View contact options");
    });
});

describe("the collection the API reads", () => {
    test("it serves the three documents it names and ignores anything else", async () => {
        // A scratch document is in the collection throughout this file. It must not appear
        // in what `GET /content` returns.
        const id = scratch();
        await applyContent(id as never, [{ id: "stray", order: 0, status: "active" }], REVIEW);
        invalidateContentCache();

        const body = await json<ContentBody>(await api("/content"));

        expect(CONTENT_IDS).toEqual(["templates", "banners", "nudges"]);
        const ids = [
            ...body.templates.map((t) => t.id),
            ...body.banners.map((b) => b.id),
            ...body.nudges.map((n) => n.id),
        ];
        expect(ids).not.toContain("stray");
    });

    test("a slot the vocabulary does not hold is dropped on the way out", () => {
        // The mechanism behind "no scores, no streaks, no comparison". A document can
        // reach this collection without passing `applyContent` — someone editing in the
        // Firebase console — so the parser is where it is enforced, and the document
        // below is one no writer in this repo would produce.
        const [template] = parseItems("templates", {
            items: [
                {
                    id: "invented",
                    rung: "phase",
                    mode: "cycle",
                    state: "home_x",
                    confidence: "plain",
                    title: "You are ahead of 80% of users",
                    actions: [],
                    slots: ["cycleDay", "streakDays", "percentile"],
                    status: "active",
                    order: 0,
                },
            ],
        }) as Template[];

        expect(template!.slots).toEqual(["cycleDay"]);
        // The card itself still comes through: the store serves what is there, it does
        // not sit in judgement of the words. The slot list is the one thing code decides.
        expect(template!.title).toBe("You are ahead of 80% of users");
    });

    test("an unseeded collection is an empty bundle, not an error", async () => {
        // The real project has no `content/` documents yet — the seed refuses until the copy
        // is signed. `GET /content` still has to answer, so the app can launch.
        const body = await json<ContentBody>(await api("/content"));
        expect(Array.isArray(body.templates)).toBe(true);
        expect(typeof body.version).toBe("string");
    });
});
