import AppKit
import SwiftUI
import UzDiscCore

// MARK: - Karşılama

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var glow = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 30) {
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(RadialGradient(colors: [Theme.accent.opacity(0.45), .clear], center: .center, startRadius: 4, endRadius: 120))
                            .frame(width: 240, height: 240)
                            .scaleEffect(glow ? 1.08 : 0.92)
                            .opacity(glow ? 1 : 0.7)
                        AppLogo(size: 112)
                            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    }
                    .frame(height: 190)
                    .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: glow)
                    .onAppear { glow = true }

                    Text(L("Diskini aç. Dosyalarını kurtar.", "Open your disk. Rescue your files."))
                        .font(Theme.rounded(34, .heavy))
                        .foregroundStyle(LinearGradient(colors: [.white, Color(hex: 0xC9D4FF)], startPoint: .top, endPoint: .bottom))
                    Text(L("Mac'in açamadığı ya da Finder'da görünmeyen diskleri salt okunur olarak tarar,\ndosyalarını güvenle Mac'ine kopyalar. Ücretsiz, sınırsız, açık kaynak.", "Scans disks your Mac can't open — or that never show up in Finder — read-only,\nand safely copies your files to your Mac. Free, unlimited, open source."))
                        .multilineTextAlignment(.center)
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.text2)
                        .lineSpacing(3)
                    HStack(spacing: 8) {
                        Chip(text: "exFAT", color: Color(hex: 0xFFB547))
                        Chip(text: "FAT32 · FAT16", color: Color(hex: 0x60A5FA))
                        Chip(text: "NTFS", color: Color(hex: 0xA78BFA))
                        Chip(text: "MBR · GPT", color: Color(hex: 0x2DD4BF))
                    }
                }
                .padding(.top, 40)

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: model.externalDisks.isEmpty ? L("Disk bekleniyor", "Waiting for a disk") : L("Takılı diskler", "Connected disks"))
                    if model.externalDisks.isEmpty {
                        HStack(spacing: 14) {
                            Image(systemName: "cable.connector")
                                .font(.system(size: 22))
                                .foregroundStyle(Theme.text3)
                            Text(L("Harici diskini tak, burada görünecek.", "Plug in your external disk and it will appear here."))
                                .font(.system(size: 13.5))
                                .foregroundStyle(Theme.text2)
                            Spacer()
                            Button(L("Yenile", "Refresh")) { model.refreshDisks() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                        }
                        .padding(18)
                        .glassCard()
                    }
                    ForEach(model.externalDisks) { d in WelcomeDiskCard(disk: d) }
                }
                .frame(maxWidth: 620)

                HStack(alignment: .top, spacing: 14) {
                    FeatureCard(symbol: "lock.shield.fill", color: Theme.green, title: L("Asla yazmaz", "Never writes"),
                                text: L("Disk yalnızca okuma modunda açılır. Silme, onarma ya da biçimlendirme yok.", "Disks are opened read-only. No deleting, repairing or formatting — ever."))
                    FeatureCard(symbol: "bolt.fill", color: Theme.amber, title: L("Bağlanmayı beklemez", "No mounting needed"),
                                text: L("macOS diski bağlayamasa bile dosyalar doğrudan diskten okunur.", "Even if macOS can't mount the disk, files are read straight from it."))
                    FeatureCard(symbol: "square.grid.2x2.fill", color: Theme.accent2, title: L("Türe göre bul", "Find by type"),
                                text: L("Fotoğraf, video, belge… Tüm diski tarar, saniyeler içinde ara.", "Photos, videos, documents… Scans the whole disk so you can search in seconds."))
                }
                .frame(maxWidth: 760)

                UzmoonCredit().padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
        }
    }
}

struct WelcomeDiskCard: View {
    @EnvironmentObject var model: AppModel
    let disk: DiskInfo
    @State private var hover = false

