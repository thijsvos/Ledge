import LedgeCore
import SwiftUI

/// The 2.5 s peek banner content (§4). Failure peeks carrying a `ResumeAction`
/// offer the §6 escape hatch: "Open in Terminal" and "Copy command".
///
/// Focus discipline: the buttons are plain tap-target views handled via
/// `onTapGesture` — the same event path as the island tap, which already works
/// on the nonactivating panel while `canBecomeKey` is false. Nothing here (or
/// in the App-layer handlers) makes the panel key or activates Ledge, so peeks
/// never steal focus from the app the user is working in.
struct PeekView: View {
    var content: PeekContent
    var onOpenInTerminal: (ResumeAction) -> Void = { _ in }
    var onCopyCommand: (ResumeAction) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                switch content {
                case let .success(filesEdited, duration):
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                    Text("\(filesEdited) file\(filesEdited == 1 ? "" : "s") · \(Int(duration.rounded()))s")
                case let .failure(message, _):
                    Image(systemName: "xmark")
                        .foregroundStyle(.red)
                    // §6: failures show the stderr tail — up to 3 lines after
                    // the headline (IslandView sizes the banner to match).
                    Text(message)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                case let .queued(position):
                    Image(systemName: "clock")
                        .foregroundStyle(.yellow)
                    Text("Queued #\(position)")
                case let .info(message):
                    Text(message)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 12, weight: .medium))

            if case let .failure(_, resume) = content, let resume {
                HStack(spacing: 8) {
                    peekButton("Open in Terminal") { onOpenInTerminal(resume) }
                    peekButton("Copy command") { onCopyCommand(resume) }
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
        .padding(.horizontal, 16)
    }

    private func peekButton(_ title: String, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(Capsule().fill(.white.opacity(0.16)))
            .contentShape(Capsule())
            .onTapGesture(perform: action)
    }
}
