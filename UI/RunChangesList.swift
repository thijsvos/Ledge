import LedgeCore
import SwiftUI

/// The `/changes` rows under the capture field, mirroring `ResumePickerList`:
/// the model (`RunChangesModel`) and the rendering rules (`RunReceipt.rows`)
/// live in LedgeCore where they are unit-tested; this file is only drawing.
/// Up to `RunChangesModel.maxVisibleRows` (6) rows are visible, scrollable
/// beyond.
///
/// A row is one of five kinds: the agent's own explanation, a file heading
/// (with a "new" tag when the run created it), an added line, a removed line,
/// or an elision ("+15 more") where a change was longer than the pane allows.
/// Nothing is selectable in the acting sense — unlike the picker, no row does
/// anything when chosen; the highlight exists so arrow keys can scroll a
/// receipt taller than the window. Never rendered by --render-preview
/// (CaptureView's static branch omits all list UI).
struct RunChangesList: View {
    /// One row's fixed height; `IslandView.shapeSize` grows the open shape by
    /// this per visible row. Same 22 pt as every other list.
    static let rowHeight: CGFloat = 22

    var model: RunChangesModel
    /// Rows the open shape's height budget still covers (from
    /// `IslandView.openPlan` — a wrap-grown capture field steals row budget).
    /// The list never renders taller than this; further rows scroll.
    var rowLimit: Int = .max

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if model.isEmpty {
                        emptyRow
                    } else {
                        ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                            self.row(row, selected: index == model.highlightIndex)
                                .id(index)
                        }
                    }
                }
            }
            .frame(
                height: CGFloat(min(max(model.visibleRowCount, 1), max(rowLimit, 0)))
                    * Self.rowHeight
            )
            .onChange(of: model.highlightIndex) { _, index in
                proxy.scrollTo(index)
            }
        }
    }

    private func row(_ row: RunReceipt.Row, selected: Bool) -> some View {
        HStack(spacing: 6) {
            switch row.kind {
            case .explanation:
                Text(row.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            case let .file(isNew):
                Text(row.text)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isNew {
                    Text("new")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .layoutPriority(1)
                }
            case .added, .removed:
                Text(row.kind == .added ? "+" : "−")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(marker(for: row.kind))
                    .layoutPriority(1)
                Text(row.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            case .elision:
                Text(row.text)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .padding(.leading, indent(for: row.kind))
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
    }

    /// Changed lines sit under their file heading; explanations and headings
    /// stay flush left.
    private func indent(for kind: RunReceipt.Row.Kind) -> CGFloat {
        switch kind {
        case .added, .removed, .elision: 10
        case .explanation, .file: 0
        }
    }

    private func marker(for kind: RunReceipt.Row.Kind) -> Color {
        kind == .added ? .green.opacity(0.8) : .red.opacity(0.75)
    }

    private var emptyRow: some View {
        Text(model.emptyMessage)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
    }
}
