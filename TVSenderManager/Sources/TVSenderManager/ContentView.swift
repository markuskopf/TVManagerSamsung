import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: ChannelStore

    var body: some View {
        Group {
            if store.folderURL == nil {
                WelcomeView()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
                } detail: {
                    HSplitView {
                        ChannelTableView()
                            .frame(minWidth: 540)
                        InspectorView()
                            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                    }
                }
                .navigationTitle(store.folderName)
                .navigationSubtitle(subtitle)
                .toolbar { ToolbarItems() }
            }
        }
        .alert("Fehler",
               isPresented: Binding(
                    get: { store.lastError != nil },
                    set: { if !$0 { store.lastError = nil } }
               ),
               actions: { Button("OK") { store.lastError = nil } },
               message: { Text(store.lastError ?? "") })
    }

    private var subtitle: String {
        store.hasUnsavedChanges ? "• Ungespeicherte Änderungen" : store.status
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject var store: ChannelStore
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "tv.inset.filled")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Samsung TV Senderverwaltung")
                .font(.largeTitle.bold())
            Text("Senderlisten bearbeiten, sortieren, umbenennen, ausblenden — und sicher mit automatischem Backup speichern.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            DropZone(isTargeted: $isDropTargeted) { url in
                store.open(folder: url)
            }
            .frame(width: 520, height: 180)

            HStack(spacing: 12) {
                Button {
                    store.openFolderPicker()
                } label: {
                    Label("Ordner auswählen…", systemImage: "folder")
                        .frame(minWidth: 180)
                }
                .keyboardShortcut("o", modifiers: .command)
                .controlSize(.large)

                Text("oder Channel_list-Ordner hier hinein ziehen")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct DropZone: View {
    @Binding var isTargeted: Bool
    let onDrop: (URL) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04))
                )
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 36))
                Text("Channel_list-Ordner hier ablegen")
                    .font(.headline)
                Text("dvbc · ipsrv · sat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(isTargeted ? .primary : .secondary)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    DispatchQueue.main.async { onDrop(url) }
                }
            }
            return true
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var store: ChannelStore

    var body: some View {
        List(selection: $store.currentFilter) {
            Section {
                FilterRow(filter: .all)
            }

            Section("Quellen") {
                FilterRow(filter: .source(.cable))
                FilterRow(filter: .source(.ip))
            }

            Section("Schnellansichten") {
                FilterRow(filter: .quality(.uhd))
                FilterRow(filter: .quality(.hd))
                FilterRow(filter: .tvOnly)
                FilterRow(filter: .radioOnly)
                FilterRow(filter: .scrambled)
                FilterRow(filter: .hidden)
                FilterRow(filter: .favorites)
            }

            let providers = store.providers
            if !providers.isEmpty {
                Section("Anbieter") {
                    ForEach(providers, id: \.name) { p in
                        FilterRow(filter: .provider(p.name), overrideCount: p.count)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct FilterRow: View {
    @EnvironmentObject var store: ChannelStore
    let filter: ChannelFilter
    var overrideCount: Int? = nil

    var body: some View {
        let count = overrideCount ?? store.count(for: filter)
        Label {
            HStack {
                Text(filter.label).lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: filter.systemImage)
        }
        .tag(filter)
    }
}

// MARK: - Table

struct ChannelTableView: View {
    @EnvironmentObject var store: ChannelStore
    @State private var sortOrder: [KeyPathComparator<Channel>] = [
        .init(\.major, order: .forward)
    ]
    @State private var editingMajorId: Int64? = nil

    var sortedChannels: [Channel] {
        store.filteredChannels.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchBar()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            Divider()

            Table(of: Channel.self, selection: $store.selection, sortOrder: $sortOrder) {
                TableColumn("#", value: \.major) { ch in
                    MajorCell(channel: ch, isEditing: editingMajorId == ch.srvId) {
                        editingMajorId = nil
                    }
                    .onTapGesture(count: 2) {
                        editingMajorId = ch.srvId
                    }
                }
                .width(min: 60, ideal: 70, max: 90)

                TableColumn("Name", value: \.name) { ch in
                    HStack(spacing: 8) {
                        if ch.isFavorite {
                            Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                        }
                        Text(ch.name)
                            .strikethrough(ch.hidden)
                            .foregroundStyle(ch.hidden ? .secondary : .primary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        store.toggleHidden([ch.srvId])
                    }
                }
                .width(min: 200, ideal: 280)

                TableColumn("Quelle", value: \.source.shortLabel) { ch in
                    HStack(spacing: 4) {
                        Image(systemName: ch.source.systemImage)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(ch.source.shortLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 64, ideal: 72, max: 96)

                TableColumn("Typ", value: \.typeBadge) { ch in
                    Text(ch.typeBadge)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ch.typeColor.opacity(0.15))
                        .foregroundStyle(ch.typeColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .width(min: 60, ideal: 70, max: 90)

                TableColumn("Anbieter", value: \.providerSortKey) { ch in
                    Text(ch.providerName ?? "—")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 160)

                TableColumn("Sichtbar", value: \.visibilitySortKey) { ch in
                    Button {
                        store.toggleHidden([ch.srvId])
                    } label: {
                        Image(systemName: ch.hidden ? "eye.slash" : "eye")
                            .foregroundStyle(ch.hidden ? Color.secondary : Color.blue)
                    }
                    .buttonStyle(.plain)
                    .help(ch.hidden ? "Sichtbar machen" : "Ausblenden")
                }
                .width(min: 64, ideal: 70, max: 80)

                TableColumn("") { ch in
                    HStack(spacing: 6) {
                        if ch.scrambled {
                            Image(systemName: "lock").foregroundStyle(.secondary)
                                .help("Verschlüsselt")
                        }
                        if ch.locked {
                            Image(systemName: "key.fill").foregroundStyle(.secondary)
                                .help("Kindersicherung")
                        }
                    }
                    .font(.caption)
                }
                .width(min: 32, ideal: 40, max: 60)
            } rows: {
                ForEach(sortedChannels) { ch in
                    TableRow(ch)
                        .draggable(ChannelDragPayload(srvId: ch.srvId))
                        .dropDestination(for: ChannelDragPayload.self) { items in
                            let dropped = Set(items.map(\.srvId))
                            // If the user dragged a selected row, carry the
                            // whole selection along; otherwise just move what
                            // was actually dragged.
                            let toMove = dropped.intersection(store.selection).isEmpty
                                ? dropped
                                : store.selection
                            store.moveChannels(toMove, before: ch.srvId)
                        }
                        .contextMenu {
                            ChannelContextMenu(targetIDs: ids(forContextOn: ch))
                        }
                }
            }

            StatusBar()
        }
    }

    private func ids(forContextOn ch: Channel) -> Set<Int64> {
        if store.selection.contains(ch.srvId) { return store.selection }
        return [ch.srvId]
    }
}

private extension Channel {
    var providerSortKey: String { providerName ?? "" }
    var visibilitySortKey: Int   { hidden ? 1 : 0 }
}

extension Source {
    // Used to sort the source column.
    var sortKey: String { shortLabel }
}

// MARK: - Drag payload (Transferable)

struct ChannelDragPayload: Codable, Transferable, Sendable, Hashable {
    let srvId: Int64
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

// MARK: - Inline major editor

struct MajorCell: View {
    @EnvironmentObject var store: ChannelStore
    let channel: Channel
    let isEditing: Bool
    let onCommit: () -> Void
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .onAppear {
                    draft = "\(channel.major)"
                    focused = true
                }
                .onSubmit { commit() }
                .onChange(of: focused) { _, new in
                    if !new { commit() }
                }
                .monospacedDigit()
        } else {
            Text("\(channel.major)")
                .monospacedDigit()
                .foregroundStyle(channel.hidden ? .secondary : .primary)
        }
    }

    private func commit() {
        if let n = Int(draft.trimmingCharacters(in: .whitespaces)), n >= 0 {
            if n != channel.major { store.setMajor(channel.srvId, to: n) }
        }
        onCommit()
    }
}

// MARK: - Search

struct SearchBar: View {
    @EnvironmentObject var store: ChannelStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Sender suchen (Name, Nummer, Anbieter)", text: $store.searchText)
                .textFieldStyle(.plain)
                .focused($focused)
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Context Menu

struct ChannelContextMenu: View {
    @EnvironmentObject var store: ChannelStore
    let targetIDs: Set<Int64>

    var body: some View {
        Button("Favorit umschalten") { store.toggleFavorite(targetIDs) }
            .keyboardShortcut("d", modifiers: .command)
        Button("Ausblenden umschalten") { store.toggleHidden(targetIDs) }
            .keyboardShortcut("e", modifiers: .command)
        if targetIDs.count >= 2 {
            Divider()
            Button("Auswahl alphabetisch sortieren") {
                store.sortAlphabetically()
            }
            Button("Auswahl Nummern lückenlos vergeben") {
                store.renumberToContiguous()
            }
        }
        Divider()
        Button("Aus Liste entfernen", role: .destructive) {
            store.deleteChannels(targetIDs)
        }
        .keyboardShortcut(.delete, modifiers: [])
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @EnvironmentObject var store: ChannelStore

    private var selected: [Channel] {
        let ids = store.selection
        return store.filteredChannels.filter { ids.contains($0.srvId) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if selected.isEmpty {
                    EmptySelectionPlaceholder()
                } else if selected.count == 1 {
                    SingleChannelEditor(channel: selected[0])
                } else {
                    MultiSelectionEditor(channels: selected)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct EmptySelectionPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Sender auswählen, um Details zu bearbeiten.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

struct SingleChannelEditor: View {
    @EnvironmentObject var store: ChannelStore
    let channel: Channel
    @State private var nameDraft: String = ""
    @State private var majorDraft: String = ""
    @FocusState private var nameFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(channel.typeBadge)
                    .font(.caption2.monospaced().bold())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(channel.typeColor.opacity(0.15))
                    .foregroundStyle(channel.typeColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(channel.source.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocus)
                    .onSubmit { commitName() }
                    .onChange(of: nameFocus) { _, focused in
                        if !focused { commitName() }
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Programmplatz").font(.caption).foregroundStyle(.secondary)
                TextField("Nummer", text: $majorDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitMajor() }
            }

            Toggle(isOn: Binding(
                get: { channel.isFavorite },
                set: { store.setFavorite(channel.srvId, $0) }
            )) {
                Label("Favorit", systemImage: "star.fill")
            }

            Toggle(isOn: Binding(
                get: { channel.hidden },
                set: { store.setHidden(channel.srvId, $0) }
            )) {
                Label("Aus Senderliste ausblenden", systemImage: "eye.slash")
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Technische Details").font(.caption).foregroundStyle(.secondary)
                infoRow("Service-ID", "\(channel.srvId)")
                if channel.siblingSrvIds.count > 1 {
                    infoRow("IP-Carrier", "\(channel.siblingSrvIds.count)")
                }
                infoRow("srvType",   "\(channel.srvType)")
                if let f = channel.freq { infoRow("Frequenz", "\(f) kHz") }
                if let p = channel.providerName { infoRow("Anbieter", p) }
                if channel.scrambled  { infoRow("Verschlüsselt", "ja") }
            }
            .font(.caption)
        }
        .onAppear(perform: refreshDrafts)
        .onChange(of: channel.srvId) { _, _ in refreshDrafts() }
        .onChange(of: channel.major) { _, new in majorDraft = "\(new)" }
        .onChange(of: channel.name)  { _, new in nameDraft  = new }
    }

    private func refreshDrafts() {
        nameDraft = channel.name
        majorDraft = "\(channel.major)"
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        guard trimmed != channel.name else { return }
        store.rename(channel.srvId, to: trimmed)
    }

    private func commitMajor() {
        guard let n = Int(majorDraft.trimmingCharacters(in: .whitespaces)), n >= 0 else {
            majorDraft = "\(channel.major)"
            return
        }
        store.setMajor(channel.srvId, to: n)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.primary)
        }
    }
}

struct MultiSelectionEditor: View {
    @EnvironmentObject var store: ChannelStore
    let channels: [Channel]

    private var ids: Set<Int64> { Set(channels.map(\.srvId)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(channels.count) Sender ausgewählt")
                .font(.headline)
            Text("Mehrfachaktionen wirken auf die gesamte Auswahl.")
                .font(.caption).foregroundStyle(.secondary)

            Button { store.toggleFavorite(ids) } label: {
                Label("Favoriten umschalten", systemImage: "star")
                    .frame(maxWidth: .infinity)
            }
            Button { store.toggleHidden(ids) } label: {
                Label("Ausblenden umschalten", systemImage: "eye.slash")
                    .frame(maxWidth: .infinity)
            }
            Button { store.sortAlphabetically() } label: {
                Label("Auswahl alphabetisch sortieren", systemImage: "textformat")
                    .frame(maxWidth: .infinity)
            }
            Button { store.renumberToContiguous() } label: {
                Label("Nummern lückenlos vergeben", systemImage: "number")
                    .frame(maxWidth: .infinity)
            }
            Button(role: .destructive) {
                store.deleteChannels(ids)
            } label: {
                Label("Aus Liste entfernen", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Status

struct StatusBar: View {
    @EnvironmentObject var store: ChannelStore

    var body: some View {
        HStack(spacing: 12) {
            Text(store.status).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(store.filteredChannels.count) von \(store.allChannels.count) angezeigt")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if store.hasUnsavedChanges {
                Text("●")
                    .foregroundStyle(.orange)
                    .help("Ungespeicherte Änderungen")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }
}

// MARK: - Toolbar

struct ToolbarItems: ToolbarContent {
    @EnvironmentObject var store: ChannelStore

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                store.openFolderPicker()
            } label: {
                Label("Öffnen", systemImage: "folder")
            }
            .help("Andere Senderliste öffnen (⌘O)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { store.undo() } label: { Label("Rückgängig", systemImage: "arrow.uturn.backward") }
                .disabled(!store.canUndo)
                .help("Rückgängig (⌘Z)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { store.redo() } label: { Label("Wiederherstellen", systemImage: "arrow.uturn.forward") }
                .disabled(!store.canRedo)
                .help("Wiederherstellen (⇧⌘Z)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                store.toggleFavorite(store.selection)
            } label: {
                Label("Favorit", systemImage: "star")
            }
            .disabled(store.selection.isEmpty)
            .help("Auswahl als Favorit umschalten (⌘D)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                store.toggleHidden(store.selection)
            } label: {
                Label("Ausblenden", systemImage: "eye.slash")
            }
            .disabled(store.selection.isEmpty)
            .help("Auswahl ausblenden (⌘E)")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Im Finder anzeigen") { store.revealInFinder() }
                Divider()
                Button("Änderungen verwerfen") { store.discardChanges() }
                    .disabled(!store.hasUnsavedChanges)
            } label: {
                Label("Mehr", systemImage: "ellipsis.circle")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                store.save()
            } label: {
                Label("Speichern", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!store.hasUnsavedChanges || store.isLoading)
            .help("Mit automatischem Backup speichern (⌘S)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                store.saveAsFolderPicker()
            } label: {
                Label("Speichern unter…", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(store.folderURL == nil || store.isLoading)
            .help("Senderliste an einen anderen Ort speichern (⇧⌘S)")
        }
    }
}
