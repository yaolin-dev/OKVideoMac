import OKVideoCore
import SwiftUI

private func activityText(_ key: String, _ fallback: String) -> String {
    L10n.string("live.background.\(key)", fallback: fallback)
}

struct LiveBackgroundActivityControl: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var epgState: LiveEPGState
    @ObservedObject var validationToolbar: LiveValidationToolbarModel
    @ObservedObject var previewToolbar: LivePreviewActivityModel.Toolbar
    let source: LiveSourceDescriptor
    @State private var presented = false

    var body: some View {
        let epg = state.liveBackgroundEPGPresentation(for: source.id, at: Date())
        let otherIndicator = LiveBackgroundIndicator(
            catalogLoading: state.isLiveCatalogLoading(source.id),
            catalogFailed: state.liveCatalogError(for: source.id) != nil,
            epg: epg, validation: nil)
        let validationIndicator: LiveBackgroundIndicator = {
            guard case .imported(let id) = source.id else { return .idle }
            return validationToolbar.indicators[id] ?? .idle
        }()
        let previewKey = LivePreviewPolicy.digest([LiveBrowserPreferenceStore.encode(source.id)])
        let previewIndicator = previewToolbar.state?.sourceKey == previewKey ? previewToolbar.state!.indicator : .idle
        let indicators = [otherIndicator, validationIndicator, previewIndicator]
        let indicator: LiveBackgroundIndicator = indicators.contains(.active)
            ? .active : indicators.contains(.warning) ? .warning : .idle
        Button { presented.toggle() } label: {
            Group {
                switch indicator {
                case .active: ProgressView().controlSize(.small)
                case .warning: Image(systemName: "exclamationmark.circle")
                case .idle: Image(systemName: "waveform.path.ecg")
                }
            }
            .frame(width: 18, height: 18)
        }
        .primaryToolbarIconControl()
        .help(activityText("title", "Background Activity"))
        .accessibilityLabel(activityText("title", "Background Activity"))
        .accessibilityValue(indicator == .active ? activityText("running", "Working")
            : indicator == .warning ? activityText("attention", "Needs attention")
            : activityText("idle", "No active tasks"))
        .accessibilityIdentifier("live.background.activity")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            LiveBackgroundActivityPopover(activity: state.liveValidationActivity,
                previews: state.livePreviews.activity,
                source: source, programmeEnd: epg?.lastProgrammeEnd)
        }
        .onChange(of: source.id) { _ in presented = false }
        .onDisappear { presented = false }
    }
}

/// Only the open details subtree subscribes to numeric progress. Neither the
/// toolbar nor the live grid observes this object or forwards its publisher.
private struct LiveBackgroundActivityPopover: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var activity: LiveValidationActivityModel
    @ObservedObject var previews: LivePreviewActivityModel
    let source: LiveSourceDescriptor
    let programmeEnd: Date?

    var body: some View {
        let key = LivePreviewPolicy.digest([LiveBrowserPreferenceStore.encode(source.id)])
        TimelineView(EPGTimelineSchedule(boundaries: [programmeEnd].compactMap { $0 })) { context in
            LiveBackgroundActivityDetails(
                sourceName: LogRedactor.text(source.name),
                epg: state.liveBackgroundEPGPresentation(for: source.id, at: context.date),
                validation: activity.presentation(for: source.id),
                catalogLoading: state.isLiveCatalogLoading(source.id),
                catalogFailed: state.liveCatalogError(for: source.id) != nil,
                hasCatalog: state.presentedLiveCatalog(for: source.id) != nil,
                nativeEPGEnabled: state.epgPreferences.automaticEPGEnabled,
                preview: previews.presentation?.sourceKey == key ? previews.presentation : nil,
                retryPreviews: { state.livePreviews.retryFailed(sourceKey: key) },
                stop: { runID in state.stopLiveBackgroundValidation(sourceID: source.id, runID: runID) })
        }
        .labelStyle(.titleAndIcon)
        .onAppear { state.synchronizeLiveValidationPresentation(for: source.id) }
    }
}

