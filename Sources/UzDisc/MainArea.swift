import AppKit
import SwiftUI
import UzDiscCore

struct MainArea: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if model.volume != nil {
                    TopBar()
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                    HStack(spacing: 0) {
                        BrowserContent()
                        if model.showInspector {
                            Rectangle().fill(Theme.stroke).frame(width: 1)
                            InspectorPanel().frame(width: 290)
                        }
                    }
                    BottomBar()
                } else if model.source != nil && model.busy == nil {
                    NoReadablePartitionView()
                } else if model.source == nil && model.busy == nil {
                    WelcomeView()
                } else {
                    Color.clear
                }
            }
            if let msg = model.busy, model.copyProgress == nil { BusyCard(message: msg) { model.cancelBusy() } }
            // ⌘Y: Quick Look (Finder ile aynı)
            Button("") { if let e = model.focusedEntry { model.quickLook(e) } }
                .keyboardShortcut("y", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            if let p = model.copyProgress { CopyOverlay(progress: p) }
            if let s = model.summary { SummaryOverlay(summary: s) }
        }
    }
}

// MARK: - Üst çubuk

struct TopBar: View {
    @EnvironmentObject var model: AppModel

    var title: String {
        switch model.mode {
        case .path: return model.pathStack.last?.name ?? model.volumeTitle
        case .type(let c): return c.title
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                IconButton(symbol: "chevron.left", disabled: !model.canGoBack, help: L("Geri (⌘[)", "Back (⌘[)")) { model.goBack() }
                IconButton(symbol: "chevron.right", disabled: !model.canGoForward, help: L("İleri (⌘])", "Forward (⌘])")) { model.goForward() }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.rounded(17, .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    Breadcrumbs()
                }
                .padding(.leading, 6)
                Spacer(minLength: 12)
                HStack(spacing: 2) {
                    IconButton(symbol: "list.bullet", active: model.viewStyle == .list, help: L("Liste", "List")) { model.setViewStyle(.list) }
                    IconButton(symbol: "square.grid.2x2", active: model.viewStyle == .grid, help: L("Izgara", "Grid")) { model.setViewStyle(.grid) }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
                IconButton(symbol: "sidebar.right", active: model.showInspector, help: L("Önizleme paneli", "Preview panel")) { model.showInspector.toggle() }
                Menu {
                    Picker(L("Sırala", "Sort"), selection: Binding(get: { model.sortKey }, set: { model.setSort($0) })) {
                        Text(L("Ad", "Name")).tag(SortKey.name)
                        Text(L("Değiştirilme", "Modified")).tag(SortKey.date)
                        Text(L("Boyut", "Size")).tag(SortKey.size)
                        Text(L("Tür", "Kind")).tag(SortKey.kind)
                    }
                    Divider()
                    Toggle(L("Sistem dosyalarını göster", "Show system files"), isOn: $model.showHidden)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 32, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("Sıralama ve filtre", "Sort & filter"))
                SearchField(text: $model.query, prompt: model.scanDone ? L("Tüm diskte ara", "Search entire disk") : L("Bu klasörde ara", "Search this folder"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
        .background(Color.black.opacity(0.12))
    }
}

struct Breadcrumbs: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            crumb(model.volumeTitle, depth: 0)
            if case .type(let c) = model.mode {
                sep
                Text(c.title).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            } else {
                ForEach(Array(model.pathStack.enumerated()), id: \.offset) { i, e in
                    sep
                    crumb(e.name, depth: i + 1)
                }
            }
        }
        .lineLimit(1)
    }

    var sep: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3)
    }

    func crumb(_ t: String, depth: Int) -> some View {
        Button { model.goTo(depth: depth) } label: {
            Text(t).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - İçerik

struct BrowserContent: View {
    @EnvironmentObject var model: AppModel

    var isLoadingCurrent: Bool {
        guard case .path = model.mode, let r = model.currentRef else { return false }
        return model.loadingRefs.contains(r)
    }

    var body: some View {
        ZStack {
            if model.rows.isEmpty {
                if isLoadingCurrent {
                    SkeletonList(slow: model.slowRefs.contains(model.currentRef ?? ""))
                } else if case .type = model.mode, !model.scanDone {
                    ScanningHero()
                } else {
                    EmptyFolder()
                }
            } else if model.viewStyle == .list {
                FileList()
            } else {
                FileGrid()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyFolder: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: model.query.isEmpty ? "folder" : "magnifyingglass")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(Theme.text3)
            Text(model.query.isEmpty ? L("Bu klasör boş", "This folder is empty") : L("“\(model.query)” ile eşleşen dosya yok", "No files match “\(model.query)”"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text2)
        }
    }
}

/// EaseUS tarzı tarama ekranı.
struct ScanningHero: View {
    @EnvironmentObject var model: AppModel
    @State private var float = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                ForEach(Array([FileCategory.videos, .photos, .audio].enumerated()), id: \.offset) { i, c in
                    CategoryTile(category: c, size: 46)
                        .rotationEffect(.degrees(Double(i - 1) * 14))
                        .offset(x: CGFloat(i - 1) * 34, y: (float ? -46 : -38) - (i == 1 ? 10 : 0))
                }
                Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                    .resizable()
                    .frame(width: 130, height: 130)
                    .shadow(color: Theme.accent.opacity(0.45), radius: 30, y: 10)
            }
            .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: float)
            .onAppear { float = true }
            .frame(height: 170)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Fmt.count(model.scan?.files ?? 0))
                    .font(Theme.rounded(34, .heavy))
                    .foregroundStyle(Theme.accentGradient)
                    .monospacedDigit()
                Text(L("dosya bulundu…", "files found…")).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.text)
            }
            Text(L("Tarama bitince tüm dosyalar türlerine göre burada listelenecek", "When the scan finishes, every file will be listed here by type"))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.accent.opacity(0.14)))
        }
    }
}

