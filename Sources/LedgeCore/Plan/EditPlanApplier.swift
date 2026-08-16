// Writing a checked filing slip to disk (§2.3). This is the only place in
// Ledge where an agent's decision becomes bytes in the vault.
//
// Two guarantees beyond "write the files":
//
// * Every step re-reads the file and confirms it still matches what the
//   validator saw. §1 is explicit that other processes write this vault —
//   register's own UI, a sync client — so a file that moved underneath us is
//   refused rather than clobbered.
// * A failure part-way rolls back everything already applied, so a plan is
//   all-or-nothing from the vault's point of view.

import Foundation
import os

public enum EditPlanApplyError: Error, Equatable, Sendable, LocalizedError {
    /// The file changed between checking the plan and applying it.
    case changedUnderfoot(path: String)
    case writeFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .changedUnderfoot(path):
            "Refused: \(path) changed while the agent was working"
        case let .writeFailed(path, reason):
            "Could not write \(path) (\(reason))"
        }
    }
}

/// What one applied plan actually did, and how to take it back.
public struct AppliedPlan: Equatable, Sendable {
    /// Distinct files written, in first-touched order.
    public let filesChanged: [URL]
    /// Pre-images for every file the plan touched (first touch wins), plus the
    /// folders it created. Plain data with no tie to the vault, the plan, or
    /// the run that produced it, so a caller may hold it for as long as
    /// `/undo` might reach this run — which is exactly what the App layer
    /// does, in memory, for one run at a time. Nothing here retains it: a
    /// caller that drops it has made the run permanent.
    public let undo: RunUndoRecord

    public var isEmpty: Bool {
        filesChanged.isEmpty
    }
}

public enum EditPlanApplier {
    /// Writes a validated plan and hands back the pre-images needed to take it
    /// away again.
    ///
    /// All-or-nothing: any step that fails — including a file another process
    /// changed since validation (§1: register's UI and sync clients write this
    /// vault too) — restores everything already written before rethrowing, so
    /// a throw means the vault is where it started rather than holding half a
    /// plan. Each step re-reads its file first; "unchanged" means
    /// byte-identical to what the validator saw, absence included.
    public static func apply(_ plan: ValidatedPlan) throws -> AppliedPlan {
        let logger = Logger(subsystem: "app.ledge", category: "runner")
        var undo = RunUndoRecord()
        var changed: [URL] = []

        for step in plan.steps {
            do {
                try verifyUnchanged(step)
                try createMissingDirectories(for: step.url, recordingInto: &undo)
                undo.record(url: step.url, before: step.before)
                try write(step)
                if !changed.contains(step.url) {
                    changed.append(step.url)
                }
            } catch {
                // Put back whatever already landed. The vault must never be
                // left holding half a plan.
                let restored = RunUndo.restore(undo)
                logger.error(
                    "edit plan failed at \(step.edit.operationName, privacy: .public) \(step.edit.path, privacy: .public); rolled back \(restored) file(s)"
                )
                throw error
            }
        }

        logger.info("applied edit plan: \(changed.count) file(s), \(plan.bytesWritten) bytes")
        return AppliedPlan(filesChanged: changed, undo: undo)
    }

    // MARK: - Steps

    private static func verifyUnchanged(_ step: ValidatedPlan.Step) throws {
        let exists = FileManager.default.fileExists(atPath: step.url.path)
        guard exists else {
            // Absent is only correct if the validator also saw it absent.
            guard step.before == nil else {
                throw EditPlanApplyError.changedUnderfoot(path: step.edit.path)
            }
            return
        }
        guard let before = step.before,
              let onDisk = try? String(contentsOf: step.url, encoding: .utf8),
              onDisk == before
        else {
            throw EditPlanApplyError.changedUnderfoot(path: step.edit.path)
        }
    }

    private static func createMissingDirectories(
        for url: URL, recordingInto undo: inout RunUndoRecord
    ) throws {
        let parent = url.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: parent.path) else { return }

        // Record every level this run brings into existence, shallowest first,
        // so undo can peel them back in reverse.
        var missing: [URL] = []
        var candidate = parent
        while !FileManager.default.fileExists(atPath: candidate.path) {
            missing.append(candidate)
            let next = candidate.deletingLastPathComponent()
            guard next != candidate else { break }
            candidate = next
        }
        do {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true
            )
        } catch {
            throw EditPlanApplyError.writeFailed(
                path: url.lastPathComponent, reason: error.localizedDescription
            )
        }
        for directory in missing.reversed() {
            undo.recordCreatedDirectory(directory)
        }
    }

    private static func write(_ step: ValidatedPlan.Step) throws {
        do {
            if step.before == nil {
                // Matches InstantCapture's creation discipline: losing the race
                // to an external writer leaves their content intact rather than
                // truncating it.
                try Data(step.after.utf8).write(to: step.url, options: .withoutOverwriting)
            } else {
                try Data(step.after.utf8).write(to: step.url, options: .atomic)
            }
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw EditPlanApplyError.changedUnderfoot(path: step.edit.path)
        } catch {
            throw EditPlanApplyError.writeFailed(
                path: step.edit.path, reason: error.localizedDescription
            )
        }
    }
}
