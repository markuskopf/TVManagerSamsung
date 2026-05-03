import Foundation
import SwiftUI

enum Source: String, CaseIterable, Identifiable, Hashable, Sendable {
    case cable
    case ip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cable: return "Kabel (DVB-C)"
        case .ip:    return "IP / Streaming"
        }
    }

    var shortLabel: String {
        switch self {
        case .cable: return "Kabel"
        case .ip:    return "IP"
        }
    }

    var dbFile: String {
        switch self {
        case .cable: return "dvbc"
        case .ip:    return "ipsrv"
        }
    }

    var systemImage: String {
        switch self {
        case .cable: return "cable.connector"
        case .ip:    return "globe.europe.africa"
        }
    }
}

enum Quality: String, Hashable, Sendable {
    case uhd, hd, sdH264, sd, radio, ip, other
}

/// One service ("channel") as shown in the UI.
///
/// On the IP source each logical channel is stored as multiple SRV rows
/// (one per "carrier"). We collapse those into a single `Channel` and remember
/// every underlying srvId in `siblingSrvIds`; edits are propagated to all
/// siblings on save so the change takes effect no matter which carrier the
/// TV is currently using.
struct Channel: Identifiable, Hashable, Sendable {
    let srvId: Int64                 // primary id, used in selection
    let siblingSrvIds: [Int64]       // includes srvId; for IP this is 1…4 entries
    let source: Source
    var major: Int
    var name: String
    let srvType: Int
    var hidden: Bool
    var scrambled: Bool
    var locked: Bool
    let freq: Int?
    let providerName: String?
    var isFavorite: Bool
    var favPos: Int?

    var id: Int64 { srvId }

    /// Channel quality / kind. Tries name parsing first (handles IP streams
    /// where srvType is always -1) then falls back to DVB service-type codes.
    var quality: Quality {
        let tokens = name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.uppercased() }
        if tokens.contains("UHD") || tokens.contains("4K") { return .uhd }
        if tokens.contains("HD") { return .hd }

        switch srvType {
        case 2:               return .radio
        case 31:              return .uhd
        case 25, 17, 19:      return .hd
        case 22:              return .sdH264
        case 1, 10, 12:       return .sd
        case -1 where source == .ip: return .ip
        default:              return .other
        }
    }

    var isRadio: Bool { quality == .radio }
    var isTV: Bool    { !isRadio }

    var typeBadge: String {
        switch quality {
        case .uhd:    return "UHD"
        case .hd:     return "HD"
        case .sdH264: return "SD"
        case .sd:     return "SD"
        case .radio:  return "Radio"
        case .ip:     return "IP"
        case .other:  return "—"
        }
    }

    var typeColor: Color {
        switch quality {
        case .uhd:    return .purple
        case .hd:     return .blue
        case .sdH264: return .secondary
        case .sd:     return .secondary
        case .radio:  return .orange
        case .ip:     return .green
        case .other:  return .gray
        }
    }
}

/// Marks per-row edits so we know what to write on save.
/// Carries `siblingSrvIds` so deduped IP rows update every underlying record.
struct ChannelEdits: Equatable, Sendable {
    var siblingSrvIds: [Int64] = []
    var name: String?
    var major: Int?
    var hidden: Bool?
    var favorite: Bool?
    var deleted: Bool = false

    var isEmpty: Bool {
        name == nil && major == nil && hidden == nil && favorite == nil && !deleted
    }
}

/// Sidebar filter — drives which channels appear in the table.
enum ChannelFilter: Hashable, Identifiable, Sendable {
    case all
    case source(Source)
    case quality(Quality)         // .hd, .uhd, .radio
    case tvOnly
    case radioOnly
    case scrambled
    case hidden
    case favorites
    case provider(String)

    var id: String {
        switch self {
        case .all:                return "all"
        case .source(let s):      return "src.\(s.rawValue)"
        case .quality(let q):     return "qual.\(q.rawValue)"
        case .tvOnly:             return "tvonly"
        case .radioOnly:          return "radioonly"
        case .scrambled:          return "scrambled"
        case .hidden:             return "hidden"
        case .favorites:          return "favorites"
        case .provider(let p):    return "prov.\(p)"
        }
    }

    var label: String {
        switch self {
        case .all:                return "Alle Sender"
        case .source(let s):      return s.label
        case .quality(.uhd):      return "UHD-Sender"
        case .quality(.hd):       return "HD-Sender"
        case .quality(.radio):    return "Radio"
        case .quality:            return "—"
        case .tvOnly:             return "Nur TV"
        case .radioOnly:          return "Nur Radio"
        case .scrambled:          return "Verschlüsselt"
        case .hidden:             return "Ausgeblendet"
        case .favorites:          return "Favoriten"
        case .provider(let p):    return p
        }
    }

    var systemImage: String {
        switch self {
        case .all:                return "tv"
        case .source(let s):      return s.systemImage
        case .quality(.uhd):      return "sparkles.tv"
        case .quality(.hd):       return "tv.and.hifispeaker.fill"
        case .quality(.radio):    return "dot.radiowaves.left.and.right"
        case .quality:            return "circle"
        case .tvOnly:             return "tv"
        case .radioOnly:          return "radio"
        case .scrambled:          return "lock"
        case .hidden:             return "eye.slash"
        case .favorites:          return "star.fill"
        case .provider:           return "antenna.radiowaves.left.and.right"
        }
    }

    func matches(_ ch: Channel) -> Bool {
        switch self {
        case .all:                  return true
        case .source(let s):        return ch.source == s
        case .quality(let q):       return ch.quality == q
        case .tvOnly:               return ch.isTV
        case .radioOnly:            return ch.isRadio
        case .scrambled:            return ch.scrambled
        case .hidden:               return ch.hidden
        case .favorites:            return ch.isFavorite
        case .provider(let name):   return ch.providerName == name
        }
    }
}

// MARK: - Undo

/// One reversible action recorded on the undo stack.
enum UndoAction: Sendable {
    case edit(srvId: Int64, before: ChannelSnapshot, after: ChannelSnapshot)
    case bulk([UndoAction])
}

/// Just the editable subset of a channel — enough to reverse one edit.
struct ChannelSnapshot: Equatable, Sendable {
    var name: String
    var major: Int
    var hidden: Bool
    var favorite: Bool

    init(_ ch: Channel) {
        name = ch.name
        major = ch.major
        hidden = ch.hidden
        favorite = ch.isFavorite
    }
}