struct SkeletonList: View {
    let slow: Bool
    @State private var phase = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<9, id: \.self) { i in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4).frame(width: 17, height: 17)
                    RoundedRectangle(cornerRadius: 5).frame(width: 22, height: 22)
                    RoundedRectangle(cornerRadius: 4).frame(width: CGFloat(140 + (i * 53) % 180), height: 11)
                    Spacer()
                    RoundedRectangle(cornerRadius: 4).frame(width: 110, height: 9)
                    RoundedRectangle(cornerRadius: 4).frame(width: 60, height: 9)
                }
                .foregroundStyle(Color.white.opacity(phase ? 0.07 : 0.035))
                .padding(.horizontal, 20)
                .frame(height: 40)
            }
            if slow {
                VStack(spacing: 6) {
                    Text(L("Disk yavaş yanıt veriyor…", "The disk is responding slowly…")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.amber)
                    Text(L("Bağlantı yavaş olabilir (USB 2.0 kablo) ya da macOS diski aynı anda kontrol ediyor.\nDosyalar geldikçe burada görünecek.", "The connection may be slow (USB 2.0 cable) or macOS may be checking the disk at the same time.\nFiles will appear here as they arrive."))
                        .font(.system(size: 11.5))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.text3)
                }
                .padding(.top, 20)
            }
            Spacer()
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
        .onAppear { phase = true }
    }
}

// MARK: - Liste

struct FileList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ListHeader()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                        FileRow(row: row, alt: i % 2 == 1)
                    }
                    if case .path = model.mode, let r = model.currentRef, model.loadingRefs.contains(r) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("Okunuyor… \(Fmt.count(model.rows.count)) öğe", "Reading… \(Fmt.count(model.rows.count)) items")).font(.system(size: 12)).foregroundStyle(Theme.text3)
                        }
                        .padding(14)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

struct Columns {
    static let date: CGFloat = 158
    static let size: CGFloat = 96
    static let kind: CGFloat = 120
}

