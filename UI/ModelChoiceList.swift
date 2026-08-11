import LedgeCore
import SwiftUI

/// The ⌘↩ per-run model chooser rows under the capture field, mirroring
/// `SlashSuggestionList`: the model (`ModelChoiceModel`) lives in LedgeCore
/// where its row construction and wrap-around selection are unit-tested; this
/// file is only the rendering. One row = the choice's title primary, its
/// one-line subtitle secondary, and a "run" capsule badge (this list picks
/// how ONE run executes — it is not a command list).
///
/// The highlighted row is what Enter submits — the selection always exists
/// (it defaults to the first row), so like the resume picker the highlight
/// always renders. Clicking a row submits the current field text with that
/// choice immediately (same as selecting it and pressing Enter). Never
/// rendered by --render-preview (CaptureView's static branch omits all list
/// UI).
struct ModelChoiceList: View {
    /// One row's fixed height; `IslandView.shapeSize` grows the open shape by
    /// this per visible row.
    static let rowHeight: CGFloat = 22

    var model: ModelChoiceModel
    /// Row click → submit the current field text with this choice (the
    /// window controller routes this through the same path as Enter on the
    /// selected row).
    var onSelect: (RunModelChoice) -> Void
    /// Rows the open shape's height budget still covers (from
    /// `IslandView.openPlan` — a wrap-grown capture field steals row budget).
    /// The list never renders taller than this; further rows scroll.
    /// CaptureView only renders the list at all when this is ≥ 1.
    var rowLimit: Int = .max

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                        rowView(
                            title: row.title,
                            subtitle: row.subtitle,
                            selected: index == model.highlightIndex
                        )
                        .id(index)
                        .onTapGesture { onSelect(row.choice) }
                    }
                }
            }
            .frame(height: CGFloat(min(model.visibleRowCount, max(rowLimit, 0))) * Self.rowHeight)
            .onChange(of: model.highlightIndex) { _, index in
                proxy.scrollTo(index)
            }
        }
    }

    private func rowView(title: String, subtitle: String, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(2)
            Text(subtitle)
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
        Text("run")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.white.opacity(0.08)))
    }
}
