import Foundation
import LedgeCore
import Observation
import os

/// Thin @Observable shell over `OnboardingChecks` (LedgeCore owns ALL the
/// logic — §7). Runs the checks off the main actor (binary resolution may
/// spawn a login shell), holds the latest report for `OnboardingView`, and
/// services the one-click headless-clause append.
@MainActor
@Observable
final class OnboardingController {
    private(set) var report: OnboardingReport?
    private(set) var isChecking = false
    /// Non-nil after a failed append; cleared by the next external
    /// `refresh()` ("Re-run checks") or successful append.
    private(set) var appendErrorMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(subsystem: "app.ledge", category: "vault")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Re-runs all five checks. A FRESH resolver each time (deliberately not
    /// the cached per-launch one): "Run Onboarding Checks…" right after
    /// installing the CLI must find it. Clears any stale append error — a
    /// user who fixed the underlying problem and re-ran the checks must not
    /// keep seeing the old red banner under fresh rows.
    func refresh() {
        refresh(clearingAppendError: true)
    }

    private func refresh(clearingAppendError: Bool) {
        guard !isChecking else { return }
        if clearingAppendError {
            appendErrorMessage = nil
        }
        isChecking = true
        let override = defaults.string(forKey: DefaultsKey.claudeBinaryPath)
            .flatMap { $0.isEmpty ? nil : $0 }
        let vaultPath = defaults.string(forKey: DefaultsKey.vaultPath)
        Task { [weak self] in
            let resolver = ClaudeBinaryResolver(overridePath: override)
            // Off the main actor: the login-shell fallback can take seconds.
            let binaryPath = await Task.detached { resolver.resolve() }.value
            guard let self else { return }
            report = OnboardingChecks.run(binaryResolution: binaryPath, vaultPath: vaultPath)
            isChecking = false
        }
    }

    /// §7 one-click append of the headless clause to the VAULT's CLAUDE.md.
    /// LedgeCore's function is idempotent and never creates the file.
    func appendHeadlessClause() {
        guard case let .valid(path) = report?.vault else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("CLAUDE.md", isDirectory: false)
        do {
            try OnboardingChecks.appendHeadlessClause(toContentsOf: url)
            appendErrorMessage = nil
            logger.info("headless clause appended to vault CLAUDE.md")
        } catch {
            appendErrorMessage = error.localizedDescription
            logger.error("headless clause append failed: \(error.localizedDescription, privacy: .public)")
        }
        // Re-check rows, but keep the append error just set above visible —
        // only an EXTERNAL refresh ("Re-run checks") clears it.
        refresh(clearingAppendError: false)
    }
}
