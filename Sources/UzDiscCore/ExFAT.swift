import Foundation

typealias ByteRun = (offset: UInt64, length: UInt64)

/// Salt okunur exFAT okuyucu.
/// ref biçimi: dizin "d:<küme>:<uzunluk>:<noFatChain>", dosya "f:<küme>:<uzunluk>:<geçerliUzunluk>:<noFatChain>".
final class ExFATReader: FileSystemReader {
    let kind = FSKind.exfat
    private(set) var label: String?
    let src: ByteSource
    let bytesPerSector: UInt64
    let clusterSize: UInt64
    let fatOffset: UInt64
    let heapOffset: UInt64
    let clusterCount: UInt32
    let rootCluster: UInt32
    let totalBytes: UInt64

    var rootRef: String { "d:\(rootCluster):0:0" }

    init(_ src: ByteSource) throws {
        self.src = src
        let b = try src.read(at: 0, count: 512)
        guard b.ascii(3, 8) == "EXFAT   " else { throw UzError.corrupt("exFAT imzası bulunamadı") }
        let bpsShift = b[108], spcShift = b[109]
        guard (9...12).contains(bpsShift), Int(bpsShift) + Int(spcShift) <= 25 else {
            throw UzError.corrupt("exFAT önyükleme kesimi geçersiz")
        }
        bytesPerSector = UInt64(1) << UInt64(bpsShift)
        clusterSize = bytesPerSector << UInt64(spcShift)
        fatOffset = UInt64(b.u32(80)) * bytesPerSector
        heapOffset = UInt64(b.u32(88)) * bytesPerSector
        clusterCount = b.u32(92)
        rootCluster = b.u32(96)
        totalBytes = b.u64(72) * bytesPerSector
        guard clusterCount > 0, clusterCount < 0xFFFF_FFF0,
              rootCluster >= 2, rootCluster < clusterCount + 2 else {
            throw UzError.corrupt("exFAT küme bilgileri geçersiz")
        }
        if let raw = try? dirBytes(cluster: rootCluster, length: 0, noFat: false) {
            var i = 0
            while i + 32 <= raw.count {
                let t = raw[i]
                if t == 0 { break }
                if t == 0x83 {
                    label = raw.utf16(i + 2, units: min(Int(raw[i + 1]), 11))
                    break
                }
                i += 32
            }
        }
    }

    func clusterOffset(_ c: UInt32) -> UInt64 { heapOffset + UInt64(c - 2) * clusterSize }

    func fatEntry(_ c: UInt32) throws -> UInt32 {
        try src.read(at: fatOffset + UInt64(c) * 4, count: 4).u32(0)
    }

    /// Bir küme zincirini bitişik bayt aralıklarına çevirir. `length == 0` ve FAT zinciri → zincir sonuna kadar.
    func clusterRuns(start: UInt32, length: UInt64, noFat: Bool) throws -> [ByteRun] {
        guard start >= 2 else {
            if length == 0 { return [] }
            throw UzError.corrupt("dosyanın başlangıç kümesi geçersiz")
        }
        if noFat {
            guard length > 0 else { return [] }
            let n = (length + clusterSize - 1) / clusterSize
            guard UInt64(start) - 2 + n <= UInt64(clusterCount) else {
                throw UzError.corrupt("kümeler birim dışına taşıyor")
            }
            return [(clusterOffset(start), n * clusterSize)]
        }
        let need: UInt64? = length > 0 ? (length + clusterSize - 1) / clusterSize : nil
        var runs: [ByteRun] = []
        var c = start
        var count: UInt64 = 0
        while true {
            guard c >= 2, c < clusterCount + 2 else { throw UzError.corrupt("geçersiz küme zinciri") }
            let off = clusterOffset(c)
            if let last = runs.last, last.offset + last.length == off {
                runs[runs.count - 1].length += clusterSize
            } else {
                runs.append((off, clusterSize))
            }
            count += 1
            if let need, count >= need { break }
            guard count <= UInt64(clusterCount) else { throw UzError.corrupt("küme zincirinde döngü") }
            let next = try fatEntry(c)
            if next >= 0xFFFF_FFF8 { break }
            guard next >= 2, next != 0xFFFF_FFF7 else { throw UzError.corrupt("küme zinciri kırık") }
            c = next
        }
        if let need, count < need { throw UzError.corrupt("küme zinciri beklenenden kısa") }
        return runs
    }

    func dirBytes(cluster: UInt32, length: UInt64, noFat: Bool) throws -> [UInt8] {
        let runs = try clusterRuns(start: cluster, length: length, noFat: noFat)
        let total = length > 0 ? length : runs.reduce(0) { $0 + $1.length }
        guard total <= 256 << 20 else { throw UzError.corrupt("dizin olağandışı büyük") }
        var out = [UInt8]()
        out.reserveCapacity(Int(total))
        try streamRuns(src, runs, length: total, valid: total) { out += $0 }
        return out
    }

