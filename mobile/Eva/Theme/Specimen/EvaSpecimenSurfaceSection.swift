#if DEBUG
import SwiftUI

/// DESIGN.md §7 — the surfaces that are neither a control nor a card: the information
/// banner, and the screen ground everything is drawn on.
///
/// Both arrived with #3, which needed them for the auth screens. They are here rather
/// than in that feature's folder because neither is specific to it: the banner is §7's
/// component, and `EvaScreenBackground` is what the canvas paints behind *every* screen —
/// only the questionnaire is still on the legacy gradient, and only until it moves.
///
/// The background is shown in a phone-shaped tile rather than behind the specimen,
/// because its whole subject is where three glows sit relative to a 390 × 844 frame; on a
/// scrolling page they would be somewhere else.
struct EvaSpecimenSurfaceSection: View {

    var body: some View {
        EvaSpecimenSection(number: "09", title: "Surfaces", reference: "DESIGN.md §7") {
            EvaSpecimenGroupLabel(title: "Information banner")
            EvaSpecimenNote(
                text: "Radius \(EvaSpecimenNumber.string(EvaRadius.banner)) · information "
                    + "tint and border · the i mark §2 requires. Information blue, never "
                    + "error red: it explains a limit, it does not report a failure."
            )

            EvaInfoBanner(
                title: "Predictions need one full cycle",
                message: "Until then Eva shows what you logged, without estimates."
            )
            .accessibilityIdentifier("specimen.banner.plain")

            EvaInfoBanner(
                title: "This email already uses Apple sign-in",
                message: "We won't create a second profile. Continue with Apple and "
                    + "everything you've logged stays in one place."
            ) {
                EvaAuthButton(
                    provider: .apple,
                    size: .compact,
                    identifier: "specimen.banner.action"
                ) {}
            }
            .accessibilityIdentifier("specimen.banner.action.banner")

            EvaSpecimenGroupLabel(title: "Screen background")
            EvaSpecimenNote(
                text: "Warm background, a pink glow off the top-left, pistachio off the "
                    + "right, blush off the bottom-left, and a 42% wash of the background "
                    + "colour back over all three. Drawn at the canvas' 390 × 844 frame; "
                    + "the glow positions are composition, not layout, so they stay put "
                    + "on a taller phone."
            )

            // Rendered at the full 390 × 844 and then scaled down as a picture. Laying
            // it out small instead would move the glows: their offsets are absolute, so a
            // third-size frame would put the pink one a third as far off the corner and
            // show a composition the canvas never draws.
            EvaScreenBackground()
                .frame(width: Self.frame.width, height: Self.frame.height)
                .clipShape(.rect(cornerRadius: EvaRadius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: EvaRadius.card, style: .continuous)
                        .strokeBorder(Color.evaControlBorder, lineWidth: 1)
                }
                .scaleEffect(Self.tileScale)
                .frame(
                    width: Self.frame.width * Self.tileScale,
                    height: Self.frame.height * Self.tileScale
                )
                .accessibilityIdentifier("specimen.background")
        }
    }

    /// The canvas' base frame (DESIGN.md §1).
    private static let frame = CGSize(width: 390, height: 844)
    /// Shown at 45%, so the whole 844-tall frame fits one screenful of the specimen.
    private static let tileScale: CGFloat = 0.45
}

#Preview("Surfaces") {
    ScrollView {
        EvaSpecimenSurfaceSection()
            .padding(EvaSpacing.lg)
    }
    .background(Color.evaWarmBackground)
}
#endif
