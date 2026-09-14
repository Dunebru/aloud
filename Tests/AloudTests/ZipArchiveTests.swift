import Compression
import Foundation
import XCTest
@testable import Aloud

final class ZipArchiveTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aloud-ziptest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testExtractsStoredAndDeflatedEntries() throws {
        let stored = Data("hello stored world".utf8)
        let deflatedSource = Data(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40).utf8)
        let zip = TestZipWriter.build([
            .file("mimetype", stored, deflate: false),
            .directory("META-INF/"),
            .file("META-INF/container.xml", deflatedSource, deflate: true),
            .file("OEBPS/chapter one.xhtml", Data("<p>chapter</p>".utf8), deflate: true),
        ], comment: "fixture comment")
        let zipURL = scratch.appendingPathComponent("fixture.zip")
        try zip.write(to: zipURL)

        let out = scratch.appendingPathComponent("out")
        try ZipArchive.extract(zipURL, to: out)

        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("mimetype")), stored)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("META-INF/container.xml")), deflatedSource)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("OEBPS/chapter one.xhtml"), encoding: .utf8), "<p>chapter</p>")

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("META-INF").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        XCTAssertEqual(try ZipArchive.entryData(zipURL, path: "META-INF/container.xml"), deflatedSource)
        XCTAssertNil(try ZipArchive.entryData(zipURL, path: "missing.txt"))
    }

    func testRejectsPathTraversal() throws {
        let zip = TestZipWriter.build([.file("../evil.txt", Data("x".utf8), deflate: false)])
        let zipURL = scratch.appendingPathComponent("evil.zip")
        try zip.write(to: zipURL)
        XCTAssertThrowsError(try ZipArchive.extract(zipURL, to: scratch.appendingPathComponent("out")))

        let absolute = TestZipWriter.build([.file("/tmp/evil.txt", Data("x".utf8), deflate: false)])
        let absoluteURL = scratch.appendingPathComponent("absolute.zip")
        try absolute.write(to: absoluteURL)
        XCTAssertThrowsError(try ZipArchive.extract(absoluteURL, to: scratch.appendingPathComponent("out2")))
    }

    func testRejectsNonZipData() throws {
        let junk = scratch.appendingPathComponent("junk.zip")
        try Data(repeating: 0x41, count: 100).write(to: junk)
        XCTAssertThrowsError(try ZipArchive.extract(junk, to: scratch.appendingPathComponent("out")))
    }

    func testDetectsCorruptedData() throws {
        var zip = TestZipWriter.build([.file("a.txt", Data(String(repeating: "abc", count: 100).utf8), deflate: true)])
        // Flip a byte inside the compressed payload, after the 30 byte local header and 5 byte name.
        zip[40] ^= 0xFF
        let zipURL = scratch.appendingPathComponent("corrupt.zip")
        try zip.write(to: zipURL)
        XCTAssertThrowsError(try ZipArchive.extract(zipURL, to: scratch.appendingPathComponent("out")))
    }
}

/// Tiny ZIP writer used only to build fixtures in tests.
enum TestZipWriter {
    enum Item {
        case file(String, Data, deflate: Bool)
        case directory(String)
    }

    static func build(_ items: [Item], comment: String = "") -> Data {
        var out = Data()
        var central = Data()
        var count: UInt16 = 0
        for item in items {
            let name: String, payload: Data, stored: Data, method: UInt16
            switch item {
            case .file(let n, let d, let deflate):
                name = n; payload = d
                if deflate { stored = rawDeflate(d); method = 8 } else { stored = d; method = 0 }
            case .directory(let n):
                name = n; payload = Data(); stored = Data(); method = 0
            }
            let nameBytes = Data(name.utf8)
            let crc = crc32(payload)
            let offset = UInt32(out.count)

            out.append(le32(0x0403_4b50)); out.append(le16(20)); out.append(le16(0)); out.append(le16(method))
            out.append(le16(0)); out.append(le16(0)); out.append(le32(crc))
            out.append(le32(UInt32(stored.count))); out.append(le32(UInt32(payload.count)))
            out.append(le16(UInt16(nameBytes.count))); out.append(le16(0))
            out.append(nameBytes); out.append(stored)

            central.append(le32(0x0201_4b50)); central.append(le16(20)); central.append(le16(20)); central.append(le16(0)); central.append(le16(method))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(crc))
            central.append(le32(UInt32(stored.count))); central.append(le32(UInt32(payload.count)))
            central.append(le16(UInt16(nameBytes.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(offset))
            central.append(nameBytes)
            count += 1
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        let commentBytes = Data(comment.utf8)
        out.append(le32(0x0605_4b50)); out.append(le16(0)); out.append(le16(0)); out.append(le16(count)); out.append(le16(count))
        out.append(le32(UInt32(central.count))); out.append(le32(centralOffset)); out.append(le16(UInt16(commentBytes.count)))
        out.append(commentBytes)
        return out
    }

    static func rawDeflate(_ input: Data) -> Data {
        let capacity = max(1024, input.count * 2)
        var dst = [UInt8](repeating: 0, count: capacity)
        let n = input.withUnsafeBytes { src -> Int in
            dst.withUnsafeMutableBufferPointer { d in
                compression_encode_buffer(d.baseAddress!, capacity, src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(n > 0, "deflate failed")
        return Data(dst[0..<n])
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return c ^ 0xFFFF_FFFF
    }

    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }
}
