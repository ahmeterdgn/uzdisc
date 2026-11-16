import AppKit
import QuickLookThumbnailing
import SwiftUI
import UzDiscCore

/// Uzun süren bir çağrıyı zaman aşımına bağlar.
func withTimeout<T: Sendable>(_ seconds: Double, _ message: String, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw HelperError(message: message)
        }
        let r = try await g.next()!
        g.cancelAll()
        return r
    }
}

// MARK: - Türler

enum FileCategory: String, CaseIterable, Identifiable, Hashable {
    case photos, videos, documents, audio, archives, code, others

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return L("Fotoğraflar", "Photos")
        case .videos: return L("Videolar", "Videos")
        case .documents: return L("Belgeler", "Documents")
        case .audio: return L("Ses", "Audio")
        case .archives: return L("Arşivler", "Archives")
        case .code: return L("Kod & Proje", "Code & Projects")
        case .others: return L("Diğer", "Other")
        }
    }

    var symbol: String {
        switch self {
        case .photos: return "photo.fill"
        case .videos: return "play.rectangle.fill"
        case .documents: return "doc.text.fill"
        case .audio: return "music.note"
        case .archives: return "archivebox.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .others: return "ellipsis"
        }
    }

    var colors: [Color] {
        switch self {
        case .photos: return [Color(hex: 0xFFB547), Color(hex: 0xFF7A45)]
        case .videos: return [Color(hex: 0xA78BFA), Color(hex: 0x7C3AED)]
        case .documents: return [Color(hex: 0x60A5FA), Color(hex: 0x2563EB)]
        case .audio: return [Color(hex: 0xFB7185), Color(hex: 0xE11D48)]
        case .archives: return [Color(hex: 0x2DD4BF), Color(hex: 0x0D9488)]
        case .code: return [Color(hex: 0x4ADE80), Color(hex: 0x16A34A)]
        case .others: return [Color(hex: 0x94A3B8), Color(hex: 0x64748B)]
        }
    }

    static func of(_ name: String) -> FileCategory {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "raw", "cr2", "cr3", "nef",
             "arw", "dng", "orf", "rw2", "raf", "svg", "psd", "ai", "avif":
            return .photos
        case "mp4", "mov", "m4v", "mkv", "avi", "wmv", "webm", "mts", "m2ts", "3gp", "flv", "mpg", "mpeg":
            return .videos
        case "pdf", "doc", "docx", "pages", "odt", "rtf", "txt", "md", "xls", "xlsx", "numbers", "csv", "ods",
             "ppt", "pptx", "key", "odp", "epub", "tex", "log":
            return .documents
        case "mp3", "wav", "flac", "m4a", "aac", "ogg", "aiff", "aif", "wma", "opus", "alac":
            return .audio
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso", "pkg", "img":
            return .archives
        case "swift", "js", "ts", "tsx", "jsx", "py", "java", "kt", "c", "cpp", "h", "hpp", "m", "go", "rs", "php",
             "rb", "html", "css", "scss", "json", "yml", "yaml", "xml", "sql", "sh", "vue", "dart", "cs":
            return .code
        default:
            return .others
        }
    }
}

enum BrowseMode: Hashable {
    case path
    case type(FileCategory)
}

enum ViewStyle: String { case list, grid }

enum SortKey: String { case name, date, size, kind }

struct OpenSource: Equatable {
    let id: String
    let title: String
    let subtitle: String
    let isImage: Bool
    let devicePath: String
    let bsdName: String?
}

struct Row: Identifiable, Equatable {
    let entry: DirEntry
    let depth: Int
    let parentRef: String
    var id: String { entry.id }
}

extension DirEntry {
    var sortDate: Date { modified ?? .distantPast }
    var ext: String { (name as NSString).pathExtension.lowercased() }

