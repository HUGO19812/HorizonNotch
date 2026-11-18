import Combine
import SwiftUI

/// Claude Code at the notch, like Pro Notch: the island grows a second row.
/// Working: an animated spark, the elapsed time and what Claude is doing
/// ("Editing router.ts", shimmering). Needs you: a badge, NEEDS YOU and
/// the question. Done: a check that draws itself, DONE and Claude's last
/// sentence. The page lists sessions and today's token usage.
final class ClaudeCodeModule: NotchModule {
    let id = "claude"
    var title: String { "Claude Code" }
    let symbol = "sparkle"
    let priority = ModulePriority.claude
    let hasExpandedContent = true

    let monitor = ClaudeCodeMonitor()
    let usage = ClaudeUsage()
    private var subscriptions = Set<AnyCancellable>()

    static let tint = Color(red: 0.85, green: 0.47, blue: 0.34)

    init() {
        monitor.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        // A soft chime when Claude is done.
        monitor.turnFinished
            .sink { Self.playDoneSound() }
            .store(in: &subscriptions)
        monitor.turnFinished
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] in self?.usage.refresh() }
            .store(in: &subscriptions)
    }

    var isActive: Bool { !monitor.visible.isEmpty }

    static func playDoneSound() {
        let name = AppSettings.shared.claudeDoneSound
        guard !name.isEmpty, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.6
        sound.play()
    }

    private var activity: ClaudeCodeMonitor.Activity { monitor.visible.first?.activity ?? .idle }

    /// Kept slim: working only needs the spark and the timer, the two
    /// alerts a short badge; the line below stays one small row.
    var compactWingWidth: CGFloat {
        if case .working = activity { return 52 }
        return 84
    }
    var isPeeking: Bool { isActive }
    var peekHeight: CGFloat { 20 }
    var compactGlow: Color? {
        switch activity {
        case .waiting, .done: return Self.tint.opacity(0.42)
        default: return nil
        }
    }

    func compactLeading() -> AnyView { AnyView(ClaudeLeading(monitor: monitor)) }
    func bubbleView() -> AnyView { AnyView(ClaudeBubble(monitor: monitor)) }
    func compactTrailing() -> AnyView { AnyView(ClaudeTrailing(monitor: monitor)) }
    func peekView() -> AnyView { AnyView(ClaudeLine(monitor: monitor)) }
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
    /// Which of the four states, without the associated text (for animations).
    var kind: Int {
        switch self {
        case .working: return 0
        case .waiting: return 1
        case .done: return 2
        case .idle: return 3
        }
    }

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

/// Left of the notch: the spark while working, a badge when Claude needs
/// you, a check that draws itself when done.
/// The drop beside the music: Claude's spark and the running time, the
/// badge when Claude needs you, a check when it is done.
private struct ClaudeBubble: View {
    @ObservedObject var monitor: ClaudeCodeMonitor

    var body: some View {
        let session = monitor.visible.first
        HStack(spacing: 6) {
            Group {
                switch session?.activity {
                case .waiting:
                    Text("✳")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(ClaudeCodeModule.tint))
                case .done: DrawnCheck().frame(width: 13, height: 13)
                default: ClaudeSpark()
                }
            }
            .id(session?.activity.kind)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            Group {
                switch session?.activity {
                case .working:
                    if let start = session?.turnStarted {
                        Text(start, style: .timer)
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                case .waiting:
                    Text(L("DU", "YOU"))
                        .font(.system(size: 10, weight: .heavy)).kerning(0.4)
                        .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.27))
                case .done:
                    Text(L("FERTIG", "DONE"))
                        .font(.system(size: 9.5, weight: .heavy)).kerning(0.3)
                        .foregroundStyle(Color(red: 0.93, green: 0.6, blue: 0.46))
                default: EmptyView()
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: session?.activity.kind)
    }
}

private struct ClaudeLeading: View {
    @ObservedObject var monitor: ClaudeCodeMonitor

