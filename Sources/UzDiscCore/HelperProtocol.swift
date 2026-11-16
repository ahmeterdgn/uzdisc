import Foundation

/// Uygulama ile uzdisc-helper arasındaki satır tabanlı JSON protokolü.
public struct HelperRequest: Codable, Sendable {
    public var id: Int
    public var op: String // "partitions" | "open" | "list" | "copy" | "cancel"
    public var partition: Int?
    public var ref: String?
    public var items: [DirEntry]?
    public var dest: String?
    public var device: String?

    public init(id: Int, op: String, partition: Int? = nil, ref: String? = nil, items: [DirEntry]? = nil,
                dest: String? = nil, device: String? = nil) {
        self.device = device
        self.id = id
        self.op = op
        self.partition = partition
        self.ref = ref
        self.items = items
        self.dest = dest
    }
}

public struct VolumeInfo: Codable, Hashable, Sendable {
    public var fileSystem: FSKind
    public var fsName: String
    public var label: String?
    public var rootRef: String
    public var totalBytes: UInt64

    public init(fileSystem: FSKind, fsName: String, label: String?, rootRef: String, totalBytes: UInt64) {
        self.fileSystem = fileSystem
        self.fsName = fsName
        self.label = label
        self.rootRef = rootRef
        self.totalBytes = totalBytes
    }
}

public struct HelperResponse: Codable, Sendable {
    public var id: Int
    public var ok: Bool
    public var event: String?
    public var error: String?
    public var partitions: [PartitionInfo]?
    public var volume: VolumeInfo?
    public var entries: [DirEntry]?
    public var progress: CopyProgress?
    public var summary: CopySummary?
    public var deviceSize: UInt64?
    public var ref: String?
    public var scan: ScanStats?
    public var ioBytesPerSec: Double?
    public var ioOpsPerSec: Double?

    public init(ref: String? = nil, scan: ScanStats? = nil, id: Int, ok: Bool, event: String? = nil, error: String? = nil, partitions: [PartitionInfo]? = nil,
                volume: VolumeInfo? = nil, entries: [DirEntry]? = nil, progress: CopyProgress? = nil,
                summary: CopySummary? = nil, deviceSize: UInt64? = nil) {
        self.id = id
        self.ok = ok
        self.event = event
        self.error = error
        self.partitions = partitions
        self.volume = volume
        self.entries = entries
        self.progress = progress
        self.summary = summary
        self.deviceSize = deviceSize
        self.ref = ref
        self.scan = scan
    }
}

public struct ScanStats: Codable, Hashable, Sendable {
    public var dirs: Int
    public var files: Int
    public var bytes: UInt64
    public var errors: Int
    public var current: String
    public var done: Bool

    public init(dirs: Int = 0, files: Int = 0, bytes: UInt64 = 0, errors: Int = 0, current: String = "", done: Bool = false) {
        self.dirs = dirs
        self.files = files
        self.bytes = bytes
        self.errors = errors
        self.current = current
        self.done = done
    }
}

extension FileSystemReader {
    public var volumeInfo: VolumeInfo {
        let fsName: String
        if let f = self as? FATReader { fsName = f.fatName } else { fsName = kind.displayName }
        return VolumeInfo(fileSystem: kind, fsName: fsName, label: label, rootRef: rootRef, totalBytes: totalBytes)
    }
}

public func sortEntries(_ e: [DirEntry]) -> [DirEntry] {
    e.sorted { a, b in
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
