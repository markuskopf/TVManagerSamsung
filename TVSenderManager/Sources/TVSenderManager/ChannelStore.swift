import Foundation
import AppKit
import Combine

@MainActor
final class ChannelStore: ObservableObject {
    @Published var folderURL: URL?
    @Published var folderName: String = ""
    @Published var channelsBySource: [Source: [Channel]] = [:]
    @Published var selectedSource: Source = .cable
    @Published var searchText: String = ""
    @Published var selection: Set<Int64> = []
    @Published var status: String = ""
    @Published var lastError: String?
    @Published var isLoading: Bool = false

    private var db: ChannelDB?
    private var originals: [Int64: Channel] = [:]
    private var edits: [Int64: ChannelEdits] = [:]

    var hasUnsavedChanges: Bool {
        edits.values.contains { !$0.isEmpty }
    }

    var availableSources: [Source] {
        Source.allCases.filter { (channelsBySource[$0]?.isEmpty == false) }
    }

    var currentChannels: [Channel] {
        channelsBySource[selectedSource] ?? []
    }

    var filteredChannels: [Channel] {
        let list = currentChannels
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list }
        let lower = query.lowercased()
        return list.filter {
            $0.name.lowercased().contains(lower) ||
            String($0.major).contains(lower) ||
            ($0.providerName?.lowercased().contains(lower) ?? false)
        }
    }

    func count(for source: Source) -> Int {
        channelsBySource[source]?.count ?? 0
    }

    // MARK: - Open / Load

    func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "Senderliste auswählen"
        panel.message = "Wähle den Ordner Channel_list_… aus"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Öffnen"
        if panel.runModal() == .OK, let url = panel.url {
            open(folder: url)
        }
    }

    func open(folder url: URL) {
        isLoading = true
        lastError = nil
        status = "Lade Senderliste…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let db = try ChannelDB(folderURL: url)
                let cable = try db.loadChannels(.cable)
                let ip    = try db.loadChannels(.ip)
                await MainActor.run {
                    guard let self else { return }
                    self.db = db
                    self.folderURL = url
                    self.folderName = url.lastPathComponent
                    self.channelsBySource = [.cable: cable, .ip: ip]
                    self.originals = Dictionary(uniqueKeysWithValues: (cable + ip).map { ($0.srvId, $0) })
                    self.edits = [:]
                    self.selection = []
                    if cable.isEmpty && !ip.isEmpty { self.selectedSource = .ip }
                    else { self.selectedSource = .cable }
                    self.status = "\(cable.count) Kabel-Sender · \(ip.count) IP-Sender"
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.status = "Fehler beim Öffnen"
                    self?.isLoading = false
                }
            }
        }
    }

    // MARK: - Edits

    private func applyEdit(_ srvId: Int64, _ mutate: (inout ChannelEdits) -> Void) {
        var edit = edits[srvId] ?? ChannelEdits()
        mutate(&edit)
        edits[srvId] = edit.isEmpty ? nil : edit
        objectWillChange.send()
    }

    private func updateInMemory(_ srvId: Int64, _ mutate: (inout Channel) -> Void) {
        for source in channelsBySource.keys {
            guard var arr = channelsBySource[source] else { continue }
            if let idx = arr.firstIndex(where: { $0.srvId == srvId }) {
                mutate(&arr[idx])
                channelsBySource[source] = arr
                return
            }
        }
    }

    func rename(_ srvId: Int64, to newName: String) {
        guard let original = originals[srvId] else { return }
        updateInMemory(srvId) { $0.name = newName }
        applyEdit(srvId) { e in
            e.name = (newName == original.name) ? nil : newName
        }
    }

    func setMajor(_ srvId: Int64, to newMajor: Int) {
        guard let original = originals[srvId] else { return }
        updateInMemory(srvId) { $0.major = newMajor }
        applyEdit(srvId) { e in
            e.major = (newMajor == original.major) ? nil : newMajor
        }
    }

    func setHidden(_ srvId: Int64, _ hidden: Bool) {
        guard let original = originals[srvId] else { return }
        updateInMemory(srvId) { $0.hidden = hidden }
        applyEdit(srvId) { e in
            e.hidden = (hidden == original.hidden) ? nil : hidden
        }
    }

    func toggleHidden(_ ids: Set<Int64>) {
        let allHidden = ids.allSatisfy { id in
            currentChannels.first(where: { $0.srvId == id })?.hidden == true
        }
        for id in ids { setHidden(id, !allHidden) }
    }

    func setFavorite(_ srvId: Int64, _ fav: Bool) {
        guard let original = originals[srvId] else { return }
        updateInMemory(srvId) { $0.isFavorite = fav }
        applyEdit(srvId) { e in
            e.favorite = (fav == original.isFavorite) ? nil : fav
        }
    }

    func toggleFavorite(_ ids: Set<Int64>) {
        let allFav = ids.allSatisfy { id in
            currentChannels.first(where: { $0.srvId == id })?.isFavorite == true
        }
        for id in ids { setFavorite(id, !allFav) }
    }

    func deleteChannels(_ ids: Set<Int64>) {
        for id in ids {
            applyEdit(id) { $0.deleted = true }
            for source in channelsBySource.keys {
                channelsBySource[source]?.removeAll { $0.srvId == id }
            }
        }
        selection.subtract(ids)
    }

    /// Move the selected channels to right before the row at `targetMajor`.
    /// All other channels are renumbered to keep `major` contiguous.
    func renumberToContiguous() {
        guard var arr = channelsBySource[selectedSource] else { return }
        arr.sort { $0.major < $1.major }
        for (idx, ch) in arr.enumerated() {
            let newMajor = idx + 1
            if ch.major != newMajor {
                applyEdit(ch.srvId) { e in
                    if let original = self.originals[ch.srvId] {
                        e.major = (newMajor == original.major) ? nil : newMajor
                    }
                }
                arr[idx].major = newMajor
            }
        }
        channelsBySource[selectedSource] = arr
    }

    func sortAlphabetically() {
        guard var arr = channelsBySource[selectedSource] else { return }
        arr.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for (idx, ch) in arr.enumerated() {
            let newMajor = idx + 1
            if ch.major != newMajor {
                setMajor(ch.srvId, to: newMajor)
            }
        }
        // setMajor already updated channelsBySource, but order needs persisting:
        channelsBySource[selectedSource]?.sort { $0.major < $1.major }
    }

    func moveSelection(_ ids: Set<Int64>, before targetSrvId: Int64) {
        guard var arr = channelsBySource[selectedSource] else { return }
        arr.sort { $0.major < $1.major }
        let moving = arr.filter { ids.contains($0.srvId) }
        guard !moving.isEmpty else { return }
        arr.removeAll { ids.contains($0.srvId) }
        guard let targetIdx = arr.firstIndex(where: { $0.srvId == targetSrvId }) else {
            channelsBySource[selectedSource] = arr + moving
            renumberToContiguous()
            return
        }
        arr.insert(contentsOf: moving, at: targetIdx)
        channelsBySource[selectedSource] = arr
        renumberToContiguous()
    }

    func discardChanges() {
        // Restore in-memory state from originals and clear edits.
        guard !originals.isEmpty else { return }
        let cable = originals.values.filter { $0.source == .cable }.sorted { $0.major < $1.major }
        let ip    = originals.values.filter { $0.source == .ip    }.sorted { $0.major < $1.major }
        channelsBySource = [.cable: cable, .ip: ip]
        edits = [:]
        objectWillChange.send()
    }

    // MARK: - Save (with backup)

    func save() {
        guard hasUnsavedChanges, let folderURL else { return }
        isLoading = true
        status = "Sichere Backup und schreibe Änderungen…"
        let editsCopy = edits
        let originalsCopy = originals
        let folder = folderURL
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let backupURL = try Self.makeBackup(of: folder)
                let db = try ChannelDB(folderURL: folder)
                try db.save(edits: editsCopy, originals: originalsCopy)

                // Reload to refresh originals.
                let cable = try db.loadChannels(.cable)
                let ip    = try db.loadChannels(.ip)

                await MainActor.run {
                    guard let self else { return }
                    self.db = db
                    self.channelsBySource = [.cable: cable, .ip: ip]
                    self.originals = Dictionary(uniqueKeysWithValues: (cable + ip).map { ($0.srvId, $0) })
                    self.edits = [:]
                    self.status = "Gespeichert · Backup: \(backupURL.lastPathComponent)"
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.status = "Speichern fehlgeschlagen"
                    self?.isLoading = false
                }
            }
        }
    }

    nonisolated private static func makeBackup(of folder: URL) throws -> URL {
        let parent = folder.deletingLastPathComponent()
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = parent.appendingPathComponent("\(folder.lastPathComponent).backup-\(ts)")
        try FileManager.default.copyItem(at: folder, to: dest)
        return dest
    }

    // MARK: - Reveal in Finder

    func revealInFinder() {
        guard let folderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }
}