    var kindName: String {
        if isDirectory { return L("Klasör", "Folder") }
        switch FileCategory.of(name) {
        case .photos: return L("Görsel", "Image")
        case .videos: return "Video"
        case .audio: return L("Ses", "Audio")
        case .archives: return L("Arşiv", "Archive")
        case .code: return L("Kaynak kodu", "Source code")
        case .documents:
            switch ext {
            case "pdf": return L("PDF belgesi", "PDF document")
            case "xls", "xlsx", "numbers", "csv", "ods": return L("Tablo", "Spreadsheet")
            case "ppt", "pptx", "key", "odp": return L("Sunum", "Presentation")
            case "txt", "md", "log": return L("Düz metin", "Plain text")
            default: return L("Belge", "Document")
            }
        case .others: return ext.isEmpty ? L("Dosya", "File") : L("\(ext.uppercased()) dosyası", "\(ext.uppercased()) file")
        }
    }
}

// MARK: - Dizin (tarama sonucu)

/// Taranan klasörlerin bellek içi dizini. Tarama bitince gezinme ve arama diske gitmeden yapılır.
final class VolumeIndex {
    var children: [String: [DirEntry]] = [:]
    var parentOf: [String: String] = [:] // entry.id → üst klasör ref
    var dirPath: [String: String] = [:]  // klasör ref → "/a/b"
    var entryByRef: [String: DirEntry] = [:]
    var recursive: [String: (files: Int, bytes: UInt64)] = [:]
    var categories: [FileCategory: (count: Int, bytes: UInt64)] = [:]
    var root: String = ""

    func reset(root: String) {
        children = [:]
        parentOf = [:]
        dirPath = [root: ""]
        entryByRef = [:]
        recursive = [:]
        categories = [:]
        self.root = root
    }

    func add(_ ref: String, _ entries: [DirEntry]) {
        children[ref] = entries
        let base = dirPath[ref] ?? ""
        for e in entries {
            parentOf[e.id] = ref
            if e.isDirectory {
                entryByRef[e.ref] = e
                if dirPath[e.ref] == nil { dirPath[e.ref] = base + "/" + e.name }
            }
        }
    }

    /// Klasörlerin toplam dosya sayısı/boyutu ve tür sayıları (alttan üste).
    func computeStats() {
        var rec: [String: (files: Int, bytes: UInt64)] = [:]
        var cats: [FileCategory: (count: Int, bytes: UInt64)] = [:]
        var order: [String] = []
        var q = [root]
        var seen = Set<String>()
        var i = 0
        while i < q.count {
            let r = q[i]
            i += 1
            if !seen.insert(r).inserted { continue }
            order.append(r)
            for e in children[r] ?? [] where e.isDirectory { q.append(e.ref) }
        }
        for r in order.reversed() {
            var files = 0
            var bytes: UInt64 = 0
            for e in children[r] ?? [] {
                if e.isDirectory {
                    let s = rec[e.ref] ?? (0, 0)
                    files += s.files
                    bytes += s.bytes
                } else {
                    files += 1
                    bytes += e.size
                    let c = FileCategory.of(e.name)
                    let old = cats[c] ?? (0, 0)
                    cats[c] = (old.count + 1, old.bytes + e.size)
                }
            }
            rec[r] = (files, bytes)
        }
        recursive = rec
        categories = cats
    }

    func files(in category: FileCategory) -> [DirEntry] {
        var out: [DirEntry] = []
        for (_, list) in children {
            for e in list where !e.isDirectory && FileCategory.of(e.name) == category { out.append(e) }
        }
        return out
    }

