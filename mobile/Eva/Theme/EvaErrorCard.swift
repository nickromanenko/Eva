import SwiftUI

/// The DESIGN.md §7 error card — "an error card with a Retry action" — first built for the
/// sync queue's "Couldn't sync your last entry" (#78, ARCHITECTURE §8.4).
///
/// Read from the design system artboard's states row: `padding:18px; border-radius:24px;
/// background:rgba(196,100,90,.06); border:1px solid rgba(196,100,90,.24)`, a white `!` in
/// a 20pt `#C4645A` rounded square, a 13/600 `#A9524A` title, an 11.5 message under it and
/// an outlined `Retry now` (`min-height:40px; border-radius:13px`).
///
/// **Error red, unlike `EvaInfoBanner`,** because here something did go wrong: the server
/// refused an entry she logged, and it is not on the server. The card says so and offers
/// the one thing she can do about it.
///
/// ## Where this rounds the artboard off
///
/// * Fill and border take §2's Error tint and border (`.08` / `.26`) rather than the
///   artboard's `.06` / `.24` — one step from the existing tokens, not two new ones.
/// * 18pt padding takes `EvaSpacing.md`, as the banner's 14 does.
/// * The message ink `#8C6460` is not a token; it takes §2's Error ink and separates from
///   the title on weight and size, which is how `EvaInfoBanner` handles its second ink.
/// * `Retry now` is `DestructiveButton(.row)` — the same outline, radius 13 and ink; the
///   row's 44pt height is §1's touch floor where the artboard draws 40.
struct EvaErrorCard<Action: View>: View {

    let title: String
    let message: String
    let action: Action

    /// The mark's side, from the artboard's `width:20px;height:20px`.
    private static var markSize: CGFloat { 20 }

    init(title: String, message: String, @ViewBuilder action: () -> Action) {
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
            HStack(spacing: EvaSpacing.xs) {
                // §2: every error state is icon + text, never colour alone. Hidden from
                // VoiceOver, which reads the title.
                Image(systemName: "exclamationmark.square.fill")
                    .font(.system(size: Self.markSize))
                    .foregroundStyle(Color.evaError)
                    .accessibilityHidden(true)

                Text(title)
                    .evaTextStyle(.control)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(message)
                .evaTextStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)

            action
                .padding(.top, EvaSpacing.xs)
        }
        .foregroundStyle(Color.evaErrorInk)
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

/// The sync card's words, in one place so the calendar and the specimen cannot drift.
///
/// The title is the artboard's. The message is not: the artboard's second sentence, "Eva
/// will retry automatically", is true of a dropped connection but not of what this card is
/// for — an entry the server *refused* (a 4xx), which ARCHITECTURE §8.4 says is never
/// retried on its own. Saying it would be the false reassurance DESIGN.md §8 rules out.
enum EvaSyncCopy {
    static let failedTitle = "Couldn't sync your last entry"
    static let failedMessage = "It's saved on this device. Eva's servers didn't accept it, "
        + "so it won't be sent again until you retry."
}

#Preview("Error card") {
    VStack(spacing: EvaSpacing.lg) {
        EvaErrorCard(
            title: "Couldn't sync your last entry",
            message: EvaSyncCopy.failedMessage
        ) {
            DestructiveButton(title: "Retry now", kind: .row) {}
        }
    }
    .padding(EvaSpacing.lg)
    .background(Color.evaWarmBackground)
}
