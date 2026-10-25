import AppKit
import OKVideoPersistence
import SwiftUI

enum FavoriteScope: Hashable {
    case all, current, unresolved, configuration(UUID)
}

struct FavoritesView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var search: SidebarSearchState
    @State private var isDeleting = false
    private var visible: [FavoriteRecord] {
        let query = LibrarySearchQuery(search.favorites)
        return state.favorites.filter { item in
            guard query.matches(item.title, state.favoriteSourceDescription(item)) else { return false }
            switch state.favoritesScope {
            case .all: return true
            case .current: return item.configurationID != nil && item.configurationID == state.activeConfigurationRecord?.id
            case .unresolved: return item.configurationID == nil
            case .configuration(let id): return item.configurationID == id
            }
        }
    }
    private var rows: [NativeLibraryRow] {
        visible.map { item in
            NativeLibraryRow(id: item.id, title: item.title, subtitle: state.favoriteSourceDescription(item),
                summary: (item.synopsis ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " "),
                posterURL: item.posterURL, date: item.createdAt, isLoading: state.favoriteLoadingID == item.id)
        }
    }
    var body: some View {
        NativeLibraryList(rows: rows, selection: $state.favoriteSelection, repository: state.imageRepository,
            openTitle: L10n.string("favorites.open", fallback: "Open Details"), openSymbol: "info.circle",
            onOpen: { state.requestOpenFavorite($0) }, onDelete: requestDeletion,
            onRepairSource: { id, _ in state.requestOpenFavorite(id, repairSource: true) })
        .overlay {
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Text(LibrarySearchQuery(search.favorites).isEmpty
                        ? L10n.string("favorites.empty.title", fallback: "No Favorites")
                        : L10n.string("sidebar.search.no-results", fallback: "No Matching Results")).font(.headline)
                    Text(LibrarySearchQuery(search.favorites).isEmpty
                        ? L10n.string("favorites.empty.message", fallback: "Add a title to Favorites from its details page.")
                        : L10n.string("sidebar.search.no-results.help", fallback: "Try another keyword or clear the search field."))
                        .foregroundColor(.secondary)
                }.padding()
            }
        }
        .navigationTitle("")
        .toolbar {
            PrimaryPageToolbarLeadingContent(title: L10n.string(.sectionFavorites) + " (\(rows.count))")
            ToolbarItemGroup(placement: .primaryAction) {
                Picker(L10n.string("favorites.scope", fallback: "Scope"), selection: $state.favoritesScope) {
                    Text(L10n.string("favorites.scope.all", fallback: "All Favorites")).tag(FavoriteScope.all)
                    Text(L10n.string("favorites.scope.current", fallback: "Current Configuration")).tag(FavoriteScope.current)
                    Text(L10n.string("favorites.source.unresolved", fallback: "Source needs confirmation")).tag(FavoriteScope.unresolved)
                    ForEach(state.configurations) { configuration in
                        Text(configuration.name).tag(FavoriteScope.configuration(configuration.id))
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .controlSize(.regular)
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .help(L10n.string("favorites.scope", fallback: "Scope"))
                Menu {
                    Button(L10n.string("common.select-all", fallback: "Select All")) { state.favoriteSelection = Set(visible.map(\.id)) }
                    Button(L10n.string("favorites.source.choose", fallback: "Confirm Favorite Source")) {
                        if let id = state.favoriteSelection.first { state.requestOpenFavorite(id, repairSource: true) }
                    }.disabled(state.favoriteSelection.count != 1)
                    Button(LibrarySearchQuery(search.favorites).isEmpty ? L10n.string("favorites.clear-scope", fallback: "Remove All in This Scope") : L10n.string("sidebar.search.remove-results", fallback: "Remove Filtered Results")) { requestDeletion(Set(visible.map(\.id)), nil) }
                } label: { Label(L10n.string("favorites.manage", fallback: "Manage Favorites"), systemImage: "ellipsis.circle") }
                .primaryToolbarMenuControl()
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .help(L10n.string("favorites.manage", fallback: "Manage Favorites"))
                Button { requestDeletion(state.favoriteSelection, nil) } label: {
                    Label(L10n.string("common.delete-selected", fallback: "Delete Selected"), systemImage: "trash")
                }
                .primaryToolbarIconControl()
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .help(L10n.string("common.delete-selected", fallback: "Delete Selected"))
                .disabled(state.favoriteSelection.isEmpty || isDeleting)
            }
        }
        .task { await state.refreshFavoritesPresentation() }
        .onChange(of: state.isBrowserWindowKey) { key in if key { Task { await state.refreshFavoritesPresentation() } } }
        .onChange(of: visible.map(\.id)) { state.favoriteSelection.formIntersection($0) }
    }
    private func requestDeletion(_ ids: Set<String>, _ window: NSWindow?) {
        guard !isDeleting else { return }
        let captured = Set(visible.filter { ids.contains($0.id) }.map(\.id))
        guard !captured.isEmpty else { return }
        let scope: String
        switch state.favoritesScope {
        case .all: scope = L10n.string("favorites.scope.all", fallback: "All Favorites")
        case .current: scope = state.activeConfigurationRecord?.name ?? ""
        case .unresolved: scope = L10n.string("favorites.source.unresolved", fallback: "Source needs confirmation")
        case .configuration(let id): scope = state.configurations.first { $0.id == id }?.name ?? ""
        }
        NativeLibraryConfirmation.present(title: L10n.string("favorites.delete.title", fallback: "Remove Favorites?"),
            message: L10n.string("favorites.delete.scope-message", fallback: "Remove %d selected favorites from %@? Watch history is preserved.", captured.count, scope), window: window) {
                isDeleting = true
                Task {
                    if await state.deleteFavorites(ids: captured) { state.favoriteSelection.subtract(captured) }
                    isDeleting = false
                }
            }
    }
}
