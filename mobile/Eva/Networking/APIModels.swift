import Foundation

/// The account as the API describes it. **Decoded, never encoded** — nothing sends a user,
/// and the synthesized `Encodable` half only ever existed because `profile` used to be typed
/// as the request body (#215).
struct APIUser: Decodable {
    let id: String
    let email: String
    let questionnaireCompleted: Bool
    /// Whether the address has been confirmed through the activation link (#6).
    ///
    /// Decoded when the API sends it and defaulted to `true` when it does not. Not a
    /// guess: a user this client can see at all is one it holds a session for, and the
    /// activation gate refuses a session to anyone who is not activated — so an absent
    /// field can only describe an activated account. Being tolerant here is what lets a
    /// build of this app validate a session against an API that predates the field.
    let activated: Bool
    /// The ways this account can be signed in to — `"password"`, `"apple.com"`,
    /// `"google.com"` (#7) — **Firebase's** provider ids, not the words the app sends in a
    /// request body.
    ///
    /// Assembled by the API for each response, not a stored copy (#117): `apple.com` and
    /// `google.com` come from Firebase Auth's own record of the account at that moment, and
    /// `password` means she chose a password through Eva (Firebase alone would also list the
    /// random one a provider sign-up is given). So a provider unlinked server-side drops out
    /// on the next response. It is for display and for the client's own decisions — the
    /// Connect buttons, and whether to ask Apple for a revocation code on delete — and the
    /// server authorizes nothing from it.
    ///
    /// This comment said `"apple"` and `"google"` until the review of #7. It was wrong, and
    /// it was the source of the defect: `EvaAuthProvider.rawValue` was compared against
    /// these strings, so Profile showed Apple as unconnected for every Apple user and the
    /// delete flow skipped Apple revocation — an App Review requirement — in silence. Use
    /// `EvaAuthProvider.firebaseProviderID`, never `rawValue`.
    ///
    /// Defaults to **empty**, not to `["password"]`, when the API does not send it. Empty
    /// is the honest reading of an absent field: it says *this build cannot tell you*,
    /// and Profile draws nothing rather than asserting a sign-in method the server never
    /// claimed. Guessing "password" would be right for every account that exists today
    /// and wrong for the first Apple-only one — and it would be the delete flow's cue to
    /// skip Apple revocation, which is the expensive way to be wrong.
    let authProviders: [String]
    /// Whether she dismissed the "complete your profile" nudge (#19). Server-side, so a
    /// dismissal survives reinstall and a second device. `false` when the API does not send
    /// it, the same tolerant read `activated` takes: the field predates the API's own
    /// introduction and an absent one only ever describes a pre-#19 account, which has never
    /// dismissed anything.
    let profileNudgeDismissed: Bool
    /// The stored profile, or `nil` until the questionnaire is answered.
    ///
    /// **`APIProfile`, not `ProfilePayload`** — what the app sends and what the API returns
    /// are different shapes, and #211 found that out the expensive way. It added `timeZone`
    /// to the payload; the API reads it to resolve *her* day and deliberately never stores
    /// it, so the moment a response carried a profile it stopped decoding. `PUT
    /// /me/questionnaire` threw `.decoding` and left her on the last questionnaire step,
    /// and `GET /me` threw the same at every launch afterwards, which `bootstrap()` reads
    /// as `.unreachable` (#215).
    let profile: APIProfile?
    /// The account's consent record (#86), as the API serves it. `nil` when the API does
    /// not send `consent` at all — an API that predates #86 also has no refusal gate, so
    /// a nil here means "this server never asks", not "she never consented", and the
    /// session must not be gated on it. A sent-but-empty record is the real never-asked
    /// state, and that one does gate.
    let consent: APIUserConsent?

    /// Spelled out rather than synthesized. `Codable` used to generate it as a side effect
    /// of the `Encodable` half nothing ever called; a type with a hand-written
    /// `init(from:)` and no encoding to synthesize gets no keys of its own.
    private enum CodingKeys: String, CodingKey {
        case id, email, questionnaireCompleted, activated, authProviders, profileNudgeDismissed, profile, consent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        questionnaireCompleted = try container.decode(Bool.self, forKey: .questionnaireCompleted)
        activated = try container.decodeIfPresent(Bool.self, forKey: .activated) ?? true
        authProviders = try container.decodeIfPresent([String].self, forKey: .authProviders) ?? []
        profileNudgeDismissed = try container.decodeIfPresent(Bool.self, forKey: .profileNudgeDismissed) ?? false
        profile = try container.decodeIfPresent(APIProfile.self, forKey: .profile)
        consent = try container.decodeIfPresent(APIUserConsent.self, forKey: .consent)
    }

