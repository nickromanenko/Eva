import SwiftUI

/// The DESIGN.md §7 toast — a dark bar that says what just happened, with one optional
/// action beside it.
///
/// §7 has listed this since the design system was written and nothing had built it: #12's
/// resend cooldown deliberately put its wait in a button instead, and §9a records that
/// choice and says "if a toast is ever built, both are candidates to move onto it". #160 is
/// what builds it, because a soft delete needs Undo and Undo has nowhere else to live — a
/// banner in the scroll view would be *above* the entry it is talking about, and a dialog
/// asking "are you sure" before a reversible action is the pattern the Undo exists to
/// replace.
///
/// Read from the App artboard: `padding:14px 16px; background:rgba(40,33,38,.92);
/// blur(20); box-shadow:0 16px 34px -14px rgba(40,33,38,.7)`, a 13.5/500 white message and
/// a 13.5/700 pink action.
///
/// Three values are rounded to the nearest named token, following the rule `ProfileView`
/// set and §9a records for the calendar: the radius is `EvaRadius.control` (17) against the
/// artboard's 18, the message takes Body medium (15/500) against 13.5/500, and the action
/// takes `evaGradientPink` (`#F3AEC4`) against `#F5B6CB` — two channel units apart, and
/// 8.7:1 on the bar either way.
///
/// **Not an alert.** It never blocks, it never asks, and dismissing it is not a decision:
/// the action it offers is always the *reversal* of something already done.
struct EvaToast<Action: View>: View {

    /// One line, describing what happened. Not a congratulation and not a count (§8).
    let message: String
    /// The way back, if there is one.
    let action: Action

    init(message: String, @ViewBuilder action: () -> Action) {
        self.message = message
        self.action = action()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: EvaSpacing.sm) {
            Text(message)
                .evaTextStyle(.bodyMedium)
                .foregroundStyle(Color.evaTextOnDark)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            action
        }
        .padding(.horizontal, EvaSpacing.md)
        .padding(.vertical, EvaSpacing.sm)
        .background(
            Color.evaPrimaryText.opacity(EvaToastMetrics.fillOpacity),
            in: .rect(cornerRadius: EvaRadius.control, style: .continuous)
        )
        .shadow(
            color: Color.evaPrimaryText.opacity(EvaToastMetrics.shadowOpacity),
            radius: EvaToastMetrics.shadowRadius,
            x: 0,
            y: EvaToastMetrics.shadowOffsetY
        )
        // One element: a bar with two parts reads as two unrelated announcements otherwise,
        // and the action's label ("Undo") says nothing on its own about what it undoes.
        .accessibilityElement(children: .contain)
    }
}

extension EvaToast where Action == EmptyView {
    /// A toast that only says something. Most of them.
    init(message: String) {
        self.init(message: message, action: { EmptyView() })
    }
}

/// The toast's own action button — `font:700 13.5px`, pink on the dark bar.
///
/// Its own type rather than `TextButton`, which is 48 high, radius 14 and drawn for a warm
/// background. This one sits inside a 44-high bar and has to be legible on `#282126`.
struct EvaToastButton: View {

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                // The scale has no 13.5/700 row. Button (14.5/600) is the nearest and is
                // what every other action label in the app takes.
                .evaTextStyle(.button)
                .foregroundStyle(Color.evaGradientPink)
                // 44pt, not the artboard's 32: §1's minimum touch target is not negotiable
                // for something you tap, and this is the only way back from a delete.
                .frame(minHeight: EvaMetrics.minimumTouchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.evaUndimmed)
        .accessibilityIdentifier("toast.\(title)")
    }
}

/// Values read off the artboard that are compositions rather than spacing — see
/// `EvaCalendarMetrics` for the same distinction.
enum EvaToastMetrics {
    /// `rgba(40,33,38,.92)`.
    static let fillOpacity: Double = 0.92
    /// `0 16px 34px -14px rgba(40,33,38,.7)`. Halved blur, like every other shadow here;
    /// SwiftUI has no spread, so the `-14px` contraction is dropped (DESIGN.md §9b).
    static let shadowOpacity: Double = 0.7
    static let shadowRadius: CGFloat = 17
    static let shadowOffsetY: CGFloat = 16
    /// `bottom:100px` from the frame, clearing the 88pt tab bar.
    static let bottomInset: CGFloat = 12
}

#Preview("Toast") {
    ZStack(alignment: .bottom) {
        EvaScreenBackground().ignoresSafeArea()

        VStack(spacing: EvaSpacing.sm) {
            EvaToast(message: "Menstrual cycle deleted") {
                EvaToastButton(title: "Undo") {}
            }
            EvaToast(message: "Body signals saved to 12 August")
            EvaToast(
                message: "That day already has an entry, so this one can't be restored"
            )
        }
        .padding(.horizontal, EvaSpacing.md)
        .padding(.bottom, EvaSpacing.xl)
    }
}
