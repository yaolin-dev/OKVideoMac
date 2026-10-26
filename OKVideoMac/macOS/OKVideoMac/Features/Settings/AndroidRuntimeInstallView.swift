import AndroidRuntimeKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AndroidRuntimeInstallView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openURL) private var openURL
    @State private var acceptsLicenses = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                if !state.managedRuntimeInstallationState.isBusy {
                    Button {
                        state.dismissManagedRuntimeInstaller()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        L10n.string("common.close", fallback: "Close")
                    )
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 60)

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 38))
                        .foregroundStyle(statusColor)
                        .frame(width: 52)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(headline)
                            .font(.title3.weight(.semibold))
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let offer {
                    installFacts(offer)
                }

                if isOfferState, let offer {
                    licenseAcceptance(offer)
                }

                if let progress = state.managedRuntimeInstallationState.progress {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress, total: 1)
                            .progressViewStyle(.linear)
                        HStack {
                            Text(progressDescription)
                            Spacer()
                            Text("\(Int(progress * 100))%")
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else if state.managedRuntimeInstallationState.isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(progressDescription)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                HStack {
                    if state.managedRuntimeInstallationState.isBusy {
                        Button(L10n.string(.commonCancel)) {
                            Task { await state.cancelManagedRuntimeInstallation() }
                        }
                    } else if case .failed = state.managedRuntimeInstallationState {
                        Button(L10n.string(
                            "diagnostics.export.action",
                            fallback: "Export Diagnostics…"
                        )) {
                            exportDiagnostics()
                        }.disabled(state.isExportingDiagnostics)
                        if state.isExportingDiagnostics { ProgressView().controlSize(.small) }
                    }

                    if !state.managedRuntimeInstallationState.isBusy,
                       state.androidRuntimeModeSnapshot.externalSDKRoot != nil {
                        Button(L10n.string(
                            "android.install.use-configured-sdk",
                            fallback: "Use Configured Android SDK"
                        )) {
                            Task {
                                await state
                                    .useConfiguredExternalAndroidRuntime()
                            }
                        }
                    }

                    Spacer()

                    primaryAction
                }
                if let message = state.diagnosticsExportMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .frame(width: 620, height: 500)
        .interactiveDismissDisabled(
            state.managedRuntimeInstallationState.isBusy
        )
    }

    private var title: String {
        switch state.managedRuntimeInstallationState {
        case .ready:
            return L10n.string(
                "android.install.title.ready",
                fallback: "Android Compatibility Component Is Ready"
            )
        case .failed, .damaged, .incompatible:
            return L10n.string(
                "android.install.title.action-required",
                fallback: "Android Compatibility Component Needs Attention"
            )
        case .updateAvailable:
            return L10n.string(
                "android.install.title.update-available",
                fallback: "Android Compatibility Component Update Available"
            )
        default:
            return L10n.string(
                "android.install.title.install",
                fallback: "Install Android Compatibility Component"
            )
        }
    }

    private var headline: String {
        switch state.managedRuntimeInstallationState {
        case .notInstalled, .available:
            return copy("needs-component", "This Content Requires the Android Compatibility Component")
        case .detecting: return copy("detecting", "Checking the Runtime")
        case .preparing: return copy("preparing", "Preparing Installation")
        case .downloading: return copy("downloading", "Downloading Components")
        case .verifying: return copy("verifying", "Verifying Downloads")
        case .extracting: return copy("extracting", "Extracting Components")
        case .installing: return copy("installing", "Installing the Runtime")
        case .validating: return copy("validating", "Validating the Runtime")
        case .activating: return copy("activating", "Activating the New Runtime")
        case .ready: return copy("bridge-ready", "Android Bridge Is Ready")
        case .updateAvailable: return copy("update-available", "An Android Compatibility Component Update Is Available")
        case .cancelling: return copy("cancelling", "Cancelling Safely")
        case .cancelled: return copy("cancelled", "Installation Cancelled")
        case .repairing: return copy("repairing", "Repairing the Compatibility Component")
        case .damaged(let failure, _), .incompatible(let failure):
            return ManagedRuntimeFailurePresentationMapper.presentation(
                for: failure
            ).title
        case .failed(let failure, _):
            return ManagedRuntimeFailurePresentationMapper.presentation(
                for: failure
            ).title
        }
    }

    private var detail: String {
        switch state.managedRuntimeInstallationState {
        case .notInstalled, .available:
            return copy(
                "detail.isolated",
                "OKVideoMac installs the required environment in its own private directory. It does not change Android Studio, Homebrew, or your other emulators."
            )
        case .ready:
            return copy(
                "detail.ready",
                "The original content request continued automatically. No manual setup is required next time."
            )
        case .updateAvailable:
            return copy(
                "detail.update",
                "A pinned and verified Runtime Generation is available. The current runtime stays unchanged until the new one is validated and activated."
            )
        case .cancelled:
            return copy(
                "detail.cancelled",
                "No incomplete environment was activated. You can continue from resumable downloads next time."
            )
        case .failed(let failure, _), .damaged(let failure, _),
             .incompatible(let failure):
            return ManagedRuntimeFailurePresentationMapper.presentation(
                for: failure
            ).message
        default:
            return copy(
                "detail.transactional",
                "Installation runs in an isolated staging directory and is activated only after every integrity check and self-test passes."
            )
        }
    }

    private var offer: ManagedRuntimeInstallOffer? {
        switch state.managedRuntimeInstallationState {
        case .available(let offer), .preparing(let offer), .repairing(let offer):
            return offer
        case .updateAvailable(_, let offer): return offer
        case .damaged(_, let offer): return offer
        case .failed(_, let offer): return offer
        default: return nil
        }
    }

    private var isOfferState: Bool {
        if case .available = state.managedRuntimeInstallationState { return true }
        if case .failed = state.managedRuntimeInstallationState { return true }
        if case .damaged = state.managedRuntimeInstallationState { return true }
        if case .updateAvailable = state.managedRuntimeInstallationState {
            return true
        }
        return false
    }

    private var statusIcon: String {
        switch state.managedRuntimeInstallationState {
        case .ready: return "checkmark.circle.fill"
        case .failed, .damaged, .incompatible:
            return "exclamationmark.triangle.fill"
        case .updateAvailable: return "arrow.triangle.2.circlepath.circle.fill"
        case .cancelled: return "pause.circle.fill"
        case .notInstalled, .available: return "arrow.down.circle.fill"
        default: return "gearshape.2.fill"
        }
    }

    private var statusColor: Color {
        switch state.managedRuntimeInstallationState {
        case .ready: return .green
        case .failed, .damaged, .incompatible: return .red
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    private var progressDescription: String {
        guard let progress = progressDetail else { return headline }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let completed = progress.completedBytes + progress.receivedBytes
        return "\(formatter.string(fromByteCount: completed)) / \(formatter.string(fromByteCount: progress.totalBytes))"
    }

    private var progressDetail: ManagedRuntimeProgressDetail? {
        switch state.managedRuntimeInstallationState {
        case .downloading(let value), .verifying(let value),
             .extracting(let value), .installing(let value),
             .validating(let value), .activating(let value):
            return value
        default: return nil
        }
    }

    @ViewBuilder
    private func installFacts(_ offer: ManagedRuntimeInstallOffer) -> some View {
        VStack(spacing: 0) {
            factRow(
                title: copy("facts.download", "Download Size"),
                value: formattedBytes(offer.downloadBytes)
            )
            Divider()
            factRow(
                title: copy("facts.disk-space", "Required Disk Space"),
                value: formattedBytes(offer.requiredFreeSpace)
            )
            Divider()
            factRow(
                title: copy("facts.location", "Install Location"),
                value: copy("facts.private-directory", "OKVideoMac Private Directory")
            )
        }
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func factRow(title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    @ViewBuilder
    private func licenseAcceptance(
        _ offer: ManagedRuntimeInstallOffer
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: $acceptsLicenses) {
                Text(copy(
                    "license.acceptance",
                    "I have read and agree to the required component licenses"
                ))
            }
            ForEach(offer.licenses) { license in
                Button(license.title) { openURL(license.url) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch state.managedRuntimeInstallationState {
        case .available:
            Button(copy("action.install", "Install")) {
                Task {
                    await state.installManagedRuntime(
                        acceptingLicenses: acceptsLicenses
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!acceptsLicenses)
        case .failed(_, let offer), .damaged(_, let offer):
            if offer != nil {
                Button(copy("action.repair-retry", "Repair and Try Again")) {
                    Task {
                        await state.repairManagedRuntime(
                            acceptingLicenses: acceptsLicenses
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!acceptsLicenses)
            } else {
                Button(L10n.string("common.close", fallback: "Close")) {
                    state.dismissManagedRuntimeInstaller()
                }
            }
        case .incompatible:
            Button(L10n.string("common.close", fallback: "Close")) {
                state.dismissManagedRuntimeInstaller()
            }
        case .updateAvailable:
            Button(copy("action.update", "Update")) {
                Task {
                    await state.installManagedRuntime(
                        acceptingLicenses: acceptsLicenses
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!acceptsLicenses)
        case .ready:
            HStack {
                Button(copy("action.repair", "Repair Component…")) {
                    Task {
                        await state.repairManagedRuntime(
                            acceptingLicenses: true
                        )
                    }
                }
                Button(copy("action.continue", "Continue")) {
                    state.dismissManagedRuntimeInstaller()
                }
                .buttonStyle(.borderedProminent)
            }
        case .cancelled, .notInstalled:
            Button(copy("action.restart", "Start Again")) {
                Task { await state.showManagedRuntimeInstaller() }
            }
            .buttonStyle(.borderedProminent)
        default:
            EmptyView()
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
                    title: L10n.string(
                        "diagnostics.export.failed.title",
                        fallback: "Diagnostics Export Failed"
                    ),
                    message: RuntimeUserFacingMessageMapper.message(for: error)
                )
            }
        }
    }

    private func copy(_ suffix: String, _ fallback: String) -> String {
        L10n.string("android.install.\(suffix)", fallback: fallback)
    }
}
