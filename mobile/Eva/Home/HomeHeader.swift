import SwiftUI

/// The Home tab's header: the `eva.` lockup, a greeting, and the two buttons the canvas
/// draws beside them.
///
/// ## The greeting has no name in it, and that is not a bug in this file
///
/// The artboard says "Good morning, Maria". **Eva stores no name.** `APIUser` is an id, an
/// address, the activation flag, the providers and the questionnaire `profile` — there is
/// no given name anywhere in the API, and #19's Edit profile is where one would arrive.
/// Substituting the address would read "Good morning, e2e+4f1c…", which is worse than
/// saying less, so the greeting is the time of day alone. When a name exists it goes here
/// and the artboard is satisfied.
///
/// The time of day is not an invention: the artboard draws "Good morning" beside an
/// offline bar stamped 08:12, and a card that says "Good morning" at eleven at night would
/// be the app asserting something it can check and got wrong.
struct HomeHeader: View {

    /// The signed-in address. Only its first letter is drawn — see `avatarInitial`.
    let email: String?
    let openProfile: () -> Void
    /// Injected so the preview and the tests can ask from a fixed hour.
    var now: Date = Date()
    var calendar: Calendar = .current

    var body: some View {
        HStack(spacing: EvaSpacing.sm) {
            wordmark

            Text(Self.greeting(at: now, calendar: calendar))
                // `font:600 14px` — between the §3 Button row (14.5/600) and Text button
                // (14/600). Text button is the exact size and weight.
                .evaTextStyle(.textButton)
                .foregroundStyle(Color.evaPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, EvaSpacing.xxs)
                .accessibilityIdentifier("home.greeting")

            notificationsButton
            profileButton
        }
        .frame(minHeight: EvaHomeMetrics.headerHeight)
    }

    /// The `eva.` lockup — the word in Primary Text, the full stop in Deep Pistachio.
    ///
    /// Drawn here rather than borrowed from `AuthWordmark`, which is the same lockup at a
    /// different size (30 against 22) inside the onboarding folder. Generalising it would
    /// be a refactor of a screen this issue does not touch (GUARDRAILS 27); the size is
    /// `EvaTextStyle.homeWordmark`, and the duplication is reported.
    private var wordmark: some View {
        (
            Text("eva").foregroundStyle(Color.evaPrimaryText)
                + Text(".").foregroundStyle(Color.evaDeepPistachio)
        )
        .evaTextStyle(.homeWordmark)
        .accessibilityLabel(Text("Eva"))
        .accessibilityAddTraits(.isHeader)
    }

    /// The bell, drawn and inert.
    ///
    /// #99 keeps it "as drawn … inert until §Notifications is sliced". Two things about
    /// how that is drawn here:
    ///
    /// * **No unread badge.** The artboard puts a 7pt pink dot on it. A dot is a claim
    ///   that something is waiting, Eva sends nothing yet, and DESIGN.md §8 is about not
    ///   saying things that are not true — so the dot arrives with notifications.
    /// * The reason is in the label, not only in the dimming, the same way the card's
    ///   unavailable actions carry theirs.
    private var notificationsButton: some View {
        Button(action: {}) {
            Image(systemName: "bell")
                .font(.evaControlText)
                .foregroundStyle(Color.evaSecondaryText)
                .frame(
                    width: EvaHomeMetrics.headerButtonSize,
                    height: EvaHomeMetrics.headerButtonSize
                )
                .background {
                    let shape = RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
                    shape
                        .fill(EvaGlassLevel.background.material)
                        .overlay { shape.fill(Color.white.opacity(0.62)) }
                        .overlay { shape.strokeBorder(Color.white.opacity(0.85), lineWidth: 1) }
                }
        }
        .buttonStyle(.evaUndimmed)
        .disabled(true)
        .accessibilityIdentifier("home.notifications")
        .accessibilityLabel("Notifications. \(EvaTodayCardTarget.unavailableSuffix)")
    }

    /// The avatar square, which opens Profile.
    ///
    /// The artboard fills it `linear-gradient(150deg,#F3AEC4,#C95F86)` with a white letter.
    /// White on that ramp measures 2.22:1 at the light stop — the §9a failure the action
    /// ramp exists for, and a letter is a label — so the fill is `LinearGradient.evaActionPink`
    /// (4.76:1 → 6.12:1). The artboard's 150° becomes the ramp's 180°, which is the same
    /// trade every other white-on-pink surface in the app has taken since #12.
    private var profileButton: some View {
        Button(action: openProfile) {
            Text(avatarInitial)
                .evaTextStyle(.button)
                .foregroundStyle(Color.evaTextOnDark)
                .frame(
                    width: EvaHomeMetrics.headerButtonSize,
                    height: EvaHomeMetrics.headerButtonSize
                )
                .background(
                    LinearGradient.evaActionPink,
                    in: .rect(cornerRadius: EvaRadius.chip, style: .continuous)
                )
        }
        .buttonStyle(.evaUndimmed)
        .accessibilityIdentifier("home.profile")
        .accessibilityLabel("Profile")
    }

    /// The artboard's "M".
    ///
    /// It is Maria's initial, and Eva has no name to take one from — so this is the
    /// address's first letter, which is the same letter for the artboard's own example
    /// (`maria.ferreira@gmail.com`). One character of an address the user typed into this
    /// device, on this device; the same screen's Profile tab shows the whole address. It
    /// becomes a real initial when #19 gives the profile a name.
    private var avatarInitial: String {
        guard let first = email?.trimmingCharacters(in: .whitespaces).first,
              first.isLetter
        else { return "?" }
        return String(first).uppercased()
    }

    /// Morning before noon, afternoon before six, evening after.
    ///
    /// Not a canvas value — the artboard draws one greeting at one hour. The boundaries
    /// are the ordinary English ones; nothing here counts anything or congratulates
    /// anybody, which is the only thing DESIGN.md §8 has to say about a greeting.
    static func greeting(at date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case ..<12: "Good morning"
        case ..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}

#Preview("Home header") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        VStack(spacing: EvaSpacing.lg) {
            HomeHeader(email: "maria.ferreira@example.com", openProfile: {})
            HomeHeader(
                email: "maria.ferreira@example.com",
                openProfile: {},
                now: Date(timeIntervalSince1970: 1_756_000_000)
            )
        }
        .padding(EvaSpacing.lg)
    }
}
