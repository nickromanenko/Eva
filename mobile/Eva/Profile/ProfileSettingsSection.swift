import SwiftUI

/// One titled block of settings rows on Profile, and one row inside it.
///
/// The Settings artboard ("Eva App.dc.html", rail item **Settings**) draws six of these;
/// #19 builds the rest. #82 needs exactly one — `Eva experience ▸ Units` — and building
/// it as the artboard's own section rather than as a one-off link is what lets #19 add
/// rows to it instead of replacing it.
///
/// Kept in `Eva/Profile/` rather than `Eva/Theme/`: DESIGN.md §7 does list the settings
/// row among the system's surfaces, but its variants (the destructive row, the toggle
/// row, a row with no chevron) belong with the screen that needs them, and a half-built
/// component in the design system is worse than a local one that is honest about its
/// scope.
///
/// ## Where this rounds the artboard off
///
/// The artboard draws the section as:
///
/// ```
/// heading  600 10.5px, .14em, uppercase, #9A9095, padding 0 4px 8px
/// card     border-radius:22px; background:rgba(255,255,255,.62);
///          border:1px rgba(255,255,255,.85); backdrop-filter:blur(22px)
/// row      min-height:52px; gap:12px; padding:8px 16px;
///          border-top:1px solid rgba(40,33,38,.05)
/// label    500 14px    · meta 400 11.5px #9A9095 · value 400 12.5px #9A9095
/// chevron  17px #C8BFC3
/// ```
///
/// * **Heading is §3 Overline (11/600/.14em)** — the same half-point rounding `EvaTabBar`
///   took for its 10.5px label.
/// * **The card is `evaCardSurface` at `EvaRadius.card`**, which is `ProfileView`'s
///   existing call for this screen's 22px cards; see its own note.
/// * **Label is §3 Body medium (15/24/500)** — the scale has no 14/500 row, and the
///   weight is the half worth keeping.
/// * **Meta and value take Secondary Text, not the artboard's Muted `#9A9095`**, which
///   measures **2.96:1** on the warm background against the 4.5:1 WCAG 2.1 SC 1.4.3 asks
///   of normal text. Secondary Text measures 5.37:1. Same deviation, same reason, as the
///   input placeholder in DESIGN.md §9a. The chevron keeps `#C8BFC3`: it is a mark, not
///   text, and the row it sits in is announced as a button either way.
/// * **No `border-top` hairline.** The artboard puts `1px rgba(40,33,38,.05)` on every
///   row including the first, which inside a clipped card is a divider between rows and a
///   line across the top of the card. This section has one row, so the line would only
///   ever be the second of those. The divider belongs with the second row — #19.
struct ProfileSettingsSection<Content: View>: View {

    let title: String
    @ViewBuilder let rows: Content

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xs) {
            Text(title)
                .textCase(.uppercase)
                .evaTextStyle(.overline)
                .foregroundStyle(Color.evaMutedText)
                .padding(.horizontal, EvaSpacing.xxs)

            VStack(spacing: 0) {
                rows
            }
            .evaCardSurface()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One `label · meta · value ›` row, as a push into a detail screen.
struct ProfileSettingsRow<Destination: View>: View {

    let label: String
    /// The line under the label, saying what the row is about. Empty draws nothing.
    var meta: String = ""
    /// The current setting, on the trailing edge. Empty draws nothing.
    var value: String = ""
    let identifier: String
    @ViewBuilder let destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: EvaSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .evaTextStyle(.bodyMedium)
                        .foregroundStyle(Color.evaPrimaryText)
                    if !meta.isEmpty {
                        Text(meta)
                            .evaTextStyle(.inputHelper)
                            .foregroundStyle(Color.evaSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !value.isEmpty {
                    Text(value)
                        .evaTextStyle(.caption)
                        .foregroundStyle(Color.evaSecondaryText)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.evaDisabledText)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, EvaSpacing.xs)
            .padding(.horizontal, EvaSpacing.md)
            .frame(maxWidth: .infinity, minHeight: EvaControl.height)
            .contentShape(.rect)
        }
        .buttonStyle(.evaUndimmed)
        .accessibilityIdentifier(identifier)
        // The value is part of what the row says, not decoration: "Units, Imperial".
        .accessibilityLabel(Text(value.isEmpty ? label : "\(label), \(value)"))
        .accessibilityHint(Text(meta))
    }
}

#Preview("Settings section") {
    NavigationStack {
        ScrollView {
            ProfileSettingsSection(title: "Eva experience") {
                ProfileSettingsRow(
                    label: "Units",
                    meta: "Follows your region by default",
                    value: "Imperial",
                    identifier: "profile.units"
                ) {
                    Text("Detail")
                }
            }
            .padding(EvaSpacing.lg)
        }
        .background(EvaScreenBackground().ignoresSafeArea())
    }
}
