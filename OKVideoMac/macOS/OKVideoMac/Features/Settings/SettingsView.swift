import SwiftUI

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigationState
    @ObservedObject var search: SidebarSearchState
    private var query: String { search.settings }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: L10n.language == .english ? 210 : 176)
            VStack(alignment: .leading, spacing: 0) {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? navigation.selectedPane.title
                    : SettingsL10n.string("settings.organized.search.results", "Settings Results"))
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 8)
                Group {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        detailContent.id(navigation.selectedPane)
                    } else { searchResults }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .environmentObject(navigation)
        .frame(minWidth: 640, minHeight: 500)
    }
    private var sidebar: some View {
        VStack(spacing: 8) {
            List(selection: Binding<SettingsPane?>(
                get: { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? navigation.selectedPane : nil },
                set: { pane in
                    guard let pane else { return }
                    search.settings = ""
                    navigation.select(pane)
                }
            )) {
                ForEach(SettingsGroup.allCases) { group in
                    Section(header: Text(group.title).font(.system(size: 11, weight: .semibold))) {
                        ForEach(group.panes) { pane in
                            HStack(spacing: 8) {
                                SettingsRowIcon(systemImage: pane.systemImage, color: pane.iconColor)
                                Text(pane.title).font(.system(size: 13)).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 3)
                            .tag(pane)
                            .accessibilityIdentifier("settings.pane.\(pane.rawValue)")
                            .help(pane.title)
                        }
                    }
                }
            }
            .modifier(SettingsCategorySurface())
            .environment(\.defaultMinListRowHeight, 28)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    @ViewBuilder private var detailContent: some View {
        switch navigation.selectedPane.canonical {
        case .general: GeneralSettingsPane()
        case .playback: PlaybackSettingsPane()
        case .details: DetailSettingsPane()
        case .configurations: SourceSettingsPane()
        case .liveSources: LiveSourceSettingsPane()
        case .data: DataSettingsPane()
        case .advanced: CompatibilitySettingsPane()
        case .about: AboutSettingsPane()
        default: GeneralSettingsPane()
        }
    }
    private var searchResults: some View {
        SettingsPage(title: SettingsL10n.string("settings.organized.search.results", "Settings Results"),
                     subtitle: SettingsL10n.string("settings.organized.search.local", "Select a result to open its setting")) {
            let results = SettingsSearchEntry.matching(query)
            if results.isEmpty {
                Text(SettingsL10n.string("settings.organized.search.empty", "No matching settings. Try “TMDB”, “history”, or “playback”."))
                    .foregroundStyle(.secondary).padding(.vertical, 32)
            } else {
                SettingsCard {
                    ForEach(results) { entry in
                        Button {
                            search.settings = ""
                            navigation.select(entry.pane, sectionID: entry.sectionID, tab: entry.tab)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title).foregroundStyle(.primary)
                                    Text(entry.path).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.padding(12).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if entry.id != results.last?.id { SettingsDivider() }
                    }
                }
            }
        }
    }
}

private struct SettingsCategorySurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content.listStyle(.sidebar).scrollContentBackground(.hidden)
        } else {
            // Inset lists do not adopt the sidebar's translucent source-list material.
            content.listStyle(.inset)
        }
    }
}
