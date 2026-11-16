import Foundation

public struct CopyProgress: Codable, Hashable, Sendable {
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    public var filesDone: Int
    public var filesTotal: Int
    public var currentFile: String

    public init(bytesDone: UInt64 = 0, bytesTotal: UInt64 = 0, filesDone: Int = 0, filesTotal: Int = 0, currentFile: String = "") {
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.currentFile = currentFile
    }
}

public struct CopySummary: Codable, Hashable, Sendable {
    public var files: Int
    public var bytes: UInt64
    public var errors: [String]
    public var cancelled: Bool
    public var destination: String
    public var createdPaths: [String]

    public init(files: Int, bytes: UInt64, errors: [String], cancelled: Bool, destination: String, createdPaths: [String]) {
        self.files = files
        self.bytes = bytes
        self.errors = errors
        self.cancelled = cancelled
        self.destination = destination
        self.createdPaths = createdPaths
    }
}

/// Seçilen öğeleri hedef klasöre kopyalar. Kaynak diske hiçbir şey yazmaz;
/// yazma işlemleri yalnızca kullanıcının seçtiği hedef klasörde yapılır.
public final class Extractor {
    final class Node {
        let entry: DirEntry
        var children: [Node] = []
        init(_ e: DirEntry) { entry = e }
    }

    let fs: FileSystemReader
    public var isCancelled: () -> Bool = { false }
    public var onProgress: (CopyProgress) -> Void = { _ in }
    /// Root olarak çalışırken oluşturulan dosyaları bu kullanıcıya devret.
    public var owner: (uid: uid_t, gid: gid_t)?

    public init(fs: FileSystemReader) { self.fs = fs }

    public static func safeName(_ s: String) -> String {
        var n = s.replacingOccurrences(of: "/", with: ":").replacingOccurrences(of: "\0", with: "")
        if n == "." || n == ".." || n.trimmingCharacters(in: .whitespaces).isEmpty { n = L("adsız", "untitled") }
        return n
    }

    static func uniqueURL(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: url.path) { return url }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var i = 2
        repeat {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            i += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }

    public func copy(_ items: [DirEntry], to dest: URL) -> CopySummary {
        var errors: [String] = []
        var progress = CopyProgress()
        var created: [String] = []

        // 1. Ağacı çıkar ve toplam boyutu hesapla.
        func build(_ e: DirEntry, path: String) -> Node {
            let n = Node(e)
            if e.isDirectory {
                if isCancelled() { return n }
                do {
                    for c in try fs.list(e.ref) { n.children.append(build(c, path: path + "/" + c.name)) }
                } catch {
                    errors.append("\(path): \(error)")
                }
            } else {
                progress.filesTotal += 1
                progress.bytesTotal += e.size
            }
            return n
        }
        let roots = items.map { build($0, path: $0.name) }
        onProgress(progress)

        var lastReport = Date.distantPast
        func report(force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = now
                onProgress(progress)
            }
        }

        // 2. Yaz.
        func write(_ n: Node, into dir: URL, path: String) {
            if isCancelled() { return }
            let url = Extractor.uniqueURL(Extractor.safeName(n.entry.name), in: dir)
            if dir == dest { created.append(url.path) }
            if n.entry.isDirectory {
                do {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    if let o = owner { chown(url.path, o.uid, o.gid) }
                } catch {
                    errors.append("\(path): klasör oluşturulamadı (\(error.localizedDescription))")
                    return
                }
                for c in n.children { write(c, into: url, path: path + "/" + c.entry.name) }
                if let m = n.entry.modified {
                    try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: url.path)
                }
                return
            }
            progress.currentFile = path
            report(force: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let h = FileHandle(forWritingAtPath: url.path) else {
                errors.append("\(path): hedef dosya oluşturulamadı")
                return
            }
            var written: UInt64 = 0
            do {
                try fs.readFile(n.entry.ref) { chunk in
                    if self.isCancelled() { throw UzError.cancelled }
                    try h.write(contentsOf: Data(chunk))
                    written += UInt64(chunk.count)
                    progress.bytesDone += UInt64(chunk.count)
                    report()
                }
                try h.close()
                if let o = owner { chown(url.path, o.uid, o.gid) }
                if let m = n.entry.modified {
                    try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: url.path)
                }
                progress.filesDone += 1
            } catch {
                try? h.close()
                try? FileManager.default.removeItem(at: url)
                if case UzError.cancelled = error { return }
                errors.append("\(path): \(error)")
                // Toplamı tutarlı tut: okunamayan kısmı ilerlemeden say.
                if n.entry.size > written { progress.bytesDone += n.entry.size - written }
            }
            report()
        }
        for r in roots { write(r, into: dest, path: r.entry.name) }
        report(force: true)

        return CopySummary(files: progress.filesDone, bytes: progress.bytesDone, errors: errors,
                           cancelled: isCancelled(), destination: dest.path, createdPaths: created)
    }
}
