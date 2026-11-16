import Foundation

public struct PartitionInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let offset: UInt64
    public let length: UInt64
    public let scheme: String
    public let typeName: String
    public var fileSystem: FSKind?
    public var label: String?

    public init(index: Int, offset: UInt64, length: UInt64, scheme: String, typeName: String,
                fileSystem: FSKind? = nil, label: String? = nil) {
        self.index = index
        self.offset = offset
        self.length = length
        self.scheme = scheme
        self.typeName = typeName
        self.fileSystem = fileSystem
        self.label = label
    }

    public var displayName: String {
        if let l = label, !l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
        if let fs = fileSystem { return L("\(fs.displayName) bölümü", "\(fs.displayName) partition") }
        return typeName
    }
}

public enum PartitionScanner {
    /// MBR, genişletilmiş MBR, GPT ve bölümsüz diskleri tanır; her bölümdeki dosya sistemini algılar.
    public static func scan(_ src: ByteSource) throws -> [PartitionInfo] {
        let ss = UInt64(max(src.sectorSize, 512))
        let s0 = try src.read(at: 0, count: 512)
        var parts: [PartitionInfo] = []

        if FSDetector.detect(s0) != nil {
            parts.append(PartitionInfo(index: 0, offset: 0, length: src.size, scheme: L("Bölümsüz", "No partition table"), typeName: L("Tüm disk", "Entire disk")))
        } else if s0.u16(510) == 0xAA55 {
            var mbr: [(type: UInt8, lba: UInt64, count: UInt64)] = []
            for i in 0..<4 {
                let e = 446 + i * 16
                let t = s0[e + 4]
                let lba = UInt64(s0.u32(e + 8))
                let n = UInt64(s0.u32(e + 12))
                if t != 0 && n > 0 { mbr.append((t, lba, n)) }
            }
            if mbr.contains(where: { $0.type == 0xEE }) {
                parts = try scanGPT(src)
            } else {
                var idx = 1
                for p in mbr {
                    if [0x05, 0x0F, 0x85].contains(p.type) {
                        parts += try scanEBR(src, base: p.lba, sectorSize: ss, index: &idx)
                        continue
                    }
                    parts.append(PartitionInfo(index: idx, offset: p.lba * ss, length: p.count * ss,
                                               scheme: "MBR", typeName: mbrTypeName(p.type)))
                    idx += 1
                }
            }
        }

        parts = parts.filter { $0.offset < src.size && $0.length > 0 }
        for i in parts.indices {
            let sl = SliceByteSource(base: src, offset: parts[i].offset, size: parts[i].length)
            guard let boot = try? sl.read(at: 0, count: 512), let k = FSDetector.detect(boot) else { continue }
            parts[i].fileSystem = k
            parts[i].label = (try? FileSystems.open(sl, kind: k))?.label
        }
        return parts
    }

    static func scanGPT(_ src: ByteSource) throws -> [PartitionInfo] {
        var sizes = [UInt64(src.sectorSize), 512, 4096]
        sizes = sizes.enumerated().filter { i, v in sizes.firstIndex(of: v) == i }.map { $0.1 }
        for ss in sizes {
            guard let h = try? src.read(at: ss, count: 512), h.ascii(0, 8) == "EFI PART" else { continue }
            let entLBA = h.u64(72)
            let num = Int(h.u32(80))
            let esz = Int(h.u32(84))
            guard esz >= 128, esz <= 4096, num > 0, num <= 1024 else { continue }
            let table = try src.read(at: entLBA * ss, count: num * esz)
            var out: [PartitionInfo] = []
            for i in 0..<num {
                let e = i * esz
                let guid = Array(table[e..<(e + 16)])
                if guid.allSatisfy({ $0 == 0 }) { continue }
                let first = table.u64(e + 32)
                let last = table.u64(e + 40)
                guard last >= first else { continue }
                let name = table.utf16(e + 56, units: 36, stopAtNull: true)
                out.append(PartitionInfo(index: i + 1, offset: first * ss, length: (last - first + 1) * ss,
                                         scheme: "GPT", typeName: gptTypeName(guid, name: name)))
            }
            return out
        }
        return []
    }

    static func scanEBR(_ src: ByteSource, base: UInt64, sectorSize ss: UInt64, index idx: inout Int) throws -> [PartitionInfo] {
        var out: [PartitionInfo] = []
        var cur = base
        for _ in 0..<128 {
            guard let s = try? src.read(at: cur * ss, count: 512), s.u16(510) == 0xAA55 else { break }
            let t = s[446 + 4]
            let lba = UInt64(s.u32(446 + 8))
            let n = UInt64(s.u32(446 + 12))
            if t != 0 && n > 0 {
                out.append(PartitionInfo(index: idx, offset: (cur + lba) * ss, length: n * ss,
                                         scheme: "MBR (mantıksal)", typeName: mbrTypeName(t)))
                idx += 1
            }
            let t2 = s[462 + 4]
            let next = UInt64(s.u32(462 + 8))
            if t2 == 0 || next == 0 { break }
            cur = base + next
        }
        return out
    }

    static func mbrTypeName(_ t: UInt8) -> String {
        switch t {
        case 0x01, 0x04, 0x06, 0x0E: return "FAT"
        case 0x0B, 0x0C: return "FAT32"
        case 0x07: return "NTFS / exFAT"
        case 0x83: return "Linux"
        case 0xAF: return "macOS (HFS+/APFS)"
        case 0xEF: return "EFI"
        default: return String(format: "Tür 0x%02X", t)
        }
    }

    static func guidString(_ g: [UInt8]) -> String {
        let d1 = g.u32(0), d2 = g.u16(4), d3 = g.u16(6)
        let rest = g[8..<16].map { String(format: "%02X", $0) }
        return String(format: "%08X-%04X-%04X-", d1, d2, d3) + rest[0..<2].joined() + "-" + rest[2..<8].joined()
    }

    static func gptTypeName(_ g: [UInt8], name: String) -> String {
        let known: [String: String] = [
            "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7": "Microsoft Temel Veri",
            "C12A7328-F81F-11D2-BA4B-00A0C93EC93B": "EFI Sistem",
            "E3C9E316-0B5C-4DB8-817D-F92DF00215AE": "Microsoft Ayrılmış",
            "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC": "Windows Kurtarma",
            "7C3457EF-0000-11AA-AA11-00306543ECAC": "APFS",
            "48465300-0000-11AA-AA11-00306543ECAC": "HFS+",
            "0FC63DAF-8483-4772-8E79-3D69D8477DE4": "Linux",
        ]
        let s = guidString(g)
        let base = known[s] ?? "GPT bölümü"
        return name.isEmpty ? base : "\(base) – \(name)"
    }
}
