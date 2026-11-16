import AppKit
import SwiftUI
import UzDiscCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
        MountBlocker.shared.start()
        DispatchQueue.main.async {
            for w in NSApp.windows {
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.isMovableByWindowBackground = true
                w.backgroundColor = NSColor(red: 0.055, green: 0.067, blue: 0.094, alpha: 1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct UzDiscApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("UzDisc") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 620)
                .ignoresSafeArea()
                .task { await DemoMode.runIfRequested(model) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Disk Kalıbı Aç…", "Open Disk Image…")) { model.chooseImage() }.keyboardShortcut("o")
            }
            CommandMenu(L("Git", "Go")) {
                Button(L("Geri", "Back")) { model.goBack() }.keyboardShortcut("[")
                Button(L("İleri", "Forward")) { model.goForward() }.keyboardShortcut("]")
                Button(L("Üst Klasör", "Enclosing Folder")) { model.goUp() }.keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button(L("Diskleri Yenile", "Refresh Disks")) { model.refreshDisks() }.keyboardShortcut("r")
            }
            CommandGroup(after: .pasteboard) {
                Button(L("Tümünü İşaretle", "Check All")) { model.toggleAll() }.keyboardShortcut("a")
                Button(L("Seçilenleri Mac'e Kopyala…", "Copy Checked to Mac…")) { model.copyChecked() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}
