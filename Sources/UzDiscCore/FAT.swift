import Foundation

/// Salt okunur FAT12/FAT16/FAT32 okuyucu (uzun dosya adı desteğiyle).
/// ref biçimi: kök (FAT12/16) "root", dizin "d:<küme>", dosya "f:<küme>:<boyut>".
final class FATReader: FileSystemReader {
    let kind = FSKind.fat
    private(set) var label: String?
    let src: ByteSource
    let bps: UInt64
    let clusterSize: UInt64
    let fatOffset: UInt64
    let dataOffset: UInt64
    let rootDirOffset: UInt64
    let rootDirSize: UInt64
    let fatBits: Int
    let clusterCount: UInt32
    let rootCluster: UInt32
    let totalBytes: UInt64

    var rootRef: String { fatBits == 32 ? "d:\(rootCluster)" : "root" }
    var fatName: String { "FAT\(fatBits)" }

    init(_ src: ByteSource) throws {
        self.src = src
        let b = try src.read(at: 0, count: 512)
        let bps = UInt64(b.u16(11))
        let spc = UInt64(b[13])
        let rsvd = UInt64(b.u16(14))
        let nf = UInt64(b[16])
        let rootEnt = UInt64(b.u16(17))
        let tot16 = UInt64(b.u16(19)), fat16 = UInt64(b.u16(22))
        let tot32 = UInt64(b.u32(32)), fat32 = UInt64(b.u32(36))
        guard [512, 1024, 2048, 4096].contains(bps), spc > 0, spc & (spc - 1) == 0, nf > 0, rsvd > 0 else {
            throw UzError.corrupt("FAT önyükleme kesimi geçersiz")
        }
        let fatSz = fat16 != 0 ? fat16 : fat32
        let tot = tot16 != 0 ? tot16 : tot32
        let rootDirSectors = (rootEnt * 32 + bps - 1) / bps
        let firstData = rsvd + nf * fatSz + rootDirSectors
        guard fatSz > 0, tot > firstData else { throw UzError.corrupt("FAT boyutları geçersiz") }
        let cc = (tot - firstData) / spc
        self.bps = bps
        clusterSize = bps * spc
        fatOffset = rsvd * bps
        dataOffset = firstData * bps
        rootDirOffset = (rsvd + nf * fatSz) * bps
        rootDirSize = rootEnt * 32
        clusterCount = UInt32(min(cc, 0x0FFF_FFF0))
        fatBits = cc < 4085 ? 12 : (cc < 65525 ? 16 : 32)
        rootCluster = fatBits == 32 ? b.u32(44) : 0
        totalBytes = tot * bps

        let bpbLabel = (fatBits == 32 ? b.ascii(71, 11) : b.ascii(43, 11)).trimmingCharacters(in: .whitespaces)
        if let raw = try? rootBytes() {
            var i = 0
            while i + 32 <= raw.count {
                if raw[i] == 0 { break }
                if raw[i] != 0xE5 && raw[i + 11] & 0x3F != 0x0F && raw[i + 11] & 0x08 != 0 {
                    label = decode8bit(Array(raw[i..<(i + 11)])).trimmingCharacters(in: .whitespaces)
                    break
                }
                i += 32
            }
        }
        if label == nil || label!.isEmpty, !bpbLabel.isEmpty, bpbLabel != "NO NAME" { label = bpbLabel }
    }

    var eoc: UInt32 { fatBits == 32 ? 0x0FFF_FFF8 : (fatBits == 16 ? 0xFFF8 : 0xFF8) }

    func next(_ c: UInt32) throws -> UInt32 {
        switch fatBits {
        case 32:
            return try src.read(at: fatOffset + UInt64(c) * 4, count: 4).u32(0) & 0x0FFF_FFFF
        case 16:
            return UInt32(try src.read(at: fatOffset + UInt64(c) * 2, count: 2).u16(0))
        default:
            let off = UInt64(c) + UInt64(c) / 2
            let v = try src.read(at: fatOffset + off, count: 2).u16(0)
            return UInt32(c & 1 == 1 ? v >> 4 : v & 0x0FFF)
        }
    }

    func clusterOffset(_ c: UInt32) -> UInt64 { dataOffset + UInt64(c - 2) * clusterSize }

    func runs(start: UInt32, length: UInt64?) throws -> [ByteRun] {
        let need: UInt64? = length.map { ($0 + clusterSize - 1) / clusterSize }
        if need == 0 { return [] }
        var out: [ByteRun] = []
        var c = start
        var count: UInt64 = 0
        while true {
            guard c >= 2, c < clusterCount + 2 else { throw UzError.corrupt("geçersiz küme zinciri") }
            let off = clusterOffset(c)
            if let last = out.last, last.offset + last.length == off {
                out[out.count - 1].length += clusterSize
            } else {
                out.append((off, clusterSize))
            }
            count += 1
            if let need, count >= need { break }
            guard count <= UInt64(clusterCount) else { throw UzError.corrupt("küme zincirinde döngü") }
            let n = try next(c)
            if n >= eoc { break }
            guard n >= 2, n != eoc - 1 else { throw UzError.corrupt("küme zinciri kırık") }
            c = n
        }
        if let need, count < need { throw UzError.corrupt("küme zinciri beklenenden kısa") }
        return out
    }

    func rootBytes() throws -> [UInt8] {
        if fatBits == 32 { return try chainBytes(rootCluster) }
        return try src.read(at: rootDirOffset, count: Int(rootDirSize))
    }

