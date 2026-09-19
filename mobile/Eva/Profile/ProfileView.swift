import SwiftUI

/// The Profile screen, cut down to the one thing #55 needs it for: somewhere the user
/// can delete their account from inside the app, which Apple requires of any app that
/// can create one.
///
/// **This is a third of the designed screen, deliberately.** "Eva App.dc.html", rail
/// item **Settings**, draws an avatar, an Edit control, a cycle-tracking status pill and
/// five sections of settings rows above the danger zone. All of that is #19. What is
/// here is the identity header reduced to the one identity fact the app actually holds
/// today, the connected-accounts card #7 needed, the Log out row, and the danger card —
/// laid out in the artboard's own shape and rhythm so #19 grows into this screen rather
/// than replacing it.
///
/// ## Where this rounds the artboard off
///
/// * **The identity header carries an email, not a name.** The artboard's card leads
///   with "Maria" and puts the address under it in grey; the app has no name to show —
///   `APIUser` is id, email and questionnaire state — so the address becomes the card's
///   value line under a §3 Label. The avatar, the Edit button and the cycle pill are all
///   #19.
/// * **Card radius is `EvaRadius.card` (24), not the artboard's 22**, and the section
///   gaps are `EvaSpacing` steps rather than the artboard's off-scale 22/36. 22 is not a
///   named radius and 22/36 are not on the 8-pt scale (DESIGN.md §4); inventing tokens
///   for one screen is a design decision, so the nearest named values are used and the
///   difference is reported.
/// * **The danger card's fill and border are the §2 Error tint and border** —
///   `rgba(196,100,90,.08)` / `.26` — where this artboard draws `.06` / `.22`. Same
///   colour, two points of alpha apart, and the semantic tokens already exist.
/// * **The delete button is the full-size outlined destructive.** The artboard draws an
///   inline 44-high control at radius 14 here, which is the `.row` variant's shape with
///   the outlined variant's border; §5's outlined destructive is the variant this is,
///   and it is what the danger card should carry when it is the only action in it.
/// * **No version footer.** The artboard's "Eva 2.4.1 · Not a medical device" line needs
///   a real version string and belongs with the rest of #19's chrome.
/// * **Connected accounts is a card, not a row with a chevron.** See the section itself:
///   the artboard's row points at a detail screen the canvas never draws.
struct ProfileView: View {

    let session: AppSession
    /// The device's units setting (#82). The artboard's `Eva experience ▸ Units` row is
    /// the first settings row this screen has, and the first piece of #19 to land here.
    let units: EvaUnitPreference

    /// The editable profile behind the Personal profile rows (#19). Seeded from the
    /// account's stored profile; a new account gets the same defaults the questionnaire
    /// used to start from.
    @State private var editor: ProfileEditorModel

    @State private var isConfirmingDeletion = false

    init(session: AppSession, units: EvaUnitPreference) {
        self.session = session
        self.units = units
        _editor = State(initialValue: ProfileEditorModel(profile: session.user?.profile))
    }

    var body: some View {
        ZStack {
            EvaScreenBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: EvaSpacing.lg) {
                    Text("Profile")
                        .evaTextStyle(.h1)
                        .foregroundStyle(Color.evaPrimaryText)

                    identityCard
                    personalProfileSection
                    connectedAccountsCard
                    evaExperienceSection
                    logOutCard
                    dangerZone
                        // The artboard sets the danger zone further off than it sets the
                        // cards from each other (36 against 22). `EvaSpacing.xl` is the
                        // scale's "gap between sections"; the stack already contributes
                        // `.lg`, so this adds the difference.
                        .padding(.top, EvaSpacing.xl - EvaSpacing.lg)
                }
                .padding(.horizontal, EvaSpacing.lg)
                .padding(.top, EvaSpacing.xs)
                .padding(.bottom, EvaSpacing.xxl)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // A cover rather than a sheet: the artboard draws the scrim over the whole
        // frame, and a sheet would leave the navigation bar sitting outside it.
        // `.presentationBackground(.clear)` is what lets the modal draw its own.
        .fullScreenCover(isPresented: $isConfirmingDeletion) {
            DeleteAccountModal(session: session) { isConfirmingDeletion = false }
                .presentationBackground(.clear)
        }
    }

    // MARK: - Sections

