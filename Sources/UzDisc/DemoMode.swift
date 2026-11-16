import AppKit
import SwiftUI
import UzDiscCore

/// README ekran görüntülerini üretmek için otomatik mod.
/// UZDISC_SCREENSHOT=<png> ayarlıysa çalışır; normal kullanımda hiçbir etkisi yoktur.
@MainActor
enum DemoMode {
    static func runIfRequested(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["UZDISC_SCREENSHOT"] else { return }
        // Gizlilik: ekran görüntülerinde bu Mac'e takılı gerçek diskler asla görünmez.
        model.disks = []
        model.showInternal = false

        if let w = NSApp.windows.first {
            w.setContentSize(NSSize(width: 1240, height: 780))
            w.center()
        }
        if let img = env["UZDISC_DEMO_IMAGE"] {
            await model.openImage(URL(fileURLWithPath: img))
            // Taramanın bitmesini bekle.
            for _ in 0..<100 where !model.scanDone { try? await Task.sleep(nanoseconds: 100_000_000) }
            if let v = env["UZDISC_DEMO_VIEW"], let st = ViewStyle(rawValue: v) { model.viewStyle = st }
            if let m = env["UZDISC_DEMO_TYPE"], let c = FileCategory(rawValue: m) { model.setMode(.type(c)) }
            for part in (env["UZDISC_DEMO_PATH"] ?? "").split(separator: "/") {
                if let e = model.rows.first(where: { $0.entry.name == part })?.entry {
                    model.openFolder(e)
                    for _ in 0..<30 where model.loadingRefs.contains(e.ref) { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
            }
            for name in (env["UZDISC_DEMO_EXPAND"] ?? "").split(separator: ",") {
                if let e = model.rows.first(where: { $0.entry.name == name })?.entry { model.toggleExpand(e) }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if let sel = env["UZDISC_DEMO_SELECT"] {
                for name in sel.split(separator: ",") {
                    if let e = model.rows.first(where: { $0.entry.name == name })?.entry { model.toggleCheck(e) }
                }
            }
            if let f = env["UZDISC_DEMO_FOCUS"], let r = model.rows.first(where: { $0.entry.name == f }) { model.focusedID = r.id }
            if let e = model.focusedEntry { model.requestThumb(e) }
            if model.viewStyle == .grid { for r in model.rows { model.requestThumb(r.entry) } }
            for _ in 0..<40 where !model.extracting.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            model.disks = []
            switch env["UZDISC_DEMO_STATE"] {
            case "copy":
                model.copyStarted = Date().addingTimeInterval(-41)
                model.copyProgress = CopyProgress(bytesDone: 1_630_000_000, bytesTotal: 2_740_000_000, filesDone: 214,
                                                  filesTotal: 388, currentFile: L("Fotoğraflar/Tatil 2026/IMG_4187.jpg", "Photos/Summer Trip 2026/IMG_4187.jpg"))
            case "done":
                model.summary = CopySummary(files: 388, bytes: 2_740_000_000, errors: [], cancelled: false,
                                            destination: "/Users/demo/Desktop/Recovered", createdPaths: [])
            default:
                break
            }
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        capture(to: out)
        NSApp.terminate(nil)
    }

    static func capture(to path: String) {
        guard let win = NSApp.windows.first(where: { $0.isVisible }) else { return }
        // Pencere çerçevesiyle birlikte (başlık çubuğu dahil) yakala.
        let wid = CGWindowID(win.windowNumber)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(wid)", path]
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus == 0, FileManager.default.fileExists(atPath: path) { return }
        // Yedek: görünümü kendi içinde çiz.
        guard let view = win.contentView?.superview ?? win.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