    var body: some View {
        let session = monitor.visible.first
        ZStack {
            switch session?.activity {
            case .working: ClaudeSpark()
            case .waiting:
                Text("✳")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(ClaudeCodeModule.tint))
            case .done: DrawnCheck().frame(width: 15, height: 15)
            default: EmptyView()
            }
        }
        .id(session?.activity.kind)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: session?.activity.kind)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
    }
}

/// Right of the notch: the time of the turn, NEEDS YOU or DONE.
private struct ClaudeTrailing: View {
    @ObservedObject var monitor: ClaudeCodeMonitor

    var body: some View {
        let session = monitor.visible.first
        Group {
            switch session?.activity {
            case .working:
                if let start = session?.turnStarted {
                    Text(start, style: .timer)
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            case .waiting:
                Text(L("BRAUCHT DICH", "NEEDS YOU"))
                    .font(.system(size: 9, weight: .bold)).kerning(0.4)
                    .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.27))
            case .done:
                Text(L("FERTIG", "DONE"))
                    .font(.system(size: 9, weight: .bold)).kerning(0.4)
                    .foregroundStyle(Color(red: 0.93, green: 0.6, blue: 0.46))
            default: EmptyView()
            }
        }
        .lineLimit(1)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 10)
    }
}

/// The row below the notch: what Claude does, the question, or its answer.
private struct ClaudeLine: View {
    @ObservedObject var monitor: ClaudeCodeMonitor

    var body: some View {
        let session = monitor.visible.first
        let extra = monitor.visible.count > 1 ? "  +\(monitor.visible.count - 1)" : ""
        Group {
            switch session?.activity {
            case .working:
                ShimmerText(text: (session?.detail ?? L("Arbeitet", "Working")) + extra)
            case .waiting(let message):
                plain([session?.project ?? "", message].filter { !$0.isEmpty }.joined(separator: " · ") + extra)
            case .done:
                plain((["Claude", session?.project ?? "", session?.summary ?? ""]).filter { !$0.isEmpty }
                        .joined(separator: " · ") + extra)
            default: EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: session?.detail)
    }

    private func plain(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(white: 0.82))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// Claude's spark, cycling through its shapes like the CLI does.
private struct ClaudeSpark: View {
    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { context in
            let index = Int(context.date.timeIntervalSinceReferenceDate / 0.12) % Self.frames.count
            Text(Self.frames[index])
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ClaudeCodeModule.tint)
                .frame(width: 18)
        }
    }
}

/// Grey text with a light running through it while Claude works.
private struct ShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            let grey = Color(white: 0.56)
            // Gradient stops must stay in order within 0…1.
            let at = { (x: Double) in min(max(x, 0), 1) }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(LinearGradient(
                    stops: [.init(color: grey, location: 0),
                            .init(color: grey, location: at(phase * 1.6 - 0.42)),
                            .init(color: .white, location: at(phase * 1.6 - 0.3)),
                            .init(color: grey, location: at(phase * 1.6 - 0.18)),
                            .init(color: grey, location: 1)],
                    startPoint: .leading, endPoint: .trailing))
        }
    }
}

/// A check mark that draws itself once.
private struct DrawnCheck: View {
    @State private var progress: CGFloat = 0

    var body: some View {
        CheckShape()
            .trim(from: 0, to: progress)
            .stroke(Color(red: 0.93, green: 0.6, blue: 0.46), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            .onAppear { withAnimation(.easeOut(duration: 0.5).delay(0.3)) { progress = 1 } }
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.78))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.22))
        return path
    }
}

// MARK: - Page

private struct ClaudePage: View {
    @ObservedObject var monitor: ClaudeCodeMonitor
    @ObservedObject var usage: ClaudeUsage
    /// The session shown across the whole page.
    @State private var focused: String?