/// Pure content view: its only action is an explicitly supplied, scoped stop.
/// Rendering, opening and closing it cannot start or retry any background work.
struct LiveBackgroundActivityDetails: View {
    let sourceName: String
    let epg: LiveEPGPresentation?
    let validation: LiveValidationPresentation?
    let catalogLoading: Bool
    let catalogFailed: Bool
    let hasCatalog: Bool
    let nativeEPGEnabled: Bool
    var preview: LivePreviewActivityPresentation? = nil
    var retryPreviews: (() -> Void)? = nil
    let stop: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(activityText("title", "Background Activity")).font(.headline)
                Text(sourceName).foregroundColor(.secondary).lineLimit(2)
            }
            if catalogLoading || catalogFailed {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(activityText("catalog", "Channel List")).font(.subheadline.weight(.semibold))
                    Text(catalogLoading ? activityText("catalog-loading", "Updating channel list…")
                        : hasCatalog ? activityText("catalog-cached", "Update failed; keeping the existing list.")
                        : activityText("catalog-failed", "Unable to load channels. Retry using the refresh button."))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if let epg {
                Divider()
                epgSection(epg)
            }
            if let validation {
                Divider()
                validationSection(validation)
            }
            if let preview {
                Divider()
                previewSection(preview)
            }
            if epg == nil && validation == nil && preview == nil && !catalogLoading && !catalogFailed {
                Text(nativeEPGEnabled
                    ? activityText("native", "Programme data is loaded on demand and shown on channel cards.")
                    : activityText("native-disabled", "Programme guide is disabled."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .labelStyle(.titleAndIcon)
        .accessibilityIdentifier("live.background.details")
    }

    private func previewSection(_ value: LivePreviewActivityPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.string("live.preview.frames", fallback: "Channel Pictures"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if value.phase == .partial, let retryPreviews {
                    Button(activityText("preview-retry", "Retry Failed"), action: retryPreviews)
                        .controlSize(.small)
                }
            }
            Text(previewTitle(value)).font(.caption)
            Text(L10n.string("live.background.preview-visible", fallback: "Pictures on screen: %d / %d",
                value.visibleReady, value.visibleTotal)).font(.caption)
            if value.active > 0 || value.queued > 0 {
                Text(L10n.string("live.background.preview-workers", fallback: "Capturing: %d · Queued: %d",
                    value.active, value.queued)).font(.caption).foregroundColor(.secondary)
            }
            if value.total > 0 {
                Text(L10n.string("live.background.preview-round", fallback: "This round: %d / %d",
                    value.completed, value.total)).font(.caption)
                if value.indicator == .active {
                    ProgressView(value: Double(value.completed), total: Double(value.total))
                        .progressViewStyle(.linear)
                        .accessibilityLabel(activityText("preview-round-label", "Channel picture progress"))
                        .accessibilityValue("\(value.completed) / \(value.total)")
                }
                Text(L10n.string("live.background.preview-results", fallback: "New: %d · Cached: %d · Failed: %d",
                    value.captured, value.cached, value.failed)).font(.caption).foregroundColor(.secondary)
            }
            Text(activityText("preview-scope", "Automatic updates refresh visible channels every 10 minutes when enabled. Saved pictures remain available."))
                .font(.caption).foregroundColor(.secondary)
        }
        .accessibilityIdentifier("live.background.previews")
    }

    private func previewTitle(_ value: LivePreviewActivityPresentation) -> String {
        switch value.phase {
        case .restoring: return activityText("preview-restoring", "Restoring saved pictures…")
        case .capturing: return activityText("preview-capturing", "Loading channel pictures…")
        case .waiting: return activityText("preview-waiting", "Waiting for an available source connection…")
        case .paused: return activityText("preview-paused", "Paused while playing or browsing elsewhere")
        case .completed: return activityText("preview-completed", "Pictures are up to date")
        case .partial: return activityText("preview-partial", "Some pictures could not be updated; saved pictures are kept")
        }
    }

    private func epgSection(_ value: LiveEPGPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(activityText("epg", "Programme Guide")).font(.subheadline.weight(.semibold))
            Text(epgTitle(value)).font(.caption)
            if value.usesCachedData {
                Text(value.coverage == .expired
                    ? activityText("cache-expired", "Using cached data · programme data expired")
                    : activityText("cache", "Using cached data"))
                    .font(.caption).foregroundColor(.secondary)
            }
            if value.coverage == .expired, let end = value.lastProgrammeEnd {
                Text(L10n.string("live.background.data-until", fallback: "Data through %@",
                    end.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func epgTitle(_ value: LiveEPGPresentation) -> String {
        if !value.enabled { return activityText("disabled", "Disabled") }
        if !value.configured { return activityText("unconfigured", "No programme guide configured") }
        switch value.activity {
        case .loading: return activityText("epg-loading", "Loading programme guide…")
        case .refreshing: return activityText("epg-refreshing", "Updating programme guide…")
        case .idle: break
        }
        if value.refreshFailed { return activityText("epg-failed", "Unable to update programme guide") }
        switch value.coverage {
        case .expired: return activityText("expired", "Programme data expired; waiting for an update")
        case .empty: return activityText("empty", "No programme data")
        case .hasUnexpiredProgrammes: return activityText("loaded", "Loaded")
        case .unknown: return activityText("waiting", "Waiting to load")
        }
    }

    private func validationSection(_ value: LiveValidationPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(activityText("validation", "Channel Check")).font(.subheadline.weight(.semibold))
                Spacer()
                if value.canStop, let runID = value.runID {
                    Button(activityText("stop", "Stop")) { stop(runID) }
                        .controlSize(.small)
                        .accessibilityIdentifier("live.background.stop")
                }
            }
            Text(validationTitle(value)).font(.caption)
            if value.phase == .cancelled || value.phase == .partial {
                Text(L10n.string("live.background.checked-count", fallback: "Checked %d / %d", value.completed, value.total))
                    .font(.caption).foregroundColor(.secondary)
            }
            if value.phase == .checking, let progress = value.progress {
                ProgressView(value: progress).progressViewStyle(.linear)
                    .accessibilityLabel(activityText("validation", "Channel Check"))
                    .accessibilityValue("\(value.completed) / \(value.total)")
            }
            Text(activityText("conservative", "Channels whose availability cannot be confirmed are kept."))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func validationTitle(_ value: LiveValidationPresentation) -> String {
        switch value.phase {
        case .idle: return activityText("not-checked", "Not checked yet")
        case .checking:
            return L10n.string("live.background.checked-count", fallback: "Checked %d / %d", value.completed, value.total)
        case .processing: return activityText("processing", "Processing results…")
        case .completed:
            return L10n.string("live.background.completed", fallback: "Checked %d channels; %d confirmed unavailable", value.total, value.hiddenCandidates)
        case .cancelled: return activityText("cancelled", "Stopped; no incomplete results applied")
        case .partial: return activityText("partial", "Time limit reached; no incomplete results applied")
        case .failed: return activityText("failed", "Check could not finish. Retry using the refresh button.")
        }
    }
}
