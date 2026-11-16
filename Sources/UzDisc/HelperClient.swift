import Foundation
import Darwin
import UzDiscCore

struct HelperError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// uzdisc-helper süreciyle satır tabanlı JSON üzerinden konuşur.
final class HelperClient: @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let process: Process?
    private let lock = NSLock()
    private var nextId = 1
    private var waiters: [Int: CheckedContinuation<HelperResponse, Error>] = [:]
    private var eventHandlers: [Int: @Sendable (HelperResponse) -> Void] = [:]
    private var buffer: [UInt8] = []
    private var scanned = 0 // tamponda satır sonu aranmış kısım
    private var closed = false
    var onClose: (@MainActor () -> Void)?
    /// id 0 ile gelen genel olaylar (ör. disk donması).
    var onBroadcast: (@Sendable (HelperResponse) -> Void)?

    private let writeQueue = DispatchQueue(label: "uzdisc.helper.write")

    private init(input: FileHandle, output: FileHandle, process: Process?) {
        self.input = input
        self.output = output
        self.process = process
        // Kendi okuma iş parçacığımız: kanal sürekli boşaltılır, yardımcı süreç asla yazarken beklemez.
        let fd = output.fileDescriptor
        let t = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                self?.receive(Data(buf[0..<n]))
            }
            self?.receive(Data())
        }
        t.name = "uzdisc.helper.read"
        t.qualityOfService = .userInitiated
        t.start()
    }

    // MARK: Başlatma

    static var helperPath: String {
        if let u = Bundle.main.url(forAuxiliaryExecutable: "uzdisc-helper") { return u.path }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("uzdisc-helper").path
    }

    /// Kalıp dosyaları için: yardımcı normal kullanıcı olarak çalışır.
    static func launchDirect(device: String, logPath: String) throws -> HelperClient {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helperPath)
        p.arguments = ["serve", "--device", device, "--log", logPath, "--lang", Lang.code]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        return HelperClient(input: inPipe.fileHandleForWriting, output: outPipe.fileHandleForReading, process: p)
    }

    /// Fiziksel diskler için: macOS'un yönetici parolası penceresiyle **oturum başına bir kez** başlatır.
    /// Yardımcı yalnızca /dev/(r)diskN aygıtlarını salt okunur açar; dosyaları kullanıcı kimliğiyle yazar.
    /// İletişim kullanıcıya özel (0700 klasörde, 0600) FIFO'larla yapılır ve FIFO'lar açılır açılmaz silinir.
    static func launchPrivileged(device: String?, logPath: String) async throws -> HelperClient {
        try await Task.detached(priority: .userInitiated) { () throws -> HelperClient in
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("uzdisc-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let inPath = dir.appendingPathComponent("in").path
            let outPath = dir.appendingPathComponent("out").path
            guard mkfifo(inPath, 0o600) == 0, mkfifo(outPath, 0o600) == 0 else {
                throw HelperError(message: L("İletişim kanalı oluşturulamadı.", "Couldn't create the communication channel."))
            }

            func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let dev = device.map { "--device \(q($0)) " } ?? ""
            let cmd = "\(q(helperPath)) serve \(dev)--uid \(getuid()) --gid \(getgid()) --log \(q(logPath)) --lang \(Lang.code) "
                + "--in \(q(inPath)) --out \(q(outPath)) </dev/null >/dev/null 2>&1 &"

            let p = Process()
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            if ProcessInfo.processInfo.environment["UZDISC_NO_SUDO"] != nil {
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", cmd]
            } else {
                let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let prompt = L("UzDisc diski salt okunur olarak açmak için yönetici izni istiyor. Diske hiçbir şey yazılmaz.", "UzDisc needs administrator permission to open disks read-only. Nothing is ever written to the disk.")
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "do shell script \"\(esc)\" with administrator privileges with prompt \"\(prompt)\""]
            }
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                try? fm.removeItem(at: dir)
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if msg.contains("-128") { throw HelperError(message: L("Yönetici izni verilmedi.", "Administrator permission was not granted.")) }
                throw HelperError(message: L("Yardımcı başlatılamadı. \(msg)", "Couldn't start the helper. \(msg)"))
            }

            var wfd: Int32 = -1
            for _ in 0..<150 {
                wfd = open(inPath, O_WRONLY | O_NONBLOCK)
                if wfd >= 0 || errno != ENXIO { break }
                usleep(100_000)
            }
            guard wfd >= 0 else {
                try? fm.removeItem(at: dir)
                throw HelperError(message: L("Yardımcı süreç yanıt vermedi.", "The helper process didn't respond."))
            }
            _ = fcntl(wfd, F_SETFL, fcntl(wfd, F_GETFL) & ~O_NONBLOCK)
            let rfd = open(outPath, O_RDONLY)
            guard rfd >= 0 else { close(wfd); throw HelperError(message: L("Yardımcı çıkış kanalı açılamadı.", "Couldn't open the helper output channel.")) }
            return HelperClient(input: FileHandle(fileDescriptor: wfd, closeOnDealloc: true),
                                output: FileHandle(fileDescriptor: rfd, closeOnDealloc: true), process: nil)
        }.value
    }

    // MARK: İletişim

    private func receive(_ d: Data) {
        if d.isEmpty { shutdown(); return }
        // Doğrusal satır ayırma: her baytı yalnızca bir kez tara (büyük listelerde kritik).
        var lines: [Data] = []
        lock.lock()
        buffer.append(contentsOf: d)
        var start = 0
        var i = scanned
        buffer.withUnsafeBufferPointer { p in
            while i < p.count {
                if p[i] == 0x0A {
                    lines.append(Data(p[start..<i]))
                    start = i + 1
                }
                i += 1
            }
        }
        if start > 0 { buffer.removeFirst(start) }
        scanned = buffer.count
        lock.unlock()
        let decoder = JSONDecoder()
        for l in lines {
            guard let r = try? decoder.decode(HelperResponse.self, from: l) else { continue }
            lock.lock()
            if r.id == 0, r.event != nil {
                let b = onBroadcast
                lock.unlock()
                b?(r)
                continue
            }
            if r.event != nil {
                let h = eventHandlers[r.id]
                lock.unlock()
                h?(r)
            } else {
                let c = waiters.removeValue(forKey: r.id)
                eventHandlers[r.id] = nil
                lock.unlock()
                c?.resume(returning: r)
            }
        }
    }

    private func shutdown() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let ws = waiters
        waiters = [:]
        eventHandlers = [:]
        lock.unlock()
        for w in ws.values { w.resume(throwing: HelperError(message: L("Disk bağlantısı koptu. Kabloyu kontrol edip diski yeniden açın.", "The disk was disconnected. Check the cable and open the disk again."))) }
        let cb = onClose
        Task { @MainActor in cb?() }
    }

    func call(_ op: String, partition: Int? = nil, ref: String? = nil, items: [DirEntry]? = nil, dest: String? = nil,
              device: String? = nil, onEvent: (@Sendable (HelperResponse) -> Void)? = nil) async throws -> HelperResponse {
        let r: HelperResponse = try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if closed {
                lock.unlock()
                cont.resume(throwing: HelperError(message: L("Disk bağlantısı kapalı.", "The disk connection is closed.")))
                return
            }
            let id = nextId
            nextId += 1
            waiters[id] = cont
            if let onEvent { eventHandlers[id] = onEvent }
            lock.unlock()
            var d = (try? JSONEncoder().encode(HelperRequest(id: id, op: op, partition: partition, ref: ref, items: items, dest: dest, device: device))) ?? Data()
            d.append(0x0A)
            writeQueue.async { [self] in
                do {
                    try input.write(contentsOf: d)
                } catch {
                    lock.lock()
                    let c = waiters.removeValue(forKey: id)
                    lock.unlock()
                    c?.resume(throwing: HelperError(message: L("Yardımcıya yazılamadı.", "Couldn't write to the helper.")))
                }
            }
        }
        if !r.ok { throw HelperError(message: r.error ?? L("Bilinmeyen hata", "Unknown error")) }
        return r
    }

    func cancelCopy() { sendRaw("cancel") }
    func pauseScan() { sendRaw("pauseScan") }
    func resumeScan() { sendRaw("resumeScan") }
    func prioritize(ref: String, path: String) { sendRaw("prioritize", ref: ref, dest: path) }
    func cancelScan() { sendRaw("cancelScan") }

    private func sendRaw(_ op: String, ref: String? = nil, dest: String? = nil) {
        var d = (try? JSONEncoder().encode(HelperRequest(id: 0, op: op, ref: ref, dest: dest))) ?? Data()
        d.append(0x0A)
        lock.lock()
        let isClosed = closed
        lock.unlock()
        if !isClosed { writeQueue.async { [input] in try? input.write(contentsOf: d) } }
    }

    func terminate() {
        try? input.close()
        process?.terminate()
    }
}
