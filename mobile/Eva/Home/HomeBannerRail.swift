import SwiftUI

/// The Dashboard's "Worth reading" rail (D7, #102): the day's banners, side by side.
///
/// Drawn from the `home` screen in "Eva App.dc.html" — the `Worth reading` block and its
/// `sc-for list="{{ banners }}"`. Every word on a card is the server's (`title`, `meta`);
/// the only words this file writes are the canvas' own header, "Worth reading" and "Learn".
///
/// ## Absent, not empty
///
/// The caller draws this only when there is at least one banner (#102: "When the payload
/// has no banners the 'Worth reading' section is absent, not empty"). A header over
/// nothing would say there is something worth reading and show that there is not.
///
/// ## Where it differs from the artboard, and why
///
/// | Artboard | Here | Why |
/// |---|---|---|
/// | header `600 10.5px`, `.14em`, uppercase, `#9A9095` | Overline (11/600/.14em), Secondary Text | Muted measures 2.96:1 on the warm ground; the §9a settings-row decision, for the same reason |
/// | "Learn" `500 11.5px #C95F86`, a plain label | §5 text button, **disabled**, "Not available yet." spoken | The Learn tab does not exist (#159); #102 asks for the link drawn and disabled until it does |
/// | card `rgba(255,255,255,.72)`, `.9` border, pink shadow, radius 22 | §4's card surface, radius 24 | The nudge slot beside it took §4's card for the canvas' `.7` fill; the shadow is neutral per §9a |
/// | image slot: 115° stripes, "editorial image" caption | §2's blush→cream / pistachio→cream wash, no caption | The stripes and caption are the canvas' placeholder for an image the payload does not carry; the wash keeps the alternation (blush, pistachio, blush) and says nothing untrue |
/// | title `600 13.5px/1.4` | Control (13/600) | The nearest row in size and weight |
/// | meta `500 11px #6F656B` | Caption (12.5/19), Secondary Text | The calendar legend's and the Today card's mapping of the same 11–11.5px |
///
/// ## Accessibility
///
/// Each card is **one** button whose label is the title, then the meta (#102: "VoiceOver
/// reads title then meta"). The image slot is decorative and hidden. The whole card is the
/// target — 214pt wide and taller than it is — so §1's 44pt floor is met by the shape the
/// canvas draws rather than by padding.
struct HomeBannerRail: View {

    let banners: [EvaTodayBanner]
    /// Called with the banner that was tapped. The presenter opens its article.
    let open: (EvaTodayBanner) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: EvaSpacing.sm) {
            header
            rail
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.banners")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Worth reading".uppercased())
                .evaTextStyle(.overline)
                .foregroundStyle(Color.evaSecondaryText)
                .accessibilityLabel(Text("Worth reading"))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.banners.title")

            Spacer(minLength: EvaSpacing.sm)

            // The canvas' "Learn" link. Drawn and disabled until the Learn tab exists — the
            // same treatment as a Today-card action whose screen is not built, including
            // the spoken reason.
            TextButton(title: "Learn") {}
                .disabled(true)
                .accessibilityLabel(Text("Learn. \(EvaTodayCardTarget.unavailableSuffix)"))
        }
    }

    // MARK: - The rail

    private var rail: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: EvaSpacing.sm) {
                ForEach(Array(banners.enumerated()), id: \.element.id) { index, banner in
                    card(banner, index: index)
                }
            }
            // With each card asking for all the height it can get, this makes every card
            // as tall as the tallest one — the artboard's flex row stretches them the same.
            .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.hidden)
        // `margin:0 -20px;padding:0 20px` — the rail runs to both screen edges and its first
        // card lines up with the column. The column's margin is `EvaSpacing.lg`, so that is
        // the distance broken out of and inset again.
        .contentMargins(.horizontal, EvaSpacing.lg, for: .scrollContent)
        .padding(.horizontal, -EvaSpacing.lg)
        // The card shadow falls below the cards; a scroll view clips to its bounds and would
        // cut it off flat.
        .scrollClipDisabled()
    }

    private func card(_ banner: EvaTodayBanner, index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: EvaRadius.card, style: .continuous)
        return Button { open(banner) } label: {
            VStack(alignment: .leading, spacing: 0) {
                art(index: index)

                VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
                    Text(banner.title)
                        .evaTextStyle(.control)
                        .foregroundStyle(Color.evaPrimaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if !banner.meta.isEmpty {
                        Text(banner.meta)
                            .evaTextStyle(.caption)
                            .foregroundStyle(Color.evaSecondaryText)
                    }
                }
                .padding(.top, EvaSpacing.sm)
                .padding(.horizontal, EvaSpacing.md)
                .padding(.bottom, EvaSpacing.md)
            }
            .frame(width: EvaHomeMetrics.bannerCardWidth, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            // The artboard's `overflow:hidden`: the image slot takes the card's top corners.
            .clipShape(shape)
            .evaCardSurface(in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.evaUndimmed)
        .accessibilityLabel(Text(banner.accessibilityLabel))
        .accessibilityIdentifier("home.banner.\(banner.id)")
    }

    /// The editorial image slot. The payload carries no image, so it is the canvas'
    /// alternation of washes by position — blush, pistachio, blush — and nothing else.
    private func art(index: Int) -> some View {
        Rectangle()
            .fill(index.isMultiple(of: 2) ? LinearGradient.evaBlushCream : .evaPistachioCream)
            .frame(height: EvaHomeMetrics.bannerArtHeight)
            .accessibilityHidden(true)
    }
}

#Preview {
    // The canvas' cycle set, inline — `EvaTodayCardFixtures` is DEBUG-only and this file
    // is not. The URLs are placeholders; the canvas draws none.
    let banners = [
        ("cycle-1", "Why appetite can change before your period", "Nutrition · 4 min read"),
        ("cycle-2", "How to adjust training when sleep is low", "Movement · 5 min read"),
        ("cycle-3", "Iron, energy and the days after your period", "Nutrition · 6 min read")
    ].compactMap { id, title, meta in
        EvaTodayBanner(
            id: id, title: title, meta: meta,
            url: URL(string: "https://example.com/\(id)")!
        )
    }

    return ZStack(alignment: .top) {
        EvaScreenBackground().ignoresSafeArea()
        HomeBannerRail(banners: banners) { _ in }
            .padding(EvaSpacing.lg)
    }
}
