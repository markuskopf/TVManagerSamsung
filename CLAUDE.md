# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

All commands run from the `TVSenderManager/` subdirectory.

```bash
# Debug build
swift build

# Release build + launch (one step)
./run.sh

# Release build only
swift build -c release

# Run debug binary
.build/debug/TVSenderManager
```

There are no tests. VS Code launch configs in `.vscode/launch.json` use the Swift extension for debug/release runs.

## Architecture

**TVSenderManager** is a macOS 14+ SwiftUI app (single `executableTarget`, no external Swift dependencies, links system `sqlite3`).

### Data flow

```
Channel_list_*/          ← Samsung TV USB export folder
  dvbc   (SQLite)        ← DVB-C cable channels
  ipsrv  (SQLite)        ← IP/streaming channels
  sat    (SQLite)        ← satellite (not yet implemented)
       ↓
  ChannelDB              ← opens the SQLite files, queries SRV/CHNL/SRV_FAV/PROV tables
       ↓
  ChannelStore           ← @MainActor ObservableObject; holds all UI state
       ↓
  SwiftUI views          ← read from store via @EnvironmentObject
```

### Edit model (important)

`ChannelStore` maintains two parallel dictionaries:
- `originals: [Int64: Channel]` — snapshot loaded from disk
- `edits: [Int64: ChannelEdits]` — only the fields that differ from originals

`ChannelEdits` stores optional overrides (`name?`, `major?`, `hidden?`, `favorite?`, `deleted`). A nil field means "unchanged". On save, only non-nil fields generate SQL `UPDATE` statements. This diff approach means you never need to flush the whole channel list.

Before writing, `save()` copies the entire `Channel_list_*` folder to a timestamped sibling directory as backup.

### Samsung encoding quirk

Samsung stores channel names as UTF-16 with **byte-swapped code units** — UTF-16 BE bytes read as UTF-16 LE. `Encoding.swift:samsungSwapped()` is a symmetric transform (same call encodes and decodes). It must be applied on every read from and write to `srvName`/`provName`.

### Key files

| File | Responsibility |
|------|----------------|
| `Models.swift` | `Channel`, `Source`, `Quality`, `ChannelEdits` value types |
| `ChannelDB.swift` | SQLite I/O — load and save channels per source |
| `ChannelStore.swift` | All business logic; I/O runs via `Task.detached`, results marshalled back to `@MainActor` |
| `SQLiteHelpers.swift` | Thin C SQLite wrapper (`Database`, `Row`, `SQLBind`) |
| `Encoding.swift` | `samsungSwapped()` byte-swap extension |
| `ContentView.swift` | All SwiftUI views in one file |
| `App.swift` | App entry point, menu commands |

### UI layout

`WelcomeView` (drag-and-drop zone + folder picker) is shown until a folder is loaded, then replaced by a `NavigationSplitView`:
- **Sidebar** — source picker (cable / IP) + quick-stat counts
- **Main** — search bar + `Table` with multi-select, sortable columns, context menu
- **Inspector** — single-channel editor or bulk-action panel depending on selection count
