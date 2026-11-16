import SwiftUI
import UzDiscCore

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 262)
            Rectangle().fill(Theme.stroke).frame(width: 1)
            MainArea()
        }
        .background(NightSky())
        .id(model.langVersion)
        .preferredColorScheme(.dark)
        .alert(L("Bir sorun oluştu", "Something went wrong"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            if model.needsFullDiskAccess {
                Button(L("Tam Disk Erişimi Ayarlarını Aç", "Open Full Disk Access Settings")) { model.openFullDiskAccessSettings() }
                Button(L("Kapat", "Close"), role: .cancel) {}
            } else {
                Button(L("Tamam", "OK"), role: .cancel) {}
            }
        } message: {
            if model.needsFullDiskAccess {
                Text(L("macOS, harici disklerin doğrudan okunmasına yalnızca Tam Disk Erişimi izni olan uygulamalarda izin veriyor.\n\n1. Sistem Ayarları → Gizlilik ve Güvenlik → Tam Disk Erişimi\n2. UzDisc'i listeden kaldırıp (−) yeniden ekle (+)\n3. UzDisc'i kapatıp yeniden aç.\n\nUzDisc bu izinle de diske yalnızca okuma amaçlı erişir.", "macOS only lets apps with Full Disk Access read external disks directly.\n\n1. System Settings → Privacy & Security → Full Disk Access\n2. Remove UzDisc from the list (−) and add it again (+)\n3. Quit and reopen UzDisc.\n\nEven with this permission, UzDisc only ever reads from the disk."))
            } else {
                Text(model.errorMessage ?? "")
            }
        }
    }
}

// MARK: - Kenar çubuğu

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Başlık (trafik ışıklarının altında)
            HStack(spacing: 10) {
                AppLogo(size: 26)
                Text("UzDisc")
                    .font(Theme.rounded(18, .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: L("Diskleri yenile", "Refresh disks")) { model.refreshDisks() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 46)
            .padding(.bottom, 14)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    if model.volume != nil {
                        VolumeSection()
                    }
                    DiskSection()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)
            SidebarFooter()
        }
        .background(
            LinearGradient(colors: [Theme.sidebarTop.opacity(0.92), Theme.sidebarBottom.opacity(0.96)], startPoint: .top, endPoint: .bottom)
        )
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased(with: Lang.locale))
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 6)
    }
}

