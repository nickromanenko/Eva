import SwiftUI

/// The signed-in app: a tab bar over the three screens that exist.
///
/// ## Three tabs, where the canvas draws five
///
/// "Eva App.dc.html" draws Home · Calendar · Eva Chat · Learn · Profile (A4). The canvas
/// also says what the other two are: its own handlers for them answer "Eva Chat is not
/// drawn yet — it is v1 (A1, A5); its own design phase follows the Dashboard" and the
/// same for Learn. So there is nothing to build behind them and nothing drawn for them to
/// look like, and a tab that opens an apology is worse than a tab that is not there yet.
/// They arrive with their screens.
///
/// ## Home is the landing tab again (#99)
///
/// #159 landed on Calendar, and said why: "Home is the canvas' first tab and the Dashboard
/// is unbuilt, so landing there would put a placeholder in front of the one real screen."
/// D4 builds the Dashboard, so the reason is spent and the canvas' own tab order stands —
/// Home is the screen a user sees first.
struct EvaTabView: View {

    let session: AppSession

    /// Tab selection, plus the one request a tab can make of another: the Today card's
    /// `Log now` opens the calendar's picker. See `EvaTabRouter`.
    @State private var router = EvaTabRouter()

    var body: some View {
        ZStack {
            // All three stay alive across switches: the calendar has fetched a year of
            // entries and rebuilding that on every tab change would re-request them. So
            // the inactive ones are hidden rather than removed — and hiding has to be all
            // three of these. A view at `opacity(0)` is still hit-testable and still in the
            // accessibility tree, so the topmost tab would swallow every tap meant for the
            // one on screen and VoiceOver would read three screens at once.
            ForEach(EvaTab.allCases, id: \.self) { tab in
                screen(tab)
                    .opacity(router.selection == tab ? 1 : 0)
                    .allowsHitTesting(router.selection == tab)
                    .accessibilityHidden(router.selection != tab)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            @Bindable var router = router
            EvaTabBar(selection: $router.selection)
        }
        .tint(Color.evaActionPinkTop)
    }

    @ViewBuilder
    private func screen(_ tab: EvaTab) -> some View {
        switch tab {
        case .home:
            HomeView(session: session, router: router)
        case .calendar:
            CalendarView(session: session, router: router)
        case .profile:
            // A stack of its own, so #19's settings detail screens push inside the tab
            // the way the canvas draws them.
            NavigationStack { ProfileView(session: session) }
        }
    }
}

/// The tabs this build has.
enum EvaTab: String, CaseIterable, Hashable, Sendable {
    case home
    case calendar
    case profile

    var title: String {
        switch self {
        case .home: "Home"
        case .calendar: "Calendar"
        case .profile: "Profile"
        }
    }

    /// The tab's mark.
    ///
    /// **Not a canvas value.** The artboard draws an 18pt rounded outline in every tab —
    /// the same placeholder convention it uses for the Google mark, which its own caption
    /// calls a slot for an asset that "drops in here". Shipping the placeholder literally
    /// would put three identical squares in the bar, so these are SF Symbols: the
    /// platform's own vocabulary rather than an icon set invented here, replaced wholesale
    /// when the canvas draws real marks.
    var systemImage: String {
        switch self {
        case .home: "house"
        case .calendar: "calendar"
        case .profile: "person"
        }
    }

    var filledSystemImage: String {
        switch self {
        case .home: "house.fill"
        case .calendar: "calendar"
        case .profile: "person.fill"
        }
    }
}

/// The DESIGN.md §7 tab bar: a translucent warm bar with the active tab tinted.
///
/// Read off the artboard rather than §7's prose where the two differ — the bar is
/// `rgba(255,249,246,.72)` there against §7's `.8`.
struct EvaTabBar: View {

    @Binding var selection: EvaTab

    var body: some View {
        HStack(spacing: Self.itemSpacing) {
            ForEach(EvaTab.allCases, id: \.self) { tab in
                item(tab)
            }
        }
        .padding(.horizontal, EvaSpacing.sm)
        .padding(.top, EvaSpacing.xs)
        .padding(.bottom, EvaSpacing.xxs)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                // `backdrop-filter:blur(24px)`, which is L2's radius and therefore L2's
                // material — see the fidelity note in `EvaGlass.swift`.
                Rectangle().fill(EvaGlassLevel.card.material)
                Rectangle().fill(Color.evaWarmBackground.opacity(0.72))
                // `border-top:1px solid rgba(40,33,38,.06)`.
                Rectangle()
                    .fill(Color.evaPrimaryText.opacity(0.06))
                    .frame(height: 1)
            }
            // The fill runs under the home indicator; the items above do not.
            .ignoresSafeArea(edges: .bottom)
        }
    }

    /// `gap:2px` — below the 4pt scale step, and the bar is three items wide rather than
    /// the artboard's five, so the gap is the artboard's rather than a scale value.
    private static let itemSpacing: CGFloat = 2
    /// `min-height:52px`.
    private static let itemHeight: CGFloat = 52
    /// `width:18px;height:18px`.
    private static let markSize: CGFloat = 18

    private func item(_ tab: EvaTab) -> some View {
        let isActive = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 5) {
                Image(systemName: isActive ? tab.filledSystemImage : tab.systemImage)
                    .font(.system(size: Self.markSize))
                    .frame(height: Self.markSize)
                Text(tab.title)
                    // `font:600 10.5px`. The §3 scale's smallest row is Overline at
                    // 11/600, and half a point is not worth a new row.
                    .font(.evaOverline)
            }
            // `#C95F86` active. White never sits on this, but the label does sit on the
            // warm background, where `#C95F86` measures 3.68:1 — the same failure §9a
            // deepened the text button for, and the same token is the answer.
            .foregroundStyle(isActive ? Color.evaActionPinkTop : Color.evaMutedText)
            .frame(maxWidth: .infinity, minHeight: Self.itemHeight)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: EvaRadius.chip, style: .continuous)
                        .fill(Color.evaPrimaryPink.opacity(0.10))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.evaUndimmed)
        .accessibilityIdentifier("tab.\(tab.rawValue)")
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    EvaTabView(session: AppSession())
}
