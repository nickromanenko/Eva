import SwiftUI

/// Kicker + serif title + optional subtitle used at the top of questionnaire steps.
struct QuestionnaireHeading: View {
    let kicker: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kicker)
                .font(.system(size: 12, weight: .bold))
                .kerning(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.evaPink)
            Text(title)
                .font(.system(size: 31, weight: .semibold, design: .serif))
                .foregroundStyle(Color.evaInk)
                .padding(.top, 8)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Color.evaBody)
                    .padding(.top, 10)
            }
        }
    }
}
