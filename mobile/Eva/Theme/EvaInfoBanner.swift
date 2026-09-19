import SwiftUI

/// The DESIGN.md §7 information banner — a tinted card that explains a limit or offers a
/// route through it, without implying anything went wrong.
///
/// Read from the design system artboard: `padding:14px; border-radius:20px;
/// background:rgba(90,123,160,.09); border:1px solid rgba(90,123,160,.26)`, an `i` in a
/// 20pt circle, a semibold title and a caption-sized message under it.
///
/// **Information blue, not error red.** The sign-up artboard's spec note is explicit
/// about why the account-linking case uses this and not the error treatment: "nothing
/// went wrong". Anything that *is* wrong belongs on the field it is wrong about — see
/// `EvaInputField`'s `errorMessage`.
///
/// The optional action is drawn under the message; the account-linking banner uses it to
/// offer the provider the address already belongs to.
///
/// ## Where this rounds the artboard off
///
/// * The canvas' 14pt padding and 3pt title-to-message gap are not on the 8-pt scale
///   (§1, §4). They take the nearest steps — `EvaSpacing.md` and `EvaSpacing.xxs`.
/// * The banner's two inks — `#2F4763` for the title and `#4A6480` for the message — are
///   not in the token set; §2's Information ink is the single `#3F5A76`. Both lines take
///   that one token and separate on weight and size instead, which is how the canvas
///   distinguishes them anyway.
struct EvaInfoBanner<Action: View>: View {

    /// One line, semibold. Says what the situation is, never what to feel about it.
    let title: String
    /// The explanation under it.
    let message: String
    /// An optional way out of the situation the banner describes.
    let action: Action

    /// The `i` mark's diameter, from the artboard's `width:20px;height:20px`.
    private static var markSize: CGFloat { 20 }

    init(title: String, message: String, @ViewBuilder action: () -> Action) {
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        HStack(alignment: .top, spacing: EvaSpacing.sm) {
            // The `i` in a circle §2 requires of every information state — the mark that
            // keeps the state from being carried by colour alone. Hidden from VoiceOver,
            // which reads the title and message instead.
            Image(systemName: "info.circle")
                .font(.system(size: Self.markSize))
                .foregroundStyle(Color.evaInformation)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
                Text(title)
                    .evaTextStyle(.control)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .evaTextStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                // `EmptyView` contributes nothing to a stack, but `EmptyView` with
                // padding on it is no longer an `EmptyView` — it would leave 8pt of
                // blank space under every banner that has no action.
                if Action.self != EmptyView.self {
                    action
                        .padding(.top, EvaSpacing.xs)
                }
            }
            .foregroundStyle(Color.evaInformationInk)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EvaSpacing.md)
        .background(
            Color.evaInformationTint,
            in: .rect(cornerRadius: EvaRadius.banner, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.banner, style: .continuous)
                .strokeBorder(Color.evaInformationBorder, lineWidth: 1)
        }
    }
}

extension EvaInfoBanner where Action == EmptyView {
    /// An information banner with nothing to act on — it only explains.
    init(title: String, message: String) {
        self.init(title: title, message: message) { EmptyView() }
    }
}

#Preview("Info banner") {
    ScrollView {
        VStack(alignment: .leading, spacing: EvaSpacing.lg) {
            EvaInfoBanner(
                title: "Predictions need one full cycle",
                message: "Until then Eva shows what you logged, without estimates."
            )

            EvaInfoBanner(
                title: "This email already has an Eva account",
                message: "Log in to continue. If you use Apple, you can link it from Profile."
            ) {
                TextButton(title: "Log in") {}
            }
        }
        .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}
