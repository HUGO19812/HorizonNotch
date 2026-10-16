import AppKit
import Combine
import SwiftUI

/// Countdown timer and stopwatch. Running clocks are drawn with
/// Text(timerInterval:)/.timer, which SwiftUI updates itself, and the end of
/// a countdown is one scheduled work item – nothing polls.
final class TimerModule: NotchModule {
    enum Mode: String { case timer, stopwatch }

    let id = "timer"
    var title: String { L("Timer", "Timer") }
    let symbol = "timer"
    let priority = ModulePriority.timer
    let hasExpandedContent = true
    let compactWingWidth: CGFloat = 58

    @Published var mode: Mode = .timer
    /// Length chosen for the next countdown.
    @Published var duration: TimeInterval = 5 * 60
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    /// Full length of the countdown in progress, for the progress ring.
    @Published private(set) var runLength: TimeInterval = 0
    @Published private(set) var finished = false
    /// Stopwatch: start date shifted by the time already accumulated.
    @Published private(set) var stopwatchStart: Date?
    @Published private(set) var stopwatchPaused: TimeInterval?

    private var finishWork: DispatchWorkItem?
    private var dismissWork: DispatchWorkItem?

    var isActive: Bool {
        endDate != nil || pausedRemaining != nil || finished || stopwatchStart != nil
    }

    var timerRunning: Bool { endDate != nil }
    var stopwatchRunning: Bool { stopwatchStart != nil }

    // MARK: - Countdown

    func startTimer() {
        let length = pausedRemaining ?? duration
        guard length > 0 else { return }
        if pausedRemaining == nil { runLength = length }
        finished = false
        pausedRemaining = nil
        let end = Date().addingTimeInterval(length)
        endDate = end
        scheduleFinish(at: end)
    }

    func pauseTimer() {
        guard let end = endDate else { return }
        pausedRemaining = max(0, end.timeIntervalSinceNow)
        endDate = nil
        finishWork?.cancel()
    }

    func resetTimer() {
        finishWork?.cancel()
        dismissWork?.cancel()
        endDate = nil
        pausedRemaining = nil
        finished = false
    }

    func adjust(by seconds: TimeInterval) {
        if let end = endDate {
            let newEnd = end.addingTimeInterval(seconds)
            guard newEnd.timeIntervalSinceNow > 1 else { return }
            endDate = newEnd
            runLength = max(runLength + seconds, newEnd.timeIntervalSinceNow)
            scheduleFinish(at: newEnd)
        } else if let paused = pausedRemaining {
            pausedRemaining = max(1, paused + seconds)
            runLength = max(runLength + seconds, pausedRemaining ?? 1)
        } else {
            duration = min(max(60, duration + seconds), 24 * 3600)
        }
    }

    func setDuration(minutes: Int) {
        resetTimer()
        duration = TimeInterval(minutes * 60)
    }

    private func scheduleFinish(at end: Date) {
        finishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.timerFinished() }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, end.timeIntervalSinceNow), execute: work)
    }

    private func timerFinished() {
        endDate = nil
        finished = true
        NSSound(named: "Glass")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.finished == true { NSSound(named: "Glass")?.play() }
        }
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finished = false }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    // MARK: - Stopwatch

    func toggleStopwatch() {
        if let start = stopwatchStart {
            stopwatchPaused = Date().timeIntervalSince(start)
            stopwatchStart = nil
        } else {
            stopwatchStart = Date().addingTimeInterval(-(stopwatchPaused ?? 0))
            stopwatchPaused = nil
        }
    }

    func resetStopwatch() {
        stopwatchStart = nil
        stopwatchPaused = nil
    }

    // MARK: - Views

    func compactLeading() -> AnyView { AnyView(TimerCompactLeading(module: self)) }
    func compactTrailing() -> AnyView { AnyView(TimerCompactTrailing(module: self)) }
    func expandedView() -> AnyView { AnyView(TimerExpandedView(module: self)) }
}

func formatClock(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded(.up))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

// MARK: - Compact

private struct TimerCompactLeading: View {
    @ObservedObject var module: TimerModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Group {
            if module.finished {
                Image(systemName: "bell.fill")
                    .foregroundStyle(theme.tint(.orange))
                    .symbolEffect(.bounce, options: .repeating)
            } else if module.timerRunning || module.pausedRemaining != nil {
                Image(systemName: module.timerRunning ? "timer" : "pause.fill")
                    .foregroundStyle(theme.tint(.orange))
            } else {
                Image(systemName: "stopwatch")
                    .foregroundStyle(theme.tint(.cyan))
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
    }
}

private struct TimerCompactTrailing: View {
    @ObservedObject var module: TimerModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Group {
            if module.finished {
                Text(L("Fertig", "Done")).foregroundStyle(theme.tint(.orange))
            } else if let end = module.endDate {
                Text(timerInterval: Date()...end, countsDown: true)
                    .foregroundStyle(theme.tint(.orange))
            } else if let paused = module.pausedRemaining {
                Text(formatClock(paused)).foregroundStyle(theme.tint(.orange).opacity(0.6))
            } else if let start = module.stopwatchStart {
                Text(start, style: .timer).foregroundStyle(theme.tint(.cyan))
            }
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .lineLimit(1)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
    }
}

// MARK: - Expanded

/// A progress ring with the time on the left; mode switch, presets and the
/// controls on the right. Orange for the timer, cyan for the stopwatch.
private struct TimerExpandedView: View {
    @ObservedObject var module: TimerModule
    @Environment(\.islandTheme) private var theme
    @Namespace private var modeSwitch