    var body: some View {
        ZStack {
            if let id = focused, let session = monitor.today.first(where: { $0.id == id }) {
                detail(session)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
            } else {
                overview
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: focused)
        .onAppear {
            usage.refresh()
            monitor.loadToday()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            usage.refresh()
            monitor.loadToday()
        }
    }

    private var overview: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("Sitzungen", "Sessions"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer(minLength: 4)
                }
                if !ClaudeHooks.isInstalled {
                    Text(L("Hooks noch nicht eingerichtet – Einstellungen → Claude Code.",
                           "Hooks not set up yet – Settings → Claude Code."))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                } else if monitor.today.isEmpty {
                    Text(L("Heute noch keine Sitzung.", "No session today yet."))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(monitor.today) { session in
                                SessionRow(session: session, desktop: monitor.desktop[session.id], isExpanded: false) {
                                    focused = session.id
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            UsageCard(usage: usage)
                .frame(width: 214)
        }
    }

    /// One session over the whole page, with the button to open it.
    private func detail(_ session: ClaudeCodeMonitor.Session) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { focused = nil } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text(L("Sitzungen", "Sessions")).font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                PlanGauge(fiveHour: usage.fiveHour, weekly: usage.weekly, problem: usage.planProblem)
            }
            .padding(.top, 6)
            .zIndex(1)
            ScrollView(.vertical, showsIndicators: false) {
                SessionRow(session: session, desktop: monitor.desktop[session.id], isExpanded: true) { focused = nil }
            }
        }
    }
}

/// One session: a line with state, project and timer; a click opens it up
/// to show what you asked, the latest steps, the folder and how long it
/// has been running. The arrow brings the app it runs in to the front.
private struct SessionRow: View {
    let session: ClaudeCodeMonitor.Session
    /// The chat in the Claude app, when the session runs there.
    let desktop: ClaudeCodeMonitor.DesktopSession?
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Orange while Claude works or waits for you, grey otherwise.
                Circle().fill(session.isActive ? ClaudeCodeModule.tint : Color.white.opacity(0.3))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(desktop?.title ?? session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    status
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
                if isExpanded {
                    OpenButton(session: session, desktop: desktop)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !isExpanded { toggle() } }

            if isExpanded {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(isExpanded ? 0.07 : 0)))
    }

    @ViewBuilder private var status: some View {
        if case .waiting(let message) = session.activity {
            Text(message)
        } else if session.activity == .idle {
            Text(L("zuletzt ", "last ") + session.updated.formatted(date: .omitted, time: .shortened)
                 + (session.prompt.map { " · " + $0 } ?? ""))
        } else if case .done = session.activity, let summary = session.summary {
            Text(summary)
        } else {
            Text(session.detail ?? session.activity.label)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let prompt = session.prompt {
                detail("text.bubble", prompt, lines: 3)
            }
            if let summary = session.summary {
                detail("checkmark.circle", summary, lines: 2)
            }
            if !session.recent.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(session.recent.enumerated()), id: \.offset) { index, step in
                        HStack(spacing: 6) {
                            Text(step.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.white.opacity(index == 0 ? 0.8 : 0.5))
                            Spacer(minLength: 4)
                            Text(step.date, style: .relative)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .font(.system(size: 10))
                    }
                }
                .padding(.leading, 20)
            }
            HStack(spacing: 12) {
                if session.toolCount > 0 {
                    Label("\(session.toolCount) " + L("Schritte", "steps"), systemImage: "hammer")
                }
                Label {
                    Text(session.started, style: .relative)
                } icon: {
                    Image(systemName: "clock")
                }
                if let app = session.appName {
                    Label(app, systemImage: "macwindow")
                }
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .labelStyle(.titleAndIcon)
            if !session.cwd.isEmpty {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
                } label: {
                    Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 9.5, weight: .medium).monospaced())
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .buttonStyle(.plain)
                .help(L("Ordner im Finder zeigen", "Show folder in Finder"))
            }
        }
        .padding(.leading, 15)
    }

    private func detail(_ symbol: String, _ text: String, lines: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(ClaudeCodeModule.tint)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// How much of the plan is used: a ring with the percentage; pointing at
/// it shows each limit and when it starts over.
private struct PlanGauge: View {
    let fiveHour: ClaudeUsage.Limit?
    let weekly: ClaudeUsage.Limit?
    var problem: String?
    @State private var hovering = false

    private var main: ClaudeUsage.Limit? { fiveHour ?? weekly }

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
                if let main {
                    Circle()
                        .trim(from: 0, to: min(1, main.percent / 100))
                        .stroke(color(main.percent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 13, height: 13)
            Text(main.map { "\(Int($0.percent.rounded())) %" } ?? "– %")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(main == nil ? 0.4 : 0.8))
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .overlay(alignment: .topTrailing) {
            if hovering {
                VStack(alignment: .leading, spacing: 5) {
                    if let fiveHour { row(L("5-Std.-Limit", "5-hour limit"), fiveHour, weekday: false) }
                    if let weekly { row(L("Wochenlimit", "Weekly limit"), weekly, weekday: true) }
                    if main == nil {
                        Text(problem ?? L("Noch keine Daten von deinem Claude-Abo.", "No data from your Claude plan yet."))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.14)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
                .fixedSize()
                .offset(y: 20)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
    }

    private func row(_ title: String, _ limit: ClaudeUsage.Limit, weekday: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(.white.opacity(0.75)).frame(width: 82, alignment: .leading)
            Text("\(Int(limit.percent.rounded())) %").fontWeight(.bold).monospacedDigit()
                .foregroundStyle(color(limit.percent))
                .frame(width: 38, alignment: .trailing)
            Text(resetText(limit, weekday: weekday))
                .foregroundStyle(.white.opacity(0.45))
        }
        .font(.system(size: 10.5, weight: .medium))
    }

    private func resetText(_ limit: ClaudeUsage.Limit, weekday: Bool) -> String {
        guard let resets = limit.resets else {
            return L("Stand ", "as of ") + (limit.asOf ?? Date()).formatted(date: .omitted, time: .shortened)
        }
        return L("Reset ", "Resets ") + (weekday && !Calendar.current.isDateInToday(resets)
            ? resets.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(appLocale))
            : resets.formatted(.dateTime.hour().minute().locale(appLocale)))
    }

    private func color(_ percent: Double) -> Color {
        percent >= 90 ? .red : (percent >= 70 ? .orange : ClaudeCodeModule.tint)
    }
}

/// Round button with an arrow: brings Claude to the front – the app the
/// session runs in, or else the Claude app or Terminal.
private struct OpenButton: View {
    let session: ClaudeCodeMonitor.Session
    let desktop: ClaudeCodeMonitor.DesktopSession?
    @State private var hovering = false

    var body: some View {
        Button { session.open(desktop: desktop) } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12, weight: .semibold))
                Text(desktop != nil ? L("Chat öffnen", "Open chat")
                     : session.appName.map { L("In \($0) öffnen", "Open in \($0)") } ?? L("Claude öffnen", "Open Claude"))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(hovering ? 1 : 0.8))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.09)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Claude öffnen", "Open Claude"))
    }
}

