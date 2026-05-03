import Foundation

/// Samsung TV channel-list databases store text as UTF-16 with the bytes of
/// each 16-bit code unit swapped (UTF-16 BE bytes interpreted as UTF-16 LE).
/// SQLite hands the text back as `䐀愀猀 䔀爀猀琀攀 䠀䐀`; swapping each code unit
/// recovers `Das Erste HD`. The transform is symmetric — same function
/// encodes and decodes.
extension String {
    func samsungSwapped() -> String {
        let units = utf16.map(\.byteSwapped)
        return String(utf16CodeUnits: units, count: units.count)
    }
}
