import { Hono } from "hono";
import { mintToken, requireAuth } from "./auth";
import {
    IdentityToolkitError,
    signInWithPassword,
    signUpWithPassword,
} from "./identity-toolkit";
import { ensureUser, getUser, saveQuestionnaire, type Profile } from "./users";

const app = new Hono();

const error = (code: string, message: string) => ({ error: { code, message } });

const normalizeEmail = (email: unknown): string | null => {
    if (typeof email !== "string") return null;
    const normalized = email.trim().toLowerCase();
    return /\S+@\S+\.\S+/.test(normalized) ? normalized : null;
};

app.get("/", (c) => c.text("Eva API"));
app.get("/health", (c) => c.json({ status: "ok" }));

app.post("/auth/signup", async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const email = normalizeEmail(body.email);
    const password = typeof body.password === "string" ? body.password : "";
    if (!email)
        return c.json(error("VALIDATION", "A valid email is required"), 400);
    if (password.length < 8) {
        return c.json(
            error("VALIDATION", "Password must be at least 8 characters"),
            400,
        );
    }

    try {
        const { localId } = await signUpWithPassword(email, password);
        const user = await ensureUser(localId, email, "password");
        return c.json({ token: await mintToken(localId, email), user }, 201);
    } catch (err) {
        if (
            err instanceof IdentityToolkitError &&
            err.reason === "EMAIL_EXISTS"
        ) {
            return c.json(
                error("EMAIL_EXISTS", "This email is already registered"),
                409,
            );
        }
        throw err;
    }
});

app.post("/auth/signin", async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const email = normalizeEmail(body.email);
    const password = typeof body.password === "string" ? body.password : "";
    if (!email || !password) {
        return c.json(
            error("VALIDATION", "Email and password are required"),
            400,
        );
    }

    try {
        const { localId } = await signInWithPassword(email, password);
        // Self-healing: also the attach point for future providers (same uid → same doc).
        const user = await ensureUser(localId, email, "password");
        return c.json({ token: await mintToken(localId, email), user });
    } catch (err) {
        if (err instanceof IdentityToolkitError) {
            return c.json(
                error("INVALID_CREDENTIALS", "Wrong email or password"),
                401,
            );
        }
        throw err;
    }
});

app.get("/me", requireAuth, async (c) => {
    const { sub, email } = c.get("claims");
    const user =
        (await getUser(sub)) ?? (await ensureUser(sub, email, "password"));
    return c.json({ user });
});

app.put("/me/questionnaire", requireAuth, async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const profile = parseProfile(body);
    if (!profile)
        return c.json(
            error("VALIDATION", "Invalid questionnaire payload"),
            400,
        );

    const user = await saveQuestionnaire(c.get("claims").sub, profile);
    if (!user) return c.json(error("UNAUTHORIZED", "User not found"), 401);
    return c.json({ user });
});

const parseProfile = (body: Record<string, unknown>): Profile | null => {
    const isStringArray = (v: unknown): v is string[] =>
        Array.isArray(v) && v.every((x) => typeof x === "string");
    const inRange = (v: unknown, min: number, max: number): v is number =>
        typeof v === "number" && Number.isFinite(v) && v >= min && v <= max;

    const {
        age,
        weightKg,
        heightCm,
        goals,
        conditions,
        medications,
        lifestyle,
        sports,
    } = body;
    if (
        !inRange(age, 13, 99) ||
        !inRange(weightKg, 30, 200) ||
        !inRange(heightCm, 120, 220) ||
        !isStringArray(goals) ||
        !isStringArray(conditions) ||
        typeof medications !== "string" ||
        typeof lifestyle !== "string" ||
        !isStringArray(sports)
    ) {
        return null;
    }
    return {
        age,
        weightKg,
        heightCm,
        goals,
        conditions,
        medications,
        lifestyle,
        sports,
    };
};

export default {
    // Cloud Run injects PORT (8080); default to 3003 for local dev
    port: Number(process.env.PORT ?? 3003),
    fetch: app.fetch,
};
