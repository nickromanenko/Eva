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
