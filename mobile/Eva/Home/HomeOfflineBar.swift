import SwiftUI

/// The `home_off` bar: "Offline · showing your cached briefing from 08:12".
///
/// `SPEC.home_off` is one sentence long and it is the whole specification: "Offline shows
/// the cached daily card with an explicit sync timestamp, not a stale-looking blank." So
/// the bar only ever appears *over a card* — `HomeModel.showsOfflineBar` — and it always
/// carries the time, because a bar that said only "Offline" would leave the reader
/// wondering how old what they are reading is, which is the thing the timestamp answers.
///
/// **Information, not error.** Nothing went wrong and nothing the user did caused it, so
/// this takes §2's Information family, the same reading `AuthRateLimitedBanner` and the
/// calendar's failed-load banner took (DESIGN.md §9a). It is not `EvaInfoBanner`: that
/// component is §7's two-line card with an `i` mark at 16pt padding, and the artboard
/// draws this as a single-line strip with a dot. The colours are the same family; the
/// geometry is not.
///
/// The state is never carried by colour alone (§2) — the first word is "Offline".
struct HomeOfflineBar: View {

    /// When this device last heard from the API.
    let syncedAt: Date?

    var body: some View {
        HStack(spacing: EvaSpacing.xs) {
            Circle()
                .fill(Color.evaInformation)
                .frame(
                    width: EvaHomeMetrics.offlineDotSize,
                    height: EvaHomeMetrics.offlineDotSize
                )
                .accessibilityHidden(true)

            Text(message)
                // `font:500 11.5px` — the same artboard value the calendar legend maps
                // onto Caption (12.5/19).
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaInformationInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvaHomeMetrics.offlineBarPadding)
        .background(
            // `rgba(90,123,160,.10)`; §2's Information tint is the same blue at .09.
            Color.evaInformationTint,
            in: .rect(cornerRadius: EvaRadius.chip, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
                // `rgba(90,123,160,.26)` — §2's Information border, exactly.
                .strokeBorder(Color.evaInformationBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityIdentifier("home.offline")
    }

    /// The canvas' sentence, with the device's own sync time in it.
    ///
    /// The shortened form is the user's locale's — "08:12" or "8:12 AM" — because the
    /// artboard's 24-hour rendering is a locale, not a format decision.
    private var message: String {
        guard let syncedAt else {
            // Reachable only if a card were restored without its timestamp, which #78's
            // store could do. Saying less is better than stamping a time that was guessed.
            return "Offline · showing your cached briefing"
        }
        let time = syncedAt.formatted(date: .omitted, time: .shortened)
        return "Offline · showing your cached briefing from \(time)"
    }
}

#Preview("Offline bar") {
    ZStack {
        EvaScreenBackground().ignoresSafeArea()
        VStack(spacing: EvaSpacing.sm) {
            HomeOfflineBar(syncedAt: Date(timeIntervalSince1970: 1_755_936_720))
            HomeOfflineBar(syncedAt: nil)
        }
        .padding(EvaSpacing.lg)
    }
}