    private var tint: Color { theme.tint(module.mode == .timer ? .orange : .cyan) }

    var body: some View {
        HStack(spacing: 24) {
            TimerRing(module: module, tint: tint)
                .frame(width: 122, height: 122)
            VStack(alignment: .leading, spacing: 12) {
                modePicker
                if module.mode == .timer {
                    HStack(spacing: 6) {
                        ForEach([1, 5, 10, 25], id: \.self) { minutes in
                            Chip(title: "\(minutes) min", selected: !module.timerRunning && module.pausedRemaining == nil
                                    && module.duration == TimeInterval(minutes * 60)) {
                                module.setDuration(minutes: minutes)
                            }
                        }
                        Chip(title: "−1") { module.adjust(by: -60) }
                        Chip(title: "+1") { module.adjust(by: 60) }
                    }
                } else {
                    Text(L("Läuft weiter, auch wenn die Island zu ist.", "Keeps running while the island is closed."))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(height: 26)
                }
                HStack(spacing: 10) {
                    PrimaryButton(title: primaryTitle, symbol: primarySymbol, tint: tint) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { primaryAction() }
                    }
                    RoundAction(symbol: "arrow.counterclockwise") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if module.mode == .timer { module.resetTimer() } else { module.resetStopwatch() }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach([TimerModule.Mode.timer, .stopwatch], id: \.self) { mode in
                let selected = module.mode == mode
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { module.mode = mode }
                } label: {
                    Text(mode == .timer ? L("Timer", "Timer") : L("Stoppuhr", "Stopwatch"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? .black : .white.opacity(0.65))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background {
                            if selected {
                                Capsule().fill(Color.white).matchedGeometryEffect(id: "mode", in: modeSwitch)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private var isRunning: Bool { module.mode == .timer ? module.timerRunning : module.stopwatchRunning }
    private var isPaused: Bool {
        module.mode == .timer ? module.pausedRemaining != nil : module.stopwatchPaused != nil
    }

    private var primaryTitle: String {
        if isRunning { return L("Pause", "Pause") }
        return isPaused ? L("Weiter", "Resume") : L("Start", "Start")
    }

    private var primarySymbol: String { isRunning ? "pause.fill" : "play.fill" }

    private func primaryAction() {
        if module.mode == .timer {
            if module.timerRunning { module.pauseTimer() } else { module.startTimer() }
        } else {
            module.toggleStopwatch()
        }
    }
}

/// Ring that empties as the countdown runs (or sweeps once a minute for the
/// stopwatch), with the time in the middle.
private struct TimerRing: View {
    @ObservedObject var module: TimerModule
    let tint: Color

    var body: some View {
        let running = module.mode == .timer ? module.timerRunning : module.stopwatchRunning
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !running)) { context in
            let (progress, time, caption) = values(at: context.date)
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.5), radius: 6)
                VStack(spacing: 2) {
                    Text(time)
                        .font(.system(size: time.count > 5 ? 20 : 26, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(caption)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private func values(at date: Date) -> (Double, String, String) {
        if module.mode == .stopwatch {
            let elapsed = module.stopwatchStart.map { date.timeIntervalSince($0) } ?? module.stopwatchPaused ?? 0
            let caption = module.stopwatchRunning ? L("läuft", "running")
                : (module.stopwatchPaused != nil ? L("pausiert", "paused") : L("Stoppuhr", "Stopwatch"))
            return (elapsed.truncatingRemainder(dividingBy: 60) / 60, formatStopwatch(elapsed), caption)
        }
        if module.finished { return (0, "0:00", L("Zeit ist um", "Time's up")) }
        let total = max(module.runLength, 1)
        if let end = module.endDate {
            let remaining = max(0, end.timeIntervalSince(date))
            return (remaining / total, formatClock(remaining),
                    L("bis ", "until ") + end.formatted(date: .omitted, time: .shortened))
        }
        if let paused = module.pausedRemaining {
            return (paused / total, formatClock(paused), L("pausiert", "paused"))
        }
        return (1, formatClock(module.duration), L("Timer", "Timer"))
    }

    private func formatStopwatch(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let tenths = Int((seconds - Double(total)) * 10)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d,%d", m, s, tenths)
    }
}

private struct Chip: View {
    let title: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(selected ? .black : .white.opacity(0.85))
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

private struct PrimaryButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .contentTransition(.symbolEffect(.replace))
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(Capsule().fill(tint))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

private struct RoundAction: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
    }
}
