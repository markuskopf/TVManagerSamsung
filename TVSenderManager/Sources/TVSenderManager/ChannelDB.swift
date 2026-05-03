import Foundation

/// Bundles the three SQLite files inside a Samsung `Channel_list_…` folder.
/// Marked `@unchecked Sendable` because all access is funnelled through the
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

        return try db.query(sql) { r in
            let rawName = r.text(2)
            let favPos = r.intOrNil(9)
            return Channel(
                srvId:        r.int(0),
                source:       source,
                major:        Int(r.int(1)),
                name:         rawName.samsungSwapped(),
                srvType:      Int(r.int(3)),
                hidden:       r.bool(4),
                scrambled:    r.bool(5),
                locked:       r.bool(6),
                freq:         r.intOrNil(7).map(Int.init),
                providerName: r.textOrNil(8)?.samsungSwapped(),
                isFavorite:   favPos != nil,
                favPos:       favPos.map(Int.init)
            )
        }
    }

    /// Apply a batch of edits in a single transaction.
    /// - parameter edits: keyed by srvId → edits to apply
    /// - parameter originals: original channel snapshots so we can derive favorite changes
    func save(edits: [Int64: ChannelEdits], originals: [Int64: Channel]) throws {
        // Group edits by source via the snapshot's source.
        var byDB: [Source: [(Int64, ChannelEdits, Channel)]] = [:]
        for (srvId, edit) in edits {
            guard let original = originals[srvId] else { continue }
            byDB[original.source, default: []].append((srvId, edit, original))
        }

        for (source, items) in byDB {
            let db: Database?
            switch source {
            case .cable: db = cableDB
            case .ip:    db = ipDB
            }
            guard let db else { continue }

            try db.transaction {
                for (srvId, edit, original) in items {
                    if edit.deleted {
                        try db.run("DELETE FROM SRV_FAV WHERE srvId = ?;", bindings: [.int(srvId)])
                        try db.run("DELETE FROM SRV     WHERE srvId = ?;", bindings: [.int(srvId)])
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
                        binds.append(.int(srvId))
                        let sql = "UPDATE SRV SET \(sets.joined(separator: ", ")) WHERE srvId = ?;"
                        try db.run(sql, bindings: binds)
                    }

                    if let fav = edit.favorite, fav != original.isFavorite {
                        if fav {
                            // Append to favorites at next free position (max+1).
                            let maxPos = try db.query(
                                "SELECT COALESCE(MAX(pos), 0) FROM SRV_FAV WHERE fav = 1;"
                            ) { $0.int(0) }.first ?? 0
                            try db.run(
                                "INSERT INTO SRV_FAV (srvId, fav, pos) VALUES (?, 1, ?);",
                                bindings: [.int(srvId), .int(maxPos + 1)]
                            )
                        } else {
                            try db.run(
                                "DELETE FROM SRV_FAV WHERE srvId = ? AND fav = 1;",
                                bindings: [.int(srvId)]
                            )
                        }
                    }
                }
            }
        }
    }
}
