import LedgeCore
import SwiftUI

/// §7 onboarding sheet (presented on the SETTINGS window, never the notch
/// panel). Pure rendering of `OnboardingReport` — all check logic lives in
/// LedgeCore's `OnboardingChecks`. The install-docs link is display-only;
/// the checkpoints recommendation is text-only (Ledge never edits the
/// vault's config); the single mutating affordance is the idempotent
/// headless-clause append.
struct OnboardingView: View {
    var controller: OnboardingController
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ledge setup checks")
                .font(.title3.weight(.semibold))

            if let report = controller.report {
                checkRows(for: report)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
            }

            if let message = controller.appendErrorMessage {
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Button("Re-run checks") { controller.refresh() }
                    .disabled(controller.isChecking)
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - Rows

    private func checkRows(for report: OnboardingReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            binaryRow(report.binary)
            vaultRow(report.vault)
            claudeMDRow(report.claudeMD)
            checkpointsRow(report.checkpoints)
            headlessRow(report.headlessClause)
        }
    }

    private func binaryRow(_ result: BinaryCheckResult) -> some View {
        switch result {
        case let .found(path):
            row(.pass, "Claude Code found", detail: path)
        case .notFound:
            row(
                .fail,
                "Claude Code not found",
                detail: "Install the official CLI, then re-run the checks.",
                trailing: AnyView(
                    // Display-only docs link (§6): Ledge never downloads the CLI.
                    Link(
                        "Install docs",
                        destination: URL(string: OnboardingChecks.installDocsURL)
                            ?? URL(fileURLWithPath: "/")
                    )
                    .font(.callout)
                )
            )
        }
    }

    private func vaultRow(_ result: VaultCheckResult) -> some View {
        switch result {
        case .notConfigured:
            row(.fail, "No vault folder set", detail: "Choose your vault in Settings, behind this sheet.")
        case let .invalid(error):
            row(.fail, "Vault folder is invalid", detail: error.errorDescription ?? "Invalid vault")
        case let .valid(path):
            row(.pass, "Vault folder is valid", detail: path)
        }
    }

    private func claudeMDRow(_ result: ClaudeMDCheckResult) -> some View {
        switch result {
        case .skipped:
            row(.skipped, "Vault CLAUDE.md", detail: "Checked once a valid vault is set.")
        case .missing:
            row(
                .fail,
                "Vault has no CLAUDE.md",
                detail: "Run `register init` in the vault to create the agent contract."
            )
        case .present:
            row(.pass, "Vault contains CLAUDE.md", detail: nil)
        }
    }

    private func checkpointsRow(_ result: CheckpointsCheckResult) -> some View {
        switch result {
        case .skipped:
            row(.skipped, "register checkpoints", detail: "Checked once a valid vault is set.")
        case .noGit:
            row(.pass, "No git in vault", detail: "Nothing to configure for checkpoints.")
        case .enabled:
            row(.pass, "register checkpoints enabled", detail: nil)
        case .recommendEnabling:
            // Text-only recommendation (§7): Ledge NEVER edits the vault config.
            row(
                .warn,
                "Recommendation: enable register checkpoints",
                detail: "The vault uses git. Set \"checkpoints\": true in .register/config.json "
                    + "so agent edits are checkpointed. Ledge never edits your vault's config."
            )
        }
    }

    private func headlessRow(_ result: HeadlessClauseCheckResult) -> some View {
        switch result {
        case .skipped:
            row(.skipped, "Headless clause", detail: "Checked once the vault has a CLAUDE.md.")
        case .present:
            row(.pass, "CLAUDE.md has the headless clause", detail: nil)
        case .missing:
            row(
                .warn,
                "CLAUDE.md lacks the headless clause",
                detail: "Recommended: makes unattended runs predictable (never asks questions).",
                trailing: AnyView(
                    Button("Add to CLAUDE.md") { controller.appendHeadlessClause() }
                        .font(.callout)
                )
            )
        }
    }

    // MARK: - Row rendering

    private enum RowStatus {
        case pass, fail, warn, skipped

        var symbol: String {
            switch self {
            case .pass: "checkmark.circle.fill"
            case .fail: "xmark.circle.fill"
            case .warn: "exclamationmark.triangle.fill"
            case .skipped: "minus.circle"
            }
        }

        var color: Color {
            switch self {
            case .pass: .green
            case .fail: .red
            case .warn: .yellow
            case .skipped: .secondary
            }
        }
    }

    private func row(
        _ status: RowStatus,
        _ title: String,
        detail: String?,
        trailing: AnyView? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if let trailing {
                trailing
            }
        }
    }
}
