import AppKit
import AndroidRuntimeKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

struct CompatibilitySettingsPane: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var navigation: SettingsNavigationState
    private let diagnostics = AppLaunchSession.current?.diagnostics
    var body: some View {
        SettingsPage(title: SettingsPane.advanced.title,
            subtitle: SettingsL10n.string("settings.organized.runtime.subtitle", "Compatibility status and troubleshooting")) {
            SettingsSectionTitle(SettingsL10n.string("settings.android.section.title", "Android Compatibility"))
            SettingsCard {
                SettingsInfoRow(icon: "arrow.triangle.branch", color: .secondary,
                    title: SettingsL10n.string("settings.android.current-runtime.title", "Current Runtime"),
                    subtitle: runtimeModeDetail, value: state.androidRuntimeModeSnapshot.mode.userFacingName)
                SettingsDivider()
                if needsManagedAttention {
                SettingsControlRow(
                    icon: managedRuntimeIcon,
                    color: managedRuntimeColor,
                    title: SettingsL10n.string("settings.android.mode.managed.title", "Managed by OKVideoMac (Recommended)"),
                    subtitle: managedRuntimeDetail
                ) {
                    HStack(spacing: 8) {
                        if state.isAndroidRuntimeBusy || state.managedRuntimeInstallationState.isBusy {
                            if let progress = state
                                .managedRuntimeInstallationState.progress {
                                ProgressView(value: progress, total: 1)
                                    .progressViewStyle(.linear)
                                    .frame(width: 100)
                            } else {
                                AppActivityIndicator(size: .small)
                            }
                        }
                        Button(managedRuntimeButtonTitle) {
                            if state.androidRuntimeModeSnapshot.mode == .managed {
                                Task {
                                    await state.showManagedRuntimeInstaller()
                                }
                            } else {
                                Task {
                                    await state.useManagedAndroidRuntime()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            state.isAndroidRuntimeBusy || state.managedRuntimeInstallationState.isBusy
                                || state.androidRuntimeStatus.isRunning
                        )
                    }
                }


                } else {
                SettingsControlRow(
                    icon: androidRuntimeIcon,
                    color: androidRuntimeColor,
                    title: state.androidRuntimeStatus.title,
                    subtitle: state.androidRuntimeStatus.detail
                ) {
                    HStack(spacing: 8) {
                        if state.isAndroidRuntimeBusy {
                            if let progress = state.androidRuntimeStatus.progress {
                                VStack(alignment: .trailing, spacing: 3) {
                                    ProgressView(value: progress, total: 1)
                                        .progressViewStyle(.linear)
                                        .frame(width: 100)
                                    Text("\(Int(progress * 100))%")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                AppActivityIndicator(size: .small)
                            }
                        }

                        if state.androidRuntimeStatus.isRunning {
                            Button(SettingsL10n.string("settings.common.stop", "Stop"), role: .destructive) {
                                Task { await state.stopAndroidRuntime() }
                            }
                            .disabled(state.isAndroidRuntimeBusy)
                        } else {
                            Button(SettingsL10n.string("settings.common.start", "Start")) {
                                Task { await state.startAndroidRuntime() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                state.isAndroidRuntimeBusy
                                    || state.androidRuntimeStatus.phase == .unavailable
                            )
                        }
                    }
                }


                }
            }.settingsAnchor("runtime")
            Text(SettingsL10n.string("settings.android.scope.note", "This component is only used by video providers that require an Android Java/Dex runtime. Standard API and JavaScript providers do not start it."))
                .font(.caption).foregroundStyle(.secondary)

            SettingsDisclosure("environment", title: SettingsL10n.string("settings.organized.runtime.environment", "Environment Configuration")) {
                if !needsManagedAttention {
                SettingsControlRow(
                    icon: managedRuntimeIcon,
                    color: managedRuntimeColor,
                    title: SettingsL10n.string("settings.android.mode.managed.title", "Managed by OKVideoMac (Recommended)"),
                    subtitle: managedRuntimeDetail
                ) {
                    HStack(spacing: 8) {
                        if state.isAndroidRuntimeBusy || state.managedRuntimeInstallationState.isBusy {
                            if let progress = state
                                .managedRuntimeInstallationState.progress {
                                ProgressView(value: progress, total: 1)
                                    .progressViewStyle(.linear)
                                    .frame(width: 100)
                            } else {
                                AppActivityIndicator(size: .small)
                            }
                        }
                        Button(managedRuntimeButtonTitle) {
                            if state.androidRuntimeModeSnapshot.mode == .managed {
                                Task {
                                    await state.showManagedRuntimeInstaller()
                                }
                            } else {
                                Task {
                                    await state.useManagedAndroidRuntime()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            state.managedRuntimeInstallationState.isBusy
                                || state.androidRuntimeStatus.isRunning
                        )
                    }
                }

                SettingsDivider()
                }
                SettingsControlRow(
                    icon: externalRuntimeIcon,
                    color: externalRuntimeColor,
                    title: SettingsL10n.string("settings.android.external.title", "Existing Android SDK"),
                    subtitle: externalRuntimeDetail
                ) {
                    HStack(spacing: 8) {
                        if state.androidRuntimeModeSnapshot.mode != .external,
                           state.androidRuntimeModeSnapshot.externalSDKRoot != nil {
                            Button(SettingsL10n.string("settings.common.use", "Use")) {
                                Task {
                                    await state
                                        .useConfiguredExternalAndroidRuntime()
                                }
                            }
                            .disabled(
                                state.isAndroidRuntimeBusy
                                    || state.androidRuntimeStatus.isRunning
                            )
                        }
                        Button(externalRuntimeButtonTitle) {
                            Task { await state.chooseAndroidSDK() }
                        }
                        .disabled(
                            state.isAndroidRuntimeBusy
                                || state.androidRuntimeStatus.isRunning
                        )
                    }
                }

            }
            SettingsDisclosure("maintenance", title: SettingsL10n.string("settings.organized.runtime.maintenance", "Repair & Uninstall")) {
                SettingsControlRow(icon: "wrench", color: .secondary,
                    title: SettingsL10n.string("settings.android.action.repair-bridge", "Repair Bridge"),
                    subtitle: SettingsL10n.string("settings.organized.runtime.bridge.help", "Repair the bridge connection used by Android providers.")) {
                    Button(SettingsL10n.string("settings.common.repair", "Repair…")) {
                        Task { await state.repairAndroidRuntime() }
                    }.disabled(state.isAndroidRuntimeBusy || state.androidRuntimeStatus.phase == .unavailable)
                }
                SettingsDivider()
                SettingsControlRow(icon: "arrow.clockwise", color: .secondary,
                    title: SettingsL10n.string("settings.organized.runtime.rebuild", "Rebuild Android Runtime"),
                    subtitle: SettingsL10n.string("settings.organized.runtime.rebuild.help", "Review the recovery backup and sign-in impact before rebuilding.")) {
                    Button(SettingsL10n.string("settings.android.action.rebuild-runtime", "Repair Android Runtime…"), role: .destructive) {
                        Task { await state.rebuildAndroidRuntime() }
                    }.disabled(state.isAndroidRuntimeBusy)
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: 10) {
                    if let storage = state.androidRuntimeStorage {
                        Text(SettingsL10n.string("settings.android.storage.summary", "Components: %@ · Installation cache: %@ · Android user data: %@ · Backups: %@",
                            ByteCountFormatter.string(fromByteCount: storage.componentBytes, countStyle: .file),
                            ByteCountFormatter.string(fromByteCount: storage.cacheBytes, countStyle: .file),
                            ByteCountFormatter.string(fromByteCount: storage.userDataBytes, countStyle: .file),
                            ByteCountFormatter.string(fromByteCount: storage.backupBytes, countStyle: .file)))
                            .font(.caption).foregroundStyle(.secondary)
                        if !storage.isComplete {
                            Text(SettingsL10n.string("settings.android.storage.incomplete", "Storage estimate is incomplete. Unverified files will not be removed."))
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            if storage.hasPendingMaintenance {
                                Button(SettingsL10n.string("settings.android.uninstall.retry-cleanup", "Resume Maintenance…")) {
                                    Task { await state.recoverAndroidMaintenanceIfNeeded() }
                                }
                            } else {
                                Button(SettingsL10n.string("settings.android.action.uninstall-runtime", "Uninstall OKVideoMac-managed Components…"), role: .destructive) {
                                    Task { await state.uninstallManagedAndroidRuntime() }
                                }
                                .disabled(storage.componentBytes + storage.cacheBytes + storage.backupBytes == 0)
                            }
                            if state.isAndroidRuntimeBusy { AppActivityIndicator(size: .small) }
                        }
                        .disabled(state.isAndroidRuntimeBusy || state.managedRuntimeInstallationState.isBusy)
                    } else {
                        Text(SettingsL10n.string("settings.android.storage.calculating", "Calculating Android storage…"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = state.androidMaintenanceMessage {
                        Text(message).font(.caption).textSelection(.enabled)
                    }
                    Text(SettingsL10n.string("settings.android.uninstall.keep-user-data", "Uninstall keeps Android sign-in data, user-data backups, private keys, and external SDK files."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)


            }.disabled(state.managedRuntimeInstallationState.isBusy)

            SettingsSectionTitle(SettingsL10n.string("settings.diagnostics.section", "Diagnostics"))
            SettingsCard {
                SettingsControlRow(
                    icon: "doc.text.magnifyingglass",
                    color: .teal,
                    title: SettingsL10n.string("settings.diagnostics.title", "Export Diagnostics"),
                    subtitle: SettingsL10n.string("settings.diagnostics.subtitle", "Export redacted runtime status and provider capabilities")
                ) {
                    Button(SettingsL10n.string("settings.common.export", "Export…")) {
                        exportDiagnostics()
                    }.disabled(state.isExportingDiagnostics)
                    if state.isExportingDiagnostics { ProgressView().controlSize(.small) }
                }
                if let message = state.diagnosticsExportMessage {
                    HStack {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        if let url = state.diagnosticsExportURL {
                            Button(SettingsL10n.string("settings.diagnostics.reveal", "Show in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 12)
                }
                SettingsDivider()
                SettingsControlRow(icon: "checkmark.circle", color: .secondary,
                    title: SettingsL10n.string("settings.organized.runtime.check", "Check Runtime"),
                    subtitle: SettingsL10n.string("settings.organized.runtime.check.help", "Refresh the current environment status without starting playback.")) {
                    if state.isCheckingAndroidRuntime { ProgressView().controlSize(.small) }
                    Button(SettingsL10n.string("settings.common.check", "Check")) { Task { await state.refreshAndroidRuntimeStatus() } }
                        .disabled(state.isAndroidRuntimeBusy || state.isCheckingAndroidRuntime)
                }
                if let message = state.androidRuntimeCheckMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
                }
                SettingsDivider()
                SettingsControlRow(icon: "hand.raised", color: .secondary,
                    title: SettingsL10n.string("settings.organized.privacy.diagnostics", "Crash Reports"),
                    subtitle: SettingsL10n.string("settings.organized.runtime.privacy.help", "Manage report sharing in Data & Privacy.")) {
                    Button(SettingsL10n.string("settings.organized.common.manage", "Manage…")) {
                        navigation.select(.data, sectionID: "crash-reports", tab: .privacy)
                    }
                }
            }.settingsAnchor("diagnostics")
            SettingsDisclosure("runtime-details", title: SettingsL10n.string("settings.organized.runtime.technical", "Technical Details")) {
                Text(runtimeIsolationDetail).font(.caption).foregroundStyle(.secondary)
                Text(externalRuntimeDetail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .task {
            await state.refreshAndroidStorage()
            while !Task.isCancelled {
                await state.refreshAndroidRuntimeStatus(reportCompletion: false)
                // Startup/install progress already arrives through dedicated observers.
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break }
            }
        }
    }
    private var needsManagedAttention: Bool {
        guard state.androidRuntimeModeSnapshot.mode == .managed else { return false }
        switch state.managedRuntimeInstallationState {
        case .ready, .updateAvailable: return false
        default: return !state.androidRuntimeStatus.isRunning
        }
    }

    private var androidRuntimeIcon: String {
        switch state.androidRuntimeStatus.phase {
        case .running: return "checkmark.circle.fill"
        case .starting, .checking, .stopping: return "hourglass"
        case .failed, .unavailable: return "exclamationmark.triangle.fill"
        case .stopped: return "power"
        }
    }

    private var androidRuntimeColor: Color {
        switch state.androidRuntimeStatus.phase {
        case .running: return .green
        case .starting, .checking, .stopping: return .orange
        case .failed, .unavailable: return .red
        case .stopped: return .secondary
        }
    }

    private var runtimeModeDetail: String {
        switch state.androidRuntimeModeSnapshot.mode {
        case .managed:
            return SettingsL10n.string("settings.android.mode.managed.detail", "Android content uses only verified components managed by OKVideoMac")
        case .external:
            return SettingsL10n.string("settings.android.mode.external.detail", "Android content uses only the SDK selected below and never triggers Managed Runtime installation")
        }
    }

    private var externalRuntimeDetail: String {
        guard let root = state.androidRuntimeModeSnapshot.externalSDKRoot else {
            return SettingsL10n.string("settings.android.external.not-configured", "Not configured. Advanced users can select an installed, complete Android SDK.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let displayPath = root.path.hasPrefix(home + "/")
            ? "~/" + root.path.dropFirst(home.count + 1)
            : root.path
        if state.androidRuntimeModeSnapshot.mode != .external {
            return SettingsL10n.string("settings.android.external.saved", "Saved: %@. It will be validated again before switching.", displayPath)
        }
        let stateDetail = state.androidRuntimeModeSnapshot.externalValidation?
            .userFacingStatus
            ?? SettingsL10n.string("settings.android.external.checking", "Checking the existing Android SDK")
        return "\(stateDetail) · \(displayPath)"
    }

    private var externalRuntimeIcon: String {
        guard state.androidRuntimeModeSnapshot.externalSDKRoot != nil else {
            return "externaldrive.badge.questionmark"
        }
        if state.androidRuntimeModeSnapshot.mode != .external {
            return "externaldrive"
        }
        return state.androidRuntimeModeSnapshot.externalValidation?
            .canPrepareRuntime == true
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill"
    }

    private var externalRuntimeColor: Color {
        guard state.androidRuntimeModeSnapshot.mode == .external else {
            return .secondary
        }
        return state.androidRuntimeModeSnapshot.externalValidation?
            .canPrepareRuntime == true ? .green : .red
    }

    private var externalRuntimeButtonTitle: String {
        state.androidRuntimeModeSnapshot.externalSDKRoot == nil
            ? SettingsL10n.string("settings.common.choose", "Choose…")
            : SettingsL10n.string("settings.common.change", "Change…")
    }

    private var managedRuntimeButtonTitle: String {
        if state.androidRuntimeModeSnapshot.mode != .managed {
            return SettingsL10n.string("settings.android.action.switch-to", "Switch To…")
        }
        return managedRuntimeActionTitle
    }

    private var runtimeIsolationDetail: String {
        switch state.androidRuntimeModeSnapshot.mode {
        case .managed:
            return SettingsL10n.string("settings.android.isolation.managed", "Required files are downloaded on demand to an OKVideoMac private directory. External Android tools are never read or reused.")
        case .external:
            return SettingsL10n.string("settings.android.isolation.external", "ADB and Emulator always come from the selected SDK, while OKVideoMac continues to use its private ADB server, keys, and dedicated AVD.")
        }
    }

    private var managedRuntimeTitle: String {
        switch state.managedRuntimeInstallationState {
        case .ready: return SettingsL10n.string("settings.android.managed.installed", "Android compatibility component installed")
        case .updateAvailable: return SettingsL10n.string("settings.android.managed.update-available", "Android compatibility component update available")
        case .failed, .damaged: return SettingsL10n.string("settings.android.managed.needs-repair", "Android compatibility component needs repair")
        case .incompatible: return SettingsL10n.string("settings.android.managed.incompatible", "Android compatibility component is incompatible")
        case .notInstalled, .available, .cancelled:
            return SettingsL10n.string("settings.android.managed.not-installed", "Android compatibility component not installed")
        default: return SettingsL10n.string("settings.android.managed.processing", "Processing the Android compatibility component")
        }
    }

    private var managedRuntimeDetail: String {
        switch state.managedRuntimeInstallationState {
        case .ready:
            return SettingsL10n.string("settings.android.managed.ready-detail", "Managed independently by OKVideoMac and started only when Dex content needs it")
        case .updateAvailable:
            return SettingsL10n.string("settings.android.managed.update-detail", "A new runtime can be installed. The current runtime remains active until the new version is validated.")
        case .failed(let failure, _), .damaged(let failure, _),
             .incompatible(let failure):
            return ManagedRuntimeFailurePresentationMapper.presentation(
                for: failure
            ).message
        case .downloading(let detail):
            return detail.componentID.map {
                SettingsL10n.string("settings.android.managed.downloading-component", "Downloading: %@", $0)
            } ?? SettingsL10n.string("settings.android.managed.downloading", "Downloading")
        default:
            return SettingsL10n.string("settings.android.managed.on-demand", "You will be prompted the first time content requires Android")
        }
    }

    private var managedRuntimeIcon: String {
        switch state.managedRuntimeInstallationState {
        case .ready: return "checkmark.circle.fill"
        case .failed, .damaged, .incompatible:
            return "exclamationmark.triangle.fill"
        case .updateAvailable: return "arrow.triangle.2.circlepath.circle.fill"
        case .notInstalled, .available, .cancelled:
            return "arrow.down.circle.fill"
        default: return "gearshape.2.fill"
        }
    }

    private var managedRuntimeColor: Color {
        switch state.managedRuntimeInstallationState {
        case .ready: return .green
        case .failed, .damaged, .incompatible: return .red
        case .updateAvailable: return .orange
        case .notInstalled, .available, .cancelled: return .accentColor
        default: return .orange
        }
    }

    private var managedRuntimeActionTitle: String {
        switch state.managedRuntimeInstallationState {
        case .ready: return SettingsL10n.string("settings.common.details", "Details")
        case .updateAvailable: return SettingsL10n.string("settings.common.update", "Update…")
        case .failed, .damaged, .incompatible: return SettingsL10n.string("settings.common.repair", "Repair…")
        default: return SettingsL10n.string("settings.common.install", "Install…")
        }
    }

    private func exportDiagnostics() {
        guard !state.isExportingDiagnostics else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "OKVideoMac-Diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                try await state.exportDiagnostics(to: url)
            } catch {
                state.presentedError = UserFacingError(
                    title: L10n.string("diagnostics.export.failed.title", fallback: "Diagnostics Export Failed"),
                    message: RuntimeUserFacingMessageMapper.message(for: error)
                )
            }
        }
    }

}
