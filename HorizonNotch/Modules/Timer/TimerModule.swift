import AppKit
import Combine
import SwiftUI

/// Countdown timer and stopwatch, shown as a flip clock. The digits are
/// redrawn once a second only while a clock runs, and the end of a
/// countdown is one scheduled work item – nothing polls.
final class TimerModule: NotchModule {
    enum Mode: String { case timer, stopwatch }

    let id = "timer"
    var title: String { L("Timer", "Timer") }
    let symbol = "timer"
    let priority = ModulePriority.timer
    let hasExpandedContent = true
    let compactWingWidth: CGFloat = 66

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
    /// Timers from the Clock app are mirrored here; the Clock app rings
    /// itself, so the mirror stays silent.
    private let systemTimers = SystemTimerWatcher()
    private(set) var mirrorsSystemTimer = false

    init() {
        systemTimers.onChange = { [weak self] status in self?.mirror(status) }
        systemTimers.start()
    }

    private func mirror(_ status: SystemTimerWatcher.Status?) {
        // The island's own countdown is never replaced.
        let ownRunning = (endDate != nil || pausedRemaining != nil) && !mirrorsSystemTimer
        guard !ownRunning else { return }
        switch status {
        case .running(let end, let length)?:
            mirrorsSystemTimer = true
            mode = .timer
            finished = false
            pausedRemaining = nil
            runLength = length
            endDate = end
            scheduleFinish(at: end)
        case .paused(let remaining, let length)?:
            mirrorsSystemTimer = true
            finishWork?.cancel()
            endDate = nil
            runLength = length
            pausedRemaining = remaining
        case nil:
            guard mirrorsSystemTimer else { return }
            mirrorsSystemTimer = false
            finishWork?.cancel()
            endDate = nil
            pausedRemaining = nil
        }
    }

    var isActive: Bool {
        endDate != nil || pausedRemaining != nil || finished || stopwatchStart != nil
    }

    var headerInfo: HeaderInfo? {
        if let end = endDate { return .countdown(end) }
        if let left = pausedRemaining { return .text(Self.clock(left)) }
        if let start = stopwatchStart { return .elapsed(start) }
        if let elapsed = stopwatchPaused { return .text(Self.clock(elapsed)) }
        return nil
    }

    /// "4:12" or "1:04:12".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Ticks exactly on the second boundaries of the countdown (or the
    /// stopwatch), so the digits change when the time does – a free-running
    /// one-second tick showed them up to a second late.
    var tickSchedule: PeriodicTimelineSchedule {
        let anchor = endDate ?? stopwatchStart ?? Date()
        let running = endDate != nil || stopwatchStart != nil
        // A hair after each boundary, so the rounding lands on the new second.
        return .periodic(from: anchor.addingTimeInterval(-ceil(anchor.timeIntervalSinceNow + 1) + 0.02), by: running ? 1 : 3600)
    }

    var timerRunning: Bool { endDate != nil }
    var stopwatchRunning: Bool { stopwatchStart != nil }

    // MARK: - Countdown

    func startTimer() {
        mirrorsSystemTimer = false
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
        mirrorsSystemTimer = false
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
            duration = min(max(1, duration + seconds), 24 * 3600)
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
        if mirrorsSystemTimer {
            // The Clock app rings; just show "Done" for a moment.
            mirrorsSystemTimer = false
            dismissWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.finished = false }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
            return
        }
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
    func bubbleView() -> AnyView { AnyView(TimerBubble(module: self)) }
    func expandedView() -> AnyView { AnyView(TimerExpandedView(module: self)) }
}

func formatClock(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded(.up))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

// MARK: - Compact

/// The digits to show right now: countdown left, paused time, stopwatch,
/// or the chosen length while idle.
private func timerDigits(_ module: TimerModule, at date: Date) -> String {
    if module.mode == .stopwatch || module.stopwatchStart != nil && module.endDate == nil && module.pausedRemaining == nil {
        let elapsed = module.stopwatchStart.map { date.timeIntervalSince($0) } ?? module.stopwatchPaused ?? 0
        return TimerModule.clock(elapsed)
    }
    if module.finished { return "0:00" }
    if let end = module.endDate { return formatClock(max(0, end.timeIntervalSince(date))) }
    if let paused = module.pausedRemaining { return formatClock(paused) }
    return formatClock(module.duration)
}

