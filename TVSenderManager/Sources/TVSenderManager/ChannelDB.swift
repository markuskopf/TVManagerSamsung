import Foundation

/// Bundles the three SQLite files inside a Samsung `Channel_list_…` folder.
/// Marked `@unchecked Sendable` because access is funnelled through the
/// owning `ChannelStore`, which serialises calls on a single Task at a time.
final class ChannelDB: @unchecked Sendable {
    let folderURL: URL
    private let cableDB: Database?
    private let ipDB:    Database?

    init(folderURL: URL) throws {
        self.folderURL = folderURL
        let cablePath = folderURL.appendingPathComponent("dvbc").path
        let ipPath    = folderURL.appendingPathComponent("ipsrv").path
        cableDB = FileManager.default.fileExists(atPath: cablePath)
            ? try Database(path: cablePath) : nil
        ipDB    = FileManager.default.fileExists(atPath: ipPath)
            ? try Database(path: ipPath)    : nil
    }

    /// Load every service from a source. Empty array if the file isn't present.
    /// IP rows are deduplicated by (major, srvName) — the underlying database
    /// stores each logical channel up to four times (one per IP carrier) and
    /// users perceive that as garbage duplicates.
    func loadChannels(_ source: Source) throws -> [Channel] {
        let db: Database?
        switch source {
        case .cable: db = cableDB
        case .ip:    db = ipDB
        }
        guard let db else { return [] }

        let sql: String
        switch source {
        case .cable:
            sql = """
                SELECT s.srvId, s.major, s.srvName, s.srvType,
                       s.hidden, s.scrambled, s.lockMode,
                       c.freq, p.provName,
                       (SELECT pos FROM SRV_FAV WHERE srvId = s.srvId AND fav = 1 LIMIT 1)
                FROM SRV s
                LEFT JOIN CHNL c ON c.chId = s.chId
                LEFT JOIN SRV_DVB d ON d.srvId = s.srvId
                LEFT JOIN PROV p ON p.provId = d.provId
                ORDER BY s.major;
                """
        case .ip:
            sql = """
                SELECT s.srvId, s.major, s.srvName, s.srvType,
                       s.hidden, s.scrambled, s.lockMode,
                       c.freq, NULL,
                       (SELECT pos FROM SRV_FAV WHERE srvId = s.srvId AND fav = 1 LIMIT 1)
                FROM SRV s
                LEFT JOIN CHNL c ON c.chId = s.chId
                ORDER BY s.major;
                """
        }

        struct RawRow {
            let srvId: Int64
            let major: Int
            let rawName: String
            let srvType: Int
            let hidden: Bool
            let scrambled: Bool
            let locked: Bool
            let freq: Int?
            let provider: String?
            let favPos: Int64?
        }

        let rawRows: [RawRow] = try db.query(sql) { r in
            RawRow(
                srvId:     r.int(0),
                major:     Int(r.int(1)),
                rawName:   r.text(2),
                srvType:   Int(r.int(3)),
                hidden:    r.bool(4),
                scrambled: r.bool(5),
                locked:    r.bool(6),
                freq:      r.intOrNil(7).map(Int.init),
                provider:  r.textOrNil(8),
                favPos:    r.intOrNil(9)
            )
        }

        switch source {
        case .cable:
            return rawRows.map { row in
                Channel(
                    srvId:         row.srvId,
                    siblingSrvIds: [row.srvId],
                    source:        .cable,
                    major:         row.major,
                    name:          row.rawName.samsungSwapped(),
                    srvType:       row.srvType,
                    hidden:        row.hidden,
                    scrambled:     row.scrambled,
                    locked:        row.locked,
                    freq:          row.freq,
                    providerName:  row.provider?.samsungSwapped(),
                    isFavorite:    row.favPos != nil,
                    favPos:        row.favPos.map(Int.init)
                )
            }
        case .ip:
            // Group by (major, decoded name) and collapse to one Channel.
            var groups: [String: [RawRow]] = [:]
            var order: [String] = []
            for row in rawRows {
                let key = "\(row.major)|\(row.rawName)"
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(row)
            }
            return order.compactMap { key in
                guard let siblings = groups[key], let primary = siblings.first else { return nil }
                let anyFavPos  = siblings.compactMap(\.favPos).first
                let anyHidden  = siblings.contains { $0.hidden }
                let anyScramb  = siblings.contains { $0.scrambled }
                let anyLocked  = siblings.contains { $0.locked }
                return Channel(
                    srvId:         primary.srvId,
                    siblingSrvIds: siblings.map(\.srvId),
                    source:        .ip,
                    major:         primary.major,
                    name:          primary.rawName.samsungSwapped(),
                    srvType:       primary.srvType,
                    hidden:        anyHidden,
                    scrambled:     anyScramb,
                    locked:        anyLocked,
                    freq:          primary.freq,
                    providerName:  primary.provider?.samsungSwapped(),
                    isFavorite:    anyFavPos != nil,
                    favPos:        anyFavPos.map(Int.init)
                )
            }
        }
    }

