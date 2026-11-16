import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UzDiscCore

/// Finder'ın kendi ikonları: klasörler, bilinen klasörler (Fotoğraflar, Belgeler…) ve dosya türleri.
@MainActor
enum FinderIcons {
    private static var cache: [String: NSImage] = [:]

    private static let specialFolders: [String: String] = {
        var m: [String: String] = [:]
        let home = NSHomeDirectory()
        let groups: [(String, [String])] = [
            ("Pictures", ["fotoğraflar", "fotograflar", "resimler", "pictures", "photos", "fotos", "dcim", "görseller"]),
            ("Documents", ["belgeler", "dokümanlar", "documents", "docs", "evraklar"]),
            ("Music", ["müzik", "muzik", "music", "şarkılar"]),
            ("Movies", ["videolar", "filmler", "movies", "videos", "film"]),
            ("Downloads", ["indirilenler", "downloads", "indirmeler"]),
            ("Desktop", ["masaüstü", "masaustu", "desktop"]),
            ("Public", ["paylaşılan", "public", "ortak"]),
        ]
        for (dir, names) in groups {
            for n in names { m[n] = home + "/" + dir }
        }
        return m
    }()

    static func icon(for e: DirEntry) -> NSImage {
        if e.isDirectory {
            let key = e.name.lowercased(with: Locale(identifier: "tr_TR"))
            if let path = specialFolders[key] {
                return cached("dir:" + path) { NSWorkspace.shared.icon(forFile: path) }
            }
            if key.hasSuffix(".app") {
                return cached("app") { NSWorkspace.shared.icon(for: .applicationBundle) }
            }
            return cached("folder") { NSWorkspace.shared.icon(for: .folder) }
        }
        let ext = (e.name as NSString).pathExtension.lowercased()
        return cached("ext:" + ext) {
            NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
    }

    static var volume: NSImage {
        cached("volume") {
            NSImage(contentsOfFile: "/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/External.icns")
                ?? NSWorkspace.shared.icon(for: UTType("public.volume") ?? .folder)
        }
    }

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let i = cache[key] { return i }
        let i = make()
        cache[key] = i
        return i
    }
}

struct EntryIcon: View {
    let entry: DirEntry
    var size: CGFloat = 18
    var body: some View {
        Image(nsImage: FinderIcons.icon(for: entry))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
