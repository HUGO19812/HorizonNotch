import Combine
import SwiftUI

/// Claude Code next to the notch: working (with the tool in use), waiting
/// for you, finished. The page lists sessions and today's token usage.
final class ClaudeCodeModule: NotchModule {
    let id = "claude"
    var title: String { "Claude Code" }
    let symbol = "sparkle"
    let priority = ModulePriority.claude
    let hasExpandedContent = true
    let compactWingWidth: CGFloat = 96

    let monitor = ClaudeCodeMonitor()
    let usage = ClaudeUsage()
    private var subscriptions = Set<AnyCancellable>()

    static let tint = Color(red: 0.85, green: 0.47, blue: 0.34)

    init() {
        monitor.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        monitor.turnFinished
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] in self?.usage.refresh() }
            .store(in: &subscriptions)
    }

    var isActive: Bool { !monitor.visible.isEmpty }

    func compactLeading() -> AnyView { AnyView(ClaudeLeading(monitor: monitor)) }
    func compactTrailing() -> AnyView { AnyView(ClaudeTrailing(monitor: monitor)) }
    func expandedView() -> AnyView { AnyView(ClaudePage(monitor: monitor, usage: usage)) }

    #if DEBUG
    func debugDemo() {
        let folder = ClaudeHooks.eventFolder
        let events: [[String: Any]] = [
            ["session_id": "demo", "hook_event_name": "UserPromptSubmit", "cwd": "/Users/demo/FlowTools"],
            ["session_id": "demo", "hook_event_name": "PreToolUse", "cwd": "/Users/demo/FlowTools", "tool_name": "Bash"],
        ]
        for (index, event) in events.enumerated() {
            let data = try? JSONSerialization.data(withJSONObject: event)
            try? data?.write(to: folder.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-demo\(index).json"))
        }
    }
    #endif
}

extension ClaudeCodeMonitor.Activity {
    var label: String {
        switch self {
        case .working(let tool): return tool ?? L("arbeitet", "working")
        case .waiting: return L("wartet", "waiting")
        case .done: return L("fertig", "done")
        case .idle: return ""
        }
    }

    var color: Color {
        switch self {
        case .working: return ClaudeCodeModule.tint
        case .waiting: return .yellow
        case .done: return .green
        case .idle: return .white.opacity(0.5)
        }
    }
}

// MARK: - Compact

private struct ClaudeLeading: View {
    @ObservedObject var monitor: ClaudeCodeMonitor
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let session = monitor.visible.first
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.tint(ClaudeCodeModule.tint))
                .symbolEffect(.pulse, isActive: { if case .working = session?.activity { return true } else { return false } }())
            Text(session?.project ?? "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
    }
}

private struct ClaudeTrailing: View {
    @ObservedObject var monitor: ClaudeCodeMonitor
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let activity = monitor.visible.first?.activity ?? .idle
        HStack(spacing: 5) {
            if monitor.visible.count > 1 {
                Text("+\(monitor.visible.count - 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            if case .done = activity {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.tint(.green))
            } else if case .waiting = activity {
                Image(systemName: "hand.raised.fill").foregroundStyle(theme.tint(.yellow))
            }
            Text(activity.label)
                .foregroundStyle(theme.tint(activity.color))
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 10)
    }
}

// MARK: - Page

private struct ClaudePage: View {
    @ObservedObject var monitor: ClaudeCodeMonitor
    @ObservedObject var usage: ClaudeUsage

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Sitzungen", "Sessions"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                if !ClaudeHooks.isInstalled {
                    Text(L("Hooks noch nicht eingerichtet – Einstellungen → Claude Code.",
                           "Hooks not set up yet – Settings → Claude Code."))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                } else if monitor.sessions.isEmpty {
                    Text(L("Gerade läuft keine Sitzung.", "No session running."))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    ForEach(monitor.sessions.prefix(3)) { session in
                        SessionRow(session: session)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            UsageCard(usage: usage)
                .frame(width: 214)
        }
        .onAppear { usage.refresh() }
    }
}

private struct SessionRow: View {
    let session: ClaudeCodeMonitor.Session

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(session.activity.color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Group {
                    if case .waiting(let message) = session.activity {
                        Text(message)
                    } else if session.activity == .idle {
                        Text(L("bereit", "ready"))
                    } else {
                        Text(session.activity.label)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let start = session.turnStarted {
                Text(start, style: .timer)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

private struct UsageCard: View {
    @ObservedObject var usage: ClaudeUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(L("Heute", "Today"), usage.today, detail: nil)
            if let ends = usage.blockEnds {
                row(L("5-Std.-Fenster", "5-hour window"), usage.block,
                    detail: L("bis ", "until ") + ends.formatted(date: .omitted, time: .shortened))
            }
            if let model = usage.topModel {
                Text(model)
                    .font(.system(size: 9, weight: .medium).monospaced())
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func row(_ title: String, _ totals: ClaudeUsage.Totals, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if let detail {
                    Text(detail).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Self.tokens(totals.tokens))
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                Text("Tokens").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 4)
                if totals.tokens > 0 {
                    Text((totals.priced ? "≈ $" : "≥ $") + String(format: "%.2f", totals.cost))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(ClaudeCodeModule.tint)
                        .lineLimit(1)
                        .fixedSize()
                        .help(L("Was dieser Verbrauch über die API kosten würde.", "What this usage would cost through the API."))
                }
            }
        }
    }

    static func tokens(_ count: Int) -> String {
        switch count {
        case 100_000_000...: return String(format: "%.0f M", Double(count) / 1_000_000)
        case 1_000_000...: return String(format: "%.1f M", Double(count) / 1_000_000)
        case 1_000...: return String(format: "%.0f k", Double(count) / 1_000)
        default: return "\(count)"
        }
    }
}
