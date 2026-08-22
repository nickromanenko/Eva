#if DEBUG
import SwiftUI

/// A soft, blurred field of brand colour to put behind glass.
///
/// Glass is a statement about what shows *through* it. On the flat warm background all
/// three levels collapse into the same off-white and there is nothing to judge, so the
/// canvas puts glass over colour and so does the specimen.
///
/// The blobs are palette colours; only their geometry and the blur radius are made up,
/// and neither is a design token — this is a backdrop for looking at glass, not a
/// component. `.blur` here is a normal foreground blur of the field's own content, which
/// is unrelated to the backdrop blur DESIGN.md §9a says SwiftUI cannot do.
struct EvaSpecimenColorField: View {

    /// Enough blur that no blob has a visible edge, so the field reads as a wash.
    private static let blurRadius: CGFloat = 44

    var body: some View {
        ZStack {
            // The ground stays *outside* the blur. Blurring an opaque backdrop needs
            // `blur(radius:opaque:)` to stop the filter sampling transparency in from
            // beyond the bounds, and that edge-clamping degenerates into hard-edged
            // colour blocks inside a lazily-rendered, clipped container. Blurring only
            // the blobs sidesteps it: their own alpha is what fades, which is the effect
            // wanted anyway.
            Color.evaWarmBackground

            ZStack {
                Circle()
                    .fill(Color.evaPrimaryPink)
                    .frame(width: 210, height: 210)
                    .offset(x: -80, y: -110)

                Circle()
                    .fill(Color.evaPistachio)
                    .frame(width: 190, height: 190)
                    .offset(x: 110, y: -30)

                Circle()
                    .fill(Color.evaDeepPink)
                    .frame(width: 160, height: 160)
                    .offset(x: -40, y: 130)

                Circle()
                    .fill(Color.evaLightPistachio)
                    .frame(width: 200, height: 200)
                    .offset(x: 120, y: 180)
            }
            .blur(radius: Self.blurRadius)
        }
        .accessibilityHidden(true)
    }
}

#Preview("Colour field") {
    EvaSpecimenColorField()
}
#endif