    func chainBytes(_ start: UInt32) throws -> [UInt8] {
        let r = try runs(start: start, length: nil)
        let total = r.reduce(0) { $0 + $1.length }
        guard total <= 256 << 20 else { throw UzError.corrupt("dizin olağandışı büyük") }
        var out = [UInt8]()
        try streamRuns(src, r, length: total, valid: total) { out += $0 }
        return out
    }

    func list(_ ref: String) throws -> [DirEntry] {
        var all: [DirEntry] = []
        try listStreaming(ref) { all += $0 }
        return all
    }

    func listStreaming(_ ref: String, batch: ([DirEntry]) -> Void) throws {
        if ref == "root" && fatBits != 32 { batch(parse(try rootBytes())); return }
        let p = ref.split(separator: ":")
        guard p.count == 2, p[0] == "d", let c = UInt32(p[1]) else { throw UzError.notFound("dizin (\(ref))") }
        let r = try runs(start: c, length: nil)
        let total = r.reduce(0) { $0 + $1.length }
        guard total <= 256 << 20 else { throw UzError.corrupt("dizin olağandışı büyük") }
        var buf: [UInt8] = []
        var ended = false
        do {
            try streamRuns(src, r, length: total, valid: total, chunk: 512 * 1024) { data in
                buf += data
                let res = parseChunk(buf, final: false)
                if res.consumed > 0 { buf.removeFirst(res.consumed) }
                if !res.entries.isEmpty { batch(res.entries) }
                if res.ended { ended = true; throw StopReading() }
            }
        } catch is StopReading {}
        if !ended && !buf.isEmpty {
            let res = parseChunk(buf, final: true)
            if !res.entries.isEmpty { batch(res.entries) }
        }
    }

    static func lfnChecksum(_ short: [UInt8]) -> UInt8 {
        var s: UInt8 = 0
        for b in short { s = ((s & 1) << 7) &+ (s >> 1) &+ b }
        return s
    }

    func decode8bit(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .windowsCP1254)
            ?? String(bytes: bytes, encoding: .isoLatin1)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    func shortName(_ s: [UInt8], caseFlags: UInt8) -> String {
        var n = s
        if n[0] == 0x05 { n[0] = 0xE5 }
        var base = decode8bit(Array(n[0..<8])).trimmingCharacters(in: .whitespaces)
        var ext = decode8bit(Array(n[8..<11])).trimmingCharacters(in: .whitespaces)
        if caseFlags & 0x08 != 0 { base = base.lowercased() }
        if caseFlags & 0x10 != 0 { ext = ext.lowercased() }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    func parse(_ d: [UInt8]) -> [DirEntry] { parseChunk(d, final: true).entries }

    /// Uzun ad dizisi parça sınırında bölünürse `consumed` o dizinin başında kalır.
    func parseChunk(_ d: [UInt8], final: Bool) -> (entries: [DirEntry], consumed: Int, ended: Bool) {
        var out: [DirEntry] = []
        var lfn: [Int: [UInt16]] = [:]
        var lfnSum: UInt8 = 0
        var lfnStart: Int?
        var ended = false
        var i = 0
        while i + 32 <= d.count {
            defer { i += 32 }
            let f = d[i]
            if f == 0 { ended = true; break }
            let attr = d[i + 11]
            if f == 0xE5 { lfn.removeAll(); lfnStart = nil; continue }
            if attr & 0x3F == 0x0F {
                if f & 0x40 != 0 { lfn.removeAll(); lfnSum = d[i + 13]; lfnStart = i }
                var u = [UInt16]()
                for o in [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30] { u.append(d.u16(i + o)) }
                lfn[Int(f & 0x1F)] = u
                continue
            }
            lfnStart = nil
            if attr & 0x08 != 0 { lfn.removeAll(); continue }
            let short = Array(d[i..<(i + 11)])
            var name: String
            if !lfn.isEmpty, lfnSum == FATReader.lfnChecksum(short), let maxOrd = lfn.keys.max(), maxOrd >= 1 {
                var units = [UInt16]()
                for k in 1...maxOrd { units += lfn[k] ?? [] }
                if let z = units.firstIndex(of: 0) { units = Array(units[..<z]) }
                name = String(decoding: units, as: UTF16.self)
            } else {
                name = shortName(short, caseFlags: d[i + 12])
            }
            lfn.removeAll()
            if name == "." || name == ".." || name.isEmpty { continue }
            let isDir = attr & 0x10 != 0
            var cl = UInt32(d.u16(i + 20)) << 16 | UInt32(d.u16(i + 26))
            if fatBits != 32 { cl &= 0xFFFF }
            let size = UInt64(d.u32(i + 28))
            let date = dosDateTime(UInt32(d.u16(i + 24)) << 16 | UInt32(d.u16(i + 22)))
            let ref: String
            if isDir { ref = cl == 0 ? rootRef : "d:\(cl)" } else { ref = "f:\(cl):\(size)" }
            out.append(DirEntry(name: name, isDirectory: isDir, size: isDir ? 0 : size, modified: date, ref: ref))
        }
        if ended { return (out, i, true) }
        if final { return (out, d.count, false) }
        return (out, lfnStart ?? (d.count / 32 * 32), false)
    }

    func readFile(_ ref: String, sink: ([UInt8]) throws -> Void) throws {
        let p = ref.split(separator: ":")
        guard p.count == 3, p[0] == "f", let c = UInt32(p[1]), let size = UInt64(p[2]) else {
            throw UzError.notFound("dosya (\(ref))")
        }
        if size == 0 { return }
        let r = try runs(start: c, length: size)
        try streamRuns(src, r, length: size, valid: size, sink: sink)
    }
}
