import Foundation

/// Salt okunur NTFS okuyucu.
/// Destekler: parçalı $MFT, öznitelik listeleri, seyrek (sparse) ve LZNT1 sıkıştırılmış dosyalar, büyük dizinler.
/// Desteklemez: EFS şifreli dosyalar, WOF/sistem sıkıştırması (bu dosyalar açık bir hatayla atlanır).
/// ref biçimi: "m:<MFT kayıt numarası>".
final class NTFSReader: FileSystemReader {
    struct Run { var vcn: UInt64; var lcn: UInt64?; var length: UInt64 }

    struct Attr {
        var type: UInt32
        var name: String
        var nonResident: Bool
        var flags: UInt16
        var value: [UInt8] = []
        var runs: [Run] = []
        var startVCN: UInt64 = 0
        var dataSize: UInt64 = 0
        var initSize: UInt64 = 0
        var compressionUnit: Int = 0
    }

    let kind = FSKind.ntfs
    private(set) var label: String?
    let src: ByteSource
    let clusterSize: UInt64
    let recordSize: Int
    let totalBytes: UInt64
    var rootRef: String { "m:5" }

    private var mftRuns: [Run] = []
    private var recordCache: [UInt64: [UInt8]] = [:]
    private var cacheOrder: [UInt64] = []
    private let cacheLock = NSLock()

    init(_ src: ByteSource) throws {
        self.src = src
        let b = try src.read(at: 0, count: 512)
        guard b.ascii(3, 8) == "NTFS    " else { throw UzError.corrupt("NTFS imzası bulunamadı") }
        let bps = UInt64(b.u16(11))
        guard [512, 1024, 2048, 4096].contains(bps) else { throw UzError.corrupt("NTFS kesim boyutu geçersiz") }
        let spcRaw = b[13]
        let spc: UInt64 = spcRaw <= 0x80 ? UInt64(spcRaw) : UInt64(1) << UInt64(256 - Int(spcRaw))
        guard spc > 0 else { throw UzError.corrupt("NTFS küme boyutu geçersiz") }
        clusterSize = bps * spc
        let cpr = Int8(bitPattern: b[64])
        recordSize = cpr < 0 ? 1 << Int(-cpr) : Int(cpr) * Int(clusterSize)
        guard recordSize >= 256, recordSize <= 65536 else { throw UzError.corrupt("MFT kayıt boyutu geçersiz") }
        totalBytes = b.u64(40) * bps

        // $MFT'nin kendi konumunu önyükleme kesiminden okuyup kayıt 0'dan tam haritayı çıkar.
        let mftStart = b.u64(48) * clusterSize
        guard mftStart < src.size, UInt64(recordSize) <= src.size - mftStart else {
            throw UzError.corrupt("$MFT konumu disk dışında")
        }
        var r0 = try src.read(at: mftStart, count: recordSize)
        try NTFSReader.fixup(&r0, sig: "FILE")
        let a0 = try parseAttributes(r0)
        guard let d0 = a0.first(where: { $0.type == 0x80 && $0.name.isEmpty && $0.nonResident }) else {
            throw UzError.corrupt("$MFT veri özniteliği yok")
        }
        mftRuns = d0.runs
        if a0.contains(where: { $0.type == 0x20 }) {
            let all = try attributes(record: 0, base: r0)
            if let m = merge(all, type: 0x80, name: "") { mftRuns = m.runs }
        }

        if let vol = try? attributes(record: 3).first(where: { $0.type == 0x60 }), !vol.value.isEmpty {
            label = vol.value.utf16(0, units: vol.value.count / 2)
        }
    }

    // MARK: Kayıtlar

    static func fixup(_ buf: inout [UInt8], sig: String) throws {
        guard buf.ascii(0, 4) == sig else { throw UzError.corrupt("\(sig) imzası yok") }
        let usaOff = Int(buf.u16(4)), usaCount = Int(buf.u16(6))
        guard usaCount >= 2, usaOff + usaCount * 2 <= buf.count else { throw UzError.corrupt("güncelleme dizisi geçersiz") }
        let stride = buf.count / (usaCount - 1)
        guard stride >= 256 else { throw UzError.corrupt("güncelleme dizisi geçersiz") }
        let u0 = buf[usaOff], u1 = buf[usaOff + 1]
        for i in 1..<usaCount {
            let pos = i * stride - 2
            guard pos + 1 < buf.count else { break }
            guard buf[pos] == u0, buf[pos + 1] == u1 else { throw UzError.corrupt("\(sig) kaydı yarım yazılmış (fixup)") }
            buf[pos] = buf[usaOff + i * 2]
            buf[pos + 1] = buf[usaOff + i * 2 + 1]
        }
    }

