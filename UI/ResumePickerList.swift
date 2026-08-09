import LedgeCore
import SwiftUI

/// The /resume picker rows under the capture field, mirroring
/// `SlashSuggestionList`: the model (`ResumePickerModel`) lives in LedgeCore
/// where its filtering/selection/validity rules are unit-tested; this file is
/// only the rendering. Up to `ResumePickerModel.maxVisibleRows` (5) rows are
/// visible, scrollable beyond.
///
/// One row = relative time ("2 min. ago"), the outcome glyph (✓ success,
/// ✗ failure, ⊘ cancelled), the prompt on one truncated line, and the edited
/// file count when > 0. The seeded "last session" fallback row (built from
/// the stored per-vault session ID, where date and outcome are UNKNOWN)
/// renders neutrally instead: a muted "stored" tag, no time, no glyph — it
/// must never claim a possibly failed, hours-old session succeeded "now".
/// The highlighted row is what Enter resumes — the
/// selection always exists (it defaults to the newest session), so unlike the
/// suggestion list the highlight always renders. Clicking a row resumes it
/// immediately (same as selecting it and pressing Enter). Never rendered by
/// --render-preview (CaptureView's static branch omits all list UI).
struct ResumePickerList: View {
    /// One row's fixed height; `IslandView.shapeSize` grows the open shape by
    /// this per visible row.
    static let rowHeight: CGFloat = 22

    var model: ResumePickerModel
    /// Row click → resume that exact session (the window controller routes
    /// this through the same path as Enter on the selected row).
    var onSelect: (RunRecord) -> Void

    /// "now" / "2 min. ago" — named style so a just-recorded run reads as
    /// "now" rather than "in 0 seconds". (The seeded fallback row never uses
    /// this — its date is unknown.)
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if model.filteredRecords.isEmpty {
                        emptyRow
                    } else {
                        ForEach(
                            Array(model.filteredRecords.enumerated()),
                            id: \.element.id
                        ) { index, record in
                            row(record, selected: index == model.highlightIndex)
                                .id(index)
                                .onTapGesture { onSelect(record) }
                        }
                    }
                }
            }
            .frame(height: CGFloat(max(model.visibleRowCount, 1)) * Self.rowHeight)
            .onChange(of: model.highlightIndex) { _, index in
                proxy.scrollTo(index)
            }
        }
    }

    private func row(_ record: RunRecord, selected: Bool) -> some View {
        HStack(spacing: 6) {
            if model.isSeededFallback {
                // The stored-ID fallback: when it ran and how it ended are
                // unknown — no fabricated time, no outcome glyph.
                Text("stored")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .layoutPriority(1)
            } else {
                Text(Self.relativeFormatter.localizedString(for: record.date, relativeTo: Date()))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(glyph(for: record.outcome))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .layoutPriority(1)
            }
            Text(record.prompt)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if !record.editedFiles.isEmpty {
                Text("\(record.editedFiles.count) file\(record.editedFiles.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
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

    private var emptyRow: some View {
        Text("No matching sessions")
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
    }

    private func glyph(for outcome: RunRecord.Outcome) -> String {
        switch outcome {
        case .success: "✓"
        case .failure: "✗"
        case .cancelled: "⊘"
        }
    }
}
