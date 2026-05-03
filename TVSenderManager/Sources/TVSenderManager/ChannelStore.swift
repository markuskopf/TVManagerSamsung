import Foundation
import AppKit
import Combine

@MainActor
final class ChannelStore: ObservableObject {
    @Published var folderURL: URL?
    @Published var folderName: String = ""
    /// All channels, in display order. Cable first, then IP. The Source column
    /// makes it obvious which is which — there is no per-source view anymore.
    @Published var allChannels: [Channel] = []
    @Published var currentFilter: ChannelFilter = .all
    @Published var searchText: String = ""
    @Published var selection: Set<Int64> = []
    @Published var status: String = ""
    @Published var lastError: String?
    @Published var isLoading: Bool = false

    private var db: ChannelDB?
    private var originals: [Int64: Channel] = [:]
    private var edits: [Int64: ChannelEdits] = [:]

    /// Undo / redo stacks. Each entry is one user-visible action.
    private var undoStack: [UndoAction] = []
    private var redoStack: [UndoAction] = []
    /// While `true`, edit primitives don't push to the undo stack — used so a
    /// single high-level operation (e.g. bulk rename) records as one entry.
    private var coalescing: Bool = false
    private var coalescedActions: [UndoAction] = []

    var hasUnsavedChanges: Bool {
        edits.values.contains { !$0.isEmpty }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Channels matching both the sidebar filter and the search box.
    var filteredChannels: [Channel] {
        let f = currentFilter
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return allChannels.filter { ch in
            guard f.matches(ch) else { return false }
            if q.isEmpty { return true }
            return ch.name.lowercased().contains(q)
                || String(ch.major).contains(q)
                || (ch.providerName?.lowercased().contains(q) ?? false)
        }
    }

    /// Counts shown next to sidebar items.
    func count(for filter: ChannelFilter) -> Int {
        allChannels.lazy.filter(filter.matches).count
    }

    /// Distinct providers for the dynamic provider section in the sidebar.
    var providers: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for ch in allChannels {
            guard let p = ch.providerName, !p.isEmpty else { continue }
            counts[p, default: 0] += 1
        }
        return counts.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value) }
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
        Task {
            do {
                let payload = try await Self.loadInBackground(url)
                self.db = payload.db
                self.folderURL = url
                self.folderName = url.lastPathComponent
                self.allChannels = payload.channels
                self.originals = Dictionary(uniqueKeysWithValues: payload.channels.map { ($0.srvId, $0) })
                self.edits = [:]
                self.undoStack.removeAll()
                self.redoStack.removeAll()
                self.selection = []
                self.currentFilter = .all
                let cable = payload.channels.filter { $0.source == .cable }.count
                let ip    = payload.channels.filter { $0.source == .ip    }.count
                self.status = "\(cable) Kabel-Sender · \(ip) IP-Sender"
                self.isLoading = false
            } catch {
                self.lastError = error.localizedDescription
                self.status = "Fehler beim Öffnen"
                self.isLoading = false
            }
        }
    }

    private struct LoadPayload: Sendable {
        let db: ChannelDB
        let channels: [Channel]
    }

    nonisolated private static func loadInBackground(_ url: URL) async throws -> LoadPayload {
        try await Task.detached(priority: .userInitiated) {
            let db = try ChannelDB(folderURL: url)
            let cable = try db.loadChannels(.cable)
            let ip    = try db.loadChannels(.ip)
            return LoadPayload(db: db, channels: cable + ip)
        }.value
    }

    // MARK: - Edits (each one undoable)

    /// Wrap a series of edits so they undo as a single step.
    func transaction(_ block: () -> Void) {
        coalescing = true
        coalescedActions.removeAll()
        block()
        coalescing = false
        if coalescedActions.count == 1 {
            pushUndo(coalescedActions[0])
        } else if coalescedActions.count > 1 {
            pushUndo(.bulk(coalescedActions))
        }
        coalescedActions.removeAll()
    }

    private func pushUndo(_ action: UndoAction) {
        if coalescing {
            coalescedActions.append(action)
        } else {
            undoStack.append(action)
            redoStack.removeAll()
        }
    }

    /// Apply a snapshot to the in-memory channel and reconcile the edits dict.
    private func apply(_ snapshot: ChannelSnapshot, to srvId: Int64) {
        guard let original = originals[srvId] else { return }
        guard let idx = allChannels.firstIndex(where: { $0.srvId == srvId }) else { return }
        var ch = allChannels[idx]
        ch.name      = snapshot.name
        ch.major     = snapshot.major
        ch.hidden    = snapshot.hidden
        ch.isFavorite = snapshot.favorite
        allChannels[idx] = ch

        // Recompute the edits dict by diffing snapshot vs original.
        var edit = edits[srvId] ?? ChannelEdits()
        edit.siblingSrvIds = original.siblingSrvIds
        edit.name     = (snapshot.name      == original.name)       ? nil : snapshot.name
        edit.major    = (snapshot.major     == original.major)      ? nil : snapshot.major
        edit.hidden   = (snapshot.hidden    == original.hidden)     ? nil : snapshot.hidden
        edit.favorite = (snapshot.favorite  == original.isFavorite) ? nil : snapshot.favorite
        edits[srvId] = edit.isEmpty ? nil : edit
    }

    /// Generic per-row mutation that records an undo action.
    private func mutate(_ srvId: Int64, _ change: (inout ChannelSnapshot) -> Void) {
        guard let idx = allChannels.firstIndex(where: { $0.srvId == srvId }) else { return }
        let before = ChannelSnapshot(allChannels[idx])
        var after = before
        change(&after)
        guard after != before else { return }
        apply(after, to: srvId)
        pushUndo(.edit(srvId: srvId, before: before, after: after))
    }

    func rename(_ srvId: Int64, to newName: String) {
        mutate(srvId) { $0.name = newName }
    }

    func setMajor(_ srvId: Int64, to newMajor: Int) {
        mutate(srvId) { $0.major = newMajor }
    }

    func setHidden(_ srvId: Int64, _ hidden: Bool) {
        mutate(srvId) { $0.hidden = hidden }
    }

    func setFavorite(_ srvId: Int64, _ fav: Bool) {
        mutate(srvId) { $0.favorite = fav }
    }

    /// Toggle hidden across `ids`. Coalesces into one undo step.
    func toggleHidden(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        let allHidden = ids.allSatisfy { id in
            allChannels.first(where: { $0.srvId == id })?.hidden == true
        }
        transaction {
            for id in ids { setHidden(id, !allHidden) }
        }
    }

    func toggleFavorite(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        let allFav = ids.allSatisfy { id in
            allChannels.first(where: { $0.srvId == id })?.isFavorite == true
        }
        transaction {
            for id in ids { setFavorite(id, !allFav) }
        }
    }

    func deleteChannels(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        // Deletion can't be undone in this build — be explicit.
        for id in ids {
            guard let original = originals[id] else { continue }
            var edit = edits[id] ?? ChannelEdits()
            edit.siblingSrvIds = original.siblingSrvIds
            edit.deleted = true
            edits[id] = edit
        }
        allChannels.removeAll { ids.contains($0.srvId) }
        selection.subtract(ids)
        // Clear undo since the channel is gone — re-doing later actions would target a missing row.
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: - Bulk operations

    /// Sort channels alphabetically. If a non-trivial selection exists, only
    /// the selected channels are alphabetised (taking the channel slots they
    /// already occupy). Otherwise every channel is renumbered.
    func sortAlphabetically() {
        let selectionScope: [Channel] = selection.count >= 2
            ? allChannels.filter { selection.contains($0.srvId) }
            : allChannels
        guard selectionScope.count >= 2 else { return }

        let sortedNames = selectionScope.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let slots = selectionScope.map(\.major).sorted()

        transaction {
            for (idx, ch) in sortedNames.enumerated() {
                setMajor(ch.srvId, to: slots[idx])
            }
        }
        sortAllChannelsArray()
    }

    /// Renumber so channels are 1, 2, 3, … with no gaps. If a selection
    /// exists, only renumber within that selection's existing slots.
    func renumberToContiguous() {
        if selection.count >= 2 {
            let sel = allChannels.filter { selection.contains($0.srvId) }.sorted { $0.major < $1.major }
            guard let firstSlot = sel.first?.major else { return }
            transaction {
                for (idx, ch) in sel.enumerated() {
                    setMajor(ch.srvId, to: firstSlot + idx)
                }
            }
        } else {
            // Renumber per source so cable + IP keep their distinct ranges.
            transaction {
                for src in [Source.cable, Source.ip] {
                    let group = allChannels.filter { $0.source == src }.sorted { $0.major < $1.major }
                    guard let firstMajor = group.first?.major else { continue }
                    for (idx, ch) in group.enumerated() {
                        setMajor(ch.srvId, to: firstMajor + idx)
                    }
                }
            }
        }
        sortAllChannelsArray()
    }

    /// Reorder: move all channels in `ids` so they sit just before `targetId`.
    /// Numbers are reassigned to maintain contiguous order within each source.
    func moveChannels(_ ids: Set<Int64>, before targetId: Int64) {
        guard !ids.isEmpty else { return }
        guard let target = allChannels.first(where: { $0.srvId == targetId }) else { return }

        let movingChannels = allChannels.filter { ids.contains($0.srvId) && $0.source == target.source }
        guard !movingChannels.isEmpty else { return }

        var sourceList = allChannels.filter { $0.source == target.source }
        sourceList.sort { $0.major < $1.major }
        sourceList.removeAll { ids.contains($0.srvId) }

        guard let insertIdx = sourceList.firstIndex(where: { $0.srvId == targetId }) else { return }
        sourceList.insert(contentsOf: movingChannels, at: insertIdx)

        // Reassign majors keeping the original contiguous range of that source.
        let originalRange = allChannels
            .filter { $0.source == target.source }
            .map(\.major)
            .sorted()

        transaction {
            for (idx, ch) in sourceList.enumerated() where idx < originalRange.count {
                setMajor(ch.srvId, to: originalRange[idx])
            }
        }
        sortAllChannelsArray()
    }

    private func sortAllChannelsArray() {
        allChannels.sort {
            if $0.source != $1.source {
                return $0.source == .cable
            }
            return $0.major < $1.major
        }
    }

    // MARK: - Undo / Redo

    func undo() {
        guard let action = undoStack.popLast() else { return }
        applyReverse(action, undoing: true)
        redoStack.append(action)
    }

    func redo() {
        guard let action = redoStack.popLast() else { return }
        applyReverse(action, undoing: false)
        undoStack.append(action)
    }

    private func applyReverse(_ action: UndoAction, undoing: Bool) {
        switch action {
        case .edit(let srvId, let before, let after):
            apply(undoing ? before : after, to: srvId)
        case .bulk(let actions):
            for a in (undoing ? actions.reversed() : actions) {
                applyReverse(a, undoing: undoing)
            }
        }
    }

    func discardChanges() {
        guard !originals.isEmpty else { return }
        let restored = originals.values.sorted {
            if $0.source != $1.source {
                return $0.source == .cable
            }
            return $0.major < $1.major
        }
        allChannels = restored
        edits = [:]
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: - Save & Save As (with backup)

    func save() {
        guard hasUnsavedChanges, let folderURL else { return }
        runSave(targetFolder: folderURL, makeBackup: true)
    }

    func saveAsFolderPicker() {
        guard let currentURL = folderURL else { return }
        let panel = NSSavePanel()
        panel.title = "Senderliste speichern unter…"
        panel.message = "Wähle einen Ort für die Kopie der Senderliste."
        panel.nameFieldStringValue = currentURL.lastPathComponent + "_modified"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dest = panel.url {
            // Copy the source folder to dest, then save into dest.
            do {
                try FileManager.default.copyItem(at: currentURL, to: dest)
                self.folderURL = dest
                self.folderName = dest.lastPathComponent
                runSave(targetFolder: dest, makeBackup: false)
            } catch {
                lastError = "Save As fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    private func runSave(targetFolder: URL, makeBackup: Bool) {
        isLoading = true
        status = makeBackup ? "Sichere Backup und schreibe Änderungen…" : "Schreibe Änderungen…"
        let editsCopy = edits
        let originalsCopy = originals
        Task {
            do {
                let result = try await Self.saveInBackground(folder: targetFolder,
                                                             edits: editsCopy,
                                                             originals: originalsCopy,
                                                             makeBackup: makeBackup)
                self.db = result.db
                self.allChannels = result.channels
                self.originals = Dictionary(uniqueKeysWithValues: result.channels.map { ($0.srvId, $0) })
                self.edits = [:]
                self.undoStack.removeAll()
                self.redoStack.removeAll()
                if let backup = result.backupName {
                    self.status = "Gespeichert · Backup: \(backup)"
                } else {
                    self.status = "Gespeichert in \(targetFolder.lastPathComponent)"
                }
                self.isLoading = false
            } catch {
                self.lastError = error.localizedDescription
                self.status = "Speichern fehlgeschlagen"
                self.isLoading = false
            }
        }
    }

    private struct SavePayload: Sendable {
        let db: ChannelDB
        let channels: [Channel]
        let backupName: String?
    }

    nonisolated private static func saveInBackground(
        folder: URL,
        edits: [Int64: ChannelEdits],
        originals: [Int64: Channel],
        makeBackup: Bool
    ) async throws -> SavePayload {
        try await Task.detached(priority: .userInitiated) {
            let backupName: String?
            if makeBackup {
                backupName = try makeBackupCopy(of: folder).lastPathComponent
            } else {
                backupName = nil
            }
            let db = try ChannelDB(folderURL: folder)
            try db.save(edits: edits, originals: originals)
            let cable = try db.loadChannels(.cable)
            let ip    = try db.loadChannels(.ip)
            return SavePayload(db: db, channels: cable + ip, backupName: backupName)
        }.value
    }

    nonisolated private static func makeBackupCopy(of folder: URL) throws -> URL {
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