    func readRecord(_ n: UInt64) throws -> [UInt8] {
        cacheLock.lock()
        if let r = recordCache[n] { cacheLock.unlock(); return r }
        cacheLock.unlock()
        var buf = try readFromRuns(mftRuns, offset: n * UInt64(recordSize), length: recordSize)
        try NTFSReader.fixup(&buf, sig: "FILE")
        cacheLock.lock()
        recordCache[n] = buf
        cacheOrder.append(n)
        if cacheOrder.count > 4096 { recordCache[cacheOrder.removeFirst()] = nil }
        cacheLock.unlock()
        return buf
    }

    func readFromRuns(_ runs: [Run], offset: UInt64, length: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(length)
        var pos = offset
        let end = offset + UInt64(length)
        while pos < end {
            let vcn = pos / clusterSize
            guard let r = runs.first(where: { vcn >= $0.vcn && vcn < $0.vcn + $0.length }) else {
                throw UzError.corrupt("küme \(vcn) haritada yok")
            }
            let runEnd = (r.vcn + r.length) * clusterSize
            let n = Int(min(end, runEnd) - pos)
            if let lcn = r.lcn {
                out += try src.read(at: lcn * clusterSize + (pos - r.vcn * clusterSize), count: n)
            } else {
                out += [UInt8](repeating: 0, count: n)
            }
            pos += UInt64(n)
        }
        return out
    }

    // MARK: Öznitelikler

    func parseAttributes(_ r: [UInt8]) throws -> [Attr] {
        var out: [Attr] = []
        var off = Int(r.u16(20))
        while off + 16 <= r.count {
            let type = r.u32(off)
            if type == 0xFFFF_FFFF || type == 0 { break }
            let len = Int(r.u32(off + 4))
            guard len >= 16, off + len <= r.count else { throw UzError.corrupt("öznitelik uzunluğu geçersiz") }
            let nonRes = r[off + 8] != 0
            let nameLen = Int(r[off + 9])
            let nameOff = Int(r.u16(off + 10))
            let name = nameLen > 0 ? r.utf16(off + nameOff, units: nameLen) : ""
            var a = Attr(type: type, name: name, nonResident: nonRes, flags: r.u16(off + 12))
            if !nonRes {
                let vlen = Int(r.u32(off + 16)), voff = Int(r.u16(off + 20))
                guard voff + vlen <= len else { throw UzError.corrupt("yerleşik öznitelik taşıyor") }
                a.value = Array(r[(off + voff)..<(off + voff + vlen)])
                a.dataSize = UInt64(vlen)
                a.initSize = a.dataSize
            } else {
                guard len >= 64 else { throw UzError.corrupt("yerleşik olmayan öznitelik kısa") }
                a.startVCN = r.u64(off + 16)
                let rlOff = Int(r.u16(off + 32))
                a.compressionUnit = Int(r.u16(off + 34))
                a.dataSize = r.u64(off + 48)
                a.initSize = r.u64(off + 56)
                guard rlOff < len else { throw UzError.corrupt("run listesi konumu geçersiz") }
                a.runs = try NTFSReader.decodeRuns(Array(r[(off + rlOff)..<(off + len)]), startVCN: a.startVCN)
            }
            out.append(a)
            off += len
        }
        return out
    }

    static func decodeRuns(_ d: [UInt8], startVCN: UInt64) throws -> [Run] {
        var runs: [Run] = []
        var p = 0
        var lcn: Int64 = 0
        var vcn = startVCN
        while p < d.count {
            let h = d[p]
            if h == 0 { break }
            p += 1
            let ls = Int(h & 0x0F), os = Int(h >> 4)
            guard ls > 0, ls <= 8, os <= 8, p + ls + os <= d.count else { throw UzError.corrupt("run listesi bozuk") }
            var length: UInt64 = 0
            for i in 0..<ls { length |= UInt64(d[p + i]) << (8 * UInt64(i)) }
            p += ls
            if os == 0 {
                runs.append(Run(vcn: vcn, lcn: nil, length: length))
            } else {
                var delta: Int64 = 0
                for i in 0..<os { delta |= Int64(d[p + i]) << (8 * Int64(i)) }
                if os < 8 && d[p + os - 1] & 0x80 != 0 { delta -= Int64(1) << (8 * Int64(os)) }
                p += os
                lcn += delta
                guard lcn >= 0 else { throw UzError.corrupt("negatif küme numarası") }
                runs.append(Run(vcn: vcn, lcn: UInt64(lcn), length: length))
            }
            vcn += length
        }
        return runs
    }