    /// The artboard's header card, reduced to the identity the app actually has.
    private var identityCard: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            Text("Signed in as")
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaSecondaryText)

            Text(session.user?.email ?? "—")
                .evaTextStyle(.bodyMedium)
                .foregroundStyle(Color.evaPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("profile.email")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .evaCardSurface()
    }

    /// The artboard's **Personal profile** section — the questionnaire fields as settings
    /// rows (#19).
    ///
    /// Each row pushes to an editor for that field group, and each editor's Save re-sends
    /// the whole profile (`PUT /me/questionnaire`). The row order and labels are the
    /// artboard's own; the detail screens are composed out of the existing chip and
    /// body-metric controls, because the canvas draws the rows and not the screens behind
    /// them.
    private var personalProfileSection: some View {
        ProfileSettingsSection(title: "Personal profile") {
            ProfileSettingsRow(
                label: "Body measurements",
                meta: "Date of birth, height, weight",
                value: "",
                identifier: "profile.bodyMeasurements"
            ) {
                BodyMeasurementsSettingsView(editor: editor, units: units, session: session)
            }

            ProfileSettingsRow(
                label: "Goals & lifestyle",
                value: goalsValue,
                identifier: "profile.goals"
            ) {
                GoalsSettingsView(editor: editor, session: session)
            }

            ProfileSettingsRow(
                label: "Activity",
                meta: "Mostly sitting · Lightly active · Active · Very active",
                value: editor.lifestyle ?? "",
                identifier: "profile.activity"
            ) {
                ActivitySettingsView(editor: editor, session: session)
            }

            ProfileSettingsRow(
                label: "Preferred sports",
                value: sportsValue,
                identifier: "profile.sports"
            ) {
                SportsSettingsView(editor: editor, session: session)
            }

            ProfileSettingsRow(
                label: "Health information",
                meta: "Conditions and history",
                value: "",
                identifier: "profile.health"
            ) {
                HealthSettingsView(editor: editor, session: session)
            }

            ProfileSettingsRow(
                label: "Hormonal medications",
                meta: "Kept private",
                value: "",
                identifier: "profile.medications"
            ) {
                MedicationsSettingsView(editor: editor, session: session)
            }
        }
    }

    /// The goals row's trailing value, the artboard's "3 active" shape. Empty until she has
    /// chosen one, so an unanswered profile does not claim a count it has not got.
    private var goalsValue: String {
        editor.goals.isEmpty ? "" : "\(editor.goals.count) active"
    }

    /// The sports row's trailing value, the artboard's bare "4" count.
    private var sportsValue: String {
        editor.sports.isEmpty ? "" : "\(editor.sports.count)"
    }

    /// The artboard's "Manage connected accounts" row, opened out into the card it would
    /// have led to (#7).
    ///
    /// The Settings artboard draws it as one row reading `Manage connected accounts ·
    /// Apple ›`, and the screen behind that chevron is not drawn anywhere on the canvas.
    /// Rather than invent one, this is the row's content in place: what is attached, and
    /// the buttons to attach what is not. The chevron and the detail screen belong with
    /// the rest of Settings (#19), and this grows into it.
    ///
    /// **Unlinking is deliberately absent** — out of scope on #7, and it is the half with
    /// the sharp edge: removing the last provider from an account with no password would
    /// lock its owner out permanently.
    ///
    /// ## What this can and cannot do, said plainly
    ///
    /// It attaches a provider identity Eva has never seen to the account you are signed in
    /// to. It does **not** merge two accounts: if you already signed in with Apple and got
    /// a separate account that way, its `sub` belongs to that account and the API answers
    /// `409 PROVIDER_ALREADY_LINKED`. The caption says so, because the opposite belief is
    /// exactly what someone in that situation would arrive with, and DESIGN.md §8 asks us
    /// to describe rather than reassure.
    private var connectedAccountsCard: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            Text("Connected accounts")
                .evaTextStyle(.label)
                .foregroundStyle(Color.evaSecondaryText)

            // Nothing is drawn for an API that does not send `authProviders`: the list is
            // empty, and stating a sign-in method the server never claimed would be a
            // guess presented as a fact.
            ForEach(connectedMethods, id: \.self) { method in
                connectedRow(method)
            }

            if !unconnectedProviders.isEmpty {
                Text(
                    "Add another way to sign in to this account. If you already made a "
                        + "separate Eva account with Apple or Google, this won't join the "
                        + "two — it will tell you instead."
                )
                .evaTextStyle(.inputHelper)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, EvaSpacing.xxs)

                ProviderSignInButtons(
                    providers: unconnectedProviders,
                    identifierPrefix: "profile.connect",
                    onCredential: session.attachProvider
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .evaCardSurface()
    }

    /// One attached sign-in method. A fact, not a control — unlinking is out of scope —
    /// so it is a row of text rather than the artboard's 52-high tappable row.
    ///
    /// The ✓ is §2's rule that a state is never colour alone; here it is not colour at
    /// all, which is the safe end of that rule.
    private func connectedRow(_ method: String) -> some View {
        HStack(spacing: EvaSpacing.xs) {
            Image(systemName: "checkmark.circle")
                .font(.evaCaption)
                .foregroundStyle(Color.evaSuccessInk)
                .accessibilityHidden(true)
            Text(method)
                .evaTextStyle(.bodyMedium)
                .foregroundStyle(Color.evaPrimaryText)
            Spacer(minLength: 0)
        }
        .frame(minHeight: EvaSpacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(method), connected"))
        .accessibilityIdentifier("profile.connected.\(method)")
    }

    /// What the account can be signed in with today, in a fixed order so the card does not
    /// reorder itself between reads.
    private var connectedMethods: [String] {
        guard let user = session.user else { return [] }
        var methods: [String] = []
        if user.hasPassword { methods.append("Email and password") }
        methods += EvaAuthProvider.allCases
            .filter(user.isConnected)
            .map(\.displayName)
        return methods
    }

    /// The providers there is still something to attach. Empty while the user is unknown,
    /// so the card offers nothing it cannot carry out.
    private var unconnectedProviders: [EvaAuthProvider] {
        guard let user = session.user else { return [] }
        return EvaAuthProvider.allCases.filter { !user.isConnected($0) }
    }

    /// The artboard's **Eva experience** section, with the one row #82 builds.
    ///
    /// The section title, the row label and its meta line are the artboard's own strings.
    /// Everything else in the section — Pregnancy Mode, Language, Personalization,
    /// Content preferences — is #19; this is the shape they slot into, not a detour
    /// around it.
    private var evaExperienceSection: some View {
        ProfileSettingsSection(title: "Eva experience") {
            ProfileSettingsRow(
                label: "Units",
                meta: "Follows your region by default",
                value: units.system.title,
                identifier: "profile.units"
            ) {
                UnitsSettingsView(units: units)
            }
        }
    }

    /// Log out, in the artboard's own shape: a 52-high row filling a glass card of its
    /// own, label in the 14/600 row, left-aligned, no chevron.
    ///
    /// It moved here from the placeholder dashboard rather than being added — the
    /// artboard puts log out on this screen, and two of them would be two answers to the
    /// same question. Its identifier moved with it, `dashboard.logout` → `profile.logout`;
    /// `EvaUITests` never used the old one.
    private var logOutCard: some View {
        Button(action: session.logOut) {
            HStack(spacing: 0) {
                Text("Log out")
                    .evaTextStyle(.textButton)
                    .foregroundStyle(Color.evaPrimaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, EvaSpacing.md)
            .frame(maxWidth: .infinity, minHeight: EvaControl.height)
            .contentShape(.rect)
        }
        // The row paints its own label and needs no fill of its own; `.evaUndimmed` is
        // the style that adds nothing, so the card behind it stays as drawn.
        .buttonStyle(.evaUndimmed)
        .evaCardSurface()
        .accessibilityIdentifier("profile.logout")
    }

    /// The artboard's danger card — the point of #55.
    ///
    /// It is the one block on the screen with no glass under it: an error-tinted card
    /// with an error border, set apart from everything above it, exactly as the
    /// `settings` spec note asks ("Delete profile is separated from everything else and
    /// uses destructive styling").
    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            Text("Delete profile")
                .evaTextStyle(.control)
                .foregroundStyle(Color.evaDestructiveInk)

            // The artboard's own line is "Removes all logs, notes and predictions", and
            // Eva has no predictions. Same defect as the modal's "within 30 days" (§9a):
            // copy describing a product that does not exist yet. Named to match what
            // `DELETE /me` actually removes, and to match the modal it opens.
            Text("Removes your cycle history, logs and notes. This cannot be undone.")
                .evaTextStyle(.inputHelper)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            DestructiveButton(title: "Delete profile") {
                isConfirmingDeletion = true
            }
            .padding(.top, EvaSpacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaSpacing.md)
        .background(
            Color.evaErrorTint,
            in: .rect(cornerRadius: EvaRadius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.card, style: .continuous)
                .strokeBorder(Color.evaErrorBorder, lineWidth: 1)
        }
    }
}

#Preview("Profile") {
    NavigationStack {
        ProfileView(session: AppSession(), units: EvaUnitPreference())
    }
}