    /// Apply a batch of edits in a single transaction. Each edit knows its
    /// sibling srvIds so deduped IP channels propagate to every underlying row.
    func save(edits: [Int64: ChannelEdits], originals: [Int64: Channel]) throws {
        var byDB: [Source: [(Channel, ChannelEdits)]] = [:]
        for (srvId, edit) in edits {
            guard let original = originals[srvId] else { continue }
            byDB[original.source, default: []].append((original, edit))
        }

        for (source, items) in byDB {
            let db: Database?
            switch source {
            case .cable: db = cableDB
            case .ip:    db = ipDB
            }
            guard let db else { continue }

            try db.transaction {
                for (original, edit) in items {
                    let targets = edit.siblingSrvIds.isEmpty
                        ? original.siblingSrvIds
                        : edit.siblingSrvIds

                    if edit.deleted {
                        for sid in targets {
                            try db.run("DELETE FROM SRV_FAV WHERE srvId = ?;", bindings: [.int(sid)])
                            try db.run("DELETE FROM SRV     WHERE srvId = ?;", bindings: [.int(sid)])
                        }
                        continue
                    }

                    var sets: [String] = []
                    var binds: [SQLBind] = []
                    if let n = edit.name {
                        sets.append("srvName = ?")
                        binds.append(.text(n.samsungSwapped()))
                    }
                    if let m = edit.major {
                        sets.append("major = ?")
                        binds.append(.int(Int64(m)))
                    }
                    if let h = edit.hidden {
                        sets.append("hidden = ?")
                        binds.append(.bool(h))
                    }

                    if !sets.isEmpty {
                        sets.append("modifiedByUser = 1")
                        let setClause = sets.joined(separator: ", ")
                        for sid in targets {
                            let sql = "UPDATE SRV SET \(setClause) WHERE srvId = ?;"
                            try db.run(sql, bindings: binds + [.int(sid)])
                        }
                    }

                    if let fav = edit.favorite, fav != original.isFavorite {
                        if fav {
                            let maxPos = try db.query(
                                "SELECT COALESCE(MAX(pos), 0) FROM SRV_FAV WHERE fav = 1;"
                            ) { $0.int(0) }.first ?? 0
                            // Add fav for every sibling so the TV shows it as fav
                            // regardless of which carrier is currently active.
                            for (offset, sid) in targets.enumerated() {
                                try db.run(
                                    "INSERT INTO SRV_FAV (srvId, fav, pos) VALUES (?, 1, ?);",
                                    bindings: [.int(sid), .int(maxPos + 1 + Int64(offset))]
                                )
                            }
                        } else {
                            for sid in targets {
                                try db.run(
                                    "DELETE FROM SRV_FAV WHERE srvId = ? AND fav = 1;",
                                    bindings: [.int(sid)]
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
