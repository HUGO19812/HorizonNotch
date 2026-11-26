import Combine
import SwiftUI

/// Priorities decide which module owns the compact island. Higher wins:
/// HUD > notification (battery, events) > downloads > privacy > Claude Code
/// > calendar > timer > media.
enum ModulePriority {
    static let hud = 100
    static let notification = 80
    static let downloads = 75
    static let privacy = 70
    static let claude = 68
    static let calendar = 65
    static let timer = 60
    static let media = 40
}

/// Everything shown in the island is a module. The coordinator asks each
/// module whether it is active and picks the one with the highest priority.
protocol NotchModule: ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    var id: String { get }
    /// Name shown in the settings.
    var title: String { get }
    var symbol: String { get }
    var priority: Int { get }
    /// True while the module wants a live activity next to the notch.
    var isActive: Bool { get }
    /// True if the module has a page in the expanded island.
    var hasExpandedContent: Bool { get }
    /// Width of the leading and trailing wings in compact mode.
    var compactWingWidth: CGFloat { get }

    /// Sneak peek: the compact island grows downward for a moment to
    /// show more (e.g. the new song). Shown below the wings.
    var isPeeking: Bool { get }
    /// Extra height below the notch while peeking.
    var peekHeight: CGFloat { get }
    /// Coloured glow under the closed island (e.g. Claude needs you).
    var compactGlow: Color? { get }

    func compactLeading() -> AnyView
    func compactTrailing() -> AnyView
    func expandedView() -> AnyView
    func peekView() -> AnyView
    /// Pill at the bottom of the open island while the module is transient
    /// (HUD, notification). Must size itself; it is not given wing widths.
    func transientView() -> AnyView
    /// Small round bubble beside the closed island (see bubbleModule).
    func bubbleView() -> AnyView
    /// Live info next to the tab icon in the open island's header (time
    /// left, temperature, …). nil = just the icon.
    var headerInfo: HeaderInfo? { get }
}

/// What a tab shows beside its icon in the header.
enum HeaderInfo: Equatable {
    /// Plain short text, e.g. "12°".
    case text(String)
    /// Counts down to the date (SwiftUI updates it itself).
    case countdown(Date)
    /// Counts up from the date.
    case elapsed(Date)
    /// Small number badge on the icon.
    case badge(Int)
}

extension NotchModule {
    var compactWingWidth: CGFloat { 44 }
    var hasExpandedContent: Bool { false }
    func expandedView() -> AnyView { AnyView(EmptyView()) }
    var isPeeking: Bool { false }
    var peekHeight: CGFloat { 0 }
    var compactGlow: Color? { nil }
    func peekView() -> AnyView { AnyView(EmptyView()) }
    var headerInfo: HeaderInfo? { nil }
    func bubbleView() -> AnyView { AnyView(Image(systemName: symbol).font(.system(size: 12, weight: .semibold))) }
    /// Both wings side by side, each as wide as next to the notch – the
    /// wing views stretch to fill, so they need a fixed width here.
    func transientView() -> AnyView {
        AnyView(HStack(spacing: 4) {
            compactLeading().frame(width: compactWingWidth)
            compactTrailing().frame(width: compactWingWidth)
        })
    }
}

/// A tab's symbol: an SF Symbol by name, or – for the one SF Symbols lacks –
/// the Bluetooth logo drawn as a shape.
struct ModuleSymbol: View {
    let name: String
    let size: CGFloat
    var weight: Font.Weight = .semibold

    var body: some View {
        if name == BluetoothRune.symbolName {
            BluetoothRune()
                .stroke(style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.62, height: size * 1.05)
        } else {
            Image(systemName: name).font(.system(size: size, weight: weight))
        }
    }
}

/// The Bluetooth logo (the rune ᛒ): a vertical line with two arrowheads
/// on the right, crossed by two diagonals.
struct BluetoothRune: Shape {
    static let symbolName = "horizon.bluetooth"

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.06, 0.27))
        path.addLine(to: point(0.94, 0.73))
        path.addLine(to: point(0.5, 1))
        path.addLine(to: point(0.5, 0))
        path.addLine(to: point(0.94, 0.27))
        path.addLine(to: point(0.06, 0.73))
        return path
    }
}