    var body: some View {
        HStack(spacing: 16) {
            DriveIcon(size: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(disk.name).font(Theme.rounded(17, .bold)).foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    Chip(text: Fmt.bytes(disk.size), symbol: "internaldrive", color: Theme.text2)
                    if let l = disk.linkDescription {
                        Chip(text: l, symbol: disk.isSlowLink ? "tortoise.fill" : "bolt.fill",
                             color: disk.isSlowLink ? Theme.amber : Theme.green)
                    }
                }
                if disk.isSlowLink {
                    Text(L("Yavaş bağlantı: USB 3 destekli bir USB-C kabloyla 10–20 kat hızlanır.", "Slow connection: a USB 3 capable USB-C cable is 10–20× faster."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.amber.opacity(0.9))
                }
            }
            Spacer()
            PrimaryButton(title: L("Tara ve Aç", "Scan & Open"), symbol: "sparkle.magnifyingglass") { Task { await model.open(disk: disk) } }
        }
        .padding(18)
        .glassCard(highlight: hover)
        .onHover { hover = $0 }
    }
}

struct FeatureCard: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.15))
                Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(color)
            }
            .frame(width: 36, height: 36)
            Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .glassCard()
    }
}

extension View {
    func glassCard(highlight: Bool = false) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(highlight ? 0.06 : 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(highlight ? 0.2 : 0.11), Color.white.opacity(0.03)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

struct NoReadablePartitionView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 50, weight: .ultraLight))
                .foregroundStyle(Theme.text3)
            Text(L("Bu diskte UzDisc'in okuyabileceği bir bölüm yok", "This disk has no partition UzDisc can read"))
                .font(Theme.rounded(20, .bold))
                .foregroundStyle(Theme.text)
            Text(L("UzDisc exFAT, FAT32/FAT16 ve NTFS bölümlerini okur.\nAPFS ve HFS+ (Mac biçimli) bölümleri macOS zaten kendisi açar.", "UzDisc reads exFAT, FAT32/FAT16 and NTFS partitions.\nAPFS and HFS+ (Mac-formatted) partitions are opened by macOS itself."))
                .multilineTextAlignment(.center)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.text2)
            if !model.partitions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.partitions) { p in
                        HStack {
                            Text(p.typeName).lineLimit(1).foregroundStyle(Theme.text)
                            Spacer()
                            Text(Fmt.bytes(p.length)).foregroundStyle(Theme.text3).monospacedDigit()
                        }
                        .font(.system(size: 12.5))
                    }
                }
                .padding(16)
                .frame(maxWidth: 440)
                .glassCard()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Katmanlar

struct BusyCard: View {
    let message: String
    var onCancel: (() -> Void)? = nil
    @State private var showCancel = false

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(message).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            if showCancel, let onCancel {
                Button(L("İptal", "Cancel"), action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.leading, 6)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            showCancel = true
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.strokeHi, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }
}

struct Dimmer: View {
    var body: some View { Color.black.opacity(0.45).ignoresSafeArea().transition(.opacity) }
}

struct CopyOverlay: View {
    @EnvironmentObject var model: AppModel
    let progress: CopyProgress

    var fraction: Double {
        progress.bytesTotal > 0 ? min(1, Double(progress.bytesDone) / Double(progress.bytesTotal)) : 0
    }

    var speed: Double {
        let t = Date().timeIntervalSince(model.copyStarted)
        return t > 0.5 ? Double(progress.bytesDone) / t : 0
    }

    var eta: String {
        guard speed > 0, progress.bytesTotal > progress.bytesDone else { return "—" }
        let s = Double(progress.bytesTotal - progress.bytesDone) / speed
        if s < 60 { return L("\(max(1, Int(s))) sn", "\(max(1, Int(s))) s") }
        if s < 3600 { return L("\(Int(s / 60) + 1) dk", "\(Int(s / 60) + 1) min") }
        return L("\(Int(s / 3600)) sa \(Int(s.truncatingRemainder(dividingBy: 3600) / 60)) dk", "\(Int(s / 3600)) h \(Int(s.truncatingRemainder(dividingBy: 3600) / 60)) min")
    }

