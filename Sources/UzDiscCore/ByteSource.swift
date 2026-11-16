import Foundation
import Darwin

/// Salt okunur bayt kaynağı: bir disk aygıtı, kalıp dosyası ya da bunların bir dilimi.
public protocol ByteSource: AnyObject {
    var size: UInt64 { get }
    var sectorSize: Int { get }
    func read(at offset: UInt64, count: Int) throws -> [UInt8]
}

/// Bir dosyayı ya da /dev/rdiskN aygıtını **yalnızca O_RDONLY** ile açar.
/// Bu sınıfta yazma yapan hiçbir kod yoktur; UzDisc kaynağa asla yazmaz.
public final class FileByteSource: ByteSource {
    public let path: String
    public let size: UInt64
    public let sectorSize: Int
    public let isDevice: Bool

    private let fd: Int32
    private let align: UInt64
    /// Yavaş USB bağlantılarında her istek pahalı: az sayıda büyük okuma yap.
    private let chunkSize: UInt64 = 512 * 1024
    private var cache: [UInt64: [UInt8]] = [:]
    private var cacheOrder: [UInt64] = []
    private let maxChunks = 384 // 192 MB önbellek
    private let lock = NSLock()
    private let inflightLock = NSLock()
    private var inflightStart: Date?
    private var counterBytes: UInt64 = 0
    private var counterOps: UInt64 = 0

    /// Toplam okunan bayt ve okuma işlemi sayısı (hız göstergesi için).
    public var ioCounters: (bytes: UInt64, ops: UInt64) {
        inflightLock.lock(); defer { inflightLock.unlock() }
        return (counterBytes, counterOps)
    }

    /// Şu an süren bir okuma varsa kaç saniyedir sürdüğü (disk donmalarını tespit etmek için).
    public var stalledSeconds: Double {
        inflightLock.lock(); defer { inflightLock.unlock() }
        return inflightStart.map { Date().timeIntervalSince($0) } ?? 0
    }

    // <sys/disk.h>: _IOR('d', 24, uint32_t) ve _IOR('d', 25, uint64_t)
    private static let DKIOCGETBLOCKSIZE: UInt = 0x4004_6418
    private static let DKIOCGETBLOCKCOUNT: UInt = 0x4008_6419