    /// Whether an identity provider is attached to this account.
    ///
    /// `authProviders` holds Firebase's provider ids (`apple.com`), not the word the
    /// request body uses (`apple`) — so this compares against `firebaseProviderID`. Using
    /// `rawValue` here made this return `false` for every account ever.
    func isConnected(_ provider: EvaAuthProvider) -> Bool {
        authProviders.contains(provider.firebaseProviderID)
    }

    /// The provider string for an email-and-password sign-in. Not an `EvaAuthProvider`:
    /// there is no button for it, because it is the form underneath them.
    static let passwordProvider = "password"

    /// Whether an address and password can sign this account in.
    var hasPassword: Bool {
        authProviders.contains(Self.passwordProvider)
    }

    /// Whether the "complete your profile" nudge is still owed (#19). It shows while the
    /// profile is incomplete *and* has not been dismissed; completing the profile clears the
    /// first, dismissing clears the second, and either one is enough to stop asking.
    var needsProfileNudge: Bool {
        !questionnaireCompleted && !profileNudgeDismissed
    }

    /// Whether this account still owes the consent screen (#86).
    ///
    /// Three ways to be past it, and each is its own line because each means something
    /// different: an API that predates the field never asks (`consent == nil`); a record
    /// with `withdrawnAt` set was asked, granted, and withdrawn — the freeze, which stops
    /// collection without deleting anything and is *not* re-asked, because a screen that
    /// demanded consent she has already declined would be nagging, and the remedy lives in
    /// Settings › Privacy; and a granted record under the version this build displays is
    /// the normal consented state. Anything else — no collect record, or one recorded
    /// against a text this build no longer shows — is the screen again, which is the whole
    /// point of storing the version: "if the terms change, Eva asks again" (canvas).
    func needsConsentGate(currentVersion: String) -> Bool {
        guard let consent else { return false }
        guard let collect = consent.collect else { return true }
        if collect.withdrawnAt != nil { return false }
        return collect.version != currentVersion
    }
}

/// The two consent kinds the API records (#86), keyed as `users/{uid}.consent` holds them.
/// `share` governs nothing today — its scope is on #86 — and is still decoded, because a
/// wire type that quietly drops what it is given is the same mistake seen from the other
/// side.
struct APIUserConsent: Decodable {
    let collect: APIUserConsentRecord?
    let share: APIUserConsentRecord?
}

/// One recorded consent: which text she saw (`version`), when she granted it (`at`), and
/// whether she has withdrawn it since (`withdrawnAt`, `nil` while the grant stands). The
/// instants arrive as ISO-8601 strings, as every timestamp the API serves does.
struct APIUserConsentRecord: Decodable {
    let version: String
    let at: String
    let withdrawnAt: String?
}

/// The profile as the API **returns** it: `users.ts`' `Profile`, field for field.
///
/// Its own type rather than `ProfilePayload`, which is what the app **sends**. The two agree
/// on eight fields and differ on one — `timeZone` is a request parameter, not a stored fact
/// — and one type standing for both turned that difference into a decode failure on every
/// response that carried a profile (#215). `Decodable` only, so the difference cannot be
/// re-erased by using this as a body.
///
/// Nothing reads these fields yet; Profile is #19. They are decoded because the server sends
/// them, and a wire type that quietly drops what it is given is the same mistake seen from
/// the other side.
struct APIProfile: Decodable {
    let dateOfBirth: String
    /// `Double`, matching what `ProfilePayload` sends and what `users.ts` declares — a TypeScript
    /// `number`, which `parseProfile` validates as a finite number in a range and never as an
    /// integer. A weight typed in pounds is stored as the kilograms it converts to (#82), so
    /// `68.04` comes back on the wire and an `Int` here would be #215 again in a new costume.
    let weightKg: Double
    let heightCm: Double
    let goals: [String]
    let conditions: [String]
    let medications: String
    /// The activity band as a code — `mostlySitting`, `lightlyActive`, `active`,
    /// `veryActive` — or `nil` when she has not given one the API can read (#221).
    ///
    /// **Read tolerantly, see `init(from:)`.** The band is the one profile answer the
    /// nutrition engine does arithmetic with, so it stopped being the chip's English label
    /// and became a code. An API from before #221 still serves the label, and a string this
    /// build does not know — a fifth band, a reworded label — must not fail the whole
    /// `GET /me` decode, which `bootstrap()` reads as `.unreachable` (#215).
    let lifestyle: String?
    let sports: [String]
}

