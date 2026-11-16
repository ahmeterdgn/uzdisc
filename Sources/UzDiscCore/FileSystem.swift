import Foundation

public enum FSKind: String, Codable, Hashable, Sendable {
    case exfat, fat, ntfs

    public var displayName: String {
        switch self {
        case .exfat: return "exFAT"
        case .fat: return "FAT"
        case .ntfs: return "NTFS"
        }
    }
}

/// Bir dizindeki öğe. `ref`, dosya sistemine özgü opak bir konum bilgisidir.
public struct DirEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String { ref + "|" + name }
    public let name: String
    public let isDirectory: Bool
    public let size: UInt64
    public let modified: Date?
    public let ref: String

    public init(name: String, isDirectory: Bool, size: UInt64, modified: Date?, ref: String) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.ref = ref
    }
}

public protocol FileSystemReader: AnyObject {
    var kind: FSKind { get }
    var label: String? { get }
    var rootRef: String { get }
    var totalBytes: UInt64 { get }
    func list(_ ref: String) throws -> [DirEntry]
    /// Dizini okurken bulunan öğeleri parça parça bildirir (yavaş disklerde liste hemen dolmaya başlar).
    func listStreaming(_ ref: String, batch: ([DirEntry]) -> Void) throws
    /// Dosya içeriğini parça parça `sink`'e verir. `sink` hata fırlatırsa okuma durur.
    func readFile(_ ref: String, sink: ([UInt8]) throws -> Void) throws
}

public enum FSDetector {
    public static func detect(_ b: [UInt8]) -> FSKind? {
        guard b.count >= 512 else { return nil }
        let oem = b.ascii(3, 8)
        if oem == "EXFAT   " { return .exfat }
        if oem == "NTFS    " { return .ntfs }
        guard b.u16(510) == 0xAA55 else { return nil }
        if b.ascii(82, 5) == "FAT32" || b.ascii(54, 5) == "FAT16" || b.ascii(54, 5) == "FAT12" {
            return .fat
        }
        // Etiketsiz FAT: BPB alanlarını sıkı biçimde doğrula.
        let bps = b.u16(11)
        let spc = b[13]
        let nf = b[16]
        let media = b[21]
        if b[0] == 0xEB || b[0] == 0xE9,
           [512, 1024, 2048, 4096].contains(bps),
           spc != 0, spc & (spc &- 1) == 0,
           nf == 1 || nf == 2,
           b.u16(14) > 0,
           media == 0xF0 || media >= 0xF8 {
            return .fat
        }
        return nil
    }
}

public enum FileSystems {
    public static func open(_ src: ByteSource, kind: FSKind? = nil) throws -> FileSystemReader {
        let boot = try src.read(at: 0, count: 512)
        guard let k = kind ?? FSDetector.detect(boot) else {
            throw UzError.unsupported(L("tanınmayan dosya sistemi (UzDisc exFAT, FAT ve NTFS okuyabilir)", "unrecognized file system (UzDisc reads exFAT, FAT and NTFS)"))
        }
        switch k {
        case .exfat: return try ExFATReader(src)
        case .fat: return try FATReader(src)
        case .ntfs: return try NTFSReader(src)
        }
    }
}

extension FileSystemReader {
    public func listStreaming(_ ref: String, batch: ([DirEntry]) -> Void) throws {
        batch(try list(ref))
    }

    /// "/Belgeler/rapor.pdf" gibi bir yolu çözer (komut satırı için).
    public func resolve(path: String) throws -> DirEntry? {
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if parts.isEmpty { return nil }
        var ref = rootRef
        var found: DirEntry?
        for (i, p) in parts.enumerated() {
            let items = try list(ref)
            guard let e = items.first(where: { $0.name == p })
                    ?? items.first(where: { $0.name.lowercased() == p.lowercased() }) else {
                throw UzError.notFound(path)
            }
            if i < parts.count - 1 && !e.isDirectory { throw UzError.notFound(path) }
            found = e
            ref = e.ref
        }
        return found
    }
}
