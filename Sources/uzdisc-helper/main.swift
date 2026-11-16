import Foundation
import Darwin
import UzDiscCore

// uzdisc-helper: diski salt okunur açar. Uygulama tarafından yönetici izniyle başlatıldığında
// aygıtı açar açmaz root yetkisini bırakır (setuid), kalan her şey kullanıcı olarak çalışır.

let usage = """
UzDisc yardımcı aracı — diskleri salt okunur okur.

Kullanım:
  uzdisc-helper disks                              Diskleri listele
  uzdisc-helper parts <aygıt|kalıp>                Bölümleri listele
  uzdisc-helper ls <aygıt|kalıp> [-p N] [yol]      Klasör içeriğini listele
  uzdisc-helper cp <aygıt|kalıp> [-p N] <yol> <hedef klasör>
                                                   Dosya/klasörü Mac'e kopyala
  uzdisc-helper serve --device <yol> [--uid U --gid G] [--in FIFO --out FIFO]

Aygıt örneği: /dev/rdisk5 (okumak için sudo gerekir). -p ile bölüm numarası seçilir.
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("hata: " + msg + "\n").utf8))
    exit(1)
}

func human(_ n: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

func openVolume(_ path: String, part: Int?) throws -> (FileSystemReader, [PartitionInfo]) {
    let src = try FileByteSource(path: path)
    let parts = try PartitionScanner.scan(src)
    let candidates = parts.filter { $0.fileSystem != nil }
    let chosen: PartitionInfo?
    if let part { chosen = parts.first { $0.index == part } } else { chosen = candidates.first }
    guard let p = chosen else {
        throw UzError.notFound("okunabilir bölüm yok. 'uzdisc-helper parts \(path)' ile bakın")
    }
    let fs = try FileSystems.open(SliceByteSource(base: src, offset: p.offset, size: p.length))
    return (fs, parts)
}

func parseOpts(_ args: [String]) -> (positional: [String], part: Int?) {
    var pos: [String] = []
    var part: Int?
    var i = 0
    while i < args.count {
        if args[i] == "-p", i + 1 < args.count { part = Int(args[i + 1]); i += 2; continue }
        pos.append(args[i])
        i += 1
    }
    return (pos, part)
}

// MARK: - serve

/// Satır tabanlı JSON sunucusu.
/// - Yönetici oturumu (`--device` yok): root olarak kalır, yalnızca /dev/(r)diskN aygıtlarını O_RDONLY açar.
///   Kopyalama sırasında etkin kimliği kullanıcıya düşürür, böylece dosyalar kullanıcı adına yazılır.
/// - Kalıp dosyası (`--device` var): kullanıcı olarak çalışır.
final class Server {
    var src: FileByteSource?
    var parts: [PartitionInfo]?
    var fs: FileSystemReader?
    let uid: uid_t?
    let gid: gid_t?
    let log: FileHandle?
    let outLock = NSLock()
    let stateLock = NSLock()
    var cancelCopyFlag = false
    var scanGeneration = 0
    var copying = false
    // Tarama durumu (öncelik ve duraklatma için paylaşılır)
    var scanSeen = Set<String>()
    var scanChildDirs: [String: [(String, String)]] = [:]
    var priority: [(String, String)] = []
    var scanPaused = false
    var priorityLabel = ""
    let work = DispatchQueue(label: "uzdisc.work")       // aygıt/bölüm/liste
    let listQ = DispatchQueue(label: "uzdisc.list")      // klasör listeleme (tarama sürerken de hızlı)
    let copyQ = DispatchQueue(label: "uzdisc.copy")
    let scanQ = DispatchQueue(label: "uzdisc.scan")
    let previewQ = DispatchQueue(label: "uzdisc.preview")
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    init(src: FileByteSource?, uid: uid_t?, gid: gid_t?, log: FileHandle?) {
        self.src = src
        self.uid = uid
        self.gid = gid
        self.log = log
    }

    func logLine(_ s: String) {
        guard let log else { return }
        let df = ISO8601DateFormatter()
        log.write(Data("\(df.string(from: Date())) \(s)\n".utf8))
    }

    func locked<T>(_ f: () -> T) -> T { stateLock.lock(); defer { stateLock.unlock() }; return f() }

    func send(_ r: HelperResponse) {
        guard var d = try? encoder.encode(r) else { logLine("kodlama hatası id=\(r.id)"); return }
        d.append(0x0A)
        outLock.lock()
        FileHandle.standardOutput.write(d)
        outLock.unlock()
    }

    func run() {
        // Disk izleyicisi: her saniye okuma hızını bildir; bir okuma 8 sn'den uzun sürerse donma uyarısı ver.
        Thread.detachNewThread { [weak self] in
            var reported = false
            var last: (bytes: UInt64, ops: UInt64) = (0, 0)
            var lastSrc: ObjectIdentifier?
            while let self {
                Thread.sleep(forTimeInterval: 1)
                let src = self.locked({ self.src })
                if let src {
                    let c = src.ioCounters
                    if lastSrc != ObjectIdentifier(src) { last = c; lastSrc = ObjectIdentifier(src) }
                    var r = HelperResponse(id: 0, ok: true, event: "io")
                    r.ioBytesPerSec = Double(c.bytes &- last.bytes)
                    r.ioOpsPerSec = Double(c.ops &- last.ops)
                    last = c
                    self.send(r)
                }
                let s = src?.stalledSeconds ?? 0
                if s > 8 {
                    self.send(HelperResponse(id: 0, ok: true, event: "stall", deviceSize: UInt64(s)))
                    if !reported { self.logLine("disk \(Int(s)) sn'dir yanıt vermiyor"); reported = true }
                } else if reported {
                    self.send(HelperResponse(id: 0, ok: true, event: "stall", deviceSize: 0))
                    reported = false
                }
            }
        }
        let group = DispatchGroup()
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let req = try? decoder.decode(HelperRequest.self, from: Data(line.utf8)) else { continue }
            switch req.op {
            case "cancel": locked { cancelCopyFlag = true }; continue
            case "cancelScan": locked { scanGeneration += 1 }; continue
            case "pauseScan": locked { scanPaused = true }; continue
            case "resumeScan": locked { scanPaused = false }; continue
            case "prioritize":
                if let r = req.ref { locked { enqueuePriority(r, req.dest ?? "", depth: 0); scanPaused = false } }
                continue
            default: break
            }
            let q: DispatchQueue
            switch req.op {
            case "list": q = listQ
            case "copy": q = copyQ
            case "scan": q = scanQ
            case "extract": q = previewQ
            default: q = work
            }
            group.enter()
            let isWork = q === work
            q.async {
                if !isWork { self.work.sync {} } // önce bekleyen aygıt/bölüm işlemleri bitsin
                self.handle(req)
                group.leave()
            }
        }
        locked { cancelCopyFlag = true; scanGeneration += 1 }
        group.wait()
    }

    func handle(_ req: HelperRequest) {
        let t0 = Date()
        logLine("→ \(req.op) \(req.ref ?? req.device ?? "")")
        defer { logLine("\(req.op) \(req.ref ?? req.device ?? "") \(String(format: "%.2f", Date().timeIntervalSince(t0)))s") }
        do {
            switch req.op {
            case "device":
                guard let path = req.device, path.range(of: #"^/dev/r?disk[0-9]+$"#, options: .regularExpression) != nil else {
                    throw UzError.unsupported("geçersiz aygıt yolu")
                }
                guard !locked({ copying }) else { throw UzError.unsupported("kopyalama sürerken disk değiştirilemez") }
                locked { scanGeneration += 1 }
                // macOS gizlilik denetimi ilk açılışta bazen geçici EPERM veriyor: birkaç kez dene.
                var opened: FileByteSource?
                var lastErr: Error?
                for attempt in 0..<4 {
                    do { opened = try FileByteSource(path: path); break } catch {
                        lastErr = error
                        logLine("aygıt açma denemesi \(attempt + 1) başarısız: \(error)")
                        usleep(400_000)
                    }
                }
                guard let s = opened else { throw lastErr ?? UzError.io("aygıt açılamadı") }
                locked { src = s; parts = nil; fs = nil }
                send(HelperResponse(id: req.id, ok: true, deviceSize: s.size))
            case "partitions":
                guard let s = locked({ src }) else { throw UzError.notFound("açık disk yok") }
                let p = try PartitionScanner.scan(s)
                locked { parts = p }
                send(HelperResponse(id: req.id, ok: true, partitions: p, deviceSize: s.size))
            case "open":
                guard let s = locked({ src }) else { throw UzError.notFound("açık disk yok") }
                if locked({ parts }) == nil { let p = try PartitionScanner.scan(s); locked { parts = p } }
                guard let p = locked({ parts })?.first(where: { $0.index == req.partition }) else { throw UzError.notFound("bölüm") }
                let f = try FileSystems.open(SliceByteSource(base: s, offset: p.offset, size: p.length))
                locked { fs = f; scanGeneration += 1 }
                send(HelperResponse(id: req.id, ok: true, volume: f.volumeInfo))
            case "list":
                guard let f = locked({ fs }) else { throw UzError.notFound("açık birim yok") }
                let ref = req.ref ?? f.rootRef
                var all: [DirEntry] = []
                var pending: [DirEntry] = []
                var last = Date()
                try f.listStreaming(ref) { b in
                    all += b
                    pending += b
                    if Date().timeIntervalSince(last) > 0.15 || all.count <= 200 {
                        send(HelperResponse(ref: ref, id: req.id, ok: true, event: "entries", entries: pending))
                        pending = []
                        last = Date()
                    }
                }
                send(HelperResponse(ref: ref, id: req.id, ok: true, entries: sortEntries(all)))
            case "scan":
                try scan(req)
            case "extract":
                // Önizleme için tek dosyayı önbelleğe çıkar (kopyalamayı beklemez).
                guard let f = locked({ fs }) else { throw UzError.notFound("açık birim yok") }
                guard let dest = req.dest, let items = req.items else { throw UzError.notFound("hedef") }
                let ex = Extractor(fs: f)
                if geteuid() == 0, let uid, let gid { ex.owner = (uid, gid) }
                let summary = ex.copy(items, to: URL(fileURLWithPath: dest, isDirectory: true))
                send(HelperResponse(id: req.id, ok: true, summary: summary))
            case "copy":
                guard let f = locked({ fs }) else { throw UzError.notFound("açık birim yok") }
                guard let dest = req.dest, let items = req.items else { throw UzError.notFound("hedef") }
                locked { cancelCopyFlag = false; copying = true }
                defer { locked { copying = false } }
                let ex = Extractor(fs: f)
                if geteuid() == 0, let uid, let gid { ex.owner = (uid, gid) }
                ex.isCancelled = { [unowned self] in self.locked { self.cancelCopyFlag } }
                ex.onProgress = { [unowned self] p in self.send(HelperResponse(id: req.id, ok: true, event: "progress", progress: p)) }
                let summary = ex.copy(items, to: URL(fileURLWithPath: dest, isDirectory: true))
                send(HelperResponse(id: req.id, ok: true, summary: summary))
            default:
                throw UzError.unsupported("bilinmeyen komut \(req.op)")
            }
        } catch {
            logLine("HATA \(req.op): \(error)")
            send(HelperResponse(id: req.id, ok: false, error: "\(error)"))
        }
    }

    /// Kullanıcının istediği klasörü (ve henüz taranmamış alt klasörlerini) sıranın başına al.
    /// stateLock tutulurken çağrılır.
    func enqueuePriority(_ ref: String, _ path: String, depth: Int) {
        guard depth < 64 else { return }
        if depth == 0 { priorityLabel = path }
        if scanSeen.contains(ref) {
            for (c, p) in scanChildDirs[ref] ?? [] { enqueuePriority(c, p, depth: depth + 1) }
        } else if !priority.contains(where: { $0.0 == ref }) {
            priority.insert((ref, path), at: 0)
        }
    }

    /// Tüm klasör ağacını genişlik öncelikli tarar; her klasörü bir "dir" olayıyla gönderir.
    /// Öncelik istenen klasörler sıranın önüne geçer; tarama duraklatılabilir.
    func scan(_ req: HelperRequest) throws {
        guard let f = locked({ fs }) else { throw UzError.notFound("açık birim yok") }
        let gen = locked { () -> Int in
            scanSeen = []
            scanChildDirs = [:]
            priority = []
            scanPaused = false
            priorityLabel = ""
            return scanGeneration
        }
        var stats = ScanStats()
        var queue: [(ref: String, path: String)] = [(f.rootRef, "")]
        var late: [(ref: String, path: String)] = [] // sistem klasörleri en sona
        let junk: Set<String> = [".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100",
                                 "System Volume Information", "$RECYCLE.BIN", "RECYCLER", "$Extend"]
        var head = 0
        var lastStats = Date.distantPast
        while true {
            if locked({ scanGeneration }) != gen { return }
            while locked({ copying || scanPaused }) {
                usleep(150_000)
                if locked({ scanGeneration }) != gen { return }
            }
            let next: (item: (String, String), pri: Bool)? = locked {
                if !priority.isEmpty { return (priority.removeFirst(), true) }
                if priority.isEmpty { priorityLabel = "" }
                if head < queue.count { head += 1; return (queue[head - 1], false) }
                if !late.isEmpty { queue += late; late = []; head += 1; return (queue[head - 1], false) }
                return nil
            }
            guard let next else { break }
            let (ref, path) = next.item
            if !locked({ scanSeen.insert(ref).inserted }) { continue }
            stats.current = (next.pri ? "⚡ " : "") + (path.isEmpty ? "/" : path)
            do {
                // Büyük klasörlerde bulunan dosyalar okundukça gönderilir.
                var items: [DirEntry] = []
                var sentCount = 0
                var lastSend = Date()
                try f.listStreaming(ref) { b in
                    items += b
                    if Date().timeIntervalSince(lastSend) > 0.3 {
                        lastSend = Date()
                        send(HelperResponse(ref: ref, id: req.id, ok: true, event: "dirPartial", entries: Array(items[sentCount...])))
                        sentCount = items.count
                    }
                }
                stats.dirs += 1
                var childDirs: [(String, String)] = []
                for e in items {
                    if e.isDirectory {
                        childDirs.append((e.ref, path + "/" + e.name))
                        if junk.contains(e.name) { late.append((e.ref, path + "/" + e.name)) } else { queue.append((e.ref, path + "/" + e.name)) }
                    } else {
                        stats.files += 1
                        stats.bytes += e.size
                    }
                }
                locked {
                    scanChildDirs[ref] = childDirs
                    if next.pri { for c in childDirs.reversed() where !scanSeen.contains(c.0) { priority.insert(c, at: 0) } }
                }
                send(HelperResponse(ref: ref, scan: stats, id: req.id, ok: true, event: "dir", entries: items))
            } catch {
                stats.errors += 1
                logLine("tarama hatası \(path): \(error)")
            }
            if Date().timeIntervalSince(lastStats) > 0.25 {
                lastStats = Date()
                send(HelperResponse(scan: stats, id: req.id, ok: true, event: "scan"))
            }
        }
        stats.done = true
        stats.current = ""
        send(HelperResponse(scan: stats, id: req.id, ok: true))
    }
}

func serve(_ args: [String]) -> Never {
    var device: String?
    var uid: uid_t?
    var gid: gid_t?
    var inPath: String?
    var outPath: String?
    var logPath: String?
    var i = 0
    while i + 1 < args.count {
        switch args[i] {
        case "--device": device = args[i + 1]
        case "--uid": uid = uid_t(args[i + 1])
        case "--gid": gid = gid_t(args[i + 1])
        case "--in": inPath = args[i + 1]
        case "--out": outPath = args[i + 1]
        case "--log": logPath = args[i + 1]
        case "--lang": Lang.isEnglish = args[i + 1] == "en"
        default: break
        }
        i += 2
    }

    var opened: Result<FileByteSource, Error>?
    if let device { opened = Result { try FileByteSource(path: device) } }

    // Kalıp dosyası modunda root'a gerek yok: tamamen bırak.
    if device != nil, let gid, let uid, getuid() == 0 || geteuid() == 0 {
        guard setgroups(0, nil) == 0, setgid(gid) == 0, setuid(uid) == 0 else { fail("yetki bırakılamadı") }
    }

    var log: FileHandle?
    if let logPath {
        let fd = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if fd >= 0 { log = FileHandle(fileDescriptor: fd, closeOnDealloc: true) }
    }

    if let inPath, let outPath {
        let inFd = open(inPath, O_RDONLY)
        guard inFd >= 0 else { fail("giriş kanalı açılamadı") }
        let outFd = open(outPath, O_WRONLY)
        guard outFd >= 0 else { fail("çıkış kanalı açılamadı") }
        dup2(inFd, STDIN_FILENO)
        dup2(outFd, STDOUT_FILENO)
        close(inFd)
        close(outFd)
        unlink(inPath)
        unlink(outPath)
        rmdir((inPath as NSString).deletingLastPathComponent)
    }
    signal(SIGPIPE, SIG_DFL)

    if case .failure(let e)? = opened {
        if let line = readLine(), let req = try? JSONDecoder().decode(HelperRequest.self, from: Data(line.utf8)),
           var d = try? JSONEncoder().encode(HelperResponse(id: req.id, ok: false, error: "\(e)")) {
            d.append(0x0A)
            FileHandle.standardOutput.write(d)
        }
        exit(1)
    }
    let src = try? opened?.get()
    Server(src: src, uid: uid, gid: gid, log: log).run()
    exit(0)
}

// MARK: - komut satırı

var argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { print(usage); exit(0) }
argv.removeFirst()

do {
    switch cmd {
    case "serve":
        serve(argv)
    case "disks":
        for d in DiskEnumerator.list() {
            let kind = d.isInternal ? "dahili" : "harici"
            print("\(d.rawDevicePath)\t\(human(d.size))\t\(kind)\t\(d.name)")
        }
    case "parts":
        guard let path = argv.first else { fail("aygıt gerekli") }
        let src = try FileByteSource(path: path)
        print("\(path): \(human(src.size)), kesim \(src.sectorSize) bayt")
        for p in try PartitionScanner.scan(src) {
            let fs = p.fileSystem?.displayName ?? "-"
            print("  -p \(p.index)\t\(p.scheme)\t\(fs)\t\(human(p.length))\t\(p.label ?? "")\t(\(p.typeName))")
        }
    case "ls":
        let (pos, part) = parseOpts(argv)
        guard let path = pos.first else { fail("aygıt gerekli") }
        let (fs, _) = try openVolume(path, part: part)
        let ref = try pos.count > 1 ? (fs.resolve(path: pos[1])?.ref ?? fs.rootRef) : fs.rootRef
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        for e in sortEntries(try fs.list(ref)) {
            let size = e.isDirectory ? "<KLASÖR>" : human(e.size)
            print("\(e.modified.map { df.string(from: $0) } ?? "                ")  \(size.padding(toLength: 10, withPad: " ", startingAt: 0))  \(e.name)\(e.isDirectory ? "/" : "")")
        }
    case "cp":
        let (pos, part) = parseOpts(argv)
        guard pos.count == 3 else { fail("kullanım: cp <aygıt> [-p N] <yol> <hedef klasör>") }
        let (fs, _) = try openVolume(pos[0], part: part)
        let items: [DirEntry]
        if let e = try fs.resolve(path: pos[1]) { items = [e] } else { items = try fs.list(fs.rootRef) }
        let ex = Extractor(fs: fs)
        var last = 0
        ex.onProgress = { p in
            let pct = p.bytesTotal > 0 ? Int(p.bytesDone * 100 / p.bytesTotal) : 100
            if pct != last { last = pct; FileHandle.standardError.write(Data("\r%\(pct)  \(p.currentFile.suffix(60))      ".utf8)) }
        }
        let s = ex.copy(items, to: URL(fileURLWithPath: pos[2], isDirectory: true))
        FileHandle.standardError.write(Data("\n".utf8))
        print("\(s.files) dosya, \(human(s.bytes)) kopyalandı → \(s.destination)")
        for e in s.errors { print("  ! \(e)") }
        exit(s.errors.isEmpty ? 0 : 2)
    case "-h", "--help", "help":
        print(usage)
    default:
        fail("bilinmeyen komut: \(cmd)\n\n\(usage)")
    }
} catch {
    fail("\(error)")
}
