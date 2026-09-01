import { FieldValue } from "firebase-admin/firestore";
import { issueToken } from "../../src/email-tokens";
import { adminAuth, firestore } from "../../src/firebase";

/**
 * How the live suites get a session now that sign-up does not hand one out (#6).
 *
 * The activation link never reaches a test — the server prints it (log transport) or
 * sends it (Postmark), and neither is readable from here — so the test process issues a
 * token of its own through the same `issueToken` the server uses, against the same
 * Firestore, and then spends it through the live `GET /auth/activate`. Every suite that
 * signs up therefore also exercises the activation route for real.
 *
 * Not a test file: Bun only picks up `*.test.ts`.
 */

const post = (base: string, path: string, body: unknown) =>
    fetch(`${base}${path}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
    });

/** Spends a freshly issued activation token on the live server. */
export const activateAccount = async (base: string, uid: string, email: string): Promise<void> => {
    const token = await issueToken(uid, email, "activation");
    const res = await fetch(`${base}/auth/activate?token=${token}`);
    if (res.status !== 200) throw new Error(`activate answered ${res.status}`);
};

/** Signs in and hands back the session token. */
export const signIn = async (base: string, email: string, password: string): Promise<string> => {
    const res = await post(base, "/auth/signin", { email, password });
    if (res.status !== 200) throw new Error(`signin answered ${res.status}`);
    return ((await res.json()) as { token: string }).token;
};

/** Sign-up → activation → sign-in. The uid comes from Auth, since sign-up no longer
 *  returns one. */
export const signUpActivated = async (
    base: string,
    email: string,
    password: string,
): Promise<{ token: string; uid: string }> => {
    const res = await post(base, "/auth/signup", { email, password });
    if (res.status !== 201) throw new Error(`signup answered ${res.status}`);
    const { uid } = await adminAuth.getUserByEmail(email);
    await activateAccount(base, uid, email);
    return { token: await signIn(base, email, password), uid };
};

/**
 * An account in the shape sign-up leaves behind: Auth user, `users/{uid}` document,
 * `activatedAt: null`. Written directly rather than through `POST /auth/signup` so a
 * suite can stand up as many as it needs without spending the shared per-IP sign-up
 * budget (#5) — and without sending an email for each.
 */
export const createUnactivatedAccount = async (
    email: string,
    password: string,
): Promise<string> => {
    const { uid } = await adminAuth.createUser({ email, password });
    await firestore.collection("users").doc(uid).set({
        email,
        authProviders: ["password"],
        questionnaireCompleted: false,
        profile: null,
        activatedAt: null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
    });
    return uid;
};

/**
 * An account exactly as every one created before #6 looks: an Auth user and a
 * `users/{uid}` document with no `activatedAt` field at all. Written directly, because
 * nothing in `src/` can produce that shape any more — which is the point of having it.
 */
export const createLegacyAccount = async (email: string, password: string): Promise<string> => {
    const { uid } = await adminAuth.createUser({ email, password });
    await firestore.collection("users").doc(uid).set({
        email,
        authProviders: ["password"],
        questionnaireCompleted: false,
        profile: null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
    });
    return uid;
};
