import { Hono, type Context } from "hono";
import { mintToken, requireAuth } from "./auth";
import {
    authRetryAfterSeconds,
    consumeAuthAttempt,
    type AuthRoute,
} from "./rate-limit";
import {
    IdentityToolkitError,
    signInWithPassword,
    signUpWithPassword,
} from "./identity-toolkit";
import {
    createEvent,
    listEvents,
    softDeleteEvent,
    updateEvent,
    type AppointmentPayload,
    type BodySignalsPayload,
    type CyclePayload,
    type EventPatch,
    type EventPayload,
    type EventSource,
    type LoggableEventType,
    type NewEvent,
    type SportPayload,
    type Symptom,
    type SymptomSeverity,
} from "./events";
import { getRefData, getSymptomRules, type SymptomRules } from "./refdata";
import { ensureUser, getUser, saveQuestionnaire, type Profile } from "./users";

const app = new Hono();

const error = (code: string, message: string) => ({ error: { code, message } });

const normalizeEmail = (email: unknown): string | null => {
    if (typeof email !== "string") return null;
    const normalized = email.trim().toLowerCase();
    return /\S+@\S+\.\S+/.test(normalized) ? normalized : null;
};

/**
 * The password rule, stated exactly as the sign-up screen states it —
 * `passwordRule` in mobile/Eva/Onboarding/Steps/CreateAccountStepView.swift. The user
 * must never be told two different rules, so this string is the rejection message
 * verbatim, and test/auth.test.ts reads the Swift file to pin the two together.
 *
 * Creation only. Sign-in never applies it: accounts predating this rule keep working.
 */
const PASSWORD_RULE = "At least 8 characters, including one number.";

/**
 * `\p{N}`, not `\d`, so "a number" means the same thing here as it does in the client's
 * `Character.isNumber` (Unicode Nd/Nl/No). ASCII-only here would reject a password the
 * sign-up CTA accepted, while quoting the rule the user just satisfied.
 */
const isValidPassword = (password: string): boolean =>
    password.length >= 8 && /\p{N}/u.test(password);

/**
 * The calling client's address, for the per-IP half of the auth throttle (issue #5).
 *
 * The **rightmost** `X-Forwarded-For` entry, not the leftmost. Cloud Run appends the
 * address it actually accepted the connection from, and everything to the left of that is
 * whatever the caller chose to send — trusting the left would put the per-IP limit one
 * request header away from useless. This assumes `eva-api` stays a *direct* Cloud Run
 * service, as `.github/workflows/deploy-api.yml` deploys it; put an external load balancer
 * in front and the rightmost entry becomes the balancer's, so revisit this then.
 *
 * `null` when there is no header, which skips the per-IP dimension rather than bucketing
 * every caller together — collapsing the world into one counter is an outage, and the
 * per-address limit still applies. Cloud Run always sets the header, so in production this
 * is unreachable; locally, and for in-process tests, it is the ordinary case.
 */
const clientIp = (c: Context): string | null => {
    const forwarded = c.req.header("x-forwarded-for");
    if (!forwarded) return null;
    const hops = forwarded.split(",");
    const client = hops[hops.length - 1]?.trim() ?? "";
    return client === "" ? null : client;
};

/**
 * Counts this attempt and, if it is over the limit, answers instead of serving it.
 * `null` means carry on.
 *
 * Called *after* validation and *before* the Identity Toolkit call, so a throttled request
 * costs neither us nor the bill anything, and so the answer cannot depend on what the
 * upstream would have said. The response is one constant for every caller: same status,
 * same code, same message, same `Retry-After`, with nothing derived from the address —
 * which is what keeps the sign-in non-enumeration property (§3) intact under throttling.
 */
const throttleAuth = (c: Context, route: AuthRoute, email: string) => {
    if (consumeAuthAttempt(route, clientIp(c), email)) return null;
    return c.json(error("RATE_LIMITED", "Too many attempts. Try again later."), 429, {
        "retry-after": String(authRetryAfterSeconds),
    });
};

