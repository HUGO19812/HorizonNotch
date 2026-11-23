import AppKit
import Combine
import EventKit
import SwiftUI

/// The start page: everything at a glance in three calm cards – a small
/// player, one card with the next appointment, open reminders and the
/// battery, and Claude's status. Each card opens its own tab.
final class OverviewModule: NotchModule {
    let id = "overview"
    var title: String { L("Übersicht", "Overview") }
    let symbol = "square.grid.2x2.fill"
    let priority = ModulePriority.calendar
    let hasExpandedContent = true
    var isActive: Bool { false }

    let nowPlaying: NowPlayingService
    let calendar: CalendarModule
    let reminders: RemindersModule
    let claude: ClaudeCodeMonitor
    /// Opens another tab by its id.
    let open: (String) -> Void

    init(nowPlaying: NowPlayingService, calendar: CalendarModule, reminders: RemindersModule,
         claude: ClaudeCodeMonitor, open: @escaping (String) -> Void) {
        self.nowPlaying = nowPlaying
        self.calendar = calendar
        self.reminders = reminders
        self.claude = claude
        self.open = open
    }

    func compactLeading() -> AnyView { AnyView(EmptyView()) }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func expandedView() -> AnyView { AnyView(OverviewPage(module: self)) }
}

private struct OverviewPage: View {
    let module: OverviewModule

    var body: some View {
        HStack(spacing: 10) {
            MiniPlayerCard(service: module.nowPlaying) { module.open("media") }
                .frame(width: 168)
            TodayCard(calendar: module.calendar, reminders: module.reminders, open: module.open)
            ClaudeCard(monitor: module.claude) { module.open("claude") }
                .frame(width: 118)
        }
        .frame(maxHeight: .infinity)
    }
}

/// The shared card look: a soft rounded panel, the whole card clickable.
private struct Card<Content: View>: View {
    var action: (() -> Void)?
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(hovering && action != nil ? 0.1 : 0.065)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture { action?() }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Player

private struct MiniPlayerCard: View {
    @ObservedObject var service: NowPlayingService
    let open: () -> Void

    var body: some View {
        Card(action: open) {
            if let info = service.info {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 9) {
                        CoverArt(image: service.artwork, cornerRadius: 8)
                            .frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(info.artist).font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        control("backward.fill", 13) { service.send(.previous) }
                        control(info.isPlaying ? "pause.fill" : "play.fill", 18) { service.send(.togglePlayPause) }
                        control("forward.fill", 13) { service.send(.next) }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer(minLength: 0)
                    Text(L("Nichts läuft", "Nothing playing"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    private func control(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, minHeight: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Today: next appointment, reminders, battery

private struct TodayCard: View {
    @ObservedObject var calendar: CalendarModule
    @ObservedObject var reminders: RemindersModule
    @ObservedObject private var power = PowerSource.shared
    let open: (String) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                row(symbol: "calendar", tint: .red, action: { open("calendar") }) {
                    if let event = calendar.nextEvent {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(event.title ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(when(event)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                        }
                    } else {
                        Text(L("Keine Termine mehr", "No more events")).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                divider
                row(symbol: "checklist", tint: .orange, action: { open("reminders") }) {
                    let today = reminders.items(in: .today)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(today.isEmpty ? L("Alles erledigt", "All done")
                                           : L("\(today.count) offen heute", "\(today.count) open today"))
                            .font(.system(size: 12, weight: .semibold))
                        if let first = today.first {
                            Text(first.title ?? "").font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                    }
                }
                if power.state.hasBattery {
                    divider
                    row(symbol: nil, tint: .green, action: nil) {
                        HStack(spacing: 6) {
                            PhoneBattery(percent: power.state.percent, showNumber: true, fill: batteryColor)
                            if power.state.isCharging || power.state.isPluggedIn {
                                Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                            }
                            Text(batteryText).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 31).padding(.vertical, 5)
    }

    private func row<Content: View>(symbol: String?, tint: Color, action: (() -> Void)?,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 9) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.18)))
                } else {
                    Color.clear.frame(width: 22, height: 1)
                }
            }
            content()
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }

    private func when(_ event: EKEvent) -> String {
        let time = event.startDate.formatted(.dateTime.hour().minute().locale(appLocale))
        if event.startDate <= Date() {
            return L("Jetzt · bis ", "Now · until ") + event.endDate.formatted(.dateTime.hour().minute().locale(appLocale))
        }
        if Calendar.current.isDateInToday(event.startDate) {
            let minutes = Int(event.startDate.timeIntervalSinceNow / 60)
            return minutes < 60 ? L("in \(minutes) Min. · \(time)", "in \(minutes) min · \(time)") : time
        }
        return event.startDate.formatted(.dateTime.weekday(.abbreviated).locale(appLocale)) + " · " + time
    }

    private var batteryColor: Color {
        if power.state.isLowPower { return .yellow }
        if power.state.isPluggedIn { return .green }
        return power.state.percent <= 20 ? .red : .white
    }

    private var batteryText: String {
        guard let minutes = power.state.minutesRemaining, minutes > 0 else {
            return power.state.isPluggedIn ? L("Am Netzteil", "On power") : L("Akku", "Battery")
        }
        let time = minutes >= 60 ? "\(minutes / 60):" + String(format: "%02d", minutes % 60) + " h" : "\(minutes) min"
        return power.state.isCharging ? L("voll in \(time)", "full in \(time)") : L("noch \(time)", "\(time) left")
    }
}

// MARK: - Claude

private struct ClaudeCard: View {
    @ObservedObject var monitor: ClaudeCodeMonitor
    let open: () -> Void

    var body: some View {
        let session = monitor.visible.first
        Card(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ClaudeCodeModule.tint)
                    .symbolEffect(.pulse, isActive: isWorking(session))
                Spacer(minLength: 0)
                Text(state(session))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isWaiting(session) ? ClaudeCodeModule.tint : .white)
                Group {
                    if isWorking(session), let start = session?.turnStarted {
                        Text(start, style: .timer).monospacedDigit()
                    } else {
                        Text(session?.project ?? "Claude")
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            }
        }
    }

    private func isWorking(_ session: ClaudeCodeMonitor.Session?) -> Bool {
        if case .working? = session?.activity { return true }
        return false
    }

    private func isWaiting(_ session: ClaudeCodeMonitor.Session?) -> Bool {
        if case .waiting? = session?.activity { return true }
        return false
    }

    private func state(_ session: ClaudeCodeMonitor.Session?) -> String {
        switch session?.activity {
        case .working?: return L("Arbeitet", "Working")
        case .waiting?: return L("Wartet auf dich", "Needs you")
        case .done?: return L("Fertig", "Done")
        default: return L("Ruhig", "Idle")
        }
    }
}