extension APIProfile {

    /// The four labels the app sent before #221 — `users.ts`' `LIFESTYLE_LABELS`, the same
    /// exact-match table the API reads stored documents with. **Frozen:** this is what was
    /// on the wire, not what the chips say now, so rewording a chip must not change it.
    static let legacyLifestyleLabels: [String: String] = [
        "Mostly sitting": "mostlySitting",
        "Lightly active": "lightlyActive",
        "Active": "active",
        "Very active": "veryActive",
    ]

    /// A served `lifestyle` read as a code this build offers, or `nil`. A code passes
    /// through, a legacy label maps, and anything else is unanswered rather than guessed —
    /// the nearest plausible band is a plausible calorie target, which is the defect.
    static func lifestyleCode(fromServed raw: String?) -> String? {
        guard let raw else { return nil }
        let code = legacyLifestyleLabels[raw] ?? raw
        return ProfileEditorModel.lifestyleOptions.contains { $0.code == code } ? code : nil
    }

    private enum CodingKeys: String, CodingKey {
        case dateOfBirth, weightKg, heightCm, goals, conditions, medications, lifestyle, sports
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dateOfBirth = try container.decode(String.self, forKey: .dateOfBirth)
        weightKg = try container.decode(Double.self, forKey: .weightKg)
        heightCm = try container.decode(Double.self, forKey: .heightCm)
        goals = try container.decode([String].self, forKey: .goals)
        conditions = try container.decode([String].self, forKey: .conditions)
        medications = try container.decode(String.self, forKey: .medications)
        // `try?` as well as `IfPresent`: a non-string here is as unreadable as an unknown
        // string, and just as little reason to lose the rest of the account.
        lifestyle = Self.lifestyleCode(
            fromServed: (try? container.decodeIfPresent(String.self, forKey: .lifestyle)) ?? nil
        )
        sports = try container.decode([String].self, forKey: .sports)
    }
}

/// `PUT /me/questionnaire`'s body.
///
/// **A date of birth, not an age** (#81): the API stores the date and derives the age, so a
/// profile cannot go quietly stale between birthdays. `conditions`, `medications` and
/// `lifestyle` carry `ProfileOption` codes, never the labels the chips draw. `timeZone` is
/// not stored — the API uses it to resolve which day "today" is when it checks the 18+ floor.
///
/// **`Encodable`, not `Codable`.** That last sentence is the whole of #215: a field the API
/// never sends back cannot be part of a type anything decodes, and a comment saying so did
/// not stop it. `APIProfile` is the response shape; this one only goes out.
struct ProfilePayload: Encodable {
    let dateOfBirth: String
    /// SI, always — the device converts at the edge and never stores what it displayed
    /// (#82, `EvaBodyUnits`). `Double` because whole kilograms cannot represent a pound:
    /// `parseProfile` has always validated these as finite numbers in a range rather than
    /// as integers, and `JSONEncoder` writes a whole `Double` as `64`, so a metric entry
    /// sends the bytes it always sent.
    let weightKg: Double
    let heightCm: Double
    let goals: [String]
    let conditions: [String]
    let medications: String
    /// An activity-band code, or `nil` — which the synthesized encoder **omits**, the way
    /// every unanswered field in this app's bodies is omitted. Never `""`: `parseProfile`
    /// takes one of the four codes or no answer at all (#221), and an empty string is
    /// neither. Omitting is what lets a save from any *other* editor go through while the
    /// band is still unanswered; only the Activity editor holds Save for it.
    let lifestyle: String?
    let sports: [String]
    let timeZone: String
}

struct AuthResponse: Decodable {
    let token: String
    let user: APIUser
}

/// `POST /auth/signup` replies `201 { pending: true, email }` — no session (#6). The
/// account exists but cannot sign in until the emailed link is opened.
struct SignUpResponse: Decodable {
    let pending: Bool
    let email: String
}