extension ClaudeCodeMonitor.Session {
    private static let claudeApp = "com.anthropic.claudefordesktop"

    var isActive: Bool {
        switch activity {
        case .working, .waiting: return true
        default: return false
        }
    }

    private var appURL: URL? {
        app.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    var appName: String? {
        appURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    /// Brings the app Claude runs in to the front. The island is a panel
    /// that never becomes active, and macOS ignores `activate()` from an
    /// inactive app – opening the app through Launch Services always works.
    func open(desktop: ClaudeCodeMonitor.DesktopSession? = nil) {
        let workspace = NSWorkspace.shared
        // In the Claude app: straight to this very chat.
        if let desktop, let encoded = desktop.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "claude://code/continue?session=\(encoded)") {
            workspace.open(url)
            return
        }
        let target = appURL ?? workspace.urlForApplication(withBundleIdentifier: Self.claudeApp)
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        guard let target else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: target, configuration: configuration) { _, error in
            if let error { NSLog("[HorizonNotch] open Claude failed: %@", error.localizedDescription) }
        }
    }
}

private struct UsageCard: View {
    @ObservedObject var usage: ClaudeUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Claude-Abo", "Claude plan"))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                PlanGauge(fiveHour: usage.fiveHour, weekly: usage.weekly, problem: usage.planProblem)
            }
            .zIndex(1)
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