/// Beside the music: the time left (a bell when done).
private struct TimerBubble: View {
    @ObservedObject var module: TimerModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let running = module.timerRunning || module.stopwatchRunning
        HStack(spacing: 5) {
            Image(systemName: module.finished ? "bell.fill" : "timer")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.tint(.orange))
            if !module.finished {
                TimelineView(module.tickSchedule) { context in
                    Text(timerDigits(module, at: context.date))
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

/// Left of the notch: the minutes as two small flip tiles (a bell when done).
private struct TimerCompactLeading: View {
    @ObservedObject var module: TimerModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Group {
            if module.finished {
                Image(systemName: "bell.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.tint(.orange))
                    .symbolEffect(.bounce, options: .repeating)
            } else {
                CompactTiles(module: module, part: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
    }
}

/// Right of the notch: the seconds as flip tiles ("Done" when finished).
private struct TimerCompactTrailing: View {
    @ObservedObject var module: TimerModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Group {
            if module.finished {
                Text(L("Fertig", "Done"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.tint(.orange))
            } else {
                CompactTiles(module: module, part: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
    }
}

/// "08 | 15": minutes left of the notch, seconds right of it (hours join
/// the minutes when there are any).
private struct CompactTiles: View {
    enum Part { case leading, trailing }
    @ObservedObject var module: TimerModule
    let part: Part

    var body: some View {
        let running = module.timerRunning || module.stopwatchRunning
        TimelineView(module.tickSchedule) { context in
            let pieces = timerDigits(module, at: context.date).split(separator: ":").map(String.init)
            let text = part == .leading ? pieces.dropLast().joined(separator: ":") : (pieces.last ?? "")
            HStack(spacing: 2) {
                ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                    FlipTile(character: character, size: .compact)
                }
            }
            .opacity(module.pausedRemaining != nil || module.stopwatchPaused != nil ? 0.55 : 1)
        }
    }
}

// MARK: - Expanded

/// Like a station clock: every digit on its own flip card, flipping as it
/// changes. Pause/resume and cancel on the right; presets below while idle.
private struct TimerExpandedView: View {
    @ObservedObject var module: TimerModule
    @Environment(\.islandTheme) private var theme
    @Namespace private var modeSwitch

    private var tint: Color { theme.tint(module.mode == .timer ? .orange : .cyan) }
    private var isRunning: Bool { module.mode == .timer ? module.timerRunning : module.stopwatchRunning }
    private var isPaused: Bool {
        module.mode == .timer ? module.pausedRemaining != nil : module.stopwatchPaused != nil
    }
    private var isIdle: Bool { !isRunning && !isPaused && !(module.mode == .timer && module.finished) }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(spacing: 10) {
                TimelineView(module.tickSchedule) { context in
                    let digits = timerDigits(module, at: context.date)
                    let characters = Array(digits)
                    HStack(spacing: 6) {
                        ForEach(characters.indices, id: \.self) { index in
                            if characters[index] == ":" {
                                Text(":")
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .offset(y: -3)
                            } else {
                                let size: FlipTile.Size = digits.count > 5 ? .medium : .large
                                FlipTile(character: characters[index], size: size)
                                    .contentShape(Rectangle())
                                    // Upper, lighter half +1; lower, dark grey half −1.
                                    .onTapGesture(coordinateSpace: .local) { location in
                                        tapDigit(at: index, in: characters, up: location.y < size.height / 2)
                                    }
                                    .help(module.mode == .timer ? L("Oben klicken: +1 · unten klicken: −1",
                                                                    "Click the top: +1 · the bottom: −1") : "")
                            }
                        }
                    }
                    .opacity(isPaused ? 0.6 : 1)
                }
                caption
                    .frame(height: 24)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                modePicker
                HStack(spacing: 12) {
                    // Pause / resume (start while idle).
                    RoundAction(symbol: isRunning ? "pause.fill" : "play.fill", size: 46, fill: tint, foreground: .black) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { primaryAction() }
                    }
                    .help(isRunning ? L("Pause", "Pause") : (isPaused ? L("Weiter", "Resume") : L("Start", "Start")))
                    // Cancel.
                    RoundAction(symbol: "xmark", size: 46) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if module.mode == .timer { module.resetTimer() } else { module.resetStopwatch() }
                        }
                    }
                    .help(L("Abbrechen", "Cancel"))
                    .opacity(isIdle ? 0.35 : 1)
                    .disabled(isIdle)
                }
            }
        }
    }

    /// Presets while idle; otherwise what is happening.
    @ViewBuilder
    private var caption: some View {
        if module.mode == .timer && isIdle {
            HStack(spacing: 6) {
                ForEach([1, 5, 10, 25], id: \.self) { minutes in
                    Chip(title: "\(minutes) min", selected: module.duration == TimeInterval(minutes * 60)) {
                        module.setDuration(minutes: minutes)
                    }
                }
                Chip(title: "−1") { module.adjust(by: -60) }
                Chip(title: "+1") { module.adjust(by: 60) }
            }
        } else {
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
    }

    private var statusText: String {
        if module.mode == .stopwatch {
            return isRunning ? L("Stoppuhr läuft", "Stopwatch running")
                : (isPaused ? L("Pausiert", "Paused") : L("Stoppuhr", "Stopwatch"))
        }
        if module.finished { return L("Zeit ist um", "Time's up") }
        if let end = module.endDate {
            return L("Läuft · bis ", "Running · until ") + end.formatted(date: .omitted, time: .shortened)
        }
        return isPaused ? L("Pausiert", "Paused") : ""
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
                        .padding(.horizontal, 11)
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

    /// A click on a digit changes it by one at its place: seconds 1, tens
    /// of seconds 10, minutes 60 and so on – up on the upper half, down on
    /// the lower one (⌥ turns it round).
    private func tapDigit(at index: Int, in characters: [Character], up: Bool) {
        guard module.mode == .timer, !module.finished else { return }
        // Seconds per step of each place, counted from the right.
        let places: [TimeInterval] = [1, 10, 60, 600, 3600, 36000]
        let digitsAfter = characters[(index + 1)...].filter { $0 != ":" }.count
        guard digitsAfter < places.count else { return }
        let step = places[digitsAfter]
        let sign: TimeInterval = up != NSEvent.modifierFlags.contains(.option) ? 1 : -1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { module.adjust(by: sign * step) }
    }

    private func primaryAction() {
        if module.mode == .timer {
            if module.timerRunning { module.pauseTimer() } else { module.startTimer() }
        } else {
            module.toggleStopwatch()
        }
    }
}

/// One flip card: a dark tile with a lighter upper half, a hairline across
/// the middle and the digit, which rolls over when it changes.
private struct FlipTile: View {
    enum Size: Equatable {
        case compact, medium, large
        var width: CGFloat { switch self { case .compact: 12; case .medium: 44; case .large: 56 } }
        var height: CGFloat { switch self { case .compact: 19; case .medium: 62; case .large: 74 } }
        var font: CGFloat { switch self { case .compact: 12; case .medium: 40; case .large: 50 } }
        var radius: CGFloat { switch self { case .compact: 3.5; case .medium: 9; case .large: 11 } }
    }

    let character: Character
    let size: Size

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        ZStack {
            shape.fill(Color(white: 0.11))
            VStack(spacing: 0) {
                Color(white: 0.15)
                Color.clear
            }
            .clipShape(shape)
            Text(String(character))
                .font(.system(size: size.font, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
            Rectangle()
                .fill(Color.black)
                .frame(height: size == .compact ? 0.5 : 1.5)
        }
        .frame(width: size.width, height: size.height)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: character)
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

private struct RoundAction: View {
    let symbol: String
    var size: CGFloat = 34
    var fill: Color = Color.white.opacity(0.14)
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(foreground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
    }
}
