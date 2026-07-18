import SwiftUI

/// Serif title + optional subtitle used at the top of questionnaire steps.
/// (Step numbering lives in the questionnaire progress header.)
struct QuestionnaireHeading: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 31, weight: .semibold, design: .serif))
                .foregroundStyle(Color.evaInk)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Color.evaBody)
                    .padding(.top, 10)
            }
        }
    }
}
