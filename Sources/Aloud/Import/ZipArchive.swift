import Compression
import Foundation

enum ZipError: LocalizedError {
    case notAZipFile
    case truncated
    case zip64Unsupported
    case encrypted(String)
    case unsupportedCompression(UInt16, String)
    case unsafePath(String)
    case corruptEntry(String)

    var errorDescription: String? {
        switch self {
        case .notAZipFile: "The file is not a ZIP archive."
        case .truncated: "The ZIP archive is truncated or damaged."
        case .zip64Unsupported: "ZIP64 archives are not supported."
        case .encrypted(let name): "The entry \"\(name)\" is encrypted."
        case .unsupportedCompression(let method, let name): "The entry \"\(name)\" uses unsupported compression method \(method)."
        case .unsafePath(let name): "The entry \"\(name)\" has an unsafe path."
        case .corruptEntry(let name): "The entry \"\(name)\" is damaged."
        }
    }
}

/// Minimal in-process ZIP reader. Supports stored and deflated entries, which covers EPUB and DOCX.
/// Reads the central directory, then each entry's local header, and inflates with libcompression.
struct ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50

    private let bytes: [UInt8]
    let entries: [Entry]

    init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    init(data: Data) throws {
        bytes = [UInt8](data)
        entries = try ZipArchive.readCentralDirectory(bytes)
    }

    // MARK: public API

    /// Extracts every file entry into `directory`, creating intermediate folders. Directory entries are
    /// skipped. Entries whose path escapes the target directory are rejected.
    static func extract(_ zipURL: URL, to directory: URL) throws {
        let archive = try ZipArchive(url: zipURL)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in archive.entries {
            guard !entry.isDirectory else { continue }
            let relative = try sanitizedPath(entry.name)
            let target = directory.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try archive.data(for: entry).write(to: target)
        }
    }

    /// Returns the decompressed bytes of the entry at `path`, or nil when the archive has no such entry.
    static func entryData(_ zipURL: URL, path: String) throws -> Data? {
        let archive = try ZipArchive(url: zipURL)
        guard let entry = archive.entries.first(where: { $0.name == path && !$0.isDirectory }) else { return nil }
        return try archive.data(for: entry)
    }

    /// Decompressed contents of one entry.
    func data(for entry: Entry) throws -> Data {
        guard entry.flags & 0x1 == 0 else { throw ZipError.encrypted(entry.name) }
        let headerStart = entry.localHeaderOffset
        guard headerStart + 30 <= bytes.count, u32(at: headerStart) == ZipArchive.localHeaderSignature else { throw ZipError.corruptEntry(entry.name) }
        let nameLength = Int(u16(at: headerStart + 26))
        let extraLength = Int(u16(at: headerStart + 28))
        let dataStart = headerStart + 30 + nameLength + extraLength
        let dataEnd = dataStart + entry.compressedSize
        guard dataEnd <= bytes.count else { throw ZipError.truncated }

        let output: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw ZipError.corruptEntry(entry.name) }
            output = Data(bytes[dataStart..<dataEnd])
        case 8:
            output = try ZipArchive.inflate(bytes[dataStart..<dataEnd], expectedSize: entry.uncompressedSize, name: entry.name)
        default:
            throw ZipError.unsupportedCompression(entry.method, entry.name)
        }
        guard ZipArchive.crc32(output) == entry.crc32 else { throw ZipError.corruptEntry(entry.name) }
        return output
    }

    // MARK: parsing

    private static func readCentralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        // The End of Central Directory record is 22 bytes plus a comment of up to 65535 bytes,
        // so scan backward from the end for its signature.
        guard bytes.count >= 22 else { throw ZipError.notAZipFile }
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        var eocd = -1
        var i = bytes.count - 22
        while i >= lowest {
            if read32(bytes, i) == endOfCentralDirectorySignature {
                let commentLength = Int(read16(bytes, i + 20))
                if i + 22 + commentLength == bytes.count { eocd = i; break }
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZipFile }

        let entryCount = Int(read16(bytes, eocd + 10))
        let directorySize = Int(read32(bytes, eocd + 12))
        let directoryOffset = Int(read32(bytes, eocd + 16))
        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF { throw ZipError.zip64Unsupported }
        guard directoryOffset + directorySize <= bytes.count else { throw ZipError.truncated }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var p = directoryOffset
        for _ in 0..<entryCount {
            guard p + 46 <= bytes.count, read32(bytes, p) == centralHeaderSignature else { throw ZipError.truncated }
            let flags = read16(bytes, p + 8)
            let method = read16(bytes, p + 10)
            let crc = read32(bytes, p + 16)
            let compressed = read32(bytes, p + 20)
            let uncompressed = read32(bytes, p + 24)
            let nameLength = Int(read16(bytes, p + 28))
            let extraLength = Int(read16(bytes, p + 30))
            let commentLength = Int(read16(bytes, p + 32))
            let localOffset = read32(bytes, p + 42)
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF { throw ZipError.zip64Unsupported }
            guard p + 46 + nameLength <= bytes.count else { throw ZipError.truncated }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name, method: method, flags: flags, crc32: crc, compressedSize: Int(compressed), uncompressedSize: Int(uncompressed), localHeaderOffset: Int(localOffset)))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Rejects absolute paths and any ".." component so an archive cannot write outside the target directory.
    static func sanitizedPath(_ name: String) throws -> String {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/") else { throw ZipError.unsafePath(name) }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(".."), !components.contains(where: { $0.contains(":") }) else { throw ZipError.unsafePath(name) }
        return components.joined(separator: "/")
    }

    // MARK: inflate

    private static func inflate(_ input: ArraySlice<UInt8>, expectedSize: Int, name: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = input.withUnsafeBufferPointer { src -> Int in
            output.withUnsafeMutableBufferPointer { dst in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return 0 }
                // COMPRESSION_ZLIB is raw deflate without the zlib header, which is what ZIP stores.
                return compression_decode_buffer(d, expectedSize, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.corruptEntry(name) }
        return Data(output)
    }

    // MARK: crc32

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: little-endian readers

    private func u16(at i: Int) -> UInt16 { ZipArchive.read16(bytes, i) }
    private func u32(at i: Int) -> UInt32 { ZipArchive.read32(bytes, i) }

    private static func read16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func read32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
