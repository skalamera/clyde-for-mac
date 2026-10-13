import SwiftUI

struct SuggestionCardView: View {
    let suggestion: Suggestion
    var onDismiss: () -> Void = {}

    private var icon: String {
        switch suggestion.kind {
        case .answer: return "lightbulb.fill"
        case .clarification: return "questionmark.circle.fill"
        case .factCheck: return "checkmark.seal.fill"
        }
    }

    private var tint: Color {
        switch suggestion.kind {
        case .answer: return .yellow
        case .clarification: return .blue
        case .factCheck: return .green
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.title)
                    .font(.system(size: 13, weight: .semibold))
                // Inline-markdown-aware: models emit **bold** etc. in card bodies despite
                // instructions — render it rather than show raw asterisks.
                Text((try? AttributedString(markdown: suggestion.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(suggestion.body))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}