    func search(_ q: String, limit: Int = 5000) -> [DirEntry] {
        var out: [DirEntry] = []
        for (_, list) in children {
            for e in list where e.name.localizedCaseInsensitiveContains(q) {
                out.append(e)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// Bir öğenin üst klasörlerinden biri işaretli mi?
    func hasCheckedAncestor(_ id: String, checkedDirRefs: Set<String>) -> Bool {
        var cur = parentOf[id]
        var n = 0
        while let r = cur, n < 512 {
            if checkedDirRefs.contains(r) { return true }
            guard let e = entryByRef[r] else { return false }
            cur = parentOf[e.id]
            n += 1
        }
        return false
    }

    func path(of e: DirEntry) -> String {
        let parent = parentOf[e.id].flatMap { dirPath[$0] } ?? ""
        return parent.isEmpty ? "/" : parent
    }
}

// MARK: - Model

@MainActor
final class AppModel: ObservableObject {
    // Diskler
    @Published var disks: [DiskInfo] = []
    @Published var showInternal = false
    @Published var source: OpenSource?
    @Published var partitions: [PartitionInfo] = []
    @Published var selectedPartition: Int?
    @Published var volume: VolumeInfo?

    // Gezinme
    @Published var mode: BrowseMode = .path
    @Published var pathStack: [DirEntry] = []
    @Published var expanded = Set<String>()
    @Published var rows: [Row] = []
    @Published var focusedID: String?
    @Published var checked: [String: DirEntry] = [:]
    @Published var query = "" { didSet { if query != oldValue { scheduleRebuild() } } }
    @Published var sortKey: SortKey = .name
    @Published var ascending = true
    @Published var viewStyle: ViewStyle = .list
    @Published var showHidden = false { didSet { rebuildRows() } }
    @Published var loadingRefs = Set<String>()
    @Published var slowRefs = Set<String>()

    // Tarama
    @Published var scan: ScanStats?
    @Published var indexVersion = 0
    @Published var scanPaused = false
    @Published var stallSeconds = 0
    @Published var ioRate: (bytes: Double, ops: Double) = (0, 0)

    func handleBroadcast(_ ev: HelperResponse) {
        switch ev.event {
        case "stall": stallSeconds = Int(ev.deviceSize ?? 0)
        case "io": ioRate = (ev.ioBytesPerSec ?? 0, ev.ioOpsPerSec ?? 0)
        default: break
        }
    }
    @Published var showInspector = true
    @Published var langVersion = 0

    func setLanguage(_ code: String) {
        UserDefaults.standard.set(code, forKey: "lang")
        Lang.isEnglish = code == "en"
        langVersion += 1
        if volume != nil { rebuildRows() }
    }

    // Önizleme
    @Published var thumbs: [String: NSImage] = [:]
    @Published var extracting = Set<String>()
    private var previewURLs: [String: URL] = [:]
    private var thumbQueue: [DirEntry] = []
    private var thumbsRunning = 0
    let previewRoot: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UzDisc/Preview", isDirectory: true)
        try? FileManager.default.removeItem(at: u) // önceki oturumun önizlemelerini temizle
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    // Durum
    @Published var busy: String?
    @Published var errorMessage: String?
    @Published var copyProgress: CopyProgress?
    @Published var copyStarted = Date()
    @Published var summary: CopySummary?

    let index = VolumeIndex()
    private var partial: [String: [DirEntry]] = [:]
    private var rootClient: HelperClient?
    private var imageClient: HelperClient?
    private var client: HelperClient? { source?.isImage == true ? imageClient : rootClient }
    private var backStack: [[DirEntry]] = []
    private var forwardStack: [[DirEntry]] = []
    private var rebuildScheduled = false

    init() {
        refreshDisks()
        // Yönetici izni uygulama açılır açılmaz bir kez istenir (kalıp dosyası/demo modunda gerekmez).
        if ProcessInfo.processInfo.environment["UZDISC_SCREENSHOT"] == nil {
            Task { await ensureAdminSession() }
        }
        if let v = UserDefaults.standard.string(forKey: "viewStyle"), let s = ViewStyle(rawValue: v) { viewStyle = s }
    }

    var externalDisks: [DiskInfo] { disks.filter { !$0.isInternal } }
    var internalDisks: [DiskInfo] { disks.filter { $0.isInternal } }
    var currentDisk: DiskInfo? { disks.first { $0.bsdName == source?.bsdName } }
    var currentRef: String? { pathStack.last?.ref ?? volume?.rootRef }
    var scanDone: Bool { scan?.done == true }

    var volumeTitle: String {
        if let l = volume?.label, !l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
        return source?.title ?? "Disk"
    }

    func refreshDisks() { disks = DiskEnumerator.list() }

    static var logURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/UzDisc")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("helper.log")
    }

    // MARK: Açma

    @Published var adminReady = false
    private var adminLaunching: Task<Void, Error>?

    /// Yönetici oturumunu (bir kez) başlatır; aynı anda gelen istekler aynı görevi bekler.
    func ensureAdminSession() async {
        if rootClient != nil { return }
        if let t = adminLaunching { _ = try? await t.value; return }
        let t = Task { @MainActor in
            let c = try await HelperClient.launchPrivileged(device: nil, logPath: Self.logURL.path)
            c.onClose = { [weak self, weak c] in
                guard let self, let c, self.rootClient === c else { return }
                self.rootClient = nil
                self.adminReady = false
                if self.source?.isImage == false { self.connectionLost() }
            }
            c.onBroadcast = { [weak self] ev in
                Task { @MainActor in self?.handleBroadcast(ev) }
            }
            self.rootClient = c
            self.adminReady = true
        }
        adminLaunching = t
        do { try await t.value } catch { errorMessage = error.localizedDescription }
        adminLaunching = nil
    }

    func open(disk: DiskInfo) async {
        guard source?.id != disk.bsdName else { return }
        resetVolume()
        busy = rootClient == nil ? L("Yönetici izni bekleniyor…", "Waiting for administrator permission…") : L("Disk açılıyor…", "Opening disk…")
        do {
            await ensureAdminSession()
            guard rootClient != nil else { busy = nil; return }
            busy = L("Disk açılıyor…", "Opening disk…")
            source = OpenSource(id: disk.bsdName, title: disk.name, subtitle: "\(Fmt.bytes(disk.size)) · \(disk.bsdName)",
                                isImage: false, devicePath: disk.rawDevicePath, bsdName: disk.bsdName)
            let c = rootClient!
            let path = disk.rawDevicePath
            _ = try await withTimeout(25, L("Disk 25 saniyedir yanıt vermiyor. Kabloyu çıkarıp takmayı ya da diski yeniden seçmeyi dene.", "The disk hasn't responded for 25 seconds. Try replugging the cable or selecting the disk again.")) {
                try await c.call("device", device: path)
            }
            try await loadPartitions()
        } catch {
            busy = nil
            source = nil
            errorMessage = error.localizedDescription
        }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = L("Disk kalıbı seç", "Choose a disk image")
        panel.message = L(".img, .dd, .raw, .bin gibi ham disk kalıpları açılabilir.", "Raw disk images such as .img, .dd, .raw and .bin can be opened.")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Aç", "Open")
        if panel.runModal() == .OK, let url = panel.url {
            Task { await openImage(url) }
        }
    }

    func openImage(_ url: URL) async {
        resetVolume()
        imageClient?.terminate()
        imageClient = nil
        busy = L("Kalıp açılıyor…", "Opening image…")
        do {
            let c = try HelperClient.launchDirect(device: url.path, logPath: Self.logURL.path)
            c.onBroadcast = { [weak self] ev in
                Task { @MainActor in self?.handleBroadcast(ev) }
            }
            imageClient = c
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0
            source = OpenSource(id: url.path, title: url.lastPathComponent, subtitle: L("Kalıp dosyası · \(Fmt.bytes(size))", "Disk image · \(Fmt.bytes(size))"),
                                isImage: true, devicePath: url.path, bsdName: nil)
            try await loadPartitions()
        } catch {
            busy = nil
            source = nil
            errorMessage = error.localizedDescription
        }
    }

    private func loadPartitions() async throws {
        guard let c = client else { return }
        busy = L("Bölümler okunuyor…", "Reading partitions…")
        let r = try await withTimeout(40, L("Bölüm tablosu okunamadı: disk yanıt vermiyor.", "Couldn't read the partition table: the disk isn't responding.")) { try await c.call("partitions") }
        partitions = r.partitions ?? []
        busy = nil
        if let first = partitions.first(where: { $0.fileSystem != nil }) {
            await openPartition(first)
        }
    }

    func openPartition(_ p: PartitionInfo) async {
        guard let c = client else { return }
        busy = L("Bölüm açılıyor…", "Opening partition…")
        do {
            let idx = p.index
            let r = try await withTimeout(40, L("Bölüm açılamadı: disk yanıt vermiyor.", "Couldn't open the partition: the disk isn't responding.")) { try await c.call("open", partition: idx) }
            resetBrowsing()
            selectedPartition = p.index
            volume = r.volume
            busy = nil
            if let v = r.volume {
                index.reset(root: v.rootRef)
                startScan()
                await ensureLoaded(v.rootRef)
            }
        } catch {
            busy = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Takılan bir açma işlemini bırak.
    func cancelBusy() {
        busy = nil
        if volume == nil { resetVolume() }
    }

    private func resetBrowsing() {
        scanPaused = false
        thumbs = [:]
        previewURLs = [:]
        extracting = []
        thumbQueue = []
        volume = nil
        mode = .path
        pathStack = []
        backStack = []
        forwardStack = []
        expanded = []
        rows = []
        checked = [:]
        focusedID = nil
        query = ""
        partial = [:]
        loadingRefs = []
        slowRefs = []
        scan = nil
    }

    private func resetVolume() {
        client?.cancelScan()
        resetBrowsing()
        source = nil
        partitions = []
        selectedPartition = nil
    }

    private func connectionLost() {
        guard source != nil else { return }
        errorMessage = L("Disk bağlantısı koptu. Kabloyu kontrol edip diski yeniden açın.", "The disk was disconnected. Check the cable and open the disk again.")
        copyProgress = nil
        resetVolume()
    }

    func closeSource() {
        resetVolume()
        imageClient?.terminate()
        imageClient = nil
    }

    // MARK: Tarama

    private func startScan() {
        guard let c = client else { return }
        scan = ScanStats()
        Task {
            do {
                let r = try await c.call("scan") { [weak self] ev in
                    Task { @MainActor in self?.handleScanEvent(ev) }
                }
                let s = r.scan
                Task { @MainActor in self.finishScan(s) }
            } catch {
                if var s = scan { s.done = true; scan = s }
            }
        }
    }

    private func handleScanEvent(_ ev: HelperResponse) {
        if ev.event == "dirPartial", let ref = ev.ref, let entries = ev.entries, index.children[ref] == nil {
            // Büyük klasör: okunan dosyalar hemen görünsün.
            partial[ref, default: []] += entries
            if ref == currentRef || expanded.contains(ref) { scheduleRebuild() }
            return
        }
        if ev.event == "dir", let ref = ev.ref, let entries = ev.entries, index.children[ref] == nil {
            index.add(ref, entries)
            if partial[ref] != nil { partial[ref] = nil }
            if ref == currentRef || expanded.contains(ref) { scheduleRebuild() }
        }
        if let s = ev.scan, !(scan?.done ?? false) { scan = s }
    }

    private func finishScan(_ s: ScanStats?) {
        index.computeStats()
        if var s = s ?? scan { s.done = true; scan = s }
        indexVersion += 1
        rebuildRows()
    }

    // MARK: Listeleme

    func ensureLoaded(_ ref: String) async {
        if index.children[ref] != nil || loadingRefs.contains(ref) { return }
        guard let c = client else { return }
        loadingRefs.insert(ref)
        partial[ref] = []
        rebuildRows()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.loadingRefs.contains(ref) else { return }
            self.slowRefs.insert(ref)
        }
        do {
            let r = try await c.call("list", ref: ref) { [weak self] ev in
                Task { @MainActor in
                    guard let self, let e = ev.entries, self.index.children[ref] == nil else { return }
                    self.partial[ref, default: []] += e
                    self.scheduleRebuild()
                }
            }
            if index.children[ref] == nil { index.add(ref, r.entries ?? []) }
        } catch {
            errorMessage = error.localizedDescription
        }
        partial[ref] = nil
        loadingRefs.remove(ref)
        slowRefs.remove(ref)
        rebuildRows()
    }

    func entries(of ref: String) -> [DirEntry]? {
        if let c = index.children[ref] { return c }
        guard let p = partial[ref] else { return nil }
        var seen = Set<String>()
        return p.filter { seen.insert($0.id).inserted } // liste ve tarama aynı klasörü birlikte okuyabilir
    }

    static func isSystemJunk(_ e: DirEntry) -> Bool {
        let n = e.name
        if n.hasPrefix("._") || n == ".DS_Store" { return true }
        return [".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100",
                "System Volume Information", "$RECYCLE.BIN", "RECYCLER", ".apdisk", ".VolumeIcon.icns",
                ".com.apple.timemachine.donotpresent"].contains(n)
    }

    func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            rebuildScheduled = false
            rebuildRows()
        }
    }

    private func sorted(_ list: [DirEntry]) -> [DirEntry] {
        let asc = ascending
        let key = sortKey
        let r = list.sorted { a, b in
            let res: Bool
            switch key {
            case .name: res = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .date: res = a.sortDate < b.sortDate
            case .size: res = folderBytes(a) < folderBytes(b)
            case .kind: res = a.kindName.localizedStandardCompare(b.kindName) == .orderedAscending
            }
            return asc ? res : !res
        }
        return r.filter(\.isDirectory) + r.filter { !$0.isDirectory }
    }

    func rebuildRows() {
        var out: [Row] = []
        let hide = !showHidden
        switch mode {
        case .path:
            if !query.isEmpty && scanDone {
                let hits = index.search(query).filter { !(hide && Self.isSystemJunk($0)) }
                out = sorted(hits).map { Row(entry: $0, depth: 0, parentRef: index.parentOf[$0.id] ?? "") }
            } else if let ref = currentRef {
                func add(_ r: String, _ depth: Int) {
                    guard let list = entries(of: r) else { return }
                    var vis = hide ? list.filter { !Self.isSystemJunk($0) } : list
                    if depth == 0 && !query.isEmpty { vis = vis.filter { $0.name.localizedCaseInsensitiveContains(query) } }
                    for e in sorted(vis) {
                        out.append(Row(entry: e, depth: depth, parentRef: r))
                        if e.isDirectory && expanded.contains(e.ref) { add(e.ref, depth + 1) }
                    }
                }
                add(ref, 0)
            }
        case .type(let c):
            var files = index.files(in: c).filter { !(hide && Self.isSystemJunk($0)) }
            if !query.isEmpty { files = files.filter { $0.name.localizedCaseInsensitiveContains(query) } }
            out = sorted(files).map { Row(entry: $0, depth: 0, parentRef: index.parentOf[$0.id] ?? "") }
        }
        rows = out
    }

    // MARK: Gezinme

    func setMode(_ m: BrowseMode) {
        mode = m
        query = ""
        focusedID = nil
        rebuildRows()
    }

    // MARK: Öncelik ve duraklatma

    func prioritize(_ e: DirEntry) {
        guard e.isDirectory, !scanDone else { return }
        client?.prioritize(ref: e.ref, path: index.dirPath[e.ref] ?? "/" + e.name)
        scanPaused = false
    }

    func togglePause() {
        scanPaused.toggle()
        if scanPaused { client?.pauseScan() } else { client?.resumeScan() }
    }

    func openFolder(_ e: DirEntry) {
        guard e.isDirectory else { return }
        if index.children[e.ref] == nil || index.recursive[e.ref] == nil { prioritize(e) }
        backStack.append(pathStack)
        forwardStack = []
        let wasPath = mode == .path && query.isEmpty
        mode = .path
        pathStack = wasPath && pathStack.last?.ref == index.parentOf[e.id] ? pathStack + [e] : stackFor(e)
        afterNavigate()
    }

    private func stackFor(_ e: DirEntry) -> [DirEntry] {
        var chain = [e]
        var cur = index.parentOf[e.id]
        var n = 0
        while let r = cur, r != volume?.rootRef, let p = index.entryByRef[r], n < 256 {
            chain.insert(p, at: 0)
            cur = index.parentOf[p.id]
            n += 1
        }
        if cur == volume?.rootRef { return chain }
        return pathStack + [e]
    }

    func goTo(depth: Int) {
        guard depth <= pathStack.count else { return }
        backStack.append(pathStack)
        forwardStack = []
        mode = .path
        pathStack = Array(pathStack.prefix(depth))
        afterNavigate()
    }

    func goUp() { if !pathStack.isEmpty { goTo(depth: pathStack.count - 1) } }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(pathStack)
        pathStack = prev
        mode = .path
        afterNavigate()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(pathStack)
        pathStack = next
        mode = .path
        afterNavigate()
    }

