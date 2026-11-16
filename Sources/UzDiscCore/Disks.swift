import Foundation
import IOKit

public struct DiskInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String { bsdName }
    public let bsdName: String
    public let name: String
    public let size: UInt64
    public let isInternal: Bool
    public let isRemovable: Bool
    public let interconnect: String?
    /// IOUSBHost hız kodu: 1 Low, 2 Full, 3 High (USB 2.0), 4 SuperSpeed 5G, 5 SuperSpeed+ 10G, 6 20G.
    public var usbSpeed: Int? = nil

    public init(bsdName: String, name: String, size: UInt64, isInternal: Bool, isRemovable: Bool, interconnect: String?, usbSpeed: Int? = nil) {
        self.usbSpeed = usbSpeed
        self.bsdName = bsdName
        self.name = name
        self.size = size
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.interconnect = interconnect
    }

    public var rawDevicePath: String { "/dev/r\(bsdName)" }

    /// Örn. "USB 2.0 · 480 Mb/s"
    public var linkDescription: String? {
        switch usbSpeed {
        case 1: return "USB 1.0 · 1,5 Mb/s"
        case 2: return "USB 1.1 · 12 Mb/s"
        case 3: return "USB 2.0 · 480 Mb/s"
        case 4: return "USB 3 · 5 Gb/s"
        case 5: return "USB 3 · 10 Gb/s"
        case 6: return "USB 3 · 20 Gb/s"
        default: return interconnect
        }
    }

    /// Disk USB 2.0 ya da daha yavaş bağlanmışsa (genelde yanlış/eski kablo).
    public var isSlowLink: Bool { (usbSpeed ?? 99) <= 3 }
}

/// IOKit üzerinden fiziksel diskleri listeler. DiskArbitration kullanmaz, bu yüzden
/// macOS'un disk bağlama servisi takılı kalsa bile çalışır. Yönetici izni gerektirmez.
public enum DiskEnumerator {
    public static func list() -> [DiskInfo] {
        guard let matching = IOServiceMatching("IOMedia") else { return [] }
        let dict = matching as NSMutableDictionary
        dict["Whole"] = true
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var out: [DiskInfo] = []
        while true {
            let s = IOIteratorNext(iter)
            if s == 0 { break }
            defer { IOObjectRelease(s) }
            guard let bsd = prop(s, "BSD Name") as? String else { continue }
            if isSynthesized(s) { continue }
            let size = (prop(s, "Size") as? NSNumber)?.uint64Value ?? 0
            if size == 0 { continue }
            let proto = search(s, "Protocol Characteristics") as? [String: Any]
            let location = proto?["Physical Interconnect Location"] as? String
            let interconnect = proto?["Physical Interconnect"] as? String
            if location == "File" || location == "Virtual" || interconnect == "Virtual Interface" { continue }
            let removable = (prop(s, "Removable") as? Bool ?? false) || (prop(s, "Ejectable") as? Bool ?? false)
            let devc = search(s, "Device Characteristics") as? [String: Any]
            var name = (devc?["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            if name.isEmpty { name = (search(s, "USB Product Name") as? String) ?? (search(s, "kUSBProductString") as? String) ?? "" }
            if name.isEmpty { name = (prop(s, "IOMediaName") as? String) ?? bsd }
            let isInt = location == "Internal" && !removable
            let speed = (search(s, "USBSpeed") as? NSNumber)?.intValue
            out.append(DiskInfo(bsdName: bsd, name: name, size: size, isInternal: isInt,
                                isRemovable: removable, interconnect: interconnect,
                                usbSpeed: interconnect == "USB" ? speed : nil))
        }
        return out.sorted { a, b in
            if a.isInternal != b.isInternal { return !a.isInternal }
            return a.bsdName.localizedStandardCompare(b.bsdName) == .orderedAscending
        }
    }

    private static func prop(_ s: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func search(_ s: io_object_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(s, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }

    /// APFS kapsayıcısının oluşturduğu sanal diskleri atla.
    private static func isSynthesized(_ s: io_object_t) -> Bool {
        if IOObjectConformsTo(s, "AppleAPFSMedia") != 0 { return true }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(s, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        return IOObjectConformsTo(parent, "AppleAPFSContainer") != 0
    }
}
