import AppKit
import SwiftUI
import UzDiscCore

enum Theme {
    static let bg = Color(hex: 0x0E1118)
    static let sidebarTop = Color(hex: 0x1A2030)
    static let sidebarBottom = Color(hex: 0x141925)
    static let panel = Color(hex: 0x131823)
    static let card = Color(hex: 0x1A2130)
    static let cardHi = Color(hex: 0x232C3E)
    static let rowAlt = Color.white.opacity(0.022)
    static let stroke = Color.white.opacity(0.07)
    static let strokeHi = Color.white.opacity(0.13)
    static let text = Color(hex: 0xE9EDF5)
    static let text2 = Color(hex: 0x9AA4B6)
    static let text3 = Color(hex: 0x5F6A7E)
    static let accent = Color(hex: 0x5B8CFF)
    static let accent2 = Color(hex: 0x9A6BFF)
    static let green = Color(hex: 0x34D399)
    static let amber = Color(hex: 0xFBBF24)
    static let red = Color(hex: 0xF87171)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Arka plan

/// Hafif yıldız dokusu ve ay ışığı parıltısı (uzmoon teması).
struct NightSky: View {
    var glow = true

    var body: some View {
        ZStack {
            Theme.bg
            if glow {
                RadialGradient(colors: [Theme.accent.opacity(0.16), .clear], center: .topTrailing, startRadius: 10, endRadius: 520)
                RadialGradient(colors: [Theme.accent2.opacity(0.10), .clear], center: .bottomLeading, startRadius: 10, endRadius: 480)
            }
            Canvas { ctx, size in
                var seed: UInt64 = 0x9E3779B97F4A7C15
                func rnd() -> Double {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return Double(seed >> 11) / Double(1 << 53)
                }
                for _ in 0..<140 {
                    let x = rnd() * size.width, y = rnd() * size.height
                    let r = 0.4 + rnd() * 1.1
                    let a = 0.05 + rnd() * 0.22
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(a)))
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Bileşenler

struct CheckBox: View {
    let on: Bool
    var inherited = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(on ? AnyShapeStyle(Theme.accentGradient.opacity(inherited ? 0.45 : 1)) : AnyShapeStyle(Color.white.opacity(0.04)))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(on ? Color.clear : Theme.strokeHi, lineWidth: 1.2)
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 17, height: 17)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let symbol: String
    var active = false
    var disabled = false
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(disabled ? Theme.text3 : (active ? Theme.text : Theme.text2))
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Color.white.opacity(0.10) : (hover && !disabled ? Color.white.opacity(0.06) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct PrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .bold)) }
                Text(title).font(Theme.rounded(14, .bold))
            }
            .foregroundStyle(.white.opacity(disabled ? 0.45 : 1))
            .padding(.horizontal, 22)
            .frame(height: 40)
            .background(
                Capsule().fill(disabled ? AnyShapeStyle(Color.white.opacity(0.08)) : AnyShapeStyle(Theme.accentGradient))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(disabled ? 0.05 : 0.18), lineWidth: 1))
            .shadow(color: disabled ? .clear : Theme.accent.opacity(hover ? 0.55 : 0.35), radius: hover ? 16 : 10, y: 4)
            .scaleEffect(hover && !disabled ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
    }
}

struct Chip: View {
    let text: String
    var symbol: String? = nil
    var color: Color = Theme.text2

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.13)))
        .overlay(Capsule().strokeBorder(color.opacity(0.18), lineWidth: 0.8))
    }
}

struct CategoryTile: View {
    let category: FileCategory
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: category.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
            Image(systemName: category.symbol)
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: category.colors[1].opacity(0.35), radius: 6, y: 2)
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text3)
            TextField("", text: $text, prompt: Text(prompt).foregroundColor(Theme.text3))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .frame(width: 250, height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// Tarama göstergesi: dönen yay + şimşek / tamamlanınca onay.
struct ScanBadge: View {
    let done: Bool
    var size: CGFloat = 54
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.card)
            Circle().strokeBorder(Theme.stroke, lineWidth: 4)
            if done {
                Circle().strokeBorder(Theme.green.opacity(0.85), lineWidth: 4)
                Image(systemName: "checkmark").font(.system(size: size * 0.32, weight: .heavy)).foregroundStyle(Theme.green)
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .padding(2)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                Image(systemName: "bolt.fill")
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(Theme.accentGradient)
            }
        }
        .frame(width: size, height: size)
        .onAppear { spin = true }
    }
}

struct UzmoonCredit: View {
    var body: some View {
        Link(destination: URL(string: "https://uzmoon.com/")!) {
            HStack(spacing: 7) {
                if let url = Bundle.main.url(forResource: "uzmoon", withExtension: "png"), let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6))
                }
                Text(L("uzmoon.com tarafından yapılmıştır", "Made by uzmoon.com"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.text3)
        }
        .buttonStyle(.plain)
        .help("https://uzmoon.com")
    }
}

struct AppLogo: View {
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size * 1.24, height: size * 1.24)
            .frame(width: size, height: size)
    }
}

struct DriveIcon: View {
    var size: CGFloat = 30
    var body: some View {
        Image(nsImage: FinderIcons.volume)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
