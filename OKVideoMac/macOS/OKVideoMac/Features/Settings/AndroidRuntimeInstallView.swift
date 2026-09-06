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
                    .accessibilityLabel("关闭")
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
                        Button("取消") {
                            Task { await state.cancelManagedRuntimeInstallation() }
                        }
                    } else if case .failed = state.managedRuntimeInstallationState {
                        Button("导出诊断…") {
                            exportDiagnostics()
                        }
                    }

                    Spacer()

                    primaryAction
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
        case .ready: return "Android 兼容组件已就绪"
        case .failed, .damaged, .incompatible:
            return "Android 兼容组件需要处理"
        case .updateAvailable: return "Android 兼容组件可更新"
        default: return "安装 Android 兼容组件"
        }
    }

    private var headline: String {
        switch state.managedRuntimeInstallationState {
        case .notInstalled, .available:
            return "当前内容需要 Android 兼容组件"
        case .detecting: return "正在检查运行环境"
        case .preparing: return "正在准备安装"
        case .downloading: return "正在下载组件"
        case .verifying: return "正在校验下载内容"
        case .extracting: return "正在解压组件"
        case .installing: return "正在安装运行环境"
        case .validating: return "正在验证运行环境"
        case .activating: return "正在启用新环境"
        case .ready: return "Android Bridge 已准备完成"
        case .updateAvailable: return "Android 兼容组件有可用更新"
        case .cancelling: return "正在安全取消"
        case .cancelled: return "安装已取消"
        case .repairing: return "正在修复兼容组件"
        case .damaged(let failure, _), .incompatible(let failure):
            return failure.title
        case .failed(let failure, _): return failure.title
        }
    }

    private var detail: String {
        switch state.managedRuntimeInstallationState {
        case .notInstalled, .available:
            return "OKVideoMac 会将所需环境安装到自己的专用目录，不会更改 Android Studio、Homebrew 或您的其他模拟器。"
        case .ready:
            return "原来的内容请求已自动继续，以后使用时无需手动配置。"
        case .updateAvailable:
            return "可安装经过锁定和校验的新 Runtime Generation；当前版本在新环境生效前保持不变。"
        case .cancelled:
            return "未启用任何未完整的环境；下次可以从已下载的部分继续。"
        case .failed(let failure, _), .damaged(let failure, _),
             .incompatible(let failure):
            return failure.message
        default:
            return "安装在隔离的临时目录中进行；校验和自检全部通过后才会生效。"
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
                title: "预计下载",
                value: formattedBytes(offer.downloadBytes)
            )
            Divider()
            factRow(
                title: "安装所需空间",
                value: formattedBytes(offer.requiredFreeSpace)
            )
            Divider()
            factRow(title: "安装位置", value: "OKVideoMac 专用目录")
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
                Text("我已阅读并同意所需组件的许可条款")
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
            Button("安装") {
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
                Button("修复并重试") {
                    Task {
                        await state.repairManagedRuntime(
                            acceptingLicenses: acceptsLicenses
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!acceptsLicenses)
            } else {
                Button("关闭") { state.dismissManagedRuntimeInstaller() }
            }
        case .incompatible:
            Button("关闭") { state.dismissManagedRuntimeInstaller() }
        case .updateAvailable:
            Button("更新") {
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
                Button("修复组件…") {
                    Task {
                        await state.repairManagedRuntime(
                            acceptingLicenses: true
                        )
                    }
                }
                Button("继续使用") {
                    state.dismissManagedRuntimeInstaller()
                }
                .buttonStyle(.borderedProminent)
            }
        case .cancelled, .notInstalled:
            Button("重新开始") {
                Task { await state.showManagedRuntimeInstaller() }
            }
            .buttonStyle(.borderedProminent)
        default:
            EmptyView()
        }
    }

    private func exportDiagnostics() {
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
                    title: "诊断导出失败",
                    message: error.localizedDescription
                )
            }
        }
    }
}