    private func afterNavigate() {
        query = ""
        focusedID = nil
        expanded = []
        rebuildRows()
        if let r = currentRef { Task { await ensureLoaded(r) } }
    }

    func toggleExpand(_ e: DirEntry) {
        if expanded.contains(e.ref) {
            expanded.remove(e.ref)
        } else {
            expanded.insert(e.ref)
            if index.children[e.ref] == nil { prioritize(e) }
            Task { await ensureLoaded(e.ref) }
        }
        rebuildRows()
    }

    func setSort(_ k: SortKey) {
        if sortKey == k { ascending.toggle() } else { sortKey = k; ascending = (k == .name || k == .kind) }
        rebuildRows()
    }

    func setViewStyle(_ s: ViewStyle) {
        viewStyle = s
        UserDefaults.standard.set(s.rawValue, forKey: "viewStyle")
    }

    // MARK: İşaretleme

    private var checkedDirRefs: Set<String> { Set(checked.values.filter(\.isDirectory).map(\.ref)) }

    func isChecked(_ e: DirEntry) -> Bool {
        if checked[e.id] != nil { return true }
        let refs = checkedDirRefs
        return !refs.isEmpty && index.hasCheckedAncestor(e.id, checkedDirRefs: refs)
    }

    func isInheritedCheck(_ e: DirEntry) -> Bool { checked[e.id] == nil && isChecked(e) }

