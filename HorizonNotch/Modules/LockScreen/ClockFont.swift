import AppKit
import CoreText

/// macOS's lock screen clock fonts (e.g. ".ADTSlabSoftNumeric-Regular")
/// live in /System/Library/Fonts/ADTNumeric.ttc. CoreText only hands such
/// dot-prefixed system names to Apple's own processes; every other app
/// gets Times, and LoginUIKit then falls back to SF Soft. So the face is
/// copied once, in memory, under a plain name and registered for this
/// process only – then the system's own glass clock can draw it.
enum ClockFont {
    private static var registered: [String: String] = [:]
    private static let lock = NSLock()

    /// A name CoreText resolves in this process for the system font
    /// `systemName`, or nil when it can't be found.
    static func usableName(for systemName: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let name = registered[systemName] { return name }
        guard systemName.hasPrefix(".") else { return systemName }
        guard let font = systemFont(named: systemName) else { return nil }
        let plain = "HN" + systemName.replacingOccurrences(of: ".", with: "")
        guard let data = renamedCopy(of: font, to: plain),
              let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else { return nil }
        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterGraphicsFont(cgFont, &error)
        let check = CTFontCreateWithName(plain as CFString, 20, nil)
        guard CTFontCopyPostScriptName(check) as String == plain else { return nil }
        registered[systemName] = plain
        return plain
    }

    /// The face itself, straight from the system's font file.
    static func systemFont(named name: String, size: CGFloat = 20) -> CTFont? {
        let url = URL(fileURLWithPath: "/System/Library/Fonts/ADTNumeric.ttc") as CFURL
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor] else { return nil }
        for descriptor in descriptors {
            let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            if CTFontCopyPostScriptName(font) as String == name { return font }
        }
        return nil
    }

    // MARK: - sfnt

    /// All tables of the face in a fresh single-font file, with a new name.
    private static func renamedCopy(of font: CTFont, to name: String) -> Data? {
        guard let tags = CTFontCopyAvailableTables(font, []) else { return nil }
        var tables: [(tag: UInt32, data: Data)] = []
        for index in 0..<CFArrayGetCount(tags) {
            let tag = UInt32(UInt(bitPattern: CFArrayGetValueAtIndex(tags, index)))
            guard let table = CTFontCopyTable(font, CTFontTableTag(tag), []) as Data? else { continue }
            tables.append((tag, tag == fourCC("name") ? renamedNameTable(table, name: name) ?? table : table))
        }
        guard !tables.isEmpty else { return nil }
        tables.sort { $0.tag < $1.tag }
        let isCFF = tables.contains { $0.tag == fourCC("CFF ") || $0.tag == fourCC("CFF2") }

        var out = Data()
        let count = UInt16(tables.count)
        var power: UInt16 = 1, log: UInt16 = 0
        while power * 2 <= count { power *= 2; log += 1 }
        out.append(be32(isCFF ? fourCC("OTTO") : 0x0001_0000))
        out.append(be16(count))
        out.append(be16(power * 16))
        out.append(be16(log))
        out.append(be16(count * 16 - power * 16))
        var offset = 12 + 16 * tables.count
        var body = Data()
        for table in tables {
            var padded = table.data
            while padded.count % 4 != 0 { padded.append(0) }
            out.append(be32(table.tag))
            out.append(be32(checksum(padded)))
            out.append(be32(UInt32(offset)))
            out.append(be32(UInt32(table.data.count)))
            body.append(padded)
            offset += padded.count
        }
        out.append(body)
        return out
    }

    /// The name table with family, full and PostScript names replaced.
    private static func renamedNameTable(_ table: Data, name: String) -> Data? {
        let bytes = [UInt8](table)
        guard bytes.count >= 6 else { return nil }
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        let count = u16(2), storage = u16(4)
        guard bytes.count >= 6 + count * 12 else { return nil }
        let replaced: Set<Int> = [1, 2, 3, 4, 6, 16, 17]
        var records: [(p: Int, e: Int, l: Int, n: Int, text: [UInt8])] = []
        for i in 0..<count {
            let base = 6 + i * 12
            let nameID = u16(base + 6)
            guard !replaced.contains(nameID) else { continue }
            let length = u16(base + 8), start = storage + u16(base + 10)
            guard start + length <= bytes.count else { continue }
            records.append((u16(base), u16(base + 2), u16(base + 4), nameID, Array(bytes[start..<start + length])))
        }
        func utf16BE(_ text: String) -> [UInt8] { text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }
        for (id, text) in [(1, name), (2, "Regular"), (3, name), (4, name), (6, name)] {
            records.append((3, 1, 0x409, id, utf16BE(text)))
        }
        records.sort { ($0.p, $0.e, $0.l, $0.n) < ($1.p, $1.e, $1.l, $1.n) }
        var out = Data()
        out.append(be16(0))
        out.append(be16(UInt16(records.count)))
        out.append(be16(UInt16(6 + records.count * 12)))
        var strings = Data()
        for record in records {
            out.append(be16(UInt16(record.p)))
            out.append(be16(UInt16(record.e)))
            out.append(be16(UInt16(record.l)))
            out.append(be16(UInt16(record.n)))
            out.append(be16(UInt16(record.text.count)))
            out.append(be16(UInt16(strings.count)))
            strings.append(contentsOf: record.text)
        }
        out.append(strings)
        return out
    }

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func checksum(_ padded: Data) -> UInt32 {
        let bytes = [UInt8](padded)
        var sum: UInt32 = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            sum &+= UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }
        return sum
    }

    private static func be16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }
    private static func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
