import Combine
import Foundation
import SwiftUI

/// Local filtering does not invalidate the browser/detail AppState publisher.
/// Each section keeps its own query for the lifetime of the browser session.
@MainActor
final class SidebarSearchState: ObservableObject {
    @Published var favorites = ""
    @Published var history = ""
    @Published var settings = ""
}

@MainActor
enum SidebarSearchBinding {
    static func text(for section: AppSection, state: AppState, live: LiveBrowserSession) -> Binding<String> {
        switch section {
        case .home: return Binding(get: { state.searchDraftKeyword }, set: { state.searchDraftKeyword = $0 })
        case .live: return Binding(get: { live.searchText }, set: { live.searchText = $0 })
        case .favorites: return Binding(get: { state.sidebarSearch.favorites }, set: { state.sidebarSearch.favorites = $0 })
        case .history: return Binding(get: { state.sidebarSearch.history }, set: { state.sidebarSearch.history = $0 })
        case .settings: return Binding(get: { state.sidebarSearch.settings }, set: { state.sidebarSearch.settings = $0 })
        }
    }
}

struct LibrarySearchQuery {
    private let words: [Substring]
    init(_ query: String) {
        words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
    }
    var isEmpty: Bool { words.isEmpty }
    func matches(_ fields: String...) -> Bool {
        let value = fields.joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return words.allSatisfy { value.contains($0) }
    }
}
