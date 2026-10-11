import SwiftUI

/// Pick what plays next without leaving the app: the queue, recent history and search.
struct TrackPickerView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case queue, recent, search
        var id: Self { self }

        var title: String {
            switch self {
            case .queue: return String(localized: "Очередь")
            case .recent: return String(localized: "Недавние")
            case .search: return String(localized: "Поиск")
            }
        }
    }

    @Environment(PlayerModel.self) private var player
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Tab = .queue
    @State private var queue: [TrackSummary] = []
    @State private var recent: [TrackSummary] = []
    @State private var results: [TrackSummary] = []
    @State private var query = ""
    @State private var canLoadMore = false
    @State private var loading = false
    @State private var error: String?
    @State private var needsRelogin = false
    @FocusState private var searchFocused: Bool

    private static let recentScope = "user-read-recently-played"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(String(localized: "Раздел"), selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                if tab == .search {
                    searchField
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Готово")) { dismiss() }
                }
                if tab != .search {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Task { await load(tab) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(loading)
                    }
                }
            }
        }
        .task(id: tab) {
            if tab == .search {
                searchFocused = results.isEmpty
            } else {
                await load(tab)
            }
        }
        .task(id: query) {
            // Debounce typing.
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard tab == .search else { return }
            guard !text.isEmpty else {
                results = []
                canLoadMore = false
                error = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await runSearch(text, offset: 0)
        }
    }

    private var navigationTitle: String {
        if let device = player.deviceName { return "Spotify · \(device)" }
        return "Spotify"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let rows = currentRows
        if needsRelogin && tab == .recent {
            reloginPrompt
        } else if let error, rows.isEmpty {
            placeholder(icon: "exclamationmark.triangle", text: error)
        } else if rows.isEmpty && loading {
            ProgressView().controlSize(.large)
        } else if rows.isEmpty {
            placeholder(icon: emptyIcon, text: emptyText)
        } else {
            List {
                if tab == .queue, let track = player.track {
                    Section(String(localized: "Сейчас играет")) {
                        TrackRow(title: track.title, subtitle: track.artistLine, artwork: track.artworkURL,
                                 duration: track.duration, highlighted: true)
                    }
                }
                Section(sectionTitle) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, track in
                        Button {
                            choose(track, at: index)
                        } label: {
                            TrackRow(title: track.title, subtitle: track.artistLine, artwork: track.thumbnailURL,
                                     duration: track.duration, highlighted: false)
                        }
                        .contextMenu { menu(for: track, at: index) }
                        .swipeActions(edge: .trailing) {
                            if tab != .queue {
                                Button {
                                    player.addToQueue(track)
                                } label: {
                                    Label(String(localized: "В очередь"), systemImage: "text.badge.plus")
                                }
                                .tint(.green)
                            }
                        }
                    }
                }
                if tab == .search && canLoadMore {
                    Button {
                        Task { await runSearch(query.trimmingCharacters(in: .whitespacesAndNewlines), offset: results.count) }
                    } label: {
                        HStack {
                            Spacer()
                            if loading { ProgressView() } else { Text(String(localized: "Показать ещё")) }
                            Spacer()
                        }
                    }
                    .disabled(loading)
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.immediately)
            .refreshable { if tab != .search { await load(tab) } }
        }
    }

    private var currentRows: [TrackSummary] {
        switch tab {
        case .queue: return queue
        case .recent: return recent
        case .search: return results
        }
    }

    private var sectionTitle: String {
        switch tab {
        case .queue: return String(localized: "Далее")
        case .recent: return String(localized: "Недавно играли")
        case .search: return String(localized: "Треки")
        }
    }

    private var emptyIcon: String {
        switch tab {
        case .queue: return "list.bullet"
        case .recent: return "clock"
        case .search: return "magnifyingglass"
        }
    }

    private var emptyText: String {
        switch tab {
        case .queue: return String(localized: "Очередь пуста")
        case .recent: return String(localized: "История пуста")
        case .search: return query.isEmpty ? String(localized: "Найдите трек по названию или исполнителю") : String(localized: "Ничего не найдено")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(String(localized: "Трек, исполнитель, альбом"), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var reloginPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.badge.exclamationmark").font(.system(size: 40))
            Text(String(localized: "Для истории прослушивания нужно заново войти в Spotify и разрешить доступ к недавним трекам."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(String(localized: "Войти заново")) {
                Task {
                    do {
                        try await auth.logIn()
                        needsRelogin = false
                        await load(.recent)
                    } catch SpotifyAuthError.cancelled {
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 36))
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }

    @ViewBuilder
    private func menu(for track: TrackSummary, at index: Int) -> some View {
        Button {
            choose(track, at: index)
        } label: {
            Label(tab == .queue ? String(localized: "Перейти к треку") : String(localized: "Слушать"), systemImage: "play.fill")
        }
        if tab != .queue {
            Button {
                player.addToQueue(track)
            } label: {
                Label(String(localized: "Добавить в очередь"), systemImage: "text.badge.plus")
            }
        }
        if let url = Self.spotifyURL(track.uri) {
            Button {
                UIApplication.shared.open(url)
            } label: {
                Label(String(localized: "Открыть в Spotify"), systemImage: "arrow.up.forward.app")
            }
        }
    }

    // MARK: Actions

    private func choose(_ track: TrackSummary, at index: Int) {
        switch tab {
        case .queue:
            player.skipAhead(index + 1)
        case .recent:
            player.play(track, context: track.contextURI)
        case .search:
            player.play(track, context: nil)
        }
        dismiss()
    }

    private func load(_ tab: Tab) async {
        guard tab != .search else { return }
        if tab == .recent && !auth.hasScope(Self.recentScope) {
            needsRelogin = true
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            switch tab {
            case .queue: queue = try await player.upcomingTracks()
            case .recent: recent = try await player.recentTracks()
            case .search: break
            }
        } catch SpotifyAPIError.missingScope {
            needsRelogin = true
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runSearch(_ text: String, offset: Int) async {
        guard !text.isEmpty else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page = try await player.searchTracks(text, offset: offset)
            guard text == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            if offset == 0 {
                results = page
            } else {
                let known = Set(results.map(\.uri))
                results += page.filter { !known.contains($0.uri) }
            }
            canLoadMore = page.count >= 10 && results.count < 100
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// `spotify:track:abc` → `https://open.spotify.com/track/abc` (opens the Spotify app).
    private static func spotifyURL(_ uri: String) -> URL? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify" else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }
}

private struct TrackRow: View {
    let title: String
    let subtitle: String
    let artwork: URL?
    let duration: Double
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: artwork) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.08))
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(highlighted ? .semibold : .regular))
                    .foregroundStyle(highlighted ? Color.green : Color.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if highlighted {
                Image(systemName: "waveform").foregroundStyle(.green)
            } else if duration > 0 {
                Text(PlaybackBar.format(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
