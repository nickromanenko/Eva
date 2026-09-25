import SwiftUI

/// The Home tab's drawing geometry, read off the `home` screen in "Eva App.dc.html".
///
/// Literals here for the reason `EvaCalendarMetrics` gives: **these are not spacing.** A
/// 7pt dot beside a sentence and a 10pt radius on a kicker pill are composition at the
/// canvas' 390 × 844 frame, and rounding them to the nearest 8-pt step moves the drawing.
/// Anything that *is* spacing — the screen margin, the gaps between blocks, the padding
/// inside the card — takes `EvaSpacing` and is not in this file.
///
/// Where the artboard collides with a named token the token wins and the difference is
/// reported rather than tokenised for one screen. That rule costs the card four values,
/// all recorded here so the next reader is not left comparing pixels:
///
/// | Artboard | Taken | Why |
/// |---|---|---|
/// | card `border-radius:28px` | `EvaRadius.card` (24) | §4's card radius; 30 is the sheet's |
/// | card `padding:22px` | `EvaSpacing.lg` (24) | nearest step on the §4 scale |
/// | offline bar `border-radius:14px` | `EvaRadius.chip` (14) | exact |
/// | header button `border-radius:15px` | `EvaRadius.chip` (14) | nearest; the calendar's steppers took the same |
/// | rail card `border-radius:22px` | `EvaRadius.card` (24) | the calendar's summary card took the same for the same 22 |
/// | rail card `padding:12px 14px 14px` | `EvaSpacing.sm` / `.md` / `.md` | nearest steps |
enum EvaHomeMetrics {

    // MARK: Header

    /// `min-height:48px` on the header row.
    static let headerHeight: CGFloat = 48
    /// `width:44px;height:44px` on both header buttons — which is also §1's minimum touch
    /// target, so the artboard and the floor agree here.
    static let headerButtonSize = EvaMetrics.minimumTouchTarget

    // MARK: Offline bar

    /// `width:7px;height:7px` — the status dot at the head of the offline bar.
    static let offlineDotSize: CGFloat = 7
    /// `padding:9px 13px`. Neither is on the 8-pt scale and both sit inside a 14pt
    /// radius, where a step either way changes the pill's proportions visibly.
    static let offlineBarPadding = EdgeInsets(top: 9, leading: 13, bottom: 9, trailing: 13)

    // MARK: Today card

    /// `padding:6px 11px;border-radius:10px` — the kicker pill.
    static let kickerPadding = EdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11)
    /// 10 — off the 14/17/24/30 scale, like the calendar cell's 15 and the FAB's 22. A
    /// chip's 14 on a 23pt-tall pill would read as a capsule.
    static let kickerRadius: CGFloat = 10

    /// `padding:12px 14px;border-radius:16px` — the suggestion surface behind `line3` on
    /// the `base` and `flag` tones.
    static let suggestionPadding = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    static let suggestionRadius: CGFloat = 16

    /// `1.5px` — the flag tone's border, the one card border the artboard draws heavier
    /// than a hairline. It is the only thing separating a red-flag card from an ordinary
    /// one at a glance, so the weight is carried rather than rounded to 1.
    static let flagBorderWidth: CGFloat = 1.5

    // MARK: "Worth reading" rail (#102)

    /// `flex:none;width:214px` — one rail card. At 390pt wide this shows a card and a
    /// half, which is the rail's affordance that it scrolls sideways; a width derived from
    /// the screen would lose that on larger phones.
    static let bannerCardWidth: CGFloat = 214
    /// `height:96px` — the editorial image slot above the words.
    static let bannerArtHeight: CGFloat = 96
}

// MARK: - One-off type

extension EvaTextStyle {

    /// The Home header's `eva.` lockup — `font:400 22px/1 Montserrat; letter-spacing:.5px`.
    ///
    /// **Not a row of the §3 scale, and not promoted to one here.** DESIGN.md §9c already
    /// reports that the canvas uses several light-weight brand title sizes the scale never
    /// captured — 40 and 34 on the auth screens, 30 on the status screens — and that
    /// promoting them is a design decision rather than something a feature PR takes. This
    /// is a fourth. It lives beside the screen that draws it, exactly as `authWordmark`
    /// lives in `AuthScreenParts.swift`, and is reported rather than tokenised.
    ///
    /// It is a different size from `authWordmark` (30) and cannot borrow it: the auth
    /// screens open with the wordmark as the page's subject, and here it shares a 48pt row
    /// with a greeting and two buttons.
    static let homeWordmark = EvaTextStyle(
        fontName: EvaFont.regular,
        size: 22,
        lineHeight: nil,
        tracking: 0.5,
        textStyle: .title2
    )
}
