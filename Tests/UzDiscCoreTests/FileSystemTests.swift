import XCTest
import CryptoKit
@testable import UzDiscCore

final class FileSystemTests: XCTestCase {
    static var cache: [String: [UInt8]] = [:]

    func fixtureBytes(_ name: String) throws -> [UInt8] {
        if let b = Self.cache[name] { return b }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name).img", withExtension: "gz"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let b = [UInt8](data)
        Self.cache[name] = b
        return b
    }

    func manifest(_ name: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "manifest"))
        var m: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            m[String(parts[2])] = String(parts[0])
        }
        return m
    }

    /// Tüm ağacı dolaşıp her dosyanın SHA-256'sını manifest ile karşılaştırır.
    func verifyAll(_ name: String, kind: FSKind, label: String) throws {
        let fs = try FileSystems.open(MemoryByteSource(try fixtureBytes(name)))
        XCTAssertEqual(fs.kind, kind)
        XCTAssertEqual(fs.label, label)
        let expected = try manifest(name)
        var seen: [String: String] = [:]

        func walk(_ ref: String, _ prefix: String) throws {
            for e in try fs.list(ref) {
                let path = prefix.isEmpty ? e.name : prefix + "/" + e.name
                if e.isDirectory {
                    try walk(e.ref, path)
                } else {
                    var h = SHA256()
                    var n: UInt64 = 0
                    try fs.readFile(e.ref) { h.update(data: Data($0)); n += UInt64($0.count) }
                    XCTAssertEqual(n, e.size, "boyut: \(path)")
                    seen[path] = h.finalize().map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        try walk(fs.rootRef, "")
        XCTAssertEqual(Set(seen.keys), Set(expected.keys), "dosya kümesi farklı")
        for (k, v) in expected { XCTAssertEqual(seen[k], v, "içerik farklı: \(k)") }
    }

    func testExFAT() throws { try verifyAll("exfat", kind: .exfat, label: "UZEXFAT") }
    func testFAT32() throws { try verifyAll("fat32", kind: .fat, label: "UZFAT32") }
    func testFAT16() throws { try verifyAll("fat16", kind: .fat, label: "UZFAT16") }
    func testNTFS() throws { try verifyAll("ntfs", kind: .ntfs, label: "UZNTFS") }

    func testFATVariantDetected() throws {
        let f32 = try XCTUnwrap(try FileSystems.open(MemoryByteSource(try fixtureBytes("fat32"))) as? FATReader)
        let f16 = try XCTUnwrap(try FileSystems.open(MemoryByteSource(try fixtureBytes("fat16"))) as? FATReader)
        XCTAssertEqual(f32.fatBits, 32)
        XCTAssertEqual(f16.fatBits, 16)
    }

    /// Sıkıştırma yolunun gerçekten çalıştığından emin ol (LZNT1).
    func testNTFSCompressedFileIsActuallyCompressed() throws {
        let fs = try XCTUnwrap(try FileSystems.open(MemoryByteSource(try fixtureBytes("ntfs"))) as? NTFSReader)
        let e = try XCTUnwrap(try fs.resolve(path: "compressed/seq.txt"))
        let n = try XCTUnwrap(UInt64(e.ref.dropFirst(2)))
        let d = try XCTUnwrap(fs.merge(try fs.attributes(record: n), type: 0x80, name: ""))
        XCTAssertTrue(d.flags & 0x0001 != 0, "dosya sıkıştırılmış olmalı")
        XCTAssertGreaterThan(d.compressionUnit, 0)
    }

    func testFragmentedFilesExist() throws {
        // frag1/frag2 dönüşümlü yazıldığı için birden fazla parçaya bölünmüş olmalı.
        let fs = try XCTUnwrap(try FileSystems.open(MemoryByteSource(try fixtureBytes("fat32"))) as? FATReader)
        let e = try XCTUnwrap(try fs.resolve(path: "frag1.txt"))
        let p = e.ref.split(separator: ":")
        let runs = try fs.runs(start: UInt32(p[1])!, length: UInt64(p[2])!)
        XCTAssertGreaterThan(runs.count, 1)
    }

    /// Dosya sistemini bir MBR bölüm tablosunun arkasına koy: bölüm tarayıcısı bulmalı.
    func testMBRPartitionScan() throws {
        let fsBytes = try fixtureBytes("exfat")
        var disk = [UInt8](repeating: 0, count: 2048 * 512)
        let e = 446
        disk[e + 4] = 0x07
        let lba: UInt32 = 2048, count = UInt32(fsBytes.count / 512)
        for i in 0..<4 {
            disk[e + 8 + i] = UInt8((lba >> (8 * UInt32(i))) & 0xFF)
            disk[e + 12 + i] = UInt8((count >> (8 * UInt32(i))) & 0xFF)
        }
        disk[510] = 0x55
        disk[511] = 0xAA
        disk += fsBytes
        let src = MemoryByteSource(disk)
        let parts = try PartitionScanner.scan(src)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].offset, 2048 * 512)
        XCTAssertEqual(parts[0].fileSystem, .exfat)
        XCTAssertEqual(parts[0].label, "UZEXFAT")
    }

    func testGPTPartitionScan() throws {
        let fsBytes = try fixtureBytes("ntfs")
        var disk = [UInt8](repeating: 0, count: 2048 * 512)
        // Koruyucu MBR
        disk[446 + 4] = 0xEE
        disk[446 + 8] = 1
        disk[446 + 12] = 0xFF; disk[446 + 13] = 0xFF
        disk[510] = 0x55; disk[511] = 0xAA
        // GPT başlığı (LBA 1)
        let h = 512
        for (i, c) in "EFI PART".utf8.enumerated() { disk[h + i] = c }
        func put64(_ v: UInt64, _ o: Int) { for i in 0..<8 { disk[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) } }
        func put32(_ v: UInt32, _ o: Int) { for i in 0..<4 { disk[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
        put64(2, h + 72)
        put32(4, h + 80)
        put32(128, h + 84)
        // Girdi 0: Microsoft Basic Data
        let g: [UInt8] = [0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44, 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7]
        let t = 1024
        for i in 0..<16 { disk[t + i] = g[i] }
        disk[t + 16] = 1
        put64(2048, t + 32)
        put64(2048 + UInt64(fsBytes.count / 512) - 1, t + 40)
        disk += fsBytes
        let parts = try PartitionScanner.scan(MemoryByteSource(disk))
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].scheme, "GPT")
        XCTAssertEqual(parts[0].fileSystem, .ntfs)
        XCTAssertEqual(parts[0].label, "UZNTFS")
        XCTAssertTrue(parts[0].typeName.hasPrefix("Microsoft Temel Veri"))
    }

    func testExtractorCopiesTreeAndHandlesNameClash() throws {
        let fs = try FileSystems.open(MemoryByteSource(try fixtureBytes("exfat")))
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("uzdisc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let hello = try XCTUnwrap(try fs.resolve(path: "hello.txt"))
        let dir = try XCTUnwrap(try fs.resolve(path: "a"))
        let ex = Extractor(fs: fs)
        var lastProgress = CopyProgress()
        ex.onProgress = { lastProgress = $0 }
        let s1 = ex.copy([hello, dir], to: dest)
        XCTAssertEqual(s1.errors, [])
        XCTAssertEqual(s1.files, 2)
        XCTAssertEqual(lastProgress.filesTotal, 2)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("a/b/c/d/deep.txt"), encoding: .utf8), "derin\n")
        // Aynı dosyayı tekrar kopyala → üzerine yazmamalı, "hello (2).txt" oluşturmalı.
        _ = ex.copy([hello], to: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("hello (2).txt").path))
    }

    func testCancelStopsCopy() throws {
        let fs = try FileSystems.open(MemoryByteSource(try fixtureBytes("fat32")))
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("uzdisc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let many = try XCTUnwrap(try fs.resolve(path: "many"))
        let ex = Extractor(fs: fs)
        var count = 0
        ex.isCancelled = { count += 1; return count > 50 }
        let s = ex.copy([many], to: dest)
        XCTAssertTrue(s.cancelled)
        XCTAssertLessThan(s.files, 300)
    }

    func testRunlistDecoding() throws {
        // 0x21: uzunluk 1 bayt, konum 2 bayt. 0x18 küme @ 0x5634; sonra seyrek 0x10; sonra -0x10 göreli.
        let rl: [UInt8] = [0x21, 0x18, 0x34, 0x56, 0x01, 0x10, 0x11, 0x08, 0xF0, 0x00]
        let runs = try NTFSReader.decodeRuns(rl, startVCN: 0)
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].lcn, 0x5634)
        XCTAssertEqual(runs[0].length, 0x18)
        XCTAssertNil(runs[1].lcn)
        XCTAssertEqual(runs[1].vcn, 0x18)
        XCTAssertEqual(runs[2].lcn, 0x5634 - 0x10)
    }

    func testLZNT1Uncompressed() throws {
        // Sıkıştırılmamış parça (bit 15 = 0)
        var input: [UInt8] = [0xFF, 0x0F]
        input += [UInt8](repeating: 0x41, count: 4096)
        XCTAssertEqual(try LZNT1.decompress(input, outputSize: 4096), [UInt8](repeating: 0x41, count: 4096))
    }

    func testLZNT1Backreference() throws {
        // "abc" + geri başvuru (uzaklık 3, uzunluk 6) → "abcabcabc"
        // pos=3 → shift=12, tuple = ((3-1) << 12) | (6-3) = 0x2003
        let payload: [UInt8] = [0x08, 0x61, 0x62, 0x63, 0x03, 0x20]
        let header = UInt16(0xB000) | UInt16(payload.count - 1)
        let input = [UInt8(header & 0xFF), UInt8(header >> 8)] + payload
        let out = try LZNT1.decompress(input, outputSize: 9)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "abcabcabc")
    }

    /// Büyük klasörler parça parça okunur; parça sınırı girdi kümesinin ortasına denk gelse de sonuç aynı olmalı.
    func testChunkedParsingMatchesFullParse() throws {
        let ex = try XCTUnwrap(try FileSystems.open(MemoryByteSource(try fixtureBytes("exfat"))) as? ExFATReader)
        let many = try XCTUnwrap(try ex.resolve(path: "many"))
        let p = many.ref.split(separator: ":")
        let raw = try ex.dirBytes(cluster: UInt32(p[1])!, length: UInt64(p[2])!, noFat: p[3] == "1")
        let full = ex.parse(raw).map(\.name)
        for step in [32, 96, 100, 1000, 4097] {
            var buf: [UInt8] = []
            var got: [String] = []
            var pos = 0
            var ended = false
            while pos < raw.count && !ended {
                buf += raw[pos..<min(pos + step, raw.count)]
                pos += step
                let r = ex.parseSets(buf, final: false)
                got += r.entries.map(\.name)
                buf.removeFirst(r.consumed)
                ended = r.ended
            }
            if !ended { got += ex.parseSets(buf, final: true).entries.map(\.name) }
            XCTAssertEqual(got, full, "exFAT parça boyutu \(step)")
        }

        let fat = try XCTUnwrap(try FileSystems.open(MemoryByteSource(try fixtureBytes("fat32"))) as? FATReader)
        let m2 = try XCTUnwrap(try fat.resolve(path: "many"))
        let raw2 = try fat.chainBytes(UInt32(m2.ref.split(separator: ":")[1])!)
        let full2 = fat.parse(raw2).map(\.name)
        XCTAssertEqual(full2.count, 300)
        for step in [32, 64, 96, 4096] {
            var buf: [UInt8] = []
            var got: [String] = []
            var pos = 0
            var ended = false
            while pos < raw2.count && !ended {
                buf += raw2[pos..<min(pos + step, raw2.count)]
                pos += step
                let r = fat.parseChunk(buf, final: false)
                got += r.entries.map(\.name)
                buf.removeFirst(r.consumed)
                ended = r.ended
            }
            if !ended { got += fat.parseChunk(buf, final: true).entries.map(\.name) }
            XCTAssertEqual(got, full2, "FAT parça boyutu \(step)")
        }
    }

    func testDetectRejectsGarbage() {
        XCTAssertNil(FSDetector.detect([UInt8](repeating: 0, count: 512)))
        XCTAssertNil(FSDetector.detect([UInt8](repeating: 0xFF, count: 512)))
    }
}