app.get("/", (c) => c.text("Eva API"));
app.get("/health", (c) => c.json({ status: "ok" }));

app.post("/auth/signup", async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const email = normalizeEmail(body.email);
    const password = typeof body.password === "string" ? body.password : "";
    if (!email)
        return c.json(error("VALIDATION", "A valid email is required"), 400);
    if (!isValidPassword(password)) {
        return c.json(error("WEAK_PASSWORD", PASSWORD_RULE), 400);
    }
    const throttled = throttleAuth(c, "signup", email);
    if (throttled) return throttled;

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
    const throttled = throttleAuth(c, "signin", email);
    if (throttled) return throttled;

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

// ── Reference data ─────────────────────────────────────────────────────────────
// The option lists the client draws (PRD:483 — new options ship without an app
// release). `version` is a hash of the content, so it changes exactly when a
// catalogue does. The client stores it beside its copy and sends it back; an
// unchanged catalogue answers 304 with no body, and the client keeps what it has.
// `If-None-Match` does the same thing for anything that speaks HTTP caching.

/** Strips the weak-validator prefix and quotes: `W/"abc"` and `"abc"` are both abc. */
const etagValue = (header: string | undefined): string | undefined =>
    header?.trim().replace(/^W\//, "").replace(/^"|"$/g, "");

app.get("/refdata", requireAuth, async (c) => {
    const refdata = await getRefData();
    c.header("ETag", `"${refdata.version}"`);
    // Reference data changes rarely but must not go stale silently: revalidate always,
    // and the revalidation is a 304 with an empty body.
    c.header("Cache-Control", "private, no-cache");
    const known = c.req.query("version") ?? etagValue(c.req.header("if-none-match"));
    if (known === refdata.version) return c.body(null, 304);
    return c.json(refdata);
});

// ── Calendar events ────────────────────────────────────────────────────────────
// Everything below validates at the edge and delegates to events.ts, which is the
// only module allowed to touch users/{uid}/events (GUARDRAILS rule 10).
//
// Times on the wire are the user's wall clock, never an instant: `localDate` is
// what the device says the day is, and the server never derives it from its own
// clock. `timeZone` (optional, IANA) is used only to work out what "today" is for
// the caller — it is not stored. Without it the server falls back to UTC and allows
// a day of slack in both directions, because UTC-12..UTC+14 means someone's real
// today is always within one day of the server's.

type Parsed<T> = { ok: true; value: T } | { ok: false; code: string; message: string };

const good = <T>(value: T): Parsed<T> => ({ ok: true, value });
const bad = (message: string, code = "VALIDATION"): Parsed<never> => ({
    ok: false,
    code,
    message,
});

const CALENDAR_DATE = /^\d{4}-\d{2}-\d{2}$/;
const LOCAL_DATETIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/;
const NOTE_LIMIT = 280;
const APPOINTMENT_NOTE_LIMIT = 10_000;
const MAX_RANGE_DAYS = 400;

/** `YYYY-MM-DD` that is also a real day — 2026-02-30 parses but is not one. */
const isCalendarDate = (value: unknown): value is string => {
    if (typeof value !== "string" || !CALENDAR_DATE.test(value)) return false;
    const parsed = new Date(`${value}T00:00:00.000Z`);
    return (
        !Number.isNaN(parsed.getTime()) &&
        parsed.toISOString().slice(0, 10) === value
    );
};

const shiftDays = (date: string, days: number): string =>
    new Date(Date.parse(`${date}T00:00:00.000Z`) + days * 86_400_000)
        .toISOString()
        .slice(0, 10);

/** Twelve months back. 29 Feb lands on 1 Mar in a non-leap year, which is fine
 *  for a cap — it is a day either way. */
const minusTwelveMonths = (date: string): string => {
    const [year, month, day] = date.split("-").map(Number);
    return new Date(Date.UTC(year! - 1, month! - 1, day!)).toISOString().slice(0, 10);
};

interface Clock {
    /** The caller's current local date. */
    today: string;
    /** The caller's current local time, `HH:mm:ss`. */
    timeOfDay: string;
    /** Days of tolerance around `today` when the caller did not name its zone. */
    slackDays: number;
}

const resolveClock = (timeZone: unknown): Parsed<Clock> => {
    if (timeZone !== undefined && typeof timeZone !== "string") {
        return bad("timeZone must be an IANA time zone name");
    }
    const zone = timeZone ?? "UTC";
    let parts: Intl.DateTimeFormatPart[];
    try {
        parts = new Intl.DateTimeFormat("en-US", {
            timeZone: zone,
            year: "numeric",
            month: "2-digit",
            day: "2-digit",
            hour: "2-digit",
            minute: "2-digit",
            second: "2-digit",
            hourCycle: "h23",
        }).formatToParts(new Date());
    } catch {
        return bad(`Unknown time zone: ${zone}`);
    }
    const part = (name: string) => parts.find((p) => p.type === name)!.value;
    return good({
        today: `${part("year")}-${part("month")}-${part("day")}`,
        timeOfDay: `${part("hour")}:${part("minute")}:${part("second")}`,
        slackDays: timeZone === undefined ? 1 : 0,
    });
};

/** Future dates are for appointments only — you cannot observe something that has
 *  not happened. Everything is capped at 12 months of backdating (PRD edge case 1). */
const checkDatePolicy = (
    type: LoggableEventType,
    localDate: string,
    clock: Clock,
): Parsed<true> => {
    if (type !== "appointment") {
        const latest = shiftDays(clock.today, clock.slackDays);
        if (localDate > latest) {
            return bad(
                "Only appointments can be logged on a future date",
                "FUTURE_DATE_NOT_ALLOWED",
            );
        }
    }
    const earliest = shiftDays(minusTwelveMonths(clock.today), -clock.slackDays);
    if (localDate < earliest) {
        return bad(
            "Entries can only be backdated 12 months",
            "BACKDATE_LIMIT_EXCEEDED",
        );
    }
    return good(true);
};

/** Now for today, 12:00 otherwise. The date half always matches `localDate`: the
 *  day sheet orders entries by this, so it is a time *on that day*, not an instant. */
const defaultLoggedAt = (localDate: string, clock: Clock): string =>
    localDate === clock.today
        ? `${localDate}T${clock.timeOfDay}`
        : `${localDate}T12:00:00`;

const parseLoggedAt = (value: unknown, localDate: string, clock: Clock): Parsed<string> => {
    if (value === undefined || value === null) return good(defaultLoggedAt(localDate, clock));
    if (typeof value !== "string" || !LOCAL_DATETIME.test(value)) {
        return bad("loggedAt must be a local YYYY-MM-DDTHH:mm:ss");
    }
    const normalized = value.length === 16 ? `${value}:00` : value;
    if (!normalized.startsWith(`${localDate}T`)) {
        return bad("loggedAt must fall on the entry's localDate");
    }
    return good(normalized);
};

const parseNote = (value: unknown, type: LoggableEventType): Parsed<string | null> => {
    if (value === undefined || value === null) return good(null);
    if (typeof value !== "string") return bad("note must be text");
    const limit = type === "appointment" ? APPOINTMENT_NOTE_LIMIT : NOTE_LIMIT;
    const note = value.trim();
    if (note.length > limit) return bad(`note must be ${limit} characters or fewer`);
    return good(note.length > 0 ? note : null);
};

const parseSource = (value: unknown): Parsed<EventSource> => {
    if (value === undefined || value === null) return good("user");
    if (value !== "user" && value !== "eva") return bad("source must be user or eva");
    return good(value);
};

const parseIdempotencyKey = (value: unknown): Parsed<string | null> => {
    if (value === undefined || value === null) return good(null);
    if (typeof value !== "string" || value.length < 1 || value.length > 128) {
        return bad("idempotencyKey must be 1–128 characters");
    }
    return good(value);
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
    typeof value === "object" && value !== null && !Array.isArray(value);

const parseCyclePayload = (body: Record<string, unknown>): Parsed<CyclePayload> => {
    const hasSpotting = body.spotting !== undefined && body.spotting !== null;
    const hasFlow = body.flow !== undefined && body.flow !== null;
    // Spotting is a marker, not a flow level: a spotting day does not start a period.
    if (hasSpotting && hasFlow) {
        return bad("A cycle entry is either spotting or a flow level, not both");
    }
    if (hasSpotting) {
        return body.spotting === true
            ? good({ spotting: true })
            : bad("spotting must be true when present");
    }
    if (hasFlow) {
        return body.flow === "light" || body.flow === "medium" || body.flow === "heavy"
            ? good({ flow: body.flow })
            : bad("flow must be light, medium or heavy");
    }
    return bad("A cycle entry needs either spotting or a flow level");
};

const parseRating = (value: unknown, name: string): Parsed<number | undefined> => {
    if (value === undefined || value === null) return good(undefined);
    if (typeof value !== "number" || !Number.isInteger(value) || value < 1 || value > 5) {
        return bad(`${name} must be a whole number from 1 to 5`);
    }
    return good(value);
};

/** Codes are checked against the catalogue `refdata.ts` serves, so the client and the
 *  validator agree on one vocabulary (PRD:484). `rules` is null when the catalogue is
 *  unavailable — codes then stay opaque, as they were before #24, because refusing a
 *  health entry over missing reference data is the worse failure.
 *
 *  A *retired* code is accepted: an offline queue may hold an entry logged while the
 *  chip was still offered, and the user must still be able to edit it. Only a code the
 *  catalogue has never carried is rejected. */
const parseSymptoms = (value: unknown, rules: SymptomRules | null): Parsed<Symptom[]> => {
    if (value === undefined || value === null) return good([]);
    if (!Array.isArray(value)) return bad("symptoms must be a list");
    if (value.length > 40) return bad("symptoms must hold 40 entries or fewer");
    const symptoms: Symptom[] = [];
    for (const entry of value) {
        if (!isRecord(entry)) return bad("each symptom must be an object");
        const { severity } = entry;
        if (typeof entry.code !== "string" || entry.code.trim().length < 1 || entry.code.length > 64) {
            return bad("each symptom needs a code of 1–64 characters");
        }
        const code = entry.code.trim();
        if (rules && !rules.has(code)) {
            // Its own code so a stale client can refetch /refdata instead of guessing.
            return bad(`Unknown symptom code: ${code}`, "UNKNOWN_SYMPTOM_CODE");
        }
        if (severity !== undefined && severity !== null && severity !== "normal" && severity !== "severe") {
            return bad("symptom severity must be normal or severe");
        }
        const parsedValue = parseSymptomValue(entry.value, code, rules);
        if (!parsedValue.ok) return parsedValue;
        if (symptoms.some((s) => s.code === code)) {
            return bad(`symptom ${code} is listed twice`);
        }
        symptoms.push({
            code,
            severity: (severity as SymptomSeverity) ?? "normal",
            // Absent, never undefined: Firestore rejects an undefined field.
            ...(parsedValue.value !== undefined ? { value: parsedValue.value } : {}),
        });
    }
    return good(symptoms);
};

/** The chip's own picker (discharge: dry/sticky/creamy/watery/egg-white). Optional
 *  even where the catalogue offers one — a chip logged without a choice is still a
 *  logged chip — but a value the catalogue does not offer is a client bug. */
const parseSymptomValue = (
    value: unknown,
    code: string,
    rules: SymptomRules | null,
): Parsed<string | undefined> => {
    if (value === undefined || value === null) return good(undefined);
    if (typeof value !== "string" || value.trim().length < 1 || value.length > 64) {
        return bad("symptom value must be 1–64 characters");
    }
    const trimmed = value.trim();
    if (!rules) return good(trimmed);
    const allowed = rules.valuesFor(code);
    if (!allowed) return bad(`symptom ${code} does not take a value`);
    if (!allowed.includes(trimmed)) {
        return bad(`symptom ${code} value must be one of ${allowed.join(", ")}`);
    }
    return good(trimmed);
};

const parseBodySignalsPayload = (
    body: Record<string, unknown>,
    rules: SymptomRules | null,
): Parsed<BodySignalsPayload> => {
    const energy = parseRating(body.energy, "energy");
    if (!energy.ok) return energy;
    const mood = parseRating(body.mood, "mood");
    if (!mood.ok) return mood;
    const sleep = parseRating(body.sleep, "sleep");
    if (!sleep.ok) return sleep;
    const symptoms = parseSymptoms(body.symptoms, rules);
    if (!symptoms.ok) return symptoms;
    // Absent ratings stay absent — nothing is preselected, and 3 is not "unanswered".
    return good({
        ...(energy.value !== undefined ? { energy: energy.value } : {}),
        ...(mood.value !== undefined ? { mood: mood.value } : {}),
        ...(sleep.value !== undefined ? { sleep: sleep.value } : {}),
        symptoms: symptoms.value,
    });
};

const parseSportPayload = (body: Record<string, unknown>): Parsed<SportPayload> => {
    const { activity, durationMin, intensity } = body;
    if (typeof activity !== "string" || activity.trim().length < 1 || activity.length > 64) {
        return bad("activity must be 1–64 characters");
    }
    if (
        typeof durationMin !== "number" ||
        !Number.isInteger(durationMin) ||
        durationMin < 5 ||
        durationMin > 300
    ) {
        return bad("durationMin must be a whole number of minutes from 5 to 300");
    }
    if (intensity !== "light" && intensity !== "medium" && intensity !== "hard") {
        return bad("intensity must be light, medium or hard");
    }
    return good({ activity: activity.trim(), durationMin, intensity });
};

const parseAppointmentPayload = (
    body: Record<string, unknown>,
    localDate: string,
): Parsed<AppointmentPayload> => {
    const { startAt, type, questions, reminderMinutesBefore } = body;
    if (typeof startAt !== "string" || !LOCAL_DATETIME.test(startAt)) {
        return bad("startAt must be a local YYYY-MM-DDTHH:mm:ss");
    }
    const normalizedStart = startAt.length === 16 ? `${startAt}:00` : startAt;
    if (!normalizedStart.startsWith(`${localDate}T`)) {
        return bad("startAt must fall on the appointment's localDate");
    }
    if (type !== undefined && type !== null && (typeof type !== "string" || type.length > 64)) {
        return bad("type must be 64 characters or fewer");
    }
    const list: string[] = [];
    if (questions !== undefined && questions !== null) {
        if (!Array.isArray(questions)) return bad("questions must be a list");
        if (questions.length > 50) return bad("questions must hold 50 entries or fewer");
        for (const question of questions) {
            if (typeof question !== "string" || question.trim().length < 1 || question.length > 500) {
                return bad("each question must be 1–500 characters");
            }
            list.push(question.trim());
        }
    }
    // Omitted means the PRD's default of one day before; explicit null means none.
    let reminder: number | null = 1440;
    if (reminderMinutesBefore === null) reminder = null;
    else if (reminderMinutesBefore !== undefined) {
        if (
            typeof reminderMinutesBefore !== "number" ||
            !Number.isInteger(reminderMinutesBefore) ||
            reminderMinutesBefore < 0 ||
            reminderMinutesBefore > 40_320
        ) {
            return bad("reminderMinutesBefore must be a whole number of minutes from 0 to 40320");
        }
        reminder = reminderMinutesBefore;
    }
    return good({
        startAt: normalizedStart,
        type: typeof type === "string" && type.trim().length > 0 ? type.trim() : null,
        questions: list,
        reminderMinutesBefore: reminder,
    });
};

/** `rules` is fetched once per request at the route edge and threaded down, so
 *  validation stays here and `refdata.ts` stays the only reader of its collection. */
const parsePayload = (
    type: LoggableEventType,
    payload: unknown,
    localDate: string,
    rules: SymptomRules | null,
): Parsed<EventPayload> => {
    if (!isRecord(payload)) return bad("payload must be an object");
    switch (type) {
        case "cycle":
            return parseCyclePayload(payload);
        case "bodySignals":
            return parseBodySignalsPayload(payload, rules);
        case "sport":
            return parseSportPayload(payload);
        case "appointment":
            return parseAppointmentPayload(payload, localDate);
    }
};

const parseEventType = (value: unknown): Parsed<LoggableEventType> => {
    if (value === "sex") {
        // Reserved in the model; ships in C10 with its privacy switch.
        return bad("The sex event type is not available yet");
    }
    if (
        value !== "cycle" &&
        value !== "bodySignals" &&
        value !== "sport" &&
        value !== "appointment"
    ) {
        return bad("type must be cycle, bodySignals, sport or appointment");
    }
    return good(value);
};

const parseNewEvent = (
    body: Record<string, unknown>,
    rules: SymptomRules | null,
): Parsed<NewEvent> => {
    const type = parseEventType(body.type);
    if (!type.ok) return type;
    if (!isCalendarDate(body.localDate)) return bad("localDate must be YYYY-MM-DD");
    const localDate = body.localDate;

    const clock = resolveClock(body.timeZone);
    if (!clock.ok) return clock;
    const policy = checkDatePolicy(type.value, localDate, clock.value);
    if (!policy.ok) return policy;

    const loggedAt = parseLoggedAt(body.loggedAt, localDate, clock.value);
    if (!loggedAt.ok) return loggedAt;
    const note = parseNote(body.note, type.value);
    if (!note.ok) return note;
    const source = parseSource(body.source);
    if (!source.ok) return source;
    const idempotencyKey = parseIdempotencyKey(body.idempotencyKey);
    if (!idempotencyKey.ok) return idempotencyKey;
    const payload = parsePayload(type.value, body.payload, localDate, rules);
    if (!payload.ok) return payload;

    return good({
        type: type.value,
        localDate,
        loggedAt: loggedAt.value,
        note: note.value,
        source: source.value,
        idempotencyKey: idempotencyKey.value,
        payload: payload.value,
    } as NewEvent);
};

app.get("/me/events", requireAuth, async (c) => {
    const from = c.req.query("from");
    const to = c.req.query("to");
    if (!isCalendarDate(from) || !isCalendarDate(to)) {
        return c.json(error("VALIDATION", "from and to must be YYYY-MM-DD"), 400);
    }
    if (from > to) return c.json(error("VALIDATION", "from must not be after to"), 400);
    if (Date.parse(`${to}T00:00:00.000Z`) - Date.parse(`${from}T00:00:00.000Z`) >
        MAX_RANGE_DAYS * 86_400_000) {
        return c.json(
            error("VALIDATION", `Range must be ${MAX_RANGE_DAYS} days or fewer`),
            400,
        );
    }
    return c.json({ events: await listEvents(c.get("claims").sub, from, to) });
});

app.post("/me/events", requireAuth, async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const parsed = parseNewEvent(body, await getSymptomRules());
    if (!parsed.ok) return c.json(error(parsed.code, parsed.message), 400);
    return c.json({ event: await createEvent(c.get("claims").sub, parsed.value) }, 201);
});

app.patch("/me/events/:id", requireAuth, async (c) => {
    const body = await c.req.json().catch(() => ({}));
    // `type` and `localDate` are always required: with both, every payload and
    // timestamp rule can be checked here instead of after a read in the module.
    const type = parseEventType(body.type);
    if (!type.ok) return c.json(error(type.code, type.message), 400);
    if (!isCalendarDate(body.localDate)) {
        return c.json(error("VALIDATION", "localDate must be YYYY-MM-DD"), 400);
    }
    const localDate = body.localDate;
    const clock = resolveClock(body.timeZone);
    if (!clock.ok) return c.json(error(clock.code, clock.message), 400);
    const policy = checkDatePolicy(type.value, localDate, clock.value);
    if (!policy.ok) return c.json(error(policy.code, policy.message), 400);

    const patch: EventPatch = { type: type.value, localDate };
    if (body.note !== undefined) {
        const note = parseNote(body.note, type.value);
        if (!note.ok) return c.json(error(note.code, note.message), 400);
        patch.note = note.value;
    }
    if (body.payload !== undefined) {
        const payload = parsePayload(type.value, body.payload, localDate, await getSymptomRules());
        if (!payload.ok) return c.json(error(payload.code, payload.message), 400);
        patch.payload = payload.value;
    }
    if (body.loggedAt !== undefined) {
        const loggedAt = parseLoggedAt(body.loggedAt, localDate, clock.value);
        if (!loggedAt.ok) return c.json(error(loggedAt.code, loggedAt.message), 400);
        patch.loggedAt = loggedAt.value;
    }

    const result = await updateEvent(c.get("claims").sub, c.req.param("id"), patch);
    if (result.ok) return c.json({ event: result.event });
    if (result.reason === "not-found") return c.json(error("NOT_FOUND", "No such event"), 404);
    if (result.reason === "type-mismatch") {
        return c.json(error("VALIDATION", "type does not match the stored event"), 400);
    }
    return c.json(
        error("VALIDATION", "This entry is one per day — delete it and log the other day instead"),
        400,
    );
});

app.delete("/me/events/:id", requireAuth, async (c) => {
    const deleted = await softDeleteEvent(c.get("claims").sub, c.req.param("id"));
    if (!deleted) return c.json(error("NOT_FOUND", "No such event"), 404);
    return c.json({ deleted: true });
});

/** Upsert-by-day: one body signals entry per user per day, always replaced whole.
 *  The ratings sit at the top level here — the route already says what this is. */
app.put("/me/body-signals/:date", requireAuth, async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const localDate = c.req.param("date");
    if (!isCalendarDate(localDate)) {
        return c.json(error("VALIDATION", "date must be YYYY-MM-DD"), 400);
    }

    const clock = resolveClock(body.timeZone);
    if (!clock.ok) return c.json(error(clock.code, clock.message), 400);
    const policy = checkDatePolicy("bodySignals", localDate, clock.value);
    if (!policy.ok) return c.json(error(policy.code, policy.message), 400);

    const payload = parseBodySignalsPayload(body, await getSymptomRules());
    if (!payload.ok) return c.json(error(payload.code, payload.message), 400);
    const loggedAt = parseLoggedAt(body.loggedAt, localDate, clock.value);
    if (!loggedAt.ok) return c.json(error(loggedAt.code, loggedAt.message), 400);
    const note = parseNote(body.note, "bodySignals");
    if (!note.ok) return c.json(error(note.code, note.message), 400);
    const source = parseSource(body.source);
    if (!source.ok) return c.json(error(source.code, source.message), 400);
    const idempotencyKey = parseIdempotencyKey(body.idempotencyKey);
    if (!idempotencyKey.ok) return c.json(error(idempotencyKey.code, idempotencyKey.message), 400);

    const event = await createEvent(c.get("claims").sub, {
        type: "bodySignals",
        localDate,
        loggedAt: loggedAt.value,
        note: note.value,
        source: source.value,
        idempotencyKey: idempotencyKey.value,
        payload: payload.value,
    });
    return c.json({ event });
});

export default {
    // Cloud Run injects PORT (8080); default to 3003 for local dev
    port: Number(process.env.PORT ?? 3003),
    fetch: app.fetch,
};