struct DiskSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: L("Diskler", "Disks"))
            if model.externalDisks.isEmpty && !model.showInternal {
                Text(L("Takılı harici disk yok", "No external disks connected"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            ForEach(model.externalDisks) { d in DiskRow(disk: d) }
            if model.showInternal {
                ForEach(model.internalDisks) { d in DiskRow(disk: d) }
            }
            if let s = model.source, s.isImage {
                SidebarRow(selected: true, action: {}) {
                    Image(systemName: "opticaldiscdrive.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.accent2)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(s.subtitle).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                }
            }
            Button { model.chooseImage() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle").font(.system(size: 13))
                    Text(L("Disk kalıbı aç…", "Open disk image…")).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }
}

struct SidebarRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { content() }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.09) : (hover ? Color.white.opacity(0.045) : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Theme.strokeHi : .clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct DiskRow: View {
    @EnvironmentObject var model: AppModel
    let disk: DiskInfo

    var body: some View {
        let selected = model.source?.id == disk.bsdName
        SidebarRow(selected: selected, action: { Task { await model.open(disk: disk) } }) {
            Group {
                if disk.isInternal {
                    Image(systemName: "internaldrive.fill").font(.system(size: 18)).foregroundStyle(Theme.text3)
                } else {
                    DriveIcon(size: 28)
                }
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(disk.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 5) {
                    Text(Fmt.bytes(disk.size))
                    if let l = disk.linkDescription {
                        Text("·")
                        Text(l).foregroundStyle(disk.isSlowLink && !disk.isInternal ? Theme.amber : Theme.text3)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if disk.isSlowLink && !disk.isInternal {
                Image(systemName: "tortoise.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.amber)
                    .help(L("Disk USB 2.0 hızında bağlı (480 Mb/s). USB 3 destekli bir USB-C kablo kullanırsan 10–20 kat hızlanır.", "The disk is connected at USB 2.0 speed (480 Mb/s). A USB 3 capable USB-C cable is 10–20× faster."))
            }
        }
    }
}

struct VolumeSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Birim başlığı
            HStack(spacing: 10) {
                Image(systemName: "house.fill").font(.system(size: 13)).foregroundStyle(Theme.text2)
                Text(model.volumeTitle).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                if let v = model.volume { Chip(text: v.fsName, color: Theme.accent) }
            }
            .padding(.horizontal, 6)

            if model.partitions.filter({ $0.fileSystem != nil }).count > 1 {
                Menu {
                    ForEach(model.partitions.filter { $0.fileSystem != nil }) { p in
                        Button("\(p.displayName) · \(Fmt.bytes(p.length))") { Task { await model.openPartition(p) } }
                    }
                } label: {
                    Text("Bölüm: \(model.partitions.first { $0.index == model.selectedPartition }?.displayName ?? "")")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 6)
            }

            ModeSwitch()

            switch model.mode {
            case .path: PathShortcuts()
            case .type: TypeList()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

struct ModeSwitch: View {
    @EnvironmentObject var model: AppModel
    @Namespace private var ns

    var isType: Bool { if case .type = model.mode { return true } else { return false } }

    var body: some View {
        HStack(spacing: 0) {
            seg(L("Konum", "Location"), "folder.fill", active: !isType) { model.setMode(.path) }
            seg(L("Tür", "Kind"), "square.grid.2x2.fill", active: isType) { model.setMode(.type(.photos)) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    func seg(_ t: String, _ s: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { action() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: s).font(.system(size: 10, weight: .bold))
                Text(t).font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(active ? Theme.text : Theme.text3)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accentGradient.opacity(0.9))
                        .shadow(color: Theme.accent.opacity(0.4), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "seg", in: ns)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PathShortcuts: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let root = model.volume?.rootRef ?? ""
        let folders = (model.index.children[root] ?? [])
            .filter { $0.isDirectory && (model.showHidden || !AppModel.isSystemJunk($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        VStack(alignment: .leading, spacing: 2) {
            SidebarRow(selected: model.mode == .path && model.pathStack.isEmpty, action: { model.goTo(depth: 0) }) {
                DriveIcon(size: 18).frame(width: 22)
                Text(L("Tüm disk", "Entire disk")).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                if let s = model.index.recursive[root] {
                    Text(Fmt.count(s.files)).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3).monospacedDigit()
                }
            }
            ForEach(folders.prefix(14)) { f in
                SidebarRow(selected: model.pathStack.first?.ref == f.ref, action: { model.openFolder(f) }) {
                    EntryIcon(entry: f, size: 18).frame(width: 22)
                    Text(f.name).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    if let s = model.index.recursive[f.ref] {
                        Text(Fmt.count(s.files)).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3).monospacedDigit()
                    }
                }
            }
        }
        .id(model.indexVersion)
    }
}

struct TypeList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(FileCategory.allCases) { c in
                let selected = model.mode == .type(c)
                let stat = model.index.categories[c]
                SidebarRow(selected: selected, action: { model.setMode(.type(c)) }) {
                    CategoryTile(category: c, size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        if let stat, stat.bytes > 0 {
                            Text(Fmt.bytes(stat.bytes)).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                        }
                    }
                    Spacer()
                    if let stat {
                        Text(Fmt.count(stat.count))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(selected ? Theme.text : Theme.text2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                            .monospacedDigit()
                    } else if !model.scanDone {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            if !model.scanDone {
                Text(L("Türler tarama bitince tamamlanır", "Types fill in as the scan completes"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
        }
        .id(model.indexVersion)
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Theme.stroke).frame(height: 1).padding(.horizontal, -16)
            Toggle(isOn: $model.showInternal) {
                Text(L("Dahili diskleri göster", "Show internal disks")).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Toggle(isOn: Binding(get: { MountBlocker.shared.enabled }, set: { MountBlocker.shared.enabled = $0; model.objectWillChange.send() })) {
                Text(L("macOS diski bağlamaya çalışmasın", "Stop macOS from mounting disks")).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(L("Açıkken, UzDisc çalıştığı sürece macOS harici diskleri otomatik bağlamaz. Böylece yavaş bağlantıyı macOS'un disk kontrolü meşgul etmez; diski önce UzDisc okur.", "When on, macOS won't automount external disks while UzDisc is running, so its disk check doesn't hog a slow connection — UzDisc reads the disk first."))
            HStack(spacing: 7) {
                Image(systemName: "lock.shield.fill").font(.system(size: 13)).foregroundStyle(Theme.green)
                Text(L("Salt okunur — diske asla yazılmaz", "Read-only — never writes to the disk")).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text2)
            }
            HStack {
                UzmoonCredit()
                Spacer()
                LanguageSwitch()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

struct LanguageSwitch: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            ForEach(["tr", "en"], id: \.self) { code in
                let on = Lang.code == code
                Button { model.setLanguage(code) } label: {
                    Text(code.uppercased())
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(on ? Theme.text : Theme.text3)
                        .frame(width: 24, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.white.opacity(0.12) : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke, lineWidth: 1))
        .help(L("Dil", "Language"))
    }
}