    /// Bir kaydın tüm özniteliklerini, öznitelik listesindeki uzantı kayıtlarıyla birlikte döner.
    func attributes(record n: UInt64, base: [UInt8]? = nil) throws -> [Attr] {
        let rec = try base ?? readRecord(n)
        var attrs = try parseAttributes(rec)
        guard let al = attrs.first(where: { $0.type == 0x20 }) else { return attrs }
        let data = al.nonResident ? try readFromRuns(al.runs, offset: 0, length: Int(al.dataSize)) : al.value
        var others: [UInt64] = []
        var p = 0
        while p + 26 <= data.count {
            let len = Int(data.u16(p + 4))
            guard len >= 26 else { break }
            let ref = data.u64(p + 16) & 0xFFFF_FFFF_FFFF
            if ref != n && !others.contains(ref) { others.append(ref) }
            p += len
        }
        for r in others {
            attrs += try parseAttributes(try readRecord(r))
        }
        return attrs
    }

    func merge(_ attrs: [Attr], type: UInt32, name: String) -> Attr? {
        let parts = attrs.filter { $0.type == type && $0.name == name }
        guard var first = parts.first(where: { !$0.nonResident || $0.startVCN == 0 }) else { return nil }
        if first.nonResident {
            first.runs = parts.filter { $0.nonResident }.sorted { $0.startVCN < $1.startVCN }.flatMap { $0.runs }
        }
        return first
    }

    func readAll(_ a: Attr) throws -> [UInt8] {
        if !a.nonResident { return a.value }
        guard a.dataSize <= 512 << 20 else { throw UzError.corrupt("öznitelik olağandışı büyük") }
        return try readFromRuns(a.runs, offset: 0, length: Int(a.dataSize))
    }

    // MARK: Dizinler

    func list(_ ref: String) throws -> [DirEntry] {
        try listStreaming(ref) { _ in }
    }

    func listStreaming(_ ref: String, batch: ([DirEntry]) -> Void) throws {
        _ = try listStreaming(ref, batch: batch) as [DirEntry]
    }

    @discardableResult
    func listStreaming(_ ref: String, batch: ([DirEntry]) -> Void) throws -> [DirEntry] {
        guard ref.hasPrefix("m:"), let n = UInt64(ref.dropFirst(2)) else { throw UzError.notFound("dizin (\(ref))") }
        let attrs = try attributes(record: n)
        guard let root = attrs.first(where: { $0.type == 0x90 && $0.name == "$I30" }) else {
            throw UzError.unsupported("bu kayıt bir dizin değil")
        }
        var entries: [DirEntry] = []
        var seen = Set<String>()

        func addNode(_ buf: [UInt8], nodeStart: Int) {
            let before = entries.count
            defer { if entries.count > before { batch(Array(entries[before...])) } }
            let eOff = Int(buf.u32(nodeStart)), total = Int(buf.u32(nodeStart + 4))
            var p = nodeStart + eOff
            let end = min(nodeStart + total, buf.count)
            while p + 16 <= end {
                let elen = Int(buf.u16(p + 8)), clen = Int(buf.u16(p + 10))
                let flags = buf.u32(p + 12)
                if flags & 2 != 0 || elen < 16 { break }
                let c = p + 16
                if clen >= 66, c + clen <= buf.count {
                    let fileRef = buf.u64(p) & 0xFFFF_FFFF_FFFF
                    let nlen = Int(buf[c + 64])
                    let ns = buf[c + 65]
                    if ns != 2, 66 + nlen * 2 <= clen {
                        let name = buf.utf16(c + 66, units: nlen)
                        let hidden = fileRef == n || (n == 5 && (fileRef < 16 || name.hasPrefix("$")))
                        let key = "\(fileRef)|\(name)"
                        if !hidden, !seen.contains(key) {
                            seen.insert(key)
                            let isDir = buf.u32(c + 56) & 0x1000_0000 != 0
                            entries.append(DirEntry(name: name, isDirectory: isDir, size: isDir ? 0 : buf.u64(c + 48),
                                                    modified: fileTimeDate(buf.u64(c + 16)), ref: "m:\(fileRef)"))
                        }
                    }
                }
                p += elen
            }
        }

        addNode(root.value, nodeStart: 16)
        if let alloc = merge(attrs, type: 0xA0, name: "$I30") {
            let irs = Int(root.value.u32(8))
            guard irs >= 512, irs <= 65536 else { throw UzError.corrupt("dizin indeks boyutu geçersiz") }
            let bitmap = try merge(attrs, type: 0xB0, name: "$I30").map { try readAll($0) }
            let data = try readAll(alloc)
            for i in 0..<(data.count / irs) {
                if let bm = bitmap {
                    guard i / 8 < bm.count, bm[i / 8] & (1 << UInt8(i % 8)) != 0 else { continue }
                }
                var blk = Array(data[(i * irs)..<((i + 1) * irs)])
                guard (try? NTFSReader.fixup(&blk, sig: "INDX")) != nil else { continue }
                addNode(blk, nodeStart: 24)
            }
        }

        // İndeksteki boyutlar Windows tarafından geç güncellenebilir; gerçek boyutu kayıttan al.
        return entries.map { e in
            guard !e.isDirectory, let rn = UInt64(e.ref.dropFirst(2)),
                  let a = try? attributes(record: rn), let d = merge(a, type: 0x80, name: "") else { return e }
            return DirEntry(name: e.name, isDirectory: false, size: d.dataSize, modified: e.modified, ref: e.ref)
        }
    }

