import Foundation

/// NTFS sıkıştırmasında kullanılan LZNT1 çözücü.
public enum LZNT1 {
    public static func decompress(_ input: [UInt8], outputSize: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(outputSize)
        var p = 0
        while p + 2 <= input.count && out.count < outputSize {
            let header = Int(input.u16(p))
            p += 2
            if header == 0 { break }
            let chunkLen = (header & 0x0FFF) + 1
            let end = min(p + chunkLen, input.count)
            let chunkStart = out.count
            if header & 0x8000 == 0 {
                out.append(contentsOf: input[p..<end])
                p = end
            } else {
                while p < end {
                    let flags = input[p]
                    p += 1
                    for bit in 0..<8 {
                        if p >= end { break }
                        if flags & (1 << UInt8(bit)) == 0 {
                            out.append(input[p])
                            p += 1
                        } else {
                            guard p + 2 <= end else { throw UzError.corrupt("LZNT1 verisi kesik") }
                            let tuple = Int(input.u16(p))
                            p += 2
                            let pos = out.count - chunkStart
                            guard pos > 0 else { throw UzError.corrupt("LZNT1 geri başvurusu geçersiz") }
                            var shift = 12
                            var t = pos - 1
                            while t >= 0x10 { t >>= 1; shift -= 1 }
                            let length = (tuple & ((1 << shift) - 1)) + 3
                            let offset = (tuple >> shift) + 1
                            guard offset <= pos else { throw UzError.corrupt("LZNT1 uzaklığı geçersiz") }
                            var from = out.count - offset
                            for _ in 0..<length {
                                out.append(out[from])
                                from += 1
                            }
                        }
                    }
                }
            }
            p = end
            // Her parça 4 KB'lık açılmış veriyi temsil eder; kısa kalan parça sıfırla tamamlanır.
            let produced = out.count - chunkStart
            if produced < 4096 && p + 2 <= input.count && input.u16(p) != 0 {
                out += [UInt8](repeating: 0, count: 4096 - produced)
            }
        }
        if out.count < outputSize { out += [UInt8](repeating: 0, count: outputSize - out.count) }
        if out.count > outputSize { out.removeLast(out.count - outputSize) }
        return out
    }
}
