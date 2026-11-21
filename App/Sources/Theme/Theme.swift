import SwiftUI
import MaiCore

enum MaiColor {
    static let pink = Color(red: 1.0, green: 0.31, blue: 0.64)
    static let magenta = Color(red: 0.93, green: 0.22, blue: 0.85)
    static let cyan = Color(red: 0.25, green: 0.82, blue: 1.0)
    static let blue = Color(red: 0.24, green: 0.55, blue: 1.0)
    static let yellow = Color(red: 1.0, green: 0.84, blue: 0.25)
    static let orange = Color(red: 1.0, green: 0.55, blue: 0.2)
    static let mint = Color(red: 0.35, green: 0.95, blue: 0.7)
    static let violet = Color(red: 0.55, green: 0.33, blue: 0.98)
    static let night = Color(red: 0.05, green: 0.04, blue: 0.16)
    static let deep = Color(red: 0.12, green: 0.06, blue: 0.32)
    static let panel = Color.white.opacity(0.1)

    static func difficulty(_ d: Difficulty) -> Color {
        let (r, g, b) = d.rgb
        return Color(red: r, green: g, blue: b)
    }

    static let tapPink = Color(red: 1.0, green: 0.35, blue: 0.68)
    static let eachYellow = Color(red: 1.0, green: 0.85, blue: 0.2)
    static let breakOrange = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let slideBlue = Color(red: 0.3, green: 0.78, blue: 1.0)
    static let touchBlue = Color(red: 0.25, green: 0.62, blue: 1.0)
}

