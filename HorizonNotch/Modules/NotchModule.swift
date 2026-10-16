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

    func compactLeading() -> AnyView
    func compactTrailing() -> AnyView
    func expandedView() -> AnyView
    func peekView() -> AnyView
    /// Pill at the bottom of the open island while the module is transient
    /// (HUD, notification). Must size itself; it is not given wing widths.
    func transientView() -> AnyView
}

extension NotchModule {
    var compactWingWidth: CGFloat { 44 }
    var hasExpandedContent: Bool { false }
    func expandedView() -> AnyView { AnyView(EmptyView()) }
    var isPeeking: Bool { false }
    var peekHeight: CGFloat { 0 }
    func peekView() -> AnyView { AnyView(EmptyView()) }
    /// Both wings side by side, each as wide as next to the notch – the
    /// wing views stretch to fill, so they need a fixed width here.
    func transientView() -> AnyView {
        AnyView(HStack(spacing: 4) {
            compactLeading().frame(width: compactWingWidth)
            compactTrailing().frame(width: compactWingWidth)
        })
    }
}