    func list(_ ref: String) throws -> [DirEntry] {
        var all: [DirEntry] = []
        try listStreaming(ref) { all += $0 }
        return all
    }

    func listStreaming(_ ref: String, batch: ([DirEntry]) -> Void) throws {
        let p = ref.split(separator: ":")
        guard p.count == 4, p[0] == "d", let c = UInt32(p[1]), let len = UInt64(p[2]) else {
            throw UzError.notFound("dizin (\(ref))")
        }
        let runs = try clusterRuns(start: c, length: len, noFat: p[3] == "1")
        let total = len > 0 ? len : runs.reduce(0) { $0 + $1.length }
        guard total <= 256 << 20 else { throw UzError.corrupt("dizin olağandışı büyük") }
        var buf: [UInt8] = []
        var ended = false
        do {
            try streamRuns(src, runs, length: total, valid: total, chunk: 512 * 1024) { data in
                buf += data
                let r = parseSets(buf, final: false)
                if r.consumed > 0 { buf.removeFirst(r.consumed) }
                if !r.entries.isEmpty { batch(r.entries) }
                if r.ended { ended = true; throw StopReading() }
            }
        } catch is StopReading {}
        if !ended && !buf.isEmpty {
            let r = parseSets(buf, final: true)
            if !r.entries.isEmpty { batch(r.entries) }
        }
    }

    func parse(_ d: [UInt8]) -> [DirEntry] { parseSets(d, final: true).entries }

    /// Tamamlanmış girdi kümelerini ayrıştırır; `consumed` işlenen bayt sayısıdır (yarım küme sonraki parçaya kalır).
    func parseSets(_ d: [UInt8], final: Bool) -> (entries: [DirEntry], consumed: Int, ended: Bool) {
        var out: [DirEntry] = []
        var i = 0
        while i + 32 <= d.count {
            let t = d[i]
            if t == 0 { return (out, i, true) }
            guard t == 0x85 else { i += 32; continue }
            let sec = Int(d[i + 1])
            let setEnd = i + (sec + 1) * 32
            if setEnd > d.count && !final { return (out, i, false) }
            guard sec >= 2, setEnd <= d.count, d[i + 32] == 0xC0 else { i += 32; continue }
            let attrs = d.u16(i + 4)
            let mtime = d.u32(i + 12)
            let s = i + 32
            let noFat = d[s + 1] & 0x02 != 0
            let nameLen = Int(d[s + 3])
            let valid = d.u64(s + 8)
            let first = d.u32(s + 20)
            let dlen = d.u64(s + 24)
            var units = [UInt16]()
            var j = s + 32
            while j < setEnd {
                if d[j] == 0xC1 {
                    for k in 0..<15 { units.append(d.u16(j + 2 + k * 2)) }
                }
                j += 32
            }
            let name = String(decoding: units.prefix(nameLen), as: UTF16.self)
            let isDir = attrs & 0x10 != 0
            let nf = noFat ? "1" : "0"
            let ref = isDir ? "d:\(first):\(dlen):\(nf)" : "f:\(first):\(dlen):\(valid):\(nf)"
            if !name.isEmpty {
                out.append(DirEntry(name: name, isDirectory: isDir, size: isDir ? 0 : dlen,
                                    modified: dosDateTime(mtime), ref: ref))
            }
            i = setEnd
        }
        return (out, final ? d.count : i, false)
    }

    func readFile(_ ref: String, sink: ([UInt8]) throws -> Void) throws {
        let p = ref.split(separator: ":")
        guard p.count == 5, p[0] == "f", let c = UInt32(p[1]), let len = UInt64(p[2]), let valid = UInt64(p[3]) else {
            throw UzError.notFound("dosya (\(ref))")
        }
        if len == 0 { return }
        let runs = try clusterRuns(start: c, length: len, noFat: p[4] == "1")
        try streamRuns(src, runs, length: len, valid: min(valid, len), sink: sink)
    }
}

/// Bayt aralıklarını en fazla 4 MB'lık parçalarla okur; `valid` sonrasını sıfır olarak verir.
struct StopReading: Error {}

func streamRuns(_ src: ByteSource, _ runs: [ByteRun], length: UInt64, valid: UInt64, chunk: UInt64 = 4 << 20,
                sink: ([UInt8]) throws -> Void) throws {
    var remaining = length
    var produced: UInt64 = 0
    for r in runs {
        var o: UInt64 = 0
        while o < r.length && remaining > 0 {
            let n = min(chunk, r.length - o, remaining)
            var data: [UInt8]
            if produced >= valid {
                data = [UInt8](repeating: 0, count: Int(n))
            } else {
                data = try src.read(at: r.offset + o, count: Int(n))
                if produced + n > valid {
                    let keep = Int(valid - produced)
                    for k in keep..<Int(n) { data[k] = 0 }
                }
            }
            try sink(data)
            o += n
            remaining -= n
            produced += n
        }
        if remaining == 0 { break }
    }
    if remaining > 0 { throw UzError.corrupt("dosya verisi beklenenden kısa") }
}