    var body: some View {
        ZStack {
            Dimmer()
            VStack(spacing: 20) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.07), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(AngularGradient(colors: [Theme.accent, Theme.accent2, Theme.accent], center: .center),
                                style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: Theme.accent.opacity(0.6), radius: 10)
                        .animation(.easeOut(duration: 0.3), value: fraction)
                    VStack(spacing: 2) {
                        Text("%\(Int(fraction * 100))")
                            .font(Theme.rounded(38, .heavy))
                            .foregroundStyle(Theme.text)
                            .monospacedDigit()
                        Text("\(Fmt.bytes(progress.bytesDone)) / \(Fmt.bytes(progress.bytesTotal))")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.text2)
                            .monospacedDigit()
                    }
                }
                .frame(width: 170, height: 170)

                VStack(spacing: 4) {
                    Text(L("Mac'e kopyalanıyor", "Copying to Mac")).font(Theme.rounded(18, .bold)).foregroundStyle(Theme.text)
                    Text(progress.currentFile.isEmpty ? L("Hazırlanıyor…", "Preparing…") : progress.currentFile)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 0) {
                    stat(L("Hız", "Speed"), speed > 0 ? "\(Fmt.bytes(UInt64(speed)))\(L("/sn", "/s"))" : "—")
                    Rectangle().fill(Theme.stroke).frame(width: 1, height: 30)
                    stat(L("Kalan", "Remaining"), eta)
                    Rectangle().fill(Theme.stroke).frame(width: 1, height: 30)
                    stat(L("Dosya", "File"), "\(Fmt.count(progress.filesDone)) / \(Fmt.count(progress.filesTotal))")
                }
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))

                HStack {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.green)
                    Text(L("Kaynak disk salt okunur", "Source disk is read-only")).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    Spacer()
                    Button { model.cancelCopy() } label: {
                        Text(L("İptal", "Cancel")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            .padding(.horizontal, 18).frame(height: 32)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(26)
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.strokeHi, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
        }
    }

    func stat(_ t: String, _ v: String) -> some View {
        VStack(spacing: 3) {
            Text(t.uppercased(with: Lang.locale)).font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.text3)
            Text(v).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

struct SummaryOverlay: View {
    @EnvironmentObject var model: AppModel
    let summary: CopySummary
    @State private var pop = false

    var ok: Bool { !summary.cancelled && summary.errors.isEmpty }

    var body: some View {
        ZStack {
            Dimmer()
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill((ok ? Theme.green : (summary.cancelled ? Theme.text3 : Theme.amber)).opacity(0.15))
                        .frame(width: 92, height: 92)
                        .scaleEffect(pop ? 1 : 0.6)
                    Image(systemName: summary.cancelled ? "xmark" : (ok ? "checkmark" : "exclamationmark"))
                        .font(.system(size: 38, weight: .heavy))
                        .foregroundStyle(ok ? Theme.green : (summary.cancelled ? Theme.text2 : Theme.amber))
                        .scaleEffect(pop ? 1 : 0.3)
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.55), value: pop)
                .onAppear { pop = true }

                Text(summary.cancelled ? L("Kopyalama iptal edildi", "Copy cancelled") : (ok ? L("Dosyaların kurtarıldı", "Your files are safe") : L("Bazı dosyalar kopyalanamadı", "Some files couldn't be copied")))
                    .font(Theme.rounded(22, .heavy))
                    .foregroundStyle(Theme.text)
                Text(L("\(Fmt.count(summary.files)) dosya · \(Fmt.bytes(summary.bytes))", "\(Fmt.count(summary.files)) files · \(Fmt.bytes(summary.bytes))"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .monospacedDigit()

                if !summary.errors.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(summary.errors, id: \.self) { e in
                                Text(e).font(.system(size: 11)).foregroundStyle(Theme.text2).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
                }

                HStack(spacing: 10) {
                    Button { model.summary = nil } label: {
                        Text(L("Kapat", "Close")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            .padding(.horizontal, 20).frame(height: 40)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    PrimaryButton(title: L("Finder'da Göster", "Show in Finder"), symbol: "folder.fill") {
                        let urls = summary.createdPaths.map { URL(fileURLWithPath: $0) }
                        if urls.isEmpty {
                            NSWorkspace.shared.open(URL(fileURLWithPath: summary.destination))
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting(urls)
                        }
                        model.summary = nil
                    }
                }
                .padding(.top, 4)
            }
            .padding(30)
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.strokeHi, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
        }
    }
}


// MARK: - Önizleme paneli

struct InspectorPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let e = model.focusedEntry {
                InspectorContent(entry: e).id(e.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "eye")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.text3)
                    Text(L("Bir dosyaya tıkla,\nne olduğunu burada gör.", "Click a file\nto see what it is."))
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.opacity(0.14))
    }
}

