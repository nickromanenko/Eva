import SwiftUI

/// The dismissible "complete your profile" nudge on the Dashboard (#19).
///
/// The PRD's nudge slot, used for the one thing a new account still needs: a profile. It
/// shows while the profile is incomplete, and takes no for an answer — the dismiss is a
/// 44pt target with an explicit label, and the dismissal is stored server-side so a second
/// device does not ask again.
///
/// ## Why it says what it says
///
/// DESIGN.md §8: describe, do not flatter. An unexplained form is the wrong ask for an app
/// whose premise is that women were left out of medical research, so the copy names what
/// the data is for rather than promising an outcome. No streaks, no scores, no "get back on
/// track".
///
/// The canvas draws no profile-specific nudge (its `NUDGES` are period, appointment, gap
/// and setup), so this is the slot's own shape — below the hero card, visually secondary —
/// composed out of the §7 card surface and text styles rather than an invented banner.
struct ProfileNudgeView: View {

    let onAddDetails: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: EvaSpacing.sm) {
            VStack(alignment: .leading, spacing: EvaSpacing.xxs) {
                Text("Make Eva yours")
                    .evaTextStyle(.control)
                    .foregroundStyle(Color.evaPrimaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    "Eva works from what you tell it — your cycle, your goals, your health. "
                        + "Add a few details so what you see is about you, not a guess."
                )
                .evaTextStyle(.caption)
                .foregroundStyle(Color.evaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

                TextButton(title: "Add details", action: onAddDetails)
                    .padding(.top, EvaSpacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The 44pt dismiss the nudge slot's spec requires, with a label that says what
            // it does — never a bare × read aloud as "X".
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.evaSecondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.evaUndimmed)
            .accessibilityLabel(Text("Dismiss"))
            .accessibilityIdentifier("nudge.dismiss")
        }
        .padding(EvaSpacing.md)
        .evaCardSurface()
        .accessibilityIdentifier("nudge.profile")
    }
}

#Preview {
    VStack(spacing: EvaSpacing.lg) {
        ProfileNudgeView(onAddDetails: {}, onDismiss: {})
    }
    .padding(EvaSpacing.lg)
    .background(Color.evaWarmBackground)
}