struct ListHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            CheckBox(on: model.allTopChecked) { model.toggleAll() }
                .padding(.leading, 30)
                .padding(.trailing, 14)
            header(L("Ad", "Name"), .name).frame(maxWidth: .infinity, alignment: .leading)
            header(L("Değiştirilme", "Modified"), .date).frame(width: Columns.date, alignment: .leading)
            header(L("Boyut", "Size"), .size).frame(width: Columns.size, alignment: .leading)
            header(L("Tür", "Kind"), .kind).frame(width: Columns.kind, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.black.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    func header(_ t: String, _ k: SortKey) -> some View {
        Button { model.setSort(k) } label: {
            HStack(spacing: 4) {
                Text(t).font(.system(size: 11.5, weight: .semibold))
                if model.sortKey == k {
                    Image(systemName: model.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .heavy))
                }
            }
            .foregroundStyle(model.sortKey == k ? Theme.text : Theme.text2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FileRow: View {
    @EnvironmentObject var model: AppModel
    let row: Row
    let alt: Bool
    @State private var hover = false

    var e: DirEntry { row.entry }

    var body: some View {
        let focused = model.focusedID == row.id
        let on = model.isChecked(e)
        HStack(spacing: 0) {
            // Açma oku
            Group {
                if e.isDirectory, case .path = model.mode, model.query.isEmpty {
                    Button { model.toggleExpand(e) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.text3)
                            .rotationEffect(.degrees(model.expanded.contains(e.ref) ? 90 : 0))
                            .frame(width: 20, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 20)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 20)

            CheckBox(on: on, inherited: model.isInheritedCheck(e)) { model.toggleCheck(e) }
                .padding(.leading, 6)
                .padding(.trailing, 12)

            HStack(spacing: 9) {
                EntryIcon(entry: e, size: 22)
                Text(e.name)
                    .font(.system(size: 13, weight: e.isDirectory ? .semibold : .regular))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let n = model.folderCount(e) {
                    Text("(\(Fmt.count(n)))").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3).monospacedDigit()
                }
                if e.isDirectory && model.loadingRefs.contains(e.ref) { ProgressView().controlSize(.mini) }
                if case .type = model.mode {
                    Text(model.index.path(of: e)).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.head)
                } else if !model.query.isEmpty && model.scanDone {
                    Text(model.index.path(of: e)).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(e.modified.map { Fmt.date.string(from: $0) } ?? "—")
                .frame(width: Columns.date, alignment: .leading)
            Text(sizeText).frame(width: Columns.size, alignment: .leading)
            Text(e.kindName).frame(width: Columns.kind, alignment: .leading).lineLimit(1)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.text2)
        .monospacedDigit()
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(focused ? Theme.accent.opacity(0.16) : (on ? Theme.accent.opacity(0.07) : (hover ? Color.white.opacity(0.045) : (alt ? Theme.rowAlt : .clear))))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.75) : .clear, lineWidth: 1.2)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .gesture(TapGesture(count: 2).onEnded {
            if e.isDirectory { model.openFolder(e) } else { model.toggleCheck(e) }
        })
        .simultaneousGesture(TapGesture().onEnded { model.focusedID = row.id })
        .contextMenu { RowMenu(entry: e) }
    }

    var sizeText: String {
        if e.isDirectory {
            if let s = model.index.recursive[e.ref] { return Fmt.bytes(s.bytes) }
            return "—"
        }
        return Fmt.bytes(e.size)
    }
}

struct RowMenu: View {
    @EnvironmentObject var model: AppModel
    let entry: DirEntry
    var body: some View {
        if !entry.isDirectory {
            Button(L("Önizle (⌘Y)", "Quick Look (⌘Y)")) { model.quickLook(entry) }
        }
        Button(L("“\(entry.name)” öğesini Mac'e kopyala…", "Copy “\(entry.name)” to Mac…")) { model.copy([entry]) }
        if entry.isDirectory && !model.scanDone {
            Button(L("⚡ Önce bu klasörü tara", "⚡ Scan this folder first")) { model.prioritize(entry) }
        }
        Button(model.checked[entry.id] == nil ? L("İşaretle", "Check") : L("İşareti kaldır", "Uncheck")) { model.toggleCheck(entry) }
        if entry.isDirectory {
            Divider()
            Button(L("Aç", "Open")) { model.openFolder(entry) }
        }
    }
}

// MARK: - Izgara

struct FileGrid: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 160), spacing: 14)], spacing: 14) {
                ForEach(model.rows.filter { $0.depth == 0 }) { row in
                    GridTile(entry: row.entry, id: row.id)
                }
            }
            .padding(18)
        }
    }
}

struct GridTile: View {
    @EnvironmentObject var model: AppModel
    let entry: DirEntry
    let id: String
    @State private var hover = false

