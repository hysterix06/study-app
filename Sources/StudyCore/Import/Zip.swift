import Foundation
import Compression

/// Minimal read-only ZIP archive reader (stored and deflate entries), enough for PPTX and DOCX.
public struct ZipArchive {
    public struct Entry { public let name: String; let method: UInt16; let compressedSize: Int; let uncompressedSize: Int; let localHeaderOffset: Int }

    public enum ZipError: Error, CustomStringConvertible {
        case notZip, corrupt(String), unsupported(String), tooLarge
        public var description: String {
            switch self {
            case .notZip: return "The file is not a valid Office document (zip container missing)."
            case .corrupt(let m): return "The file is damaged: \(m)."
            case .unsupported(let m): return "Unsupported compression: \(m)."
            case .tooLarge: return "An entry inside the file is too large."
            }
        }
    }

    let data: Data
    public private(set) var entries: [String: Entry] = [:]

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw ZipError.notZip }
        // Find End Of Central Directory (signature 0x06054b50) scanning backwards.
        var eocd = -1
        let minPos = max(0, data.count - 65557)
        var i = data.count - 22
        while i >= minPos {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = Int(u16(eocd + 10))
        var p = Int(u32(eocd + 16))
        for _ in 0..<count {
            guard p + 46 <= data.count, u32(p) == 0x02014b50 else { throw ZipError.corrupt("central directory") }
            let method = u16(p + 10)
            let csize = Int(u32(p + 20)), usize = Int(u32(p + 24))
            let nlen = Int(u16(p + 28)), elen = Int(u16(p + 30)), clen = Int(u16(p + 32))
            let offset = Int(u32(p + 42))
            guard p + 46 + nlen <= data.count else { throw ZipError.corrupt("entry name") }
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nlen))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: offset)
            p += 46 + nlen + elen + clen
        }
    }

    public var names: [String] { Array(entries.keys) }

    public func read(_ name: String) throws -> Data? {
        guard let e = entries[name] ?? entries.first(where: { $0.key.lowercased() == name.lowercased() })?.value else { return nil }
        let h = e.localHeaderOffset
        guard h + 30 <= data.count, u32(h) == 0x04034b50 else { throw ZipError.corrupt("local header") }
        let start = h + 30 + Int(u16(h + 26)) + Int(u16(h + 28))
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt("entry data") }
        let slice = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        switch e.method {
        case 0: return slice
        case 8:
            guard e.uncompressedSize < 200_000_000 else { throw ZipError.tooLarge }
            return try inflate(slice, expected: e.uncompressedSize)
        default: throw ZipError.unsupported("method \(e.method)")
        }
    }

    public func readString(_ name: String) throws -> String? {
        guard let d = try read(name) else { return nil }
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }

    func inflate(_ input: Data, expected: Int) throws -> Data {
        if expected == 0 { return Data() }
        var out = Data(count: expected)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw ZipError.corrupt("deflate stream") }
        out.count = written
        return out
    }

    private func u16(_ o: Int) -> UInt16 {
        let b = data.startIndex + o
        return UInt16(data[b]) | UInt16(data[b + 1]) << 8
    }
    private func u32(_ o: Int) -> UInt32 {
        let b = data.startIndex + o
        return UInt32(data[b]) | UInt32(data[b + 1]) << 8 | UInt32(data[b + 2]) << 16 | UInt32(data[b + 3]) << 24
    }
}

/// Resolves a relationship target ("../media/image1.png") against the part that references it.
func resolvePartPath(base: String, target: String) -> String {
    if target.hasPrefix("/") { return String(target.dropFirst()) }
    var parts = base.split(separator: "/").map(String.init)
    parts.removeLast()
    for seg in target.split(separator: "/") {
        if seg == ".." { if !parts.isEmpty { parts.removeLast() } } else if seg != "." { parts.append(String(seg)) }
    }
    return parts.joined(separator: "/")
}

func relsPath(for part: String) -> String {
    var parts = part.split(separator: "/").map(String.init)
    let file = parts.removeLast()
    return (parts + ["_rels", file + ".rels"]).joined(separator: "/")
}
