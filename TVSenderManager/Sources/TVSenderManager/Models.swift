import Foundation
import SwiftUI

enum Source: String, CaseIterable, Identifiable, Hashable {
    case cable
    case ip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cable: return "Kabel (DVB-C)"
        case .ip:    return "IP / Streaming"
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

/// One service ("channel") as shown in the UI.
struct Channel: Identifiable, Hashable, Sendable {
    let srvId: Int64
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

    var quality: Quality {
        switch srvType {
        case 2:        return .radio
        case 31:       return .uhd
        case 25, 17, 19: return .hd
        case 22:       return .sdH264
        case 1, 10, 12: return .sd
        case -1:       return .ip
        default:       return .other
        }
    }

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

enum Quality {
    case uhd, hd, sdH264, sd, radio, ip, other
}

/// Marks per-row edits so we know what to write on save.
struct ChannelEdits: Equatable, Sendable {
    var name: String?
    var major: Int?
    var hidden: Bool?
    var favorite: Bool?
    var deleted: Bool = false

    var isEmpty: Bool {
        name == nil && major == nil && hidden == nil && favorite == nil && !deleted
    }
}
