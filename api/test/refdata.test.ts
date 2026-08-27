import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { FieldValue } from "firebase-admin/firestore";
import { adminAuth, firestore } from "../src/firebase";
import {
    CATALOGUE_IDS,
    buildSymptomRules,
    applyCatalogue,
    catalogueVersion,
    readCatalogue,
    retireCode,
    seedIfMissing,
    type Catalogues,
    type OptionItem,
    type SymptomItem,
} from "../src/refdata";
import { DEFAULT_CATALOGUES } from "../scripts/seed-refdata";

/**
 * Integration tests against the REAL Firebase project, same pattern as events.test.ts.
 *
 * Two rules keep this suite from vandalising shared reference data:
 *
 * - It bootstraps with `seedIfMissing`, never `applyCatalogue`. A catalogue is meant to
 *   be edited in Firestore without a deploy (PRD:483); a test run that reset labels to
 *   the ones in the seed file would destroy exactly that property.
 * - Everything that *mutates* a catalogue does it to a throwaway `test-<uuid>` document,
 *   which `GET /refdata` does not serve, so two verify runs cannot collide and a crashed
 *   run leaves no half-retired chip behind.
 */

const BASE = process.env.EVA_API_URL ?? "http://localhost:3003";
const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
const password = "correct-horse-8";
let token = "";
let uid = "";
const tempCatalogues: string[] = [];

const api = (
    path: string,
    init?: RequestInit & { token?: string | null },
) =>
    fetch(`${BASE}${path}`, {
        ...init,
        headers: {
            "content-type": "application/json",
            ...(init?.token === null ? {} : { authorization: `Bearer ${init?.token ?? token}` }),
            ...(init?.headers ?? {}),
        },
    });

const json = <T>(res: Response): Promise<T> => res.json() as Promise<T>;

interface RefDataBody {
    version: string;
    catalogues: Catalogues;
}
interface ErrorResponse {
    error: { code: string; message: string };
}
interface EvaEventBody {
    id: string;
    type: string;
    localDate: string;
    payload: { symptoms?: { code: string; severity: string; value?: string }[] };
    deletedAt: string | null;
}

const todayIn = (timeZone: string): string => {
    const parts = new Intl.DateTimeFormat("en-US", {
        timeZone,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
    }).formatToParts(new Date());
    const part = (name: string) => parts.find((p) => p.type === name)!.value;
    return `${part("year")}-${part("month")}-${part("day")}`;
};

const today = todayIn("UTC");

const eventsCollection = () => firestore.collection("users").doc(uid).collection("events");

const refDataDoc = () => firestore.collection("refdata");

/** A throwaway catalogue document, swept in afterAll. */
const tempCatalogue = (): string => {
    const id = `test-${crypto.randomUUID()}`;
    tempCatalogues.push(id);
    return id;
};

const item = (code: string, label: string, extra: Record<string, unknown> = {}) =>
    ({ code, label, order: 10, status: "active", freeText: false, ...extra }) as OptionItem;

const symptomItem = (code: string, label: string, values: string[] | null = null): SymptomItem => ({
    code,
    label,
    order: 10,
    status: "active",
    group: "primary",
    severable: false,
    values,
});

/** The three served catalogues, with one of them filled in — enough to hash. */
const catalogues = (symptoms: SymptomItem[]): Catalogues => ({
    symptoms,
    sportActivities: [],
    appointmentTypes: [],
});

const bodySignals = (body: Record<string, unknown>) =>
    api(`/me/body-signals/${today}`, { method: "PUT", body: JSON.stringify(body) });

let live: RefDataBody;

beforeAll(async () => {
    const res = await api("/auth/signup", {
        method: "POST",
        token: null,
        body: JSON.stringify({ email, password }),
    });
    expect(res.status).toBe(201);
    const body = await json<{ token: string; user: { id: string } }>(res);
    token = body.token;
    uid = body.user.id;

    // Bootstrap only — writes nothing where a catalogue already exists.
    for (const id of CATALOGUE_IDS) await seedIfMissing(id, DEFAULT_CATALOGUES[id]);
    live = await json<RefDataBody>(await api("/refdata"));
});

afterAll(async () => {
    if (uid) {
        const docs = await eventsCollection().listDocuments();
        await Promise.all(docs.map((doc) => doc.delete().catch(() => {})));
        await firestore.collection("users").doc(uid).delete().catch(() => {});
        await adminAuth.deleteUser(uid).catch(() => {});
    }
    await Promise.all(
        tempCatalogues.map((id) => refDataDoc().doc(id).delete().catch(() => {})),
    );
});

