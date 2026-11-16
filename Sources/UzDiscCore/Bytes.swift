import Foundation

/// UzDisc genelinde kullanılan hata türü. Mesajlar arayüzde doğrudan gösterilir.
public enum UzError: Error, CustomStringConvertible, LocalizedError, Equatable {
    case io(String)
    case corrupt(String)
    case unsupported(String)
    case notFound(String)
    case cancelled

    public var description: String {
        switch self {
        case .io(let s): return L("Okuma hatası: ", "Read error: ") + s
        case .corrupt(let s): return L("Bozuk veri: ", "Corrupt data: ") + s
        case .unsupported(let s): return L("Desteklenmiyor: ", "Not supported: ") + s
        case .notFound(let s): return L("Bulunamadı: ", "Not found: ") + s
        case .cancelled: return L("İptal edildi", "Cancelled")
        }
    }

    public var errorDescription: String? { description }
}

/// Küçük-endian okuma yardımcıları. Sınır dışı okumalar 0 döner; çağıranlar uzunlukları ayrıca doğrular.
extension Array where Element == UInt8 {
    @inline(__always) func u8(_ o: Int) -> UInt8 {
        (o >= 0 && o < count) ? self[o] : 0
    }

    @inline(__always) func u16(_ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= count else { return 0 }
        return UInt16(self[o]) | UInt16(self[o + 1]) << 8
    }

    @inline(__always) func u32(_ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= count else { return 0 }
        return UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }

    @inline(__always) func u64(_ o: Int) -> UInt64 {
        guard o >= 0, o + 8 <= count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(self[o + i]) << (8 * UInt64(i)) }
        return v
    }

    func ascii(_ o: Int, _ n: Int) -> String {
        guard o >= 0, o + n <= count else { return "" }
        return String(decoding: self[o..<(o + n)], as: UTF8.self)
    }

    /// UTF-16LE metin; `stopAtNull` ise ilk 0 karakterinde durur.
    func utf16(_ o: Int, units: Int, stopAtNull: Bool = false) -> String {
        var a = [UInt16]()
        a.reserveCapacity(units)
        for i in 0..<units {
            let v = u16(o + 2 * i)
            if stopAtNull && v == 0 { break }
            a.append(v)
        }
        return String(decoding: a, as: UTF16.self)
    }
}

/// FAT ve exFAT'in ortak 32 bit tarih/saat biçimi (yerel saat).
func dosDateTime(_ v: UInt32) -> Date? {
    if v == 0 { return nil }
    var dc = DateComponents()
    dc.year = Int(v >> 25) + 1980
    dc.month = Int((v >> 21) & 0xF)
    dc.day = Int((v >> 16) & 0x1F)
    dc.hour = Int((v >> 11) & 0x1F)
    dc.minute = Int((v >> 5) & 0x3F)
    dc.second = Int(v & 0x1F) * 2
    guard let m = dc.month, (1...12).contains(m), let d = dc.day, (1...31).contains(d) else { return nil }
    return Calendar(identifier: .gregorian).date(from: dc)
}

/// NTFS FILETIME (1601'den beri 100 ns) → Date.
func fileTimeDate(_ ft: UInt64) -> Date? {
    if ft == 0 { return nil }
    return Date(timeIntervalSince1970: Double(ft) / 10_000_000 - 11_644_473_600)
}
