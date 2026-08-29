import SwiftUI

/// The Profile screen, cut down to the one thing #55 needs it for: somewhere the user
/// can delete their account from inside the app, which Apple requires of any app that
/// can create one.
///
/// **This is a third of the designed screen, deliberately.** "Eva App.dc.html", rail
/// item **Settings**, draws an avatar, an Edit control, a cycle-tracking status pill and
/// five sections of settings rows above the danger zone. All of that is #19. What is
/// here is the identity header reduced to the one identity fact the app actually holds
/// today, the Log out row, and the danger card — laid out in the artboard's own shape
/// and rhythm so #19 grows into this screen rather than replacing it.
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
struct ProfileView: View {

    let session: AppSession

    @State private var isConfirmingDeletion = false

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
        ProfileView(session: AppSession())
    }
}