enum MaiFont {
    static func title(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .black, design: .rounded) }
    static func heavy(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static func bold(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func body(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func mono(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .semibold, design: .monospaced) }
}

/// Animated background: deep gradient, slowly rotating rings and twinkling sparkles.
struct MaiBackground: View {
    var animated = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let w = size.width, h = size.height
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(colors: [MaiColor.deep, MaiColor.night, Color(red: 0.02, green: 0.08, blue: 0.2)]),
                    startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
                // soft colour blobs
                let blobs: [(Color, Double, Double, Double)] = [(MaiColor.pink, 0.15, 0.2, 0.9), (MaiColor.cyan, 0.85, 0.75, 1.1), (MaiColor.violet, 0.75, 0.15, 0.7)]
                for (i, b) in blobs.enumerated() {
                    let cx = w * (b.1 + 0.05 * sin(t * 0.2 + Double(i)))
                    let cy = h * (b.2 + 0.05 * cos(t * 0.17 + Double(i)))
                    let r = min(w, h) * 0.55 * b.3
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                             with: .radialGradient(Gradient(colors: [b.0.opacity(0.28), b.0.opacity(0)]), center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r))
                }
                // "washing machine" rings
                let c = CGPoint(x: w * 0.82, y: h * 0.88)
                for k in 0..<3 {
                    let r = min(w, h) * (0.35 + 0.17 * Double(k))
                    var p = Path()
                    p.addArc(center: c, radius: r, startAngle: .degrees(t * (8 + Double(k) * 3)), endAngle: .degrees(t * (8 + Double(k) * 3) + 280), clockwise: false)
                    ctx.stroke(p, with: .color(.white.opacity(0.06)), style: StrokeStyle(lineWidth: 10 - CGFloat(k) * 2, lineCap: .round))
                }
                // sparkles
                for i in 0..<28 {
                    let fx = Double((i * 7919) % 1000) / 1000, fy = Double((i * 104729) % 1000) / 1000
                    let tw = 0.5 + 0.5 * sin(t * (0.8 + Double(i % 5) * 0.3) + Double(i))
                    let s = 1.5 + 2.5 * tw
                    let x = w * fx, y = h * fy
                    var star = Path()
                    star.move(to: CGPoint(x: x, y: y - s * 2)); star.addLine(to: CGPoint(x: x + s * 0.5, y: y - s * 0.5))
                    star.addLine(to: CGPoint(x: x + s * 2, y: y)); star.addLine(to: CGPoint(x: x + s * 0.5, y: y + s * 0.5))
                    star.addLine(to: CGPoint(x: x, y: y + s * 2)); star.addLine(to: CGPoint(x: x - s * 0.5, y: y + s * 0.5))
                    star.addLine(to: CGPoint(x: x - s * 2, y: y)); star.addLine(to: CGPoint(x: x - s * 0.5, y: y - s * 0.5))
                    star.closeSubpath()
                    ctx.fill(star, with: .color(.white.opacity(0.25 + 0.5 * tw)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct MaiPanel: ViewModifier {
    var accent: Color = MaiColor.pink
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [accent.opacity(0.9), MaiColor.cyan.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
            )
            .shadow(color: accent.opacity(0.25), radius: 14, y: 6)
    }
}

extension View {
    func maiPanel(accent: Color = MaiColor.pink, padding: CGFloat = 16) -> some View { modifier(MaiPanel(accent: accent, padding: padding)) }
}

struct MaiButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, difficulty(Difficulty) }
    var kind: Kind = .primary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let colors: [Color]
        switch kind {
        case .primary: colors = [MaiColor.pink, MaiColor.orange]
        case .secondary: colors = [MaiColor.blue, MaiColor.cyan]
        case .danger: colors = [Color.red, MaiColor.orange]
        case .difficulty(let d): colors = [MaiColor.difficulty(d), MaiColor.difficulty(d).opacity(0.7)]
        }
        return configuration.label
            .font(MaiFont.heavy(compact ? 14 : 17))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            .padding(.horizontal, compact ? 14 : 22)
            .padding(.vertical, compact ? 8 : 13)
            .background(Capsule().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 2.5))
            .shadow(color: colors[0].opacity(0.5), radius: configuration.isPressed ? 2 : 10, y: configuration.isPressed ? 1 : 5)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct DifficultyBadge: View {
    var difficulty: Difficulty
    var level: String
    var compact = false

    var body: some View {
        let c = MaiColor.difficulty(difficulty)
        let isRe = difficulty == .remaster
        HStack(spacing: 6) {
            Text(difficulty.displayName)
                .font(MaiFont.heavy(compact ? 10 : 12))
                .foregroundColor(isRe ? MaiColor.violet : .white)
            Text(level)
                .font(MaiFont.title(compact ? 15 : 20))
                .foregroundColor(isRe ? MaiColor.violet : .white)
        }
        .padding(.horizontal, compact ? 9 : 12)
        .padding(.vertical, compact ? 4 : 6)
        .background(Capsule().fill(isRe ? AnyShapeStyle(LinearGradient(colors: [.white, Color(red: 0.92, green: 0.86, blue: 1)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(c)))
        .overlay(Capsule().strokeBorder(isRe ? MaiColor.violet : Color.white.opacity(0.85), lineWidth: 2))
        .shadow(color: c.opacity(0.5), radius: 5, y: 2)
    }
}

struct SectionHeader: View {
    var title: String
    var icon: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(MaiFont.heavy(15)).foregroundColor(MaiColor.yellow)
            Text(title.uppercased()).font(MaiFont.heavy(14)).foregroundColor(.white).tracking(1.2)
            Spacer()
        }
    }
}

struct StatPill: View {
    var label: String
    var value: String
    var color: Color = MaiColor.cyan
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(MaiFont.heavy(16)).foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(MaiFont.bold(10)).foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.25)))
    }
}

/// Big glossy title used on hero headers.
struct MaiTitle: View {
    var text: String
    var size: CGFloat = 32
    var body: some View {
        Text(text)
            .font(MaiFont.title(size))
            .foregroundStyle(LinearGradient(colors: [.white, Color(red: 1, green: 0.85, blue: 0.95)], startPoint: .top, endPoint: .bottom))
            .shadow(color: MaiColor.pink.opacity(0.8), radius: 0, x: 2, y: 2)
            .shadow(color: MaiColor.pink.opacity(0.5), radius: 10)
    }
}
