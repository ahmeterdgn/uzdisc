import DiskArbitration
import Foundation
import UzDiscCore

/// UzDisc açıkken macOS'un harici diskleri otomatik bağlamasını engeller.
/// Böylece macOS'un disk kontrolü (fskitd) yavaş bir bağlantıyı meşgul etmez; diski önce UzDisc okur.
/// Uygulama kapanınca engel kendiliğinden kalkar.
final class MountBlocker {
    static let shared = MountBlocker()
    private var session: DASession?
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "blockAutomount") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "blockAutomount") }
    }

    func start() {
        guard session == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
        session = s
        DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let match = [kDADiskDescriptionDeviceInternalKey as String: false] as CFDictionary
        DARegisterDiskMountApprovalCallback(s, match, { _, ctx in
            guard let ctx else { return nil }
            let me = Unmanaged<MountBlocker>.fromOpaque(ctx).takeUnretainedValue()
            guard me.enabled else { return nil }
            let d = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted),
                                      L("UzDisc açıkken otomatik bağlama kapalı", "Automount is disabled while UzDisc is open") as CFString)
            return Unmanaged.passRetained(d)
        }, Unmanaged.passUnretained(self).toOpaque())
    }
}