/// `POST /auth/activation/resend` and `POST /auth/password/forgot` both reply
/// `{ sent: true }` whether or not the address is registered — the response must not say
/// which addresses have accounts (#6, ARCHITECTURE §3).
struct SentResponse: Decodable {
    let sent: Bool
}

struct UserResponse: Decodable {
    let user: APIUser
}

/// `DELETE /me` replies `{ "deleted": true }`. `AppSession.deleteAccount` checks the flag
/// rather than treating any 2xx as success — see the note there.
struct DeleteAccountResponse: Decodable {
    let deleted: Bool
}

struct Credentials: Encodable {
    let email: String
    let password: String
}

/// The body of every route that takes an address and nothing else: the two "send me an
/// email" routes, and — since #120 — sign-up, which no longer takes a password because it
/// no longer creates an account.
struct EmailAddress: Encodable {
    let email: String
}

/// The two consent kinds, in the API's own spelling — the `:kind` of `PUT /me/consent/:kind`
/// (#86). The record on `users/{uid}` is keyed the same way.
enum EvaConsentKind: String {
    case collect
    case share
}

/// The body `PUT /me/consent/:kind` takes (#86). `version` is present only when granting —
/// it names the text the screen displayed; withdrawing sends `nil`, because the text being
/// withdrawn from is the one the record already holds.
struct ConsentRequestBody: Encodable {
    let granted: Bool
    let version: String?
}

/// What an identity provider handed the app, in the shape `POST /auth/idp` and
/// `POST /me/auth/providers` both take (#7).
///
/// The two routes take the **same** body and differ only in whether they carry a bearer
/// token: unauthenticated it signs you in or creates an account, authenticated it attaches
/// the provider to the account you are already in. So there is one type here rather than
/// two identical ones.
///
/// Note what is *not* in either case: no Firebase ID token, no Google access token, no
/// Apple refresh token. The app forwards a single-use credential and the API does
/// everything else (ARCHITECTURE §2), which is why the app never has a provider session
/// to keep, refresh or leak.
enum ProviderCredential: Encodable, Sendable {

    /// Apple's `identityToken`, with the **raw** nonce whose SHA-256 the app put in the
    /// authorization request. The pairing is the replay defence — see
    /// `AppleSignInController`.
    case apple(identityToken: String, rawNonce: String)

    /// Google's authorization `code`, the PKCE verifier that unlocks it, and the exact
    /// `redirect_uri` Google was given. All three are needed at the token exchange, and
    /// the redirect has to match character for character or Google refuses the grant.
    case google(code: String, codeVerifier: String, redirectUri: String)

    /// Which provider this is, in the API's own spelling.
    var provider: EvaAuthProvider {
        switch self {
        case .apple: .apple
        case .google: .google
        }
    }

    private enum CodingKeys: String, CodingKey {
        case provider, identityToken, rawNonce, code, codeVerifier, redirectUri
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider.rawValue, forKey: .provider)
        switch self {
        case .apple(let identityToken, let rawNonce):
            try container.encode(identityToken, forKey: .identityToken)
            try container.encode(rawNonce, forKey: .rawNonce)
        case .google(let code, let codeVerifier, let redirectUri):
            try container.encode(code, forKey: .code)
            try container.encode(codeVerifier, forKey: .codeVerifier)
            try container.encode(redirectUri, forKey: .redirectUri)
        }
    }
}

/// The optional body of `DELETE /me` (#7).
///
/// Apple requires an app that offers both Sign in with Apple and in-app account deletion
/// to revoke its token on delete, and Eva deliberately stores no Apple refresh token —
/// so the code is obtained fresh at the moment of deletion and sent here. It is optional
/// on the route on purpose: an account with no Apple provider has none, and a user who
/// declines the re-authorization still gets their account deleted.
struct DeleteAccountRequest: Encodable {
    let appleAuthorizationCode: String
}

/// `PUT /me/devices/{deviceId}`'s body (#79): the APNs device token, which APNs environment
/// it belongs to, and the device's own IANA time zone — stored on `users/{uid}/devices/` so
/// the sender job can resolve a wall-clock reminder in the zone it was set for. The token is
/// an identifier that reaches Apple; it is a credential, never logged and never shown.
struct DeviceRegistration: Encodable {
    let token: String
    let environment: String
    let timeZone: String
}

struct DeviceRegisteredResponse: Decodable {
    let registered: Bool
}

struct DeviceRemovedResponse: Decodable {
    let removed: Bool
}