struct InspectorContent: View {
    @EnvironmentObject var model: AppModel
    let entry: DirEntry

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.035))
                    if let t = model.thumbs[entry.id] {
                        Image(nsImage: t)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(10)
                    } else {
                        EntryIcon(entry: entry, size: 96).shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                    }
                    if model.extracting.contains(entry.id) {
                        VStack {
                            Spacer()
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(L("Diskten okunuyor…", "Reading from disk…")).font(.system(size: 10.5)).foregroundStyle(Theme.text2)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                            .padding(10)
                        }
                    }
                }
                .frame(height: 210)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))

                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.name)
                        .font(Theme.rounded(16, .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    if entry.isDirectory {
                        Chip(text: L("Klasör", "Folder"), symbol: "folder.fill", color: Theme.accent)
                    } else {
                        let c = FileCategory.of(entry.name)
                        Chip(text: entry.kindName, symbol: c.symbol, color: c.colors[0])
                    }
                }

                VStack(spacing: 0) {
                    if entry.isDirectory {
                        info(L("Dosya sayısı", "Files"), model.folderCount(entry).map { Fmt.count($0) } ?? (model.scanDone ? "—" : L("taranıyor…", "scanning…")))
                        info(L("Toplam boyut", "Total size"), model.index.recursive[entry.ref].map { Fmt.bytes($0.bytes) } ?? (model.scanDone ? "—" : L("taranıyor…", "scanning…")))
                    } else {
                        info(L("Boyut", "Size"), Fmt.bytes(entry.size))
                    }
                    info(L("Değiştirilme", "Modified"), entry.modified.map { Fmt.date.string(from: $0) } ?? "—")
                    info(L("Konum", "Location"), model.index.path(of: entry))
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.03)))

                VStack(spacing: 8) {
                    if entry.isDirectory {
                        wideButton(L("Klasörü Aç", "Open Folder"), "folder") { model.openFolder(entry) }
                        if !model.scanDone {
                            wideButton(L("Önce bunu tara", "Scan this first"), "bolt.fill") { model.prioritize(entry) }
                        }
                    } else {
                        wideButton(L("Önizle", "Quick Look"), "eye.fill", hint: "⌘Y") { model.quickLook(entry) }
                    }
                    PrimaryButton(title: L("Mac'e Kopyala", "Copy to Mac"), symbol: "square.and.arrow.down.fill") { model.copy([entry]) }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .onAppear { model.requestThumb(entry) }
    }

    func info(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
            Spacer(minLength: 10)
            Text(v)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .truncationMode(.head)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    func wideButton(_ t: String, _ s: String, hint: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: s).font(.system(size: 12, weight: .bold))
                Text(t).font(.system(size: 13, weight: .semibold))
                if let hint {
                    Text(hint).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.strokeHi, lineWidth: 1))
                }
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
