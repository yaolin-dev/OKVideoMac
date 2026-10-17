import AppKit
import SwiftUI

struct AppStartupView: View {
    @ObservedObject var startup: AppStartupController

    var body: some View {
        Group {
            if startup.phase == .failed || startup.phase == .recovery {
                recoveryContent
            } else {
                AppStartupBrowserShell().ignoresSafeArea()
            }
        }
        .task { startup.beginIfReady() }
    }

    private var recoveryContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if startup.phase == .failed {
                Text(L10n.string("app.initialization.failed", fallback: "Unable to Initialize App"))
                    .font(.title2).bold()
                Text(startup.failureMessage ?? "")
                Button(L10n.string("crash.recovery.quit", fallback: "Quit")) { NSApp.terminate(nil) }
            } else {
                Text(L10n.string("crash.recovery.title", fallback: "OKVideoMac closed unexpectedly"))
                    .font(.title2).bold()
                Text(L10n.string("crash.recovery.local", fallback: "A filtered crash report is saved on this Mac for up to 7 days, with at most 3 reports kept. You can continue opening the app."))
                CrashDiagnosticsControls(diagnostics: startup.diagnostics)
                HStack {
                    Button(L10n.string("crash.recovery.quit", fallback: "Quit")) { NSApp.terminate(nil) }
                    Button(L10n.string("crash.recovery.continue", fallback: "Continue Opening")) { startup.continueStartup() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("crash-recovery-continue")
                }
            }
        }
        .padding(28).frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Presentation only: never constructs AppState, opens the database or runs a
/// command before the recovery gate has admitted the business environment.
struct AppStartupBrowserShell: NSViewControllerRepresentable {
    private let navigation = AppNavigationState()

    func makeNSViewController(context: Context) -> BrowserRootSplitController {
        let controller = BrowserRootSplitController()
        updateNSViewController(controller, context: context)
        return controller
    }

    func updateNSViewController(_ controller: BrowserRootSplitController, context: Context) {
        controller.sidebarHost.rootView = AnyView(
            NativeSidebarSourceList(text: .constant(""),
                presentation: SidebarSearchPresentationPolicy.presentation(for: .home),
                isSearchEnabled: false, focusRequest: 0, selection: navigation.selection,
                navigation: navigation, onTextChange: { _ in }, onSubmit: {},
                onExitSearch: { false }, onSelect: { _ in }, isNavigationEnabled: false)
                .environment(\.locale, context.environment.locale)
                .environment(\.layoutDirection, context.environment.layoutDirection)
        )
        controller.detailHost.rootView = AnyView(
            StartupContentPlaceholder()
                .toolbar { PrimaryPageToolbarLeadingContent(title: AppSection.home.title) }
                .modifier(BrowserToolbarBackgroundModifier())
                .environment(\.locale, context.environment.locale)
                .environment(\.layoutDirection, context.environment.layoutDirection)
        )
    }

    static func dismantleNSViewController(_ controller: BrowserRootSplitController, coordinator: ()) {
        controller.detachWindowChrome()
    }
}

/// Shared with the first local-data restore, so the browser keeps its structure
/// through both startup gates. Only the small activity label is delayed.
struct StartupContentPlaceholder: View {
    @State private var showsActivity = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                PosterInitialSkeleton(width: geometry.size.width, height: geometry.size.height)
                    .padding(20)
            }
            .overlay(alignment: .bottom) {
                if showsActivity {
                    AppActivityLabel(L10n.string("home.restoring-last-content", fallback: "Restoring your last content…"))
                        .padding(12)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 20)
                        .accessibilityIdentifier("startup.loading-content")
                }
            }
        }
        .background(AppSurfacePalette.background)
        .background { WindowCloseObserver(onClose: {}, onKeyChange: { _ in }) }
        .task {
            do { try await Task.sleep(nanoseconds: 300_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            showsActivity = true
        }
    }
}