    func toggleCheck(_ e: DirEntry) {
        if checked[e.id] != nil { checked[e.id] = nil } else if !isChecked(e) { checked[e.id] = e }
    }

    var allTopChecked: Bool {
        let top = rows.filter { $0.depth == 0 }
        return !top.isEmpty && top.allSatisfy { checked[$0.id] != nil }
    }

    func toggleAll() {
        let top = rows.filter { $0.depth == 0 }
        if allTopChecked {
            for r in top { checked[r.id] = nil }
        } else {
            for r in top { checked[r.id] = r.entry }
        }
    }

    /// Kopyalanacak öğeler: üst klasörü zaten işaretli olanlar tekrar eklenmez.
    var itemsToCopy: [DirEntry] {
        let refs = checkedDirRefs
        return checked.values.filter { !index.hasCheckedAncestor($0.id, checkedDirRefs: refs) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var checkedSummary: (count: Int, bytes: UInt64, unknownDirs: Bool) {
        var bytes: UInt64 = 0
        var unknown = false
        let items = itemsToCopy
        for e in items {
            if e.isDirectory {
                if let s = index.recursive[e.ref] { bytes += s.bytes } else { unknown = true }
            } else {
                bytes += e.size
            }
        }
        return (items.count, bytes, unknown)
    }

    func folderBytes(_ e: DirEntry) -> UInt64 {
        e.isDirectory ? (index.recursive[e.ref]?.bytes ?? 0) : e.size
    }

    func folderCount(_ e: DirEntry) -> Int? {
        guard e.isDirectory else { return nil }
        if let s = index.recursive[e.ref] { return s.files }
        return index.children[e.ref]?.count
    }

    // MARK: Kopyalama

    func copyChecked() { copy(itemsToCopy) }

    func copy(_ items: [DirEntry]) {
        guard !items.isEmpty, copyProgress == nil else { return }
        let panel = NSOpenPanel()
        panel.title = L("Kopyalanacak yeri seç", "Choose where to copy")
        panel.message = items.count == 1 ? L("“\(items[0].name)” bu klasöre kopyalanacak.", "“\(items[0].name)” will be copied to this folder.")
                                         : L("\(items.count) öğe bu klasöre kopyalanacak.", "\(items.count) items will be copied to this folder.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Buraya Kopyala", "Copy Here")
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        if let bsd = source?.bsdName, Self.volumeDevice(of: dest)?.hasPrefix("/dev/\(bsd)") == true {
            errorMessage = L("Hedef klasör, okunan diskin üzerinde. UzDisc kaynak diske asla yazmaz; lütfen Mac'inizde ya da başka bir diskte bir klasör seçin.", "The destination is on the disk being read. UzDisc never writes to the source disk — please choose a folder on your Mac or another disk.")
            return
        }
        Task { await runCopy(items, to: dest) }
    }

    static func volumeDevice(of url: URL) -> String? {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return nil }
        return withUnsafePointer(to: &st.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    private func runCopy(_ items: [DirEntry], to dest: URL) async {
        guard let c = client else { return }
        copyStarted = Date()
        copyProgress = CopyProgress()
        do {
            let r = try await c.call("copy", items: items, dest: dest.path) { [weak self] ev in
                Task { @MainActor in
                    if let p = ev.progress, self?.copyProgress != nil { self?.copyProgress = p }
                }
            }
            copyProgress = nil
            summary = r.summary
            if r.summary?.cancelled == false && r.summary?.errors.isEmpty == true { checked = [:] }
        } catch {
            copyProgress = nil
            errorMessage = error.localizedDescription
        }
    }

    func cancelCopy() { client?.cancelCopy() }

    // MARK: Önizleme

    var focusedEntry: DirEntry? {
        guard let id = focusedID else { return nil }
        return rows.first { $0.id == id }?.entry
    }

    /// Dosyayı önizleme önbelleğine çıkarır (kaynak diske yazılmaz).
    func extractForPreview(_ e: DirEntry) async -> URL? {
        if let u = previewURLs[e.id], FileManager.default.fileExists(atPath: u.path) { return u }
        guard let c = client, !e.isDirectory else { return nil }
        let dir = previewRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        extracting.insert(e.id)
        defer { extracting.remove(e.id) }
        guard let r = try? await c.call("extract", items: [e], dest: dir.path),
              let p = r.summary?.createdPaths.first, r.summary?.errors.isEmpty == true else { return nil }
        let u = URL(fileURLWithPath: p)
        previewURLs[e.id] = u
        return u
    }

    static func thumbEligible(_ e: DirEntry) -> Bool {
        guard !e.isDirectory, e.size > 0 else { return false }
        switch FileCategory.of(e.name) {
        case .photos: return e.size <= 40_000_000
        case .videos: return e.size <= 60_000_000
        case .documents: return e.ext == "pdf" && e.size <= 30_000_000
        default: return false
        }
    }

    func requestThumb(_ e: DirEntry) {
        guard Self.thumbEligible(e), thumbs[e.id] == nil, !thumbQueue.contains(where: { $0.id == e.id }),
              !extracting.contains(e.id) else { return }
        thumbQueue.insert(e, at: 0) // en son istenen önce
        if thumbQueue.count > 60 { thumbQueue.removeLast(thumbQueue.count - 60) }
        pumpThumbs()
    }

    private func pumpThumbs() {
        while thumbsRunning < 2, !thumbQueue.isEmpty {
            let e = thumbQueue.removeFirst()
            thumbsRunning += 1
            Task {
                if let url = await extractForPreview(e), let img = await Self.makeThumb(url) { thumbs[e.id] = img }
                thumbsRunning -= 1
                pumpThumbs()
            }
        }
    }

    static func makeThumb(_ url: URL) async -> NSImage? {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 320, height: 320), scale: 2,
                                               representationTypes: .thumbnail)
        return await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                cont.resume(returning: rep?.nsImage)
            }
        }
    }

    /// Quick Look ile tam boy önizleme.
    func quickLook(_ e: DirEntry) {
        guard !e.isDirectory else { openFolder(e); return }
        Task {
            guard let u = await extractForPreview(e) else {
                errorMessage = L("Önizleme için dosya okunamadı.", "Couldn't read the file for preview.")
                return
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            p.arguments = ["-p", u.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }

    var needsFullDiskAccess: Bool { (errorMessage?.contains("Tam Disk Erişimi") == true || errorMessage?.contains("Full Disk Access") == true) }

    func openFullDiskAccessSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: - Biçimlendirme

enum Fmt {
    static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Lang.locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f
    }()

    static func bytes(_ n: UInt64) -> String {
        if n < 1000 { return L("\(n) bayt", "\(n) bytes") }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var v = Double(n) / 1000
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        number.maximumFractionDigits = v < 10 ? 2 : (v < 100 ? 1 : 0)
        return "\(number.string(from: NSNumber(value: v)) ?? "\(v)") \(units[i])"
    }

    static func count(_ n: Int) -> String {
        number.maximumFractionDigits = 0
        return number.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Lang.locale
        f.dateFormat = Lang.isEnglish ? "MMM d, yyyy HH:mm" : "d MMM yyyy HH:mm"
        return f
    }()
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}