    var body: some View {
        let on = model.isChecked(entry)
        let focused = model.focusedID == id
        VStack(spacing: 8) {
            Group {
                if let t = model.thumbs[entry.id] {
                    Image(nsImage: t)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                } else {
                    EntryIcon(entry: entry, size: 64)
                }
            }
            .frame(height: 72)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            .padding(.top, 14)
            .onAppear { if FileCategory.of(entry.name) == .photos { model.requestThumb(entry) } }
            Text(entry.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 30, alignment: .top)
            Text(entry.isDirectory ? (model.folderCount(entry).map { L("\(Fmt.count($0)) öğe", "\(Fmt.count($0)) items") } ?? L("Klasör", "Folder")) : Fmt.bytes(entry.size))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(focused ? Theme.accent.opacity(0.16) : (on ? Theme.accent.opacity(0.08) : (hover ? Color.white.opacity(0.06) : Color.white.opacity(0.025))))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.75) : Theme.stroke, lineWidth: focused ? 1.3 : 1)
        )
        .overlay(alignment: .topLeading) {
            if on || hover {
                CheckBox(on: on, inherited: model.isInheritedCheck(entry)) { model.toggleCheck(entry) }.padding(9)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .gesture(TapGesture(count: 2).onEnded {
            if entry.isDirectory { model.openFolder(entry) } else { model.toggleCheck(entry) }
        })
        .simultaneousGesture(TapGesture().onEnded { model.focusedID = id })
        .contextMenu { RowMenu(entry: entry) }
    }
}

// MARK: - Alt çubuk (ay evresi teması)

/// Tarama sürerken evreleri dönen ay; bitince parlayan dolunay.
struct MoonPhase: View {
    let done: Bool
    let paused: Bool
    var size: CGFloat = 30
    private let phases = ["moonphase.new.moon", "moonphase.waxing.crescent", "moonphase.first.quarter",
                          "moonphase.waxing.gibbous", "moonphase.full.moon", "moonphase.waning.gibbous",
                          "moonphase.last.quarter", "moonphase.waning.crescent"]

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [(done ? Color(hex: 0xFFE9A8) : Theme.accent).opacity(0.45), .clear],
                                     center: .center, startRadius: 2, endRadius: size))
                .frame(width: size * 2, height: size * 2)
            if done {
                Image(systemName: "moonphase.full.moon")
                    .font(.system(size: size, weight: .regular))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFFF4D0), Color(hex: 0xFFD27A)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color(hex: 0xFFD27A).opacity(0.7), radius: 10)
            } else {
                TimelineView(.periodic(from: .now, by: 0.22)) { ctx in
                    let i = paused ? 2 : Int(ctx.date.timeIntervalSinceReferenceDate / 0.22) % phases.count
                    Image(systemName: phases[i])
                        .font(.system(size: size, weight: .regular))
                        .foregroundStyle(LinearGradient(colors: [Color(hex: 0xDCE4FF), Theme.accent], startPoint: .top, endPoint: .bottom))
                }
            }
        }
        .frame(width: size + 14, height: size + 14)
    }
}

/// Üst kenarda akan ay ışığı çizgisi.
struct MoonlightLine: View {
    let active: Bool
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.stroke)
                if active {
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                        LinearGradient(colors: [.clear, Theme.accent, Theme.accent2, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.35)
                            .offset(x: -g.size.width * 0.35 + (g.size.width * 1.35) * t)
                    }
                }
            }
        }
        .frame(height: 2)
        .clipped()
    }
}

struct StatPill: View {
    let value: String
    let label: String
    var tint: Color = Theme.text

    var body: some View {
        HStack(spacing: 5) {
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(tint).monospacedDigit()
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        .fixedSize()
    }
}

/// Canlı disk okuma hızı: MB/sn ve işlem/sn.
struct IORatePill: View {
    let bytes: Double
    let ops: Double
    let stalled: Bool

    var color: Color { stalled ? Theme.red : (bytes > 0 ? Theme.green : Theme.text3) }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: bytes > 0 ? 4 : 0)
            Text(stalled ? L("yanıt yok", "no response") : "\(Fmt.bytes(UInt64(bytes)))\(L("/sn", "/s"))")
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(stalled ? Theme.red : Theme.text)
                .monospacedDigit()
            Text(L("\(Fmt.count(Int(ops))) işlem/sn", "\(Fmt.count(Int(ops))) ops/s"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text3)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 1))
        .fixedSize()
        .help(L("Diskten anlık okuma hızı", "Live disk read speed"))
    }
}

