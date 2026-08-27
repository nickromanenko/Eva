import { afterAll, describe, expect, test } from "bun:test";
import { verify } from "hono/jwt";
import { config } from "../src/config";
import { adminAuth, firestore } from "../src/firebase";

/**
 * Integration tests against the REAL Firebase project (per spec §6).
 * Every account uses the e2e+<uuid>@e2e.evaapp.dev pattern and is deleted
 * (Auth user + Firestore doc) in afterAll, success or failure.
 */

const BASE = process.env.EVA_API_URL ?? "http://localhost:3003";
const email = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
const password = "correct-horse-8";
const createdUids: string[] = [];

const api = (path: string, init?: RequestInit & { token?: string }) =>
    fetch(`${BASE}${path}`, {
        ...init,
        headers: {
            "content-type": "application/json",
            ...(init?.token ? { authorization: `Bearer ${init.token}` } : {}),
        },
    });

interface UserBody {
    id: string;
    email: string;
    questionnaireCompleted: boolean;
}
interface UserResponse {
    user: UserBody;
}
interface AuthResponse extends UserResponse {
    token: string;
}
interface ErrorResponse {
    error: { code: string; message: string };
}

/** Typed `res.json()` — the API contract is documented in docs/ARCHITECTURE.md §3. */
const json = <T>(res: Response): Promise<T> => res.json() as Promise<T>;

afterAll(async () => {
    for (const uid of createdUids) {
        await adminAuth.deleteUser(uid).catch(() => {});
        await firestore
            .collection("users")
            .doc(uid)
            .delete()
            .catch(() => {});
    }
});

describe("auth", () => {
    let token = "";
    let uid = "";

    test("signup creates account, JWT and Firestore record", async () => {
        const res = await api("/auth/signup", {
            method: "POST",
            body: JSON.stringify({ email, password }),
        });
        expect(res.status).toBe(201);
        const body = await json<AuthResponse>(res);
        token = body.token;
        uid = body.user.id;
        createdUids.push(uid);

        expect(body.user.email).toBe(email);
        expect(body.user.questionnaireCompleted).toBe(false);

        const claims = await verify(token, config.jwtSecret, "HS256");
        expect(claims.sub).toBe(uid);

        // The spec's core assertion: the users/{uid} record exists in Firestore.
        const doc = await firestore.collection("users").doc(uid).get();
        expect(doc.exists).toBe(true);
        expect(doc.data()!.email).toBe(email);
        expect(doc.data()!.authProviders).toEqual(["password"]);
        expect(doc.data()!.questionnaireCompleted).toBe(false);
    });

    test("duplicate signup is rejected with 409", async () => {
        const res = await api("/auth/signup", {
            method: "POST",
            body: JSON.stringify({ email, password }),
        });
        expect(res.status).toBe(409);
        expect((await json<ErrorResponse>(res)).error.code).toBe(
            "EMAIL_EXISTS",
        );
    });

    test("signup validates email and password", async () => {
        const bad = await api("/auth/signup", {
            method: "POST",
            body: JSON.stringify({ email: "not-an-email", password }),
        });
        expect(bad.status).toBe(400);
        const weak = await api("/auth/signup", {
            method: "POST",
            body: JSON.stringify({
                email: `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`,
                password: "short",
            }),
        });
        expect(weak.status).toBe(400);
    });

    test("signin returns token for correct password, matches same user", async () => {
        const res = await api("/auth/signin", {
            method: "POST",
            body: JSON.stringify({ email: email.toUpperCase(), password }), // case-insensitive email
        });
        expect(res.status).toBe(200);
        const body = await json<AuthResponse>(res);
        expect(body.user.id).toBe(uid); // same uid → same users doc, no second record
    });

    test("signin rejects wrong password with 401", async () => {
        const res = await api("/auth/signin", {
            method: "POST",
            body: JSON.stringify({ email, password: "wrong-password-1" }),
        });
        expect(res.status).toBe(401);
        expect((await json<ErrorResponse>(res)).error.code).toBe(
            "INVALID_CREDENTIALS",
        );
    });

    test("signin answers a wrong password and an unknown address identically", async () => {
        // The live half of the non-enumeration property (issue #21): this one guards the
        // upstream layer, and it is the weaker of the two. Identity Toolkit collapses both
        // cases into INVALID_LOGIN_CREDENTIALS today, so this stays green even if the route
        // interpolates the upstream reason into the message. test/signin-non-enumeration.test.ts
        // is the test that pins our half, with the upstream controlled.
        const wrongPassword = await api("/auth/signin", {
            method: "POST",
            body: JSON.stringify({ email, password: "wrong-password-1" }),
        });
        const unknownAddress = await api("/auth/signin", {
            method: "POST",
            body: JSON.stringify({
                email: `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`,
                password,
            }),
        });
        expect(wrongPassword.status).toBe(unknownAddress.status);
        const wrong = await json<ErrorResponse>(wrongPassword);
        const unknown = await json<ErrorResponse>(unknownAddress);
        expect(wrong.error.code).toBe(unknown.error.code);
        expect(wrong.error.message).toBe(unknown.error.message);
    });

    test("GET /me requires and honors the JWT", async () => {
        expect((await api("/me")).status).toBe(401);
        const res = await api("/me", { token });
        expect(res.status).toBe(200);
        expect((await json<UserResponse>(res)).user.id).toBe(uid);
    });

    test("questionnaire submission completes the profile", async () => {
        const profile = {
            age: 28,
            weightKg: 64,
            heightCm: 168,
            goals: ["Energy", "Sleep"],
            conditions: ["None of these"],
            medications: "No",
            lifestyle: "Active",
            sports: ["Yoga"],
        };
        const res = await api("/me/questionnaire", {
            method: "PUT",
            token,
            body: JSON.stringify(profile),
        });
        expect(res.status).toBe(200);
        expect(
            (await json<UserResponse>(res)).user.questionnaireCompleted,
        ).toBe(true);

        const doc = await firestore.collection("users").doc(uid).get();
        expect(doc.data()!.questionnaireCompleted).toBe(true);
        expect(doc.data()!.profile.age).toBe(28);

        // Returning user now routes as completed.
        const signin = await api("/auth/signin", {
            method: "POST",
            body: JSON.stringify({ email, password }),
        });
        expect(
            (await json<UserResponse>(signin)).user.questionnaireCompleted,
        ).toBe(true);
    });

    test("invalid questionnaire payload is rejected", async () => {
        const res = await api("/me/questionnaire", {
            method: "PUT",
            token,
            body: JSON.stringify({ age: 5 }),
        });
        expect(res.status).toBe(400);
    });
});

