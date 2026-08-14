// The whole read-a-reply-and-write-the-vault path in one pure call (§2.3).
//
// This exists so the App layer's completion handler stays a switch over three
// outcomes instead of a three-stage do/catch ladder: AgentRunController is the
// largest untested file in the repo, and every piece of logic that can live in
// LedgeCore instead should.

import Foundation
import os

public enum PlanApplication {
    public enum Outcome: Sendable {
        /// The plan was checked and written.
        case applied(AppliedPlan)
        /// A well-formed plan with nothing in it. A real answer, not a failure.
        case nothingToChange
        /// The reply held no usable plan, or the plan was refused, or writing
        /// it failed. `reason` is user-showable; the caller pairs it with what
        /// the agent actually said so nothing is lost.
        case refused(reason: String)
    }

    /// Reads the agent's final message and, if it holds a usable plan, applies
    /// it to `vault`. Never throws: every failure is an `Outcome` the caller
    /// reports, because a run that produced text must never disappear into an
    /// unhandled error.
    public static func apply(finalMessage: String?, in vault: Vault) -> Outcome {
        let logger = Logger(subsystem: "app.ledge", category: "runner")

        guard let finalMessage,
              !finalMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .refused(reason: "The agent finished without a reply")
        }

        let plan: EditPlan
        do {
            plan = try EditPlanExtractor.extract(from: finalMessage)
        } catch {
            logger.error("no usable edit plan in reply: \(describe(error), privacy: .public)")
            return .refused(reason: describe(error))
        }

        guard !plan.isEmpty else { return .nothingToChange }

        do {
            let validated = try EditPlanValidator.validate(plan, in: vault)
            return try .applied(EditPlanApplier.apply(validated))
        } catch {
            logger.error("edit plan refused: \(describe(error), privacy: .public)")
            return .refused(reason: describe(error))
        }
    }

    /// Typed errors here all carry a written-for-humans `errorDescription`;
    /// falling back to `localizedDescription` would print the enum case.
    private static func describe(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