struct BottomBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.scan
        let done = s?.done ?? false
        let sel = model.checkedSummary
        let priority = s?.current.hasPrefix("⚡") ?? false
        VStack(spacing: 0) {
            if model.stallSeconds > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                    Text(L("Disk \(model.stallSeconds) saniyedir yanıt vermiyor.", "The disk hasn't responded for \(model.stallSeconds) s."))
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.text)
                    Text(L("Sürücü bağlantıda takıldı (yetersiz güç/USB 2.0 kablo olabilir). Kabloyu çıkarıp USB 3 bir kabloyla tak.", "The drive stalled on the connection (low power / USB 2.0 cable?). Replug it with a USB 3 cable."))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Theme.amber.opacity(0.14))
            }
            MoonlightLine(active: !done && !model.scanPaused && model.stallSeconds == 0)
            HStack(spacing: 12) {
                MoonPhase(done: done, paused: model.scanPaused, size: 26)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(done ? L("Dizin hazır", "Index ready") : (model.scanPaused ? L("Tarama duraklatıldı", "Scan paused") : L("Disk taranıyor", "Scanning disk")))
                            .font(Theme.rounded(14, .bold))
                            .foregroundStyle(done ? Color(hex: 0xFFE3A0) : Theme.text)
                        if !done {
                            Button { model.togglePause() } label: {
                                Image(systemName: model.scanPaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.text2)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Color.white.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                            .help(model.scanPaused ? L("Sürdür", "Resume") : L("Duraklat", "Pause"))
                        }
                        if let d = model.currentDisk, d.isSlowLink {
                            Chip(text: "USB 2.0", symbol: "tortoise.fill", color: Theme.amber)
                                .help(L("Disk 480 Mb/s ile bağlı. USB 3 destekli bir USB-C kabloyla tarama ve kopyalama 10–20 kat hızlanır.", "The disk is connected at 480 Mb/s. A USB 3 capable USB-C cable makes scanning and copying 10–20× faster."))
                        }
                    }
                    if let s, !done, !s.current.isEmpty {
                        HStack(spacing: 5) {
                            if priority {
                                Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Theme.amber)
                            }
                            Text(priority ? String(s.current.dropFirst(2)) : s.current)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(priority ? Theme.amber : Theme.text3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else if done {
                        Text(L("Gezinme ve arama artık anında — diske tekrar gidilmez.", "Browsing and search are now instant — no more disk reads."))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                    }
                }
                .frame(minWidth: 150, maxWidth: 340, alignment: .leading)
                .layoutPriority(0)

                HStack(spacing: 6) {
                    IORatePill(bytes: model.ioRate.bytes, ops: model.ioRate.ops, stalled: model.stallSeconds > 0)
                    StatPill(value: Fmt.count(s?.files ?? 0), label: L("dosya", "files"), tint: Theme.accent)
                    StatPill(value: Fmt.count(s?.dirs ?? 0), label: L("klasör", "folders"))
                    StatPill(value: Fmt.bytes(s?.bytes ?? 0), label: "")
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                if sel.count > 0 {
                    HStack(spacing: 8) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(L("\(Fmt.count(sel.count)) seçili", "\(Fmt.count(sel.count)) selected")).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.text)
                            Text(sel.unknownDirs && sel.bytes == 0 ? L("boyut hesaplanıyor…", "calculating size…") : Fmt.bytes(sel.bytes) + (sel.unknownDirs ? "+" : ""))
                                .font(.system(size: 11)).foregroundStyle(Theme.text2).monospacedDigit()
                        }
                        Button { model.checked = [:] } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3)
                                .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .help(L("Seçimi temizle", "Clear selection"))
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                PrimaryButton(title: sel.count > 0 ? L("Mac'e Kopyala", "Copy to Mac") : L("Dosya seç", "Select files"), symbol: "square.and.arrow.down.fill",
                              disabled: sel.count == 0 || model.copyProgress != nil) { model.copyChecked() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: sel.count > 0)
        }
        .background(
            LinearGradient(colors: [Color(hex: 0x141A28).opacity(0.95), Color(hex: 0x0F131D).opacity(0.98)], startPoint: .top, endPoint: .bottom)
        )
    }
}