describe("refdata: the endpoint", () => {
    test("requires a bearer token", async () => {
        const res = await api("/refdata", { token: null });
        expect(res.status).toBe(401);
        expect((await json<ErrorResponse>(res)).error.code).toBe("UNAUTHORIZED");
    });

    test("serves the three catalogues, every item with a code and a label", async () => {
        expect(Object.keys(live.catalogues).sort()).toEqual(
            [...CATALOGUE_IDS].sort(),
        );
        // Seeded by beforeAll if this project had never seen them.
        expect(live.catalogues.symptoms.length).toBeGreaterThan(0);
        expect(live.catalogues.sportActivities.length).toBeGreaterThan(0);
        expect(live.catalogues.appointmentTypes.length).toBeGreaterThan(0);

        for (const id of CATALOGUE_IDS) {
            const items = live.catalogues[id];
            for (const entry of items) {
                expect(typeof entry.code).toBe("string");
                expect(entry.code.length).toBeGreaterThan(0);
                expect(typeof entry.label).toBe("string");
                expect(entry.label.length).toBeGreaterThan(0);
                expect(["active", "retired"]).toContain(entry.status);
            }
            const codes = items.map((entry) => entry.code);
            expect(new Set(codes).size).toBe(codes.length);
        }
    });

    test("one vocabulary: the cycle sheet's chips and the body-signals grid read the same list", async () => {
        // There is exactly one symptoms catalogue — nothing keyed by flow or by sheet.
        const symptomKeys = Object.keys(live.catalogues).filter((key) =>
            key.toLowerCase().includes("symptom"),
        );
        expect(symptomKeys).toEqual(["symptoms"]);
        // And it carries the whole vocabulary, not a subset per surface.
        const codes = live.catalogues.symptoms.map((entry) => entry.code);
        expect(codes).toContain("cramps");
        expect(codes).toContain("discharge");
        // Spotting is a cycle marker (#23), never a symptom: one day, one claim
        // about bleeding.
        expect(codes).not.toContain("spotting");
        // Energy is a 1–5 scale on the same sheet, so it is not also a chip (PRD:484).
        expect(codes).not.toContain("low-energy");
    });

    test("the version is a hash of the content it just served", async () => {
        expect(live.version).toBe(catalogueVersion(live.catalogues));
        expect(live.version.length).toBeGreaterThan(8);
    });

    test("a client holding the current version gets 304 and no body", async () => {
        const res = await api(`/refdata?version=${live.version}`);
        expect(res.status).toBe(304);
        expect(await res.text()).toBe("");
    });

    test("a stale version gets the catalogues back", async () => {
        const res = await api("/refdata?version=not-the-current-one");
        expect(res.status).toBe(200);
        expect((await json<RefDataBody>(res)).version).toBe(live.version);
    });

    test("If-None-Match works the same way, weak or strong", async () => {
        const fresh = await api("/refdata");
        expect(fresh.headers.get("etag")).toBe(`"${live.version}"`);
        for (const header of [`"${live.version}"`, `W/"${live.version}"`]) {
            const res = await api("/refdata", { headers: { "if-none-match": header } });
            expect(res.status).toBe(304);
        }
        const stale = await api("/refdata", { headers: { "if-none-match": '"0000000000000000"' } });
        expect(stale.status).toBe(200);
    });
});

describe("refdata: codes are permanent, labels are not", () => {
    test("changing a label leaves the code alone", async () => {
        const id = tempCatalogue();
        await applyCatalogue(id, [item("probe", "First name")]);
        const before = await readCatalogue(id);
        expect(before.map((entry) => entry.code)).toEqual(["probe"]);
        expect(before[0]!.label).toBe("First name");

        await applyCatalogue(id, [item("probe", "Renamed in the console")], { relabel: true });
        const after = await readCatalogue(id);
        // The identity events point at is unchanged; only the display text moved.
        expect(after.map((entry) => entry.code)).toEqual(["probe"]);
        expect(after[0]!.code).toBe(before[0]!.code);
        expect(after[0]!.label).toBe("Renamed in the console");
    });

    test("the version changes when a label changes, and not when nothing does", () => {
        const first = catalogues([symptomItem("probe", "First name")]);
        const relabelled = catalogues([symptomItem("probe", "Renamed in the console")]);
        const added = catalogues([symptomItem("probe", "First name"), symptomItem("other", "Other")]);

        expect(catalogueVersion(first)).toBe(catalogueVersion(catalogues([symptomItem("probe", "First name")])));
        expect(catalogueVersion(relabelled)).not.toBe(catalogueVersion(first));
        expect(catalogueVersion(added)).not.toBe(catalogueVersion(first));
    });

    test("seeding never drops a code that has left the seed list", async () => {
        const id = tempCatalogue();
        await applyCatalogue(id, [item("kept", "Kept"), item("dropped", "Dropped")]);
        // Re-seeding without `dropped`: an option vanishing would orphan every event
        // that already references it, so it stays.
        const after = await applyCatalogue(id, [item("kept", "Kept")]);
        expect(after.map((entry) => entry.code).sort()).toEqual(["dropped", "kept"]);
    });

    test("retiring takes a code out of the pickers but leaves it valid to write", async () => {
        const id = tempCatalogue();
        await applyCatalogue(id, [item("fading", "Fading")]);
        expect(await retireCode(id, "fading")).toBe(true);

        const items = await readCatalogue(id);
        expect(items[0]!.status).toBe("retired");
        // Still in the validator's index: an offline queue may hold an entry logged
        // while the chip was still on screen.
        const rules = buildSymptomRules([symptomItem("fading", "Fading"), symptomItem("live", "Live")]);
        expect(rules.has("fading")).toBe(true);
        expect(rules.has("never-existed")).toBe(false);

        // A re-seed must not quietly bring it back either.
        await applyCatalogue(id, [item("fading", "Fading")], { relabel: true });
        expect((await readCatalogue(id))[0]!.status).toBe("retired");
    });
});

