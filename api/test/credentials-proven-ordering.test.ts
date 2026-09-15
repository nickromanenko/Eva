import { afterAll, beforeAll, describe, expect, mock, setDefaultTimeout, test } from "bun:test";
import { adminAuth, firestore } from "../src/firebase";

/**
 * The ordering invariant `api/CLAUDE.md` states, pinned at the two call sites that have to
 * obey it (#127).
 *
 * > `emailVerified` is what turns off `claimUnprovenAccount`'s address test, and
 * > `activatedAt` is what turns off the claim itself. Any window in which the first is set
 * > and the second is not is the one combination that claims unconditionally.
 *
 * So `markActivated` must run **before** `markCredentialsProven`, in `/auth/activate` and
 * in `/auth/password/reset` alike. #120 restructured activation to obey it and left the
 * reset route calling them the other way round; #127 swapped them, and this file is what
 * stops either drifting back. Reversing the pair in either route fails a case here.
 *
 * **Why a call-order assertion and not a state assertion.** Both flags are set by the time
 * the route answers, so the finished account looks identical either way — the difference is
 * a window one dropped request wide, which has no observable outside the process. The order
 * the route calls them in *is* the property, so it is what gets asserted.
 *
 * **The seam** is the one `unhandled-errors.test.ts` uses, with the same caveat and the
 * same discipline: Bun's `mock.module` replaces the live bindings every already-imported
 * module sees, process-globally and permanently, so `afterAll` puts both modules back as
 * they were found. Unlike that file, every mock here **delegates to the real
 * implementation** — this is a recorder, not a fake. Firebase is the real project, the
 * account is a real `e2e+*` account, and the sweep deletes it.
 */

// Real Firebase, several round trips per case, and an account stood up and torn down:
// the same 20s ceiling the other live suites set (#31).
setDefaultTimeout(20_000);

const identityToolkit = { ...(await import("../src/identity-toolkit")) };
const users = { ...(await import("../src/users")) };
const emailTokens = { ...(await import("../src/email-tokens")) };

/** Every stamp call the routes make, in the order they were made. */
let calls: string[] = [];

mock.module("../src/identity-toolkit", () => ({
    ...identityToolkit,
    markCredentialsProven: async (uid: string) => {
        calls.push("markCredentialsProven");
        return identityToolkit.markCredentialsProven(uid);
    },
}));

mock.module("../src/users", () => ({
    ...users,
    markActivated: async (uid: string) => {
        calls.push("markActivated");
        return users.markActivated(uid);
    },
}));

// After the mocks, and never as a listening server: the route has to run in *this*
// process for the recorders above to be the bindings it calls.
const { default: server } = await import("../src/index");

const PASSWORD = "correct-horse-8";
const NEW_PASSWORD = "correct-horse-9";
const createdUids: string[] = [];
const createdEmails: string[] = [];

const address = () => {
    const value = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
    createdEmails.push(value);
    return value;
};

const post = async (path: string, body: unknown) => {
    const res = await server.fetch(
        new Request(`http://api.test${path}`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(body),
        }),
    );
    return { status: res.status, body: (await res.json()) as Record<string, unknown> };
};

/** An account in the shape sign-up leaves behind, written directly so this file spends no
 *  per-IP sign-up budget and sends no email (#5). */
const unactivatedAccount = async (email: string): Promise<string> => {
    const { uid } = await adminAuth.createUser({ email, password: PASSWORD });
    await firestore.collection("users").doc(uid).set({
        email,
        authProviders: ["password"],
        questionnaireCompleted: false,
        profile: null,
        activatedAt: null,
        createdAt: new Date(),
        updatedAt: new Date(),
    });
    createdUids.push(uid);
    return uid;
};

beforeAll(() => {
    calls = [];
});

afterAll(async () => {
    for (const uid of createdUids) {
        await adminAuth.deleteUser(uid).catch(() => {});
        await firestore.collection("users").doc(uid).delete().catch(() => {});
    }
    // `authTokens/` is keyed by the token's hash and holds the address, so the rows this
    // file issues are swept by address the way auth.test.ts sweeps its own.
    for (const value of createdEmails) {
        const rows = await firestore.collection("authTokens").where("email", "==", value).get();
        for (const row of rows.docs) await row.ref.delete().catch(() => {});
    }
    // Hand both modules back exactly as they were found.
    mock.module("../src/identity-toolkit", () => identityToolkit);
    mock.module("../src/users", () => users);
});

describe("markCredentialsProven runs after markActivated", () => {
    test("on /auth/password/reset — the call site #127 corrected", async () => {
        const email = address();
        const uid = await unactivatedAccount(email);
        const token = await emailTokens.issueToken(uid, email, "reset");

        calls = [];
        const answer = await post("/auth/password/reset", { token, password: NEW_PASSWORD });

        expect(answer.status).toBe(200);
        // Reversing the two calls in the route makes this line fail and nothing else
        // change — which is the whole reason it is an array comparison and not two
        // `toHaveBeenCalled`s.
        expect(calls).toEqual(["markActivated", "markCredentialsProven"]);
    });

    test("on /auth/activate — the call site #120 established it at", async () => {
        const email = address();
        const token = await emailTokens.issueToken(null, email, "activation");

        calls = [];
        const answer = await post("/auth/activate", { token, password: PASSWORD });

        expect(answer.status).toBe(200);
        expect(calls).toEqual(["markActivated", "markCredentialsProven"]);
        // Sign-up creates nothing since #120, so the account this made has to be swept too.
        const made = await adminAuth.getUserByEmail(email).catch(() => null);
        if (made) createdUids.push(made.uid);
    });

    test("the account ends with both set, whichever order they were called in", async () => {
        // The state assertion the ordering one cannot make: it is true either way, and
        // saying so is what stops the next reader thinking the order is about the outcome.
        const email = address();
        const uid = await unactivatedAccount(email);
        const token = await emailTokens.issueToken(uid, email, "reset");

        await post("/auth/password/reset", { token, password: NEW_PASSWORD });

        const authUser = await adminAuth.getUser(uid);
        const doc = await firestore.collection("users").doc(uid).get();
        expect(authUser.emailVerified).toBe(true);
        expect(doc.get("activatedAt")).not.toBeNull();
    });
});