    public init(path: String) throws {
        self.path = path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            let msg = String(cString: strerror(errno))
            if errno == EPERM {
                // Root olsak bile macOS gizlilik koruması (TCC) harici disklere ham erişimi engeller.
                throw UzError.io(L("macOS bu diske erişimi engelledi (\(msg)). UzDisc'e Tam Disk Erişimi izni verilmesi gerekiyor.",
                                   "macOS blocked access to this disk (\(msg)). UzDisc needs Full Disk Access."))
            }
            if errno == EACCES {
                throw UzError.io(L("\(path) için izin yok (\(msg)). Diskleri okumak yönetici izni gerektirir.",
                                   "No permission for \(path) (\(msg)). Reading disks requires administrator permission."))
            }
            throw UzError.io("\(path) açılamadı: \(msg)")
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw UzError.io("\(path) bilgileri okunamadı")
        }
        if (st.st_mode & S_IFMT) == S_IFREG {
            size = UInt64(st.st_size)
            sectorSize = 512
            align = 512
            isDevice = false
        } else {
            var bs: UInt32 = 0
            var bc: UInt64 = 0
            guard ioctl(fd, FileByteSource.DKIOCGETBLOCKSIZE, &bs) == 0,
                  ioctl(fd, FileByteSource.DKIOCGETBLOCKCOUNT, &bc) == 0, bs > 0 else {
                close(fd)
                throw UzError.io("\(path) disk boyutu alınamadı")
            }
            sectorSize = Int(bs)
            size = UInt64(bs) * bc
            align = UInt64(max(Int(bs), 512))
            isDevice = true
        }
        self.fd = fd
    }

    deinit { close(fd) }

    public func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        if count == 0 { return [] }
        guard count > 0, offset <= size, UInt64(count) <= size - offset else {
            throw UzError.io("disk sınırı dışında okuma (konum \(offset), \(count) bayt)")
        }
        lock.lock()
        defer { lock.unlock() }

        // Büyük okumalar önbelleği atlar (dosya kopyalama).
        if count >= 1024 * 1024 {
            let start = offset / align * align
            let end = roundUp(offset + UInt64(count))
            let buf = try rawRead(start, Int(end - start))
            let s = Int(offset - start)
            return Array(buf[s..<(s + count)])
        }

        var out = [UInt8]()
        out.reserveCapacity(count)
        var pos = offset
        let end = offset + UInt64(count)
        while pos < end {
            let idx = pos / chunkSize
            let chunk = try loadChunk(idx)
            let inChunk = Int(pos - idx * chunkSize)
            let take = min(Int(chunkSize) - inChunk, Int(end - pos))
            out.append(contentsOf: chunk[inChunk..<(inChunk + take)])
            pos += UInt64(take)
        }
        return out
    }

    private func roundUp(_ v: UInt64) -> UInt64 {
        let r = (v + align - 1) / align * align
        return min(r, (size + align - 1) / align * align)
    }

    private func loadChunk(_ idx: UInt64) throws -> [UInt8] {
        if let c = cache[idx] { return c }
        let start = idx * chunkSize
        let len = Int(min(chunkSize, roundUp(size) - start))
        var c = try rawRead(start, len)
        if c.count < Int(chunkSize) { c += [UInt8](repeating: 0, count: Int(chunkSize) - c.count) }
        cache[idx] = c
        cacheOrder.append(idx)
        if cacheOrder.count > maxChunks {
            cache[cacheOrder.removeFirst()] = nil
        }
        return c
    }

    private func rawRead(_ off: UInt64, _ len: Int) throws -> [UInt8] {
        inflightLock.lock(); inflightStart = Date(); inflightLock.unlock()
        defer {
            inflightLock.lock()
            inflightStart = nil
            counterBytes += UInt64(len)
            counterOps += 1
            inflightLock.unlock()
        }
        var buf = [UInt8](repeating: 0, count: len)
        var done = 0
        var retries = 0
        try buf.withUnsafeMutableBytes { p in
            while done < len {
                let r = pread(fd, p.baseAddress! + done, len - done, off_t(off) + off_t(done))
                if r < 0 {
                    if errno == EINTR { continue }
                    if errno == EIO && retries < 3 { retries += 1; usleep(200_000); continue }
                    throw UzError.io("\(path) konum \(off + UInt64(done)): \(String(cString: strerror(errno)))")
                }
                if r == 0 { break } // dosya sonu: geri kalanı sıfır
                done += r
            }
        }
        return buf
    }
}

/// Bir kaynağın belirli bir aralığı (ör. bir bölüm).
public final class SliceByteSource: ByteSource {
    public let base: ByteSource
    public let offset: UInt64
    public let size: UInt64
    public var sectorSize: Int { base.sectorSize }

    public init(base: ByteSource, offset: UInt64, size: UInt64) {
        self.base = base
        self.offset = offset
        let avail = base.size > offset ? base.size - offset : 0
        self.size = min(size, avail)
    }

    public func read(at o: UInt64, count: Int) throws -> [UInt8] {
        guard o <= size, UInt64(count) <= size - o else {
            throw UzError.io("bölüm sınırı dışında okuma (konum \(o), \(count) bayt)")
        }
        return try base.read(at: offset + o, count: count)
    }
}

/// Bellekteki bayt dizisi (testler için).
public final class MemoryByteSource: ByteSource {
    public let bytes: [UInt8]
    public var size: UInt64 { UInt64(bytes.count) }
    public let sectorSize: Int

    public init(_ bytes: [UInt8], sectorSize: Int = 512) {
        self.bytes = bytes
        self.sectorSize = sectorSize
    }

    public func read(at o: UInt64, count: Int) throws -> [UInt8] {
        guard o <= size, UInt64(count) <= size - o else { throw UzError.io("sınır dışı okuma") }
        return Array(bytes[Int(o)..<(Int(o) + count)])
    }
}