describe("events: symptoms are checked against the catalogue", () => {
    test("a code the catalogue has never carried is rejected", async () => {
        const res = await bodySignals({ symptoms: [{ code: "zz-not-a-real-symptom" }] });
        expect(res.status).toBe(400);
        expect((await json<ErrorResponse>(res)).error.code).toBe("UNKNOWN_SYMPTOM_CODE");
    });

    test("the same check runs on POST /me/events", async () => {
        const res = await api("/me/events", {
            method: "POST",
            body: JSON.stringify({
                type: "bodySignals",
                localDate: today,
                payload: { symptoms: [{ code: "zz-not-a-real-symptom" }] },
            }),
        });
        expect(res.status).toBe(400);
        expect((await json<ErrorResponse>(res)).error.code).toBe("UNKNOWN_SYMPTOM_CODE");
    });

    test("a code from the live catalogue is accepted", async () => {
        const code = live.catalogues.symptoms.find((entry) => entry.values === null)!.code;
        const res = await bodySignals({ symptoms: [{ code }] });
        expect(res.status).toBe(200);
        const { event } = await json<{ event: EvaEventBody }>(res);
        expect(event.payload.symptoms).toEqual([{ code, severity: "normal" }]);
    });

    test("discharge carries a value from its own picker, and severity stays separate", async () => {
        const discharge = live.catalogues.symptoms.find((entry) => entry.code === "discharge")!;
        expect(discharge.values).toContain("egg-white");

        const res = await bodySignals({
            symptoms: [
                { code: "discharge", value: "egg-white" },
                { code: "cramps", severity: "severe" },
            ],
        });
        expect(res.status).toBe(200);
        const { event } = await json<{ event: EvaEventBody }>(res);
        expect(event.payload.symptoms).toEqual([
            { code: "discharge", severity: "normal", value: "egg-white" },
            { code: "cramps", severity: "severe" },
        ]);
    });

    test("a value the picker does not offer is rejected", async () => {
        const res = await bodySignals({ symptoms: [{ code: "discharge", value: "sparkly" }] });
        expect(res.status).toBe(400);
        const { error } = await json<ErrorResponse>(res);
        expect(error.code).toBe("VALIDATION");
        expect(error.message).toContain("discharge");
    });

    test("a value on a chip that has no picker is rejected", async () => {
        const res = await bodySignals({ symptoms: [{ code: "cramps", value: "egg-white" }] });
        expect(res.status).toBe(400);
        expect((await json<ErrorResponse>(res)).error.code).toBe("VALIDATION");
    });
});

describe("events: history survives the catalogue changing under it", () => {
    /** Written straight to Firestore because the point is an event that predates the
     *  catalogue it no longer matches — the API will not create one for us. Same
     *  liberty events.test.ts takes when it sweeps the collection. */
    const legacyDate = "2026-01-15";
    let legacyId = "";

    beforeAll(async () => {
        const ref = eventsCollection().doc();
        await ref.set({
            type: "bodySignals",
            localDate: legacyDate,
            loggedAt: `${legacyDate}T12:00:00`,
            note: null,
            source: "user",
            payload: { energy: 3, symptoms: [{ code: "zz-deleted-in-2025", severity: "severe" }] },
            idempotencyKey: null,
            deletedAt: null,
            createdAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
        });
        legacyId = ref.id;
    });

    test("it reads back untouched — no migration, no silent change of meaning", async () => {
        const res = await api(`/me/events?from=${legacyDate}&to=${legacyDate}`);
        expect(res.status).toBe(200);
        const { events } = await json<{ events: EvaEventBody[] }>(res);
        const found = events.find((event) => event.id === legacyId)!;
        expect(found).toBeDefined();
        // The stored code is returned verbatim: reads never validate, so a code that
        // has since left the catalogue cannot break or rewrite an old entry.
        expect(found.payload.symptoms).toEqual([{ code: "zz-deleted-in-2025", severity: "severe" }]);
    });

    test("and it can still be deleted", async () => {
        const res = await api(`/me/events/${legacyId}`, { method: "DELETE" });
        expect(res.status).toBe(200);
    });
});
