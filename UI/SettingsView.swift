import KeyboardShortcuts
import LedgeCore
import ServiceManagement
import SwiftUI

/// §7 Settings (hosted in `SettingsWindowController` — see the documented
/// deviation there): vault folder picker with live validity, global hotkey
/// recorder, launch-at-login via SMAppService, claude binary override with
/// executable check, and the "continue last session" toggle.
///
/// §2 discipline: there is NO API-key field and never will be — the binary
/// PATH override is the only Claude-related setting (§2.1).
struct SettingsView: View {
    @AppStorage(DefaultsKey.vaultPath) private var vaultPath = ""
    @AppStorage(DefaultsKey.claudeBinaryPath) private var claudeBinaryPath = ""
    @AppStorage(DefaultsKey.continueLastSession) private var continueLastSession = false
    @AppStorage(DefaultsKey.claudeModel) private var claudeModel = ""
    @AppStorage(DefaultsKey.claudeEffort) private var claudeEffort = "high"
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemErrorMessage: String?

    /// Bumped by SettingsWindowController whenever the window becomes key
    /// again (e.g. the user returns from System Settings or Finder). The
    /// change re-renders the body — refreshing the login-item status AND
    /// re-evaluating the computed path-validity rows against the live
    /// filesystem, so neither goes stale while the window stays open.
    var refreshTick = 0
    /// Presents the onboarding sheet ("Re-run checks").
    var onRunChecks: () -> Void = {}

    var body: some View {
        Form {
            vaultSection
            hotkeySection
            generalSection
            claudeSection
            checksSection
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .onAppear { loginItemStatus = SMAppService.mainApp.status }
        .onChange(of: refreshTick) { loginItemStatus = SMAppService.mainApp.status }
    }

    // MARK: - Vault

    /// Reuses Vault's typed errors (§2.5 rules live in ONE place).
    private var vaultValidity: (ok: Bool, message: String) {
        guard !vaultPath.isEmpty else {
            return (false, "No vault folder selected")
        }
        let expanded = (vaultPath as NSString).expandingTildeInPath
        do {
            _ = try Vault(root: URL(fileURLWithPath: expanded, isDirectory: true))
            return (true, "Valid vault folder")
        } catch {
            let message = (error as? VaultError)?.errorDescription ?? "Invalid vault folder"
            return (false, message)
        }
    }

    private var vaultSection: some View {
        Section("Vault") {
            HStack {
                // Read-only: the panel is the only way to change it (no typo
                // states); the field still allows copying the path.
                TextField("Vault folder", text: .constant(vaultPath), prompt: Text("No folder selected"))
                    .labelsHidden()
                    .disabled(true)
                Button("Choose…") { chooseVaultFolder() }
            }
            validityLabel(ok: vaultValidity.ok, message: vaultValidity.message)
        }
    }

    private func chooseVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Vault"
        panel.message = "Choose your register vault folder"
        if !vaultPath.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: (vaultPath as NSString).expandingTildeInPath, isDirectory: true
            )
        }
        if panel.runModal() == .OK, let url = panel.url {
            vaultPath = url.path
        }
    }

    // MARK: - Hotkey

    private var hotkeySection: some View {
        Section("Hotkey") {
            KeyboardShortcuts.Recorder("Toggle capture", name: .toggleCapture)
        }
    }

    // MARK: - General (launch at login + continue last session)

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: launchAtLoginBinding)
            if loginItemStatus == .requiresApproval {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text("Approval needed in System Settings → Login Items")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                .font(.callout)
            }
            if let loginItemErrorMessage {
                validityLabel(ok: false, message: loginItemErrorMessage)
            }
            Toggle("Continue last session for / runs", isOn: $continueLastSession)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginItemStatus == .enabled },
            set: { enable in
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    loginItemErrorMessage = nil
                } catch {
                    loginItemErrorMessage = error.localizedDescription
                }
                loginItemStatus = SMAppService.mainApp.status
            }
        )
    }

    // MARK: - Claude binary override

    /// Nil = unset (resolver probes normally); otherwise the executable check.
    private var binaryValidity: (ok: Bool, message: String)? {
        guard !claudeBinaryPath.isEmpty else { return nil }
        let expanded = (claudeBinaryPath as NSString).expandingTildeInPath
        return FileManager.default.isExecutableFile(atPath: expanded)
            ? (true, "Executable")
            : (false, "Not executable — the resolver will fall back to probing")
    }

    private var claudeSection: some View {
        Section("Claude Code") {
            HStack {
                TextField(
                    "claude binary",
                    text: $claudeBinaryPath,
                    prompt: Text("Auto-detect (leave empty)")
                )
                .labelsHidden()
                Button("Choose…") { chooseBinary() }
            }
            if let binaryValidity {
                validityLabel(ok: binaryValidity.ok, message: binaryValidity.message)
            } else {
                Text("Optional override — leave empty to auto-detect the claude CLI")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // Model/effort select WHICH model does the note-work; the §2.3
            // sandbox flags (allowedTools, disallowedTools, max-turns) are
            // pinned in `ClaudeRunner.arguments` and not configurable here.
            // There is no --permission-mode: the agent holds no edit tools,
            // so there is nothing to accept.
            HStack {
                TextField(
                    "Model",
                    text: $claudeModel,
                    prompt: Text("Your Claude Code default")
                )
                Text("e.g. sonnet, opus")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Picker("Effort", selection: $claudeEffort) {
                Text("CLI default").tag(DefaultsKey.effortCLIDefault)
                Text("medium").tag("medium")
                Text("high (Ledge default)").tag("high")
                Text("xhigh").tag("xhigh")
            }
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose claude"
        panel.message = "Choose the claude CLI binary"
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            claudeBinaryPath = url.path
        }
    }

    // MARK: - Onboarding checks

    private var checksSection: some View {
        Section {
            HStack {
                Text("Setup checks")
                Spacer()
                Button("Re-run checks…") { onRunChecks() }
            }
        }
    }

    // MARK: - Shared bits

    private func validityLabel(ok: Bool, message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