/**
 * The canvas' password rule, enforced at creation only (issue #20).
 *
 * The last test is the load-bearing one: the rule applies to signup, never to signin,
 * because accounts created before it exist and must keep working.
 */
describe("signup password rule", () => {
    /** The helper text the sign-up screen actually shows, read from the client. */
    const clientHelperText = async (): Promise<string> => {
        const swift = await Bun.file(
            `${import.meta.dir}/../../mobile/Eva/Onboarding/Steps/CreateAccountStepView.swift`,
        ).text();
        const match = swift.match(/passwordRule = "([^"]+)"/);
        if (!match) throw new Error("passwordRule not found in CreateAccountStepView.swift");
        return match[1]!;
    };

    const signup = (password: string) =>
        api("/auth/signup", {
            method: "POST",
            body: JSON.stringify({
                email: `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`,
                password,
            }),
        });

    test("8 characters without a digit is rejected", async () => {
        const res = await signup("password");
        expect(res.status).toBe(400);
        expect((await json<ErrorResponse>(res)).error.code).toBe("WEAK_PASSWORD");
    });

    test("7 characters with a digit is rejected", async () => {
        const res = await signup("passwo1");
        expect(res.status).toBe(400);
        expect((await json<ErrorResponse>(res)).error.code).toBe("WEAK_PASSWORD");
    });

    test("8 characters with a digit is accepted", async () => {
        const res = await signup("passwor1");
        expect(res.status).toBe(201);
        createdUids.push((await json<AuthResponse>(res)).user.id);
    });

    test("a non-ASCII digit counts as a number, as it does on the client", async () => {
        // Swift's Character.isNumber is Unicode-wide, so the CTA enables for this
        // password. An ASCII-only server check would reject it while quoting the rule
        // the user had just satisfied.
        const res = await signup("passwor\u0663");
        expect(res.status).toBe(201);
        createdUids.push((await json<AuthResponse>(res)).user.id);
    });

    test("the rejection message is the sign-up screen's helper text", async () => {
        const res = await signup("password");
        expect((await json<ErrorResponse>(res)).error.message).toBe(await clientHelperText());
    });

    test("signin still accepts a pre-rule password with no digit", async () => {
        // Created through the Admin SDK deliberately: signup itself now refuses this
        // password, so this is the only way to stand up an account that predates the
        // rule. Sign-in must not start rejecting the users who already hold one.
        const legacyEmail = `e2e+${crypto.randomUUID()}@e2e.evaapp.dev`;
        const legacyPassword = "horsestaple";
        const { uid: legacyUid } = await adminAuth.createUser({
            email: legacyEmail,
            password: legacyPassword,
        });
        createdUids.push(legacyUid);

        const res = await api("/auth/signin", {
            method: "POST",
            body: JSON.stringify({ email: legacyEmail, password: legacyPassword }),
        });
        expect(res.status).toBe(200);
        expect((await json<AuthResponse>(res)).user.id).toBe(legacyUid);
    });
});
