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
                        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                } detail: {
                    HSplitView {
                        ChannelTableView()
                            .frame(minWidth: 520)
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
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
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
        List(selection: Binding(
            get: { store.selectedSource },
            set: { if let v = $0 { store.selectedSource = v } }
        )) {
            Section("Quellen") {
                ForEach(Source.allCases) { src in
                    let count = store.count(for: src)
                    if count > 0 {
                        Label {
                            HStack {
                                Text(src.label)
                                Spacer()
                                Text("\(count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: src.systemImage)
                        }
                        .tag(src)
                    }
                }
            }

            Section("Schnellansicht") {
                let chans = store.currentChannels
                Label("HD-Sender · \(chans.filter { $0.quality == .hd || $0.quality == .uhd }.count)",
                      systemImage: "sparkles.tv")
                Label("Verschlüsselt · \(chans.filter(\.scrambled).count)",
                      systemImage: "lock")
                Label("Ausgeblendet · \(chans.filter(\.hidden).count)",
                      systemImage: "eye.slash")
                Label("Favoriten · \(chans.filter(\.isFavorite).count)",
                      systemImage: "star.fill")
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Table

struct ChannelTableView: View {
    @EnvironmentObject var store: ChannelStore
    @State private var sortOrder: [KeyPathComparator<Channel>] = [
        .init(\.major, order: .forward)
    ]

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
                    Text("\(ch.major)")
                        .monospacedDigit()
                        .foregroundStyle(ch.hidden ? .secondary : .primary)
                }
                .width(min: 50, ideal: 60, max: 80)

                TableColumn("Name", value: \.name) { ch in
                    HStack(spacing: 8) {
                        if ch.isFavorite {
                            Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                        }
                        Text(ch.name)
                            .strikethrough(ch.hidden)
                            .foregroundStyle(ch.hidden ? .secondary : .primary)
                    }
                }
                .width(min: 200, ideal: 280)

                TableColumn("Typ") { ch in
                    Text(ch.typeBadge)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ch.typeColor.opacity(0.15))
                        .foregroundStyle(ch.typeColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .width(min: 60, ideal: 70, max: 90)

                TableColumn("Anbieter") { ch in
                    Text(ch.providerName ?? "—")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 160)

                TableColumn("") { ch in
                    HStack(spacing: 6) {
                        if ch.scrambled {
                            Image(systemName: "lock").foregroundStyle(.secondary)
                                .help("Verschlüsselt")
                        }
                        if ch.hidden {
                            Image(systemName: "eye.slash").foregroundStyle(.secondary)
                                .help("Ausgeblendet")
                        }
                        if ch.locked {
                            Image(systemName: "key.fill").foregroundStyle(.secondary)
                                .help("Kindersicherung")
                        }
                    }
                    .font(.caption)
                }
                .width(min: 60, ideal: 80, max: 100)
            } rows: {
                ForEach(sortedChannels) { ch in
                    TableRow(ch)
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
            .keyboardShortcut("h", modifiers: .command)
        Divider()
        Button("Alphabetisch sortieren (alle)") { store.sortAlphabetically() }
        Button("Nummern lückenlos neu vergeben") { store.renumberToContiguous() }
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
        return store.currentChannels.filter { ids.contains($0.srvId) }
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
            Text("\(store.filteredChannels.count) von \(store.currentChannels.count) angezeigt")
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
            .help("Auswahl ausblenden (⌘H)")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Alphabetisch sortieren (alle)") { store.sortAlphabetically() }
                Button("Nummern lückenlos neu vergeben") { store.renumberToContiguous() }
                Divider()
                Button("Im Finder anzeigen") { store.revealInFinder() }
            } label: {
                Label("Mehr", systemImage: "ellipsis.circle")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                store.discardChanges()
            } label: {
                Label("Verwerfen", systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.hasUnsavedChanges)
            .help("Alle Änderungen verwerfen")
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
    }
}
