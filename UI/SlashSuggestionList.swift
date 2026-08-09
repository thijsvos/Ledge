import LedgeCore
import SwiftUI

/// The suggestion rows under the capture field: Ledge's own native commands
/// (`NativeCommand`), up to `SlashSuggestionModel.maxVisibleRows` (4)
/// visible, scrollable beyond. The model itself lives in LedgeCore (its
/// tokenization/selection/Enter policy is unit-tested there); this file is
/// only the rendering: /name primary, the one-line summary secondary, and a
/// "ledge" capsule badge — native commands take no arguments, so there is no
/// argument hint.
///
/// The selection highlight renders under EXACTLY the model's
/// `shouldCompleteOnReturn` condition (an actively chosen row, or a single
/// unambiguous match for a real query) — so a highlighted row always means
/// "Enter runs this" and an un-highlighted list always means "Enter submits
/// the raw text". Clicking a row completes the command into the field
/// without submitting. Never rendered by --render-preview (CaptureView's
/// static branch omits it entirely).
struct SlashSuggestionList: View {
    /// One row's fixed height; `IslandView.shapeSize` grows the open shape by
    /// this per visible row.
    static let rowHeight: CGFloat = 22

    var model: SlashSuggestionModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(model.matches.enumerated()), id: \.offset) { index, command in
                        row(
                            command,
                            selected: model.shouldCompleteOnReturn && index == model.highlightIndex
                        )
                        .id(index)
                        .onTapGesture { model.complete(command) }
                    }
                }
            }
            .frame(height: CGFloat(model.visibleRowCount) * Self.rowHeight)
            .onChange(of: model.highlightIndex) { _, index in
                proxy.scrollTo(index)
            }
        }
    }

    private func row(_ command: NativeCommand, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Text("/" + command.name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(2)
            Text(command.summary)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55)) // secondary
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            badge
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
    }

    private var badge: some View {
        Text("ledge")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.white.opacity(0.08)))
    }
}