    // MARK: Dosya içeriği

    func readFile(_ ref: String, sink: ([UInt8]) throws -> Void) throws {
        guard ref.hasPrefix("m:"), let n = UInt64(ref.dropFirst(2)) else { throw UzError.notFound("dosya (\(ref))") }
        let attrs = try attributes(record: n)
        if let rp = attrs.first(where: { $0.type == 0xC0 }), !rp.nonResident, rp.value.u32(0) == 0x8000_0017 {
            throw UzError.unsupported("Windows sistem sıkıştırması (WOF) ile sıkıştırılmış dosya")
        }
        guard let d = merge(attrs, type: 0x80, name: "") else { throw UzError.notFound("dosya veri akışı") }
        if d.flags & 0x4000 != 0 { throw UzError.unsupported("EFS ile şifrelenmiş dosya") }
        if !d.nonResident {
            if !d.value.isEmpty { try sink(d.value) }
            return
        }
        if d.flags & 0x0001 != 0 && d.compressionUnit > 0 {
            try streamCompressed(d, sink: sink)
        } else {
            try streamPlain(d, sink: sink)
        }
    }

    func streamPlain(_ a: Attr, sink: ([UInt8]) throws -> Void) throws {
        var remaining = a.dataSize
        var produced: UInt64 = 0
        let chunk: UInt64 = 4 << 20
        for r in a.runs {
            if remaining == 0 { break }
            let runBytes = r.length * clusterSize
            var o: UInt64 = 0
            while o < runBytes && remaining > 0 {
                let n = min(chunk, runBytes - o, remaining)
                var data: [UInt8]
                if r.lcn == nil || produced >= a.initSize {
                    data = [UInt8](repeating: 0, count: Int(n))
                } else {
                    data = try src.read(at: r.lcn! * clusterSize + o, count: Int(n))
                    if produced + n > a.initSize {
                        for k in Int(a.initSize - produced)..<Int(n) { data[k] = 0 }
                    }
                }
                try sink(data)
                o += n
                remaining -= n
                produced += n
            }
        }
        if remaining > 0 { throw UzError.corrupt("dosya verisi beklenenden kısa") }
    }

    /// [vcn, vcn+count) aralığını run'lara böler.
    func segments(_ runs: [Run], from vcn: UInt64, count: UInt64) -> [(lcn: UInt64?, count: UInt64)] {
        var out: [(lcn: UInt64?, count: UInt64)] = []
        var cur = vcn
        let end = vcn + count
        for r in runs where r.vcn + r.length > cur && r.vcn < end {
            let s = max(cur, r.vcn)
            let e = min(end, r.vcn + r.length)
            out.append((r.lcn.map { $0 + (s - r.vcn) }, e - s))
            cur = e
        }
        if cur < end { out.append((nil, end - cur)) }
        return out
    }

    func streamCompressed(_ a: Attr, sink: ([UInt8]) throws -> Void) throws {
        let unitClusters = UInt64(1) << UInt64(a.compressionUnit)
        let unitBytes = unitClusters * clusterSize
        var remaining = a.dataSize
        var vcn: UInt64 = 0
        while remaining > 0 {
            let segs = segments(a.runs, from: vcn, count: unitClusters)
            let allocated = segs.reduce(UInt64(0)) { $0 + ($1.lcn == nil ? 0 : $1.count) }
            var raw = [UInt8]()
            for s in segs {
                guard let l = s.lcn else { continue }
                raw += try src.read(at: l * clusterSize, count: Int(s.count * clusterSize))
            }
            var out: [UInt8]
            if allocated == 0 {
                out = [UInt8](repeating: 0, count: Int(unitBytes))
            } else if allocated >= unitClusters {
                out = raw
            } else {
                out = try LZNT1.decompress(raw, outputSize: Int(unitBytes))
            }
            let n = min(unitBytes, remaining)
            try sink(Array(out.prefix(Int(n))))
            remaining -= n
            vcn += unitClusters
        }
    }
}
